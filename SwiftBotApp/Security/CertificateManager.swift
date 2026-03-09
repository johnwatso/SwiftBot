import Foundation
import Crypto
import SwiftASN1
import X509
import Darwin

actor CertificateManager {
    enum ValidationStatus: String, Sendable {
        case success
        case warning
        case error
    }

    struct ValidationItem: Identifiable, Sendable {
        let id: String
        let title: String
        let status: ValidationStatus
        let detail: String?
    }

    struct AutomaticHTTPSValidation: Sendable {
        let items: [ValidationItem]
        let canCreateDNSRecord: Bool
        let isReadyForCertificateRequest: Bool
        let isAwaitingDNSPropagation: Bool
    }

    struct DNSRecordCreation: Sendable {
        let type: String
        let name: String
        let content: String
        let zoneName: String
    }

    private struct AutomaticHTTPSRecordTarget: Sendable {
        let type: String
        let content: String
        let detail: String
    }

    struct StoredCertificate: Sendable {
        let certificateURL: URL
        let privateKeyURL: URL
        let expiresAt: Date
        let wasRenewed: Bool
    }

    struct ImportedCertificate: Sendable {
        let certificateURL: URL
        let privateKeyURL: URL
        let expiresAt: Date
        let reloadToken: String
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
        case inactiveCloudflareToken
        case certificateExpired(String)
        case missingImportedCertificateFile
        case missingImportedPrivateKeyFile
        case importedCertificateFileUnreadable(String)
        case importedPrivateKeyFileUnreadable(String)
        case importedChainFileUnreadable(String)
        case unableToDetermineDNSRecordTarget
        case publicIPAddressLookupFailed

        var errorDescription: String? {
            switch self {
            case .missingHTTPSDomain:
                return "HTTPS is enabled for the Admin Web UI, but no domain is configured."
            case .invalidStoredCertificate(let message):
                return message
            case .missingCloudflareToken:
                return "A Cloudflare API token is required to provision or renew the Admin Web UI certificate."
            case .inactiveCloudflareToken:
                return "Cloudflare reports that the configured API token is not active."
            case .certificateExpired(let domain):
                return "The stored Admin Web UI certificate for \(domain) has expired."
            case .missingImportedCertificateFile:
                return "Select a PEM certificate file to use imported HTTPS."
            case .missingImportedPrivateKeyFile:
                return "Select a PEM private key file to use imported HTTPS."
            case .importedCertificateFileUnreadable(let path):
                return "SwiftBot could not read the imported certificate file at \(path)."
            case .importedPrivateKeyFileUnreadable(let path):
                return "SwiftBot could not read the imported private key file at \(path)."
            case .importedChainFileUnreadable(let path):
                return "SwiftBot could not read the imported certificate chain file at \(path)."
            case .unableToDetermineDNSRecordTarget:
                return "SwiftBot could not determine a public DNS target automatically. Set a public base URL host or use a routable bind address, then try again."
            case .publicIPAddressLookupFailed:
                return "SwiftBot could not detect the machine's public IP address automatically."
            }
        }
    }

    private let fileManager = FileManager.default
    private let renewalLeadTime: TimeInterval = 30 * 24 * 60 * 60
    private let certificateURL: URL
    private let privateKeyURL: URL
    private let metadataURL: URL
    private let importedCertificateURL: URL
    private let importedPrivateKeyURL: URL
    private let importedChainURL: URL
    private let importedFullChainURL: URL
    private let certificatesDirectoryURL: URL
    private let acmeClient: ACMEClient

    init() {
        let directory = SwiftBotStorage.folderURL().appendingPathComponent("certs", isDirectory: true)
        self.certificatesDirectoryURL = directory
        self.certificateURL = directory.appendingPathComponent("cert.pem")
        self.privateKeyURL = directory.appendingPathComponent("key.pem")
        self.metadataURL = directory.appendingPathComponent("metadata.json")
        self.importedCertificateURL = directory.appendingPathComponent("imported-cert.pem")
        self.importedPrivateKeyURL = directory.appendingPathComponent("imported-key.pem")
        self.importedChainURL = directory.appendingPathComponent("imported-chain.pem")
        self.importedFullChainURL = directory.appendingPathComponent("imported-fullchain.pem")
        self.acmeClient = ACMEClient(storageDirectoryURL: directory)
    }

    func validateAutomaticHTTPSConfiguration(
        for domain: String,
        cloudflareAPIToken: String
    ) async -> AutomaticHTTPSValidation {
        let normalizedDomain = normalizeDomain(domain)
        let trimmedToken = cloudflareAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)

        var tokenIsValid = false
        var zoneFound = false
        var dnsRecordFound = false
        var domainResolves = false
        var matchedZoneID: String?
        var matchedZoneName: String?
        var cloudflareItem = ValidationItem(
            id: "cloudflare-access",
            title: "Cloudflare API access verified",
            status: .warning,
            detail: nil
        )
        var resolutionItem = ValidationItem(
            id: "domain-resolves",
            title: "Domain resolves",
            status: .warning,
            detail: nil
        )
        var dnsRecordItem = ValidationItem(
            id: "dns-record-present",
            title: "DNS record present",
            status: .warning,
            detail: nil
        )

        if trimmedToken.isEmpty {
            cloudflareItem = ValidationItem(
                id: "cloudflare-access",
                title: "Cloudflare API access verified",
                status: .error,
                detail: "Cloudflare verification failed. Check your API token."
            )
        } else {
            let provider = CloudflareDNSProvider(apiToken: trimmedToken)
            do {
                tokenIsValid = try await provider.verifyAPIToken()
                if tokenIsValid, let zone = try await provider.findZone(for: normalizedDomain) {
                    zoneFound = true
                    matchedZoneID = zone.id
                    matchedZoneName = zone.name
                    cloudflareItem = ValidationItem(
                        id: "cloudflare-access",
                        title: "Cloudflare API access verified",
                        status: .success,
                        detail: "Cloudflare token is active and zone \(zone.name) is available."
                    )
                } else if tokenIsValid {
                    cloudflareItem = ValidationItem(
                        id: "cloudflare-access",
                        title: "Cloudflare API access verified",
                        status: .error,
                        detail: "Cloudflare zone lookup failed. Check that the domain is in your Cloudflare account."
                    )
                } else {
                    cloudflareItem = ValidationItem(
                        id: "cloudflare-access",
                        title: "Cloudflare API access verified",
                        status: .error,
                        detail: "Cloudflare verification failed. Check your API token."
                    )
                }
            } catch {
                cloudflareItem = ValidationItem(
                    id: "cloudflare-access",
                    title: "Cloudflare API access verified",
                    status: .error,
                    detail: "Cloudflare verification failed. Check your API token."
                )
            }
        }

        if normalizedDomain.isEmpty {
            resolutionItem = ValidationItem(
                id: "domain-resolves",
                title: "Domain resolves",
                status: .error,
                detail: "Enter an HTTPS domain to validate DNS resolution."
            )
        } else {
            let resolution = await Task.detached(priority: .userInitiated) {
                Self.resolveHostname(normalizedDomain)
            }.value
            domainResolves = resolution.success
            resolutionItem = ValidationItem(
                id: "domain-resolves",
                title: "Domain resolves",
                status: resolution.success ? .success : .warning,
                detail: resolution.detail
            )
        }

        if tokenIsValid, zoneFound, !normalizedDomain.isEmpty {
            let provider = CloudflareDNSProvider(apiToken: trimmedToken)
            do {
                if let matchedZoneID, let matchedZoneName {
                    if let record = try await provider.findDNSRecord(
                        zoneID: matchedZoneID,
                        hostname: normalizedDomain,
                        allowedTypes: Self.hostnameRecordTypes
                    ) {
                        dnsRecordFound = true
                        dnsRecordItem = ValidationItem(
                            id: "dns-record-present",
                            title: "DNS record present",
                            status: .success,
                            detail: "Found \(record.type) \(record.content) for \(normalizedDomain) in \(matchedZoneName)."
                        )
                    } else {
                        dnsRecordItem = ValidationItem(
                            id: "dns-record-present",
                            title: "DNS record present",
                            status: .warning,
                            detail: "DNS record missing."
                        )
                    }
                }
            } catch {
                cloudflareItem = ValidationItem(
                    id: "cloudflare-access",
                    title: "Cloudflare API access verified",
                    status: .error,
                    detail: "Cloudflare DNS lookup failed. Check that the zone is accessible."
                )
                dnsRecordItem = ValidationItem(
                    id: "dns-record-present",
                    title: "DNS record present",
                    status: .warning,
                    detail: "Skipped until Cloudflare access is verified."
                )
                zoneFound = false
                dnsRecordFound = false
            }
        } else {
            dnsRecordItem = ValidationItem(
                id: "dns-record-present",
                title: "DNS record present",
                status: .warning,
                detail: "Skipped until Cloudflare access is verified."
            )
        }

        let readyStatus = Self.validationSummaryState(
            tokenIsValid: tokenIsValid,
            zoneFound: zoneFound,
            dnsRecordFound: dnsRecordFound,
            hostnameResolves: domainResolves
        )

        return AutomaticHTTPSValidation(
            items: [
                cloudflareItem,
                resolutionItem,
                dnsRecordItem,
                ValidationItem(
                    id: "ready",
                    title: "Ready for certificate request",
                    status: readyStatus,
                    detail: validationSummaryDetail(
                        domain: normalizedDomain,
                        matchedZoneName: matchedZoneName,
                        tokenIsValid: tokenIsValid,
                        zoneFound: zoneFound,
                        dnsRecordFound: dnsRecordFound,
                        hostnameResolves: domainResolves
                    )
                )
            ],
            canCreateDNSRecord: tokenIsValid && zoneFound && !dnsRecordFound && !normalizedDomain.isEmpty,
            isReadyForCertificateRequest: readyStatus == .success,
            isAwaitingDNSPropagation: tokenIsValid && zoneFound && dnsRecordFound && !domainResolves
        )
    }

    func createAutomaticHTTPSDNSRecord(
        for domain: String,
            cloudflareAPIToken: String,
            publicBaseURL: String,
            bindHost: String
    ) async throws -> DNSRecordCreation {
        let normalizedDomain = normalizeDomain(domain)
        guard !normalizedDomain.isEmpty else {
            throw Error.missingHTTPSDomain
        }

        let trimmedToken = cloudflareAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw Error.missingCloudflareToken
        }

        let provider = CloudflareDNSProvider(apiToken: trimmedToken)
        let tokenIsValid = try await provider.verifyAPIToken()
        guard tokenIsValid else {
            throw Error.inactiveCloudflareToken
        }

        let zone: CloudflareDNSProvider.ZoneSummary
        do {
            guard let matchedZone = try await provider.findZone(for: normalizedDomain) else {
                throw CloudflareDNSProvider.Error.zoneNotFound(normalizedDomain)
            }
            zone = matchedZone
        } catch let error as CloudflareDNSProvider.Error {
            switch error {
            case .zoneNotFound:
                throw error
            case .invalidDomain, .apiFailed:
                throw CloudflareDNSProvider.Error.apiFailed("Cloudflare zone lookup failed. Check that the domain is in your Cloudflare account.")
            }
        } catch {
            throw CloudflareDNSProvider.Error.zoneNotFound(normalizedDomain)
        }

        let existingRecord: CloudflareDNSProvider.DNSRecordSummary?
        do {
            existingRecord = try await provider.findDNSRecord(
                zoneID: zone.id,
                hostname: normalizedDomain,
                allowedTypes: Self.hostnameRecordTypes
            )
        } catch {
            throw CloudflareDNSProvider.Error.apiFailed("Cloudflare DNS lookup failed. Check that the token has DNS read access.")
        }

        if let existing = existingRecord {
            return DNSRecordCreation(
                type: existing.type,
                name: existing.name,
                content: existing.content,
                zoneName: zone.name
            )
        }

        let target = try await preferredAutomaticHTTPSRecordTarget(
            domain: normalizedDomain,
            publicBaseURL: publicBaseURL,
            bindHost: bindHost
        )
        let record: CloudflareDNSProvider.DNSRecordSummary
        do {
            record = try await provider.createDNSRecord(
                zoneID: zone.id,
                type: target.type,
                name: normalizedDomain,
                content: target.content,
                ttl: 120,
                proxied: false
            )
        } catch {
            throw CloudflareDNSProvider.Error.apiFailed("Cloudflare DNS record creation failed. Check that the token has DNS edit access.")
        }

        return DNSRecordCreation(
            type: record.type,
            name: record.name,
            content: record.content,
            zoneName: zone.name
        )
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

    func prepareImportedCertificate(
        certificateFilePath: String,
        privateKeyFilePath: String,
        certificateChainFilePath: String?
    ) throws -> ImportedCertificate {
        let normalizedCertificatePath = certificateFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCertificatePath.isEmpty else {
            throw Error.missingImportedCertificateFile
        }

        let normalizedPrivateKeyPath = privateKeyFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrivateKeyPath.isEmpty else {
            throw Error.missingImportedPrivateKeyFile
        }

        let normalizedChainPath = certificateChainFilePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let certificatePEM = try readImportedPEMFile(at: normalizedCertificatePath, error: .importedCertificateFileUnreadable(normalizedCertificatePath))
        let privateKeyPEM = try readImportedPEMFile(at: normalizedPrivateKeyPath, error: .importedPrivateKeyFileUnreadable(normalizedPrivateKeyPath))
        let chainPEM = try normalizedChainPath.isEmpty
            ? ""
            : readImportedPEMFile(at: normalizedChainPath, error: .importedChainFileUnreadable(normalizedChainPath))

        let expiresAt = try leafCertificateExpirationDate(from: certificatePEM)
        let fullChainPEM = concatenatePEMBlocks(primary: certificatePEM, additional: chainPEM)

        try ensureCertificatesDirectory()
        try certificatePEM.write(to: importedCertificateURL, atomically: true, encoding: .utf8)
        try privateKeyPEM.write(to: importedPrivateKeyURL, atomically: true, encoding: .utf8)
        try fullChainPEM.write(to: importedFullChainURL, atomically: true, encoding: .utf8)

        if chainPEM.isEmpty {
            try? fileManager.removeItem(at: importedChainURL)
        } else {
            try chainPEM.write(to: importedChainURL, atomically: true, encoding: .utf8)
        }

        return ImportedCertificate(
            certificateURL: importedFullChainURL,
            privateKeyURL: importedPrivateKeyURL,
            expiresAt: expiresAt,
            reloadToken: importedCertificateReloadToken(
                certificatePEM: fullChainPEM,
                privateKeyPEM: privateKeyPEM
            )
        )
    }

    static func shouldRenew(expiresAt: Date, referenceDate: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(referenceDate) < 30 * 24 * 60 * 60
    }

    private static let hostnameRecordTypes: Set<String> = ["A", "AAAA", "CNAME"]

    static func validationSummaryState(
        tokenIsValid: Bool,
        zoneFound: Bool,
        dnsRecordFound: Bool,
        hostnameResolves: Bool
    ) -> ValidationStatus {
        guard tokenIsValid, zoneFound, dnsRecordFound else {
            return .error
        }

        return hostnameResolves ? .success : .warning
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

    private func readImportedPEMFile(at path: String, error: Error) throws -> String {
        guard let pem = try? String(contentsOfFile: path, encoding: .utf8),
              !pem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw error
        }
        return pem
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

    private func concatenatePEMBlocks(primary: String, additional: String) -> String {
        let trimmedPrimary = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAdditional = additional.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedAdditional.isEmpty else {
            return trimmedPrimary + "\n"
        }

        return trimmedPrimary + "\n" + trimmedAdditional + "\n"
    }

    private func importedCertificateReloadToken(certificatePEM: String, privateKeyPEM: String) -> String {
        let combined = Data((certificatePEM + "\n" + privateKeyPEM).utf8)
        let digest = SHA256.hash(data: combined)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func shouldRenew(_ expiresAt: Date) -> Bool {
        expiresAt.timeIntervalSince(Date()) < renewalLeadTime
    }

    private func normalizeDomain(_ domain: String) -> String {
        let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let url = URL(string: trimmed), let host = url.host {
            return host.lowercased()
        }

        let normalized = trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: " ", with: "")
            .lowercased()

        if let slashIndex = normalized.firstIndex(of: "/") {
            return String(normalized[..<slashIndex])
        }

        return normalized
    }

    private func preferredAutomaticHTTPSRecordTarget(
        domain: String,
        publicBaseURL: String,
        bindHost: String
    ) async throws -> AutomaticHTTPSRecordTarget {
        if let target = Self.recordTarget(
            from: Self.hostCandidate(from: publicBaseURL),
            domain: domain,
            sourceLabel: "public base URL"
        ) {
            return target
        }

        if let target = Self.recordTarget(
            from: bindHost.trimmingCharacters(in: .whitespacesAndNewlines),
            domain: domain,
            sourceLabel: "bind address"
        ) {
            return target
        }

        let publicIPAddress = try await Self.resolvePublicIPAddress()
        if let target = Self.recordTarget(from: publicIPAddress, domain: domain, sourceLabel: "detected public IP") {
            return target
        }

        throw Error.unableToDetermineDNSRecordTarget
    }

    private func validationSummaryDetail(
        domain: String,
        matchedZoneName: String?,
        tokenIsValid: Bool,
        zoneFound: Bool,
        dnsRecordFound: Bool,
        hostnameResolves: Bool
    ) -> String {
        switch Self.validationSummaryState(
            tokenIsValid: tokenIsValid,
            zoneFound: zoneFound,
            dnsRecordFound: dnsRecordFound,
            hostnameResolves: hostnameResolves
        ) {
        case .success:
            if let matchedZoneName {
                return "\(domain) is ready for certificate provisioning through Cloudflare zone \(matchedZoneName)."
            }
            return "\(domain) is ready for certificate provisioning."
        case .warning:
            return "Certificate request not ready. DNS propagation is still in progress."
        case .error:
            return "Certificate request not ready."
        }
    }

    nonisolated private static func hostCandidate(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let url = URL(string: trimmed), let host = url.host {
            return host.lowercased()
        }

        return trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }

    nonisolated private static func recordTarget(
        from candidate: String,
        domain: String,
        sourceLabel: String
    ) -> AutomaticHTTPSRecordTarget? {
        let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        guard normalized.caseInsensitiveCompare(domain) != .orderedSame else { return nil }
        guard !isLocalOnlyHost(normalized) else { return nil }

        if isIPv4Address(normalized) {
            guard !isPrivateIPv4Address(normalized) else { return nil }
            return AutomaticHTTPSRecordTarget(
                type: "A",
                content: normalized,
                detail: "Using \(normalized) from the \(sourceLabel)."
            )
        }

        if isIPv6Address(normalized) {
            guard !isPrivateIPv6Address(normalized) else { return nil }
            return AutomaticHTTPSRecordTarget(
                type: "AAAA",
                content: normalized,
                detail: "Using \(normalized) from the \(sourceLabel)."
            )
        }

        return AutomaticHTTPSRecordTarget(
            type: "CNAME",
            content: normalized,
            detail: "Using \(normalized) from the \(sourceLabel)."
        )
    }

    nonisolated private static func isLocalOnlyHost(_ host: String) -> Bool {
        host == "localhost" || host.hasSuffix(".local")
    }

    nonisolated private static func isIPv4Address(_ host: String) -> Bool {
        var address = in_addr()
        return host.withCString { inet_pton(AF_INET, $0, &address) } == 1
    }

    nonisolated private static func isIPv6Address(_ host: String) -> Bool {
        var address = in6_addr()
        return host.withCString { inet_pton(AF_INET6, $0, &address) } == 1
    }

    nonisolated private static func isPrivateIPv4Address(_ host: String) -> Bool {
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }

        switch (octets[0], octets[1]) {
        case (0, _), (10, _), (127, _):
            return true
        case (169, 254):
            return true
        case (172, 16...31):
            return true
        case (192, 168):
            return true
        default:
            return false
        }
    }

    nonisolated private static func isPrivateIPv6Address(_ host: String) -> Bool {
        let normalized = host.lowercased()
        return normalized == "::1"
            || normalized.hasPrefix("fc")
            || normalized.hasPrefix("fd")
            || normalized.hasPrefix("fe80:")
    }

    nonisolated private static func resolvePublicIPAddress() async throws -> String {
        let endpoints = [
            URL(string: "https://api64.ipify.org?format=text"),
            URL(string: "https://api.ipify.org?format=text")
        ].compactMap { $0 }

        for endpoint in endpoints {
            do {
                let (data, response) = try await URLSession.shared.data(from: endpoint)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    continue
                }

                let candidate = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()

                if isIPv4Address(candidate) || isIPv6Address(candidate) {
                    return candidate
                }
            } catch {
                continue
            }
        }

        throw Error.publicIPAddressLookupFailed
    }

    nonisolated private static func resolveHostname(_ hostname: String) -> (success: Bool, detail: String) {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: 0,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var resultsPointer: UnsafeMutablePointer<addrinfo>?

        let status = hostname.withCString { hostCString in
            getaddrinfo(hostCString, nil, &hints, &resultsPointer)
        }

        guard status == 0, let firstResult = resultsPointer else {
            return (false, "Domain could not be resolved by system DNS.")
        }
        defer { freeaddrinfo(firstResult) }

        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = firstResult

        while let current = cursor {
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let nameInfoStatus = getnameinfo(
                current.pointee.ai_addr,
                current.pointee.ai_addrlen,
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            if nameInfoStatus == 0 {
                addresses.append(String(cString: hostBuffer))
            }

            cursor = current.pointee.ai_next
        }

        let uniqueAddresses = Array(Set(addresses)).sorted()
        guard !uniqueAddresses.isEmpty else {
            return (false, "Domain could not be resolved by system DNS.")
        }

        return (true, "Resolved \(hostname) to \(uniqueAddresses.joined(separator: ", ")).")
    }
}
