import Foundation
import Crypto
import SwiftASN1
import X509

actor CertificateManager {
    struct StoredCertificate: Sendable {
        let certificateURL: URL
        let privateKeyURL: URL
        let expiresAt: Date
        let wasRenewed: Bool
    }

    struct CertificateMetadata: Codable, Sendable {
        let domain: String
        let expiresAt: Date
        let renewedAt: Date
    }

    enum Error: LocalizedError {
        case missingHTTPSDomain
        case invalidStoredCertificate(String)
        case missingCloudflareToken
        case certificateExpired(String)

        var errorDescription: String? {
            switch self {
            case .missingHTTPSDomain:
                return "HTTPS is enabled for the Admin Web UI, but no domain is configured."
            case .invalidStoredCertificate(let message):
                return message
            case .missingCloudflareToken:
                return "A Cloudflare API token is required to provision or renew the Admin Web UI certificate."
            case .certificateExpired(let domain):
                return "The stored Admin Web UI certificate for \(domain) has expired."
            }
        }
    }

    private let fileManager = FileManager.default
    private let renewalLeadTime: TimeInterval = 30 * 24 * 60 * 60
    private let certificateURL: URL
    private let privateKeyURL: URL
    private let metadataURL: URL
    private let certificatesDirectoryURL: URL
    private let acmeClient: ACMEClient

    init() {
        let directory = SwiftBotStorage.folderURL().appendingPathComponent("certs", isDirectory: true)
        self.certificatesDirectoryURL = directory
        self.certificateURL = directory.appendingPathComponent("cert.pem")
        self.privateKeyURL = directory.appendingPathComponent("key.pem")
        self.metadataURL = directory.appendingPathComponent("metadata.json")
        self.acmeClient = ACMEClient(storageDirectoryURL: directory)
    }

    func ensureCertificate(
        for domain: String,
        cloudflareAPIToken: String,
        log: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> StoredCertificate {
        let normalizedDomain = normalizeDomain(domain)
        guard !normalizedDomain.isEmpty else {
            throw Error.missingHTTPSDomain
        }

        try ensureCertificatesDirectory()

        let existing = try loadStoredCertificate(for: normalizedDomain)
        if let existing, !shouldRenew(existing.expiresAt) {
            return existing
        }

        let trimmedToken = cloudflareAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedToken.isEmpty {
            if let existing {
                if existing.expiresAt > Date() {
                    await log("⚠️ Admin Web UI HTTPS renewal skipped because the Cloudflare token is missing. Using the existing certificate until \(existing.expiresAt.formatted()).")
                    return existing
                }
                throw Error.certificateExpired(normalizedDomain)
            }
            throw Error.missingCloudflareToken
        }

        do {
            let issued = try await provisionCertificate(
                for: normalizedDomain,
                cloudflareAPIToken: trimmedToken,
                log: log
            )
            return issued
        } catch {
            if let existing, existing.expiresAt > Date() {
                await log("⚠️ Admin Web UI certificate renewal failed (\(error.localizedDescription)). Continuing with the existing certificate until \(existing.expiresAt.formatted()).")
                return existing
            }
            throw error
        }
    }

    func currentCertificate(for domain: String) throws -> StoredCertificate? {
        let normalizedDomain = normalizeDomain(domain)
        guard !normalizedDomain.isEmpty else { return nil }
        return try loadStoredCertificate(for: normalizedDomain)
    }

    static func shouldRenew(expiresAt: Date, referenceDate: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(referenceDate) < 30 * 24 * 60 * 60
    }

    private func provisionCertificate(
        for domain: String,
        cloudflareAPIToken: String,
        log: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> StoredCertificate {
        let dnsProvider = CloudflareDNSProvider(apiToken: cloudflareAPIToken)
        let privateKey = P256.Signing.PrivateKey()

        await log("🔏 Provisioning Let's Encrypt certificate for \(domain)")
        let issued = try await acmeClient.issueCertificate(
            for: domain,
            certificatePrivateKey: privateKey,
            dnsProvider: dnsProvider,
            log: log
        )

        let expiresAt = try leafCertificateExpirationDate(from: issued.certificatePEM)
        try saveCertificateArtifacts(
            certificatePEM: issued.certificatePEM,
            privateKeyPEM: privateKey.pemRepresentation,
            domain: domain,
            expiresAt: expiresAt
        )

        await log("💾 Saved Admin Web UI certificate to \(certificateURL.path)")
        return StoredCertificate(
            certificateURL: certificateURL,
            privateKeyURL: privateKeyURL,
            expiresAt: expiresAt,
            wasRenewed: true
        )
    }

    private func loadStoredCertificate(for domain: String) throws -> StoredCertificate? {
        guard fileManager.fileExists(atPath: certificateURL.path),
              fileManager.fileExists(atPath: privateKeyURL.path) else {
            return nil
        }

        let pemString = try String(contentsOf: certificateURL, encoding: .utf8)
        let certificate = try leafCertificate(from: pemString)
        let expiresAt = certificate.notValidAfter

        guard expiresAt > Date() else {
            throw Error.certificateExpired(domain)
        }

        guard certificateMatches(certificate, domain: domain) else {
            return nil
        }

        return StoredCertificate(
            certificateURL: certificateURL,
            privateKeyURL: privateKeyURL,
            expiresAt: expiresAt,
            wasRenewed: false
        )
    }

    private func saveCertificateArtifacts(
        certificatePEM: String,
        privateKeyPEM: String,
        domain: String,
        expiresAt: Date
    ) throws {
        try ensureCertificatesDirectory()

        try certificatePEM.write(to: certificateURL, atomically: true, encoding: .utf8)
        try privateKeyPEM.write(to: privateKeyURL, atomically: true, encoding: .utf8)

        let metadata = CertificateMetadata(domain: domain, expiresAt: expiresAt, renewedAt: Date())
        let metadataData = try JSONEncoder().encode(metadata)
        try metadataData.write(to: metadataURL, options: .atomic)
    }

    private func leafCertificateExpirationDate(from certificatePEM: String) throws -> Date {
        try leafCertificate(from: certificatePEM).notValidAfter
    }

    private func leafCertificate(from certificatePEM: String) throws -> Certificate {
        let documents = try PEMDocument.parseMultiple(pemString: certificatePEM)
        guard let firstCertificate = documents.first else {
            throw Error.invalidStoredCertificate("The stored Admin Web UI certificate PEM file is empty.")
        }
        return try Certificate(derEncoded: firstCertificate.derBytes)
    }

    private func certificateMatches(_ certificate: Certificate, domain: String) -> Bool {
        if let subjectAlternativeNames = try? certificate.extensions.subjectAlternativeNames {
            for name in subjectAlternativeNames {
                if case .dnsName(let dnsName) = name,
                   String(describing: dnsName).caseInsensitiveCompare(domain) == .orderedSame {
                    return true
                }
            }
        }

        return certificate.subject.description
            .lowercased()
            .contains("cn=\(domain.lowercased())")
    }

    private func ensureCertificatesDirectory() throws {
        try fileManager.createDirectory(
            at: certificatesDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    private func shouldRenew(_ expiresAt: Date) -> Bool {
        expiresAt.timeIntervalSince(Date()) < renewalLeadTime
    }

    private func normalizeDomain(_ domain: String) -> String {
        domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
