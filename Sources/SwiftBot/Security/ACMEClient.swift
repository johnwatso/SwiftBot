import Foundation
import Crypto
import SwiftASN1
import X509

actor ACMEClient {
    static let publicDNSPropagationResolvers: [URL] = [
        URL(string: "https://cloudflare-dns.com/dns-query")!,
        URL(string: "https://dns.google/resolve")!
    ]

    struct IssuedCertificate: Sendable {
        let certificatePEM: String
    }

    enum Error: LocalizedError {
        case invalidResponse
        case missingReplayNonce
        case missingAccountLocation
        case missingAuthorizations
        case dnsChallengeUnavailable(String)
        case dnsPropagationTimedOut(String)
        case orderFailed(String)
        case challengeFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "The ACME server returned an invalid response."
            case .missingReplayNonce:
                return "The ACME server did not return a replay nonce."
            case .missingAccountLocation:
                return "The ACME server did not return an account location."
            case .missingAuthorizations:
                return "The ACME order did not contain any authorization URLs."
            case .dnsChallengeUnavailable(let domain):
                return "No dns-01 ACME challenge was available for \(domain)."
            case .dnsPropagationTimedOut(let recordName):
                return "SwiftBot could not verify the DNS challenge record for \(recordName) via public DNS yet. Wait for propagation, then try again."
            case .orderFailed(let message):
                return message
            case .challengeFailed(let message):
                return message
            }
        }
    }

    private struct Directory: Decodable {
        let newNonce: URL
        let newAccount: URL
        let newOrder: URL
    }

    private struct AccountPayload: Encodable {
        let termsOfServiceAgreed = true
    }

    private struct Identifier: Codable, Sendable {
        let type: String
        let value: String
    }

    private struct NewOrderPayload: Encodable {
        let identifiers: [Identifier]
    }

    private struct OrderResponse: Decodable {
        let status: String
        let authorizations: [URL]?
        let finalize: URL
        let certificate: URL?
        let error: ProblemDocument?
    }

    private struct AuthorizationResponse: Decodable {
        let identifier: Identifier
        let status: String
        let wildcard: Bool?
        let challenges: [Challenge]
    }

    private struct Challenge: Decodable {
        let type: String
        let url: URL
        let status: String?
        let token: String
        let error: ProblemDocument?
    }

    private struct FinalizePayload: Encodable {
        let csr: String
    }

    private struct EmptyJSONPayload: Encodable {}

    private struct DNSQueryResponse: Decodable {
        let status: Int?
        let answer: [DNSAnswer]?

        private enum CodingKeys: String, CodingKey {
            case status = "Status"
            case answer = "Answer"
        }
    }

    private struct DNSAnswer: Decodable {
        let type: Int?
        let data: String?
    }

    private struct AccountMetadata: Codable {
        var keyID: String
    }

    private struct JWK: Encodable {
        let crv = "P-256"
        let kty = "EC"
        let x: String
        let y: String
    }

    private struct ProtectedHeader: Encodable {
        let alg = "ES256"
        let nonce: String
        let url: String
        let kid: String?
        let jwk: JWK?
    }

    private struct JWSBody: Encodable {
        let protected: String
        let payload: String
        let signature: String
    }

    struct ProblemDocument: Decodable, LocalizedError, Sendable {
        let type: String?
        let detail: String?
        let status: Int?

        var errorDescription: String? {
            if let detail, !detail.isEmpty {
                return detail
            }
            return type ?? "Unknown ACME error"
        }
    }

    private struct HTTPResult {
        let data: Data
        let response: HTTPURLResponse
    }

    private let directoryURL: URL
    private let storageDirectoryURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let accountKeyURL: URL
    private let accountMetadataURL: URL
    private var directoryCache: Directory?
    private var cachedNonce: String?
    private var accountKeyID: String?

    init(
        storageDirectoryURL: URL,
        directoryURL: URL = URL(string: ProcessInfo.processInfo.environment["SWIFTBOT_ACME_DIRECTORY_URL"] ?? "https://acme-v02.api.letsencrypt.org/directory")!,
        session: URLSession = .shared
    ) {
        self.storageDirectoryURL = storageDirectoryURL
        self.directoryURL = directoryURL
        self.session = session
        self.accountKeyURL = storageDirectoryURL.appendingPathComponent("acme-account.key.pem")
        self.accountMetadataURL = storageDirectoryURL.appendingPathComponent("acme-account.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    func issueCertificate(
        for domain: String,
        certificatePrivateKey: P256.Signing.PrivateKey,
        dnsProvider: CloudflareDNSProvider,
        progress: @escaping @MainActor @Sendable (AdminWebAutomaticHTTPSSetupEvent) -> Void,
        log: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> IssuedCertificate {
        let normalizedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        try ensureStorageDirectory()
        try await ensureAccount()

        await log("🔐 Requesting Let's Encrypt order for \(normalizedDomain)")
        let orderResult = try await signedJSONRequest(
            to: try await directory().newOrder,
            payload: NewOrderPayload(identifiers: [.init(type: "dns", value: normalizedDomain)])
        )
        guard let orderURL = locationURL(from: orderResult.response) else {
            throw Error.invalidResponse
        }
        let initialOrder = try decodeOrder(from: orderResult.data)
        var order: OrderResponse
        if let initialOrder {
            order = initialOrder
        } else {
            order = try await fetchOrderDetails(orderURL: orderURL)
        }

        guard let authorizations = order.authorizations, !authorizations.isEmpty else {
            throw Error.missingAuthorizations
        }

        for authorizationURL in authorizations {
            let authorization = try await fetchDecodedResource(url: authorizationURL, as: AuthorizationResponse.self)
            switch authorization.status {
            case "valid":
                continue
            case "pending":
                try await solveDNSChallenge(
                    authorization: authorization,
                    dnsProvider: dnsProvider,
                    progress: progress,
                    log: log
                )
            default:
                let failure = authorization.challenges.first(where: { $0.type == "dns-01" })?.error?.errorDescription
                throw Error.challengeFailed(failure ?? "Authorization for \(authorization.identifier.value) is \(authorization.status).")
            }
        }

        order = try await pollOrderReady(orderURL: orderURL)
        let csrDER = try buildCSRDER(for: normalizedDomain, privateKey: certificatePrivateKey)

        await progress(.requestingTLSCertificate(domain: normalizedDomain))
        await log("📜 Finalizing Let's Encrypt certificate for \(normalizedDomain)")
        _ = try await signedJSONRequest(
            to: order.finalize,
            payload: FinalizePayload(csr: base64URLEncode(csrDER))
        )

        order = try await pollOrderValid(orderURL: orderURL)
        guard let certificateURL = order.certificate else {
            throw Error.orderFailed("The ACME order completed without a certificate URL.")
        }

        let certificateResult = try await signedRawRequest(to: certificateURL, payload: nil, accept: "application/pem-certificate-chain")
        guard (200..<300).contains(certificateResult.response.statusCode),
              let certificatePEM = String(data: certificateResult.data, encoding: .utf8),
              !certificatePEM.isEmpty else {
            throw Error.orderFailed("Let's Encrypt returned an empty certificate chain.")
        }

        await progress(.tlsCertificateIssued(domain: normalizedDomain))
        await log("✅ Let's Encrypt issued a certificate for \(normalizedDomain)")
        return IssuedCertificate(certificatePEM: certificatePEM)
    }

    private func solveDNSChallenge(
        authorization: AuthorizationResponse,
        dnsProvider: CloudflareDNSProvider,
        progress: @escaping @MainActor @Sendable (AdminWebAutomaticHTTPSSetupEvent) -> Void,
        log: @escaping @MainActor @Sendable (String) -> Void
    ) async throws {
        guard let challenge = authorization.challenges.first(where: { $0.type == "dns-01" }) else {
            throw Error.dnsChallengeUnavailable(authorization.identifier.value)
        }

        let challengeValue = try dnsChallengeValue(for: challenge.token)
        let recordName = CloudflareDNSProvider.acmeChallengeRecordName(for: authorization.identifier.value) ?? "_acme-challenge.\(authorization.identifier.value)"
        await progress(.creatingDNSChallengeRecord(recordName: recordName))
        let record = try await dnsProvider.createACMEChallengeRecord(
            for: authorization.identifier.value,
            content: challengeValue
        )
        let shouldDeleteChallengeRecord = record.wasCreated

        defer {
            if shouldDeleteChallengeRecord {
                Task {
                    try? await dnsProvider.deleteTXTRecord(record)
                    await log("🧹 Removed Cloudflare TXT record for \(recordName)")
                }
            }
        }

        if record.wasCreated {
            await log("🌐 Creating Cloudflare TXT record for \(recordName)")
        } else {
            await log("✅ DNS challenge record verified")
            await log("Existing DNS record will be reused for certificate provisioning.")
        }

        await progress(.dnsChallengeRecordCreated(
            recordName: recordName,
            reusedExistingRecord: !record.wasCreated
        ))
        await progress(.waitingForDNSPropagation(recordName: recordName))
        await log("⏳ Waiting for DNS propagation for \(recordName)")
        try await waitForDNSPropagation(
            recordName: recordName,
            expectedValue: challengeValue,
            log: log
        )
        await progress(.dnsChallengeRecordPropagated(recordName: recordName))
        await progress(.dnsChallengeRecordVerified(
            recordName: recordName,
            reusedExistingRecord: !record.wasCreated
        ))

        await log("🧩 Notifying Let's Encrypt that the DNS challenge is ready")
        _ = try await signedJSONRequest(to: challenge.url, payload: EmptyJSONPayload())

        let validated = try await pollChallenge(url: challenge.url)
        guard validated.status == "valid" else {
            let message = validated.error?.errorDescription ?? "dns-01 validation failed for \(authorization.identifier.value)."
            throw Error.challengeFailed(message)
        }
    }

    private func waitForDNSPropagation(
        recordName: String,
        expectedValue: String,
        log: @escaping @MainActor @Sendable (String) -> Void
    ) async throws {
        for attempt in 1...18 {
            if await dnsTXTRecordIsVisible(recordName: recordName, expectedValue: expectedValue) {
                await log("✅ DNS TXT record propagated for \(recordName)")
                return
            }

            if attempt < 18 {
                try? await sleep(seconds: 5)
            }
        }

        await log("⚠️ DNS propagation for \(recordName) was not confirmed via public DNS.")
        throw Error.dnsPropagationTimedOut(recordName)
    }

    private func dnsTXTRecordIsVisible(recordName: String, expectedValue: String) async -> Bool {
        for resolver in Self.publicDNSPropagationResolvers {
            do {
                let data = try await dnsQueryTXTRecord(recordName: recordName, resolver: resolver)
                let values = Self.dnsTXTAnswerValues(from: data)
                if values.contains(expectedValue) {
                    return true
                }
            } catch {
                continue
            }
        }

        return false
    }

    private func dnsQueryTXTRecord(recordName: String, resolver: URL) async throws -> Data {
        var components = URLComponents(url: resolver, resolvingAgainstBaseURL: false)
        let existingItems = components?.queryItems ?? []
        components?.queryItems = existingItems + [
            URLQueryItem(name: "name", value: recordName),
            URLQueryItem(name: "type", value: "TXT")
        ]

        guard let url = components?.url else {
            throw Error.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        request.setValue("SwiftBot/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Error.invalidResponse
        }

        return data
    }

    private func pollOrderReady(orderURL: URL) async throws -> OrderResponse {
        try await pollOrder(orderURL: orderURL, acceptedStates: ["ready", "valid"])
    }

    private func pollOrderValid(orderURL: URL) async throws -> OrderResponse {
        try await pollOrder(orderURL: orderURL, acceptedStates: ["valid"])
    }

    private func pollOrder(orderURL: URL, acceptedStates: Set<String>) async throws -> OrderResponse {
        for _ in 0..<30 {
            guard let order = try await signedPOSTAsGET(url: orderURL, as: OrderResponse.self) else {
                try await sleep(seconds: 2)
                continue
            }
            if acceptedStates.contains(order.status) {
                return order
            }
            if order.status == "invalid" {
                let message = order.error?.errorDescription ?? "The ACME order became invalid."
                throw Error.orderFailed(message)
            }
            try await sleep(seconds: 2)
        }

        throw Error.orderFailed("Timed out waiting for the ACME order to reach \(acceptedStates.joined(separator: ", ")).")
    }

    private func pollChallenge(url: URL) async throws -> Challenge {
        for _ in 0..<30 {
            guard let challenge = try await signedPOSTAsGET(url: url, as: Challenge.self) else {
                try await sleep(seconds: 2)
                continue
            }
            switch challenge.status {
            case "valid":
                return challenge
            case "invalid":
                return challenge
            default:
                try await sleep(seconds: 2)
            }
        }

        throw Error.challengeFailed("Timed out waiting for the ACME challenge to validate.")
    }

    private func buildCSRDER(for domain: String, privateKey: P256.Signing.PrivateKey) throws -> Data {
        let subject = try DistinguishedName {
            CommonName(domain)
        }
        let extensions = try Certificate.Extensions {
            SubjectAlternativeNames([.dnsName(domain)])
        }
        let extensionRequest = ExtensionRequest(extensions: extensions)
        let attributes = try CertificateSigningRequest.Attributes([.init(extensionRequest)])
        let csr = try CertificateSigningRequest(
            version: .v1,
            subject: subject,
            privateKey: .init(privateKey),
            attributes: attributes,
            signatureAlgorithm: .ecdsaWithSHA256
        )

        var serializer = DER.Serializer()
        try serializer.serialize(csr)
        return Data(serializer.serializedBytes)
    }

    private func dnsChallengeValue(for token: String) throws -> String {
        let thumbprint = try accountJWKThumbprint()
        let keyAuthorization = token + "." + thumbprint
        let digest = SHA256.hash(data: Data(keyAuthorization.utf8))
        return base64URLEncode(Data(digest))
    }

    static func dnsTXTAnswerValues(from data: Data) -> [String] {
        guard let response = try? JSONDecoder().decode(DNSQueryResponse.self, from: data),
              (response.status ?? 0) == 0
        else {
            return []
        }

        return (response.answer ?? [])
            .filter { $0.type == 16 }
            .compactMap(\.data)
            .map(normalizeTXTAnswerValue)
            .filter { !$0.isEmpty }
    }

    static func normalizeTXTAnswerValue(_ value: String) -> String {
        var normalized = ""
        var isInsideQuotes = false

        for character in value {
            if character == "\"" {
                isInsideQuotes.toggle()
                continue
            }

            if character == " " && !isInsideQuotes {
                continue
            }

            normalized.append(character)
        }

        return normalized
    }

    private func ensureAccount() async throws {
        if accountKeyID == nil {
            loadAccountMetadataIfNeeded()
        }
        if accountKeyID != nil {
            return
        }

        let accountResult = try await signedJSONRequest(
            to: try await directory().newAccount,
            payload: AccountPayload(),
            useJWK: true
        )

        guard (200..<300).contains(accountResult.response.statusCode) else {
            throw try problemDocument(from: accountResult)
        }

        guard let location = locationURL(from: accountResult.response)?.absoluteString else {
            throw Error.missingAccountLocation
        }

        accountKeyID = location
        try saveAccountMetadata()
    }

    private func directory() async throws -> Directory {
        if let directoryCache {
            return directoryCache
        }

        var request = URLRequest(url: directoryURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SwiftBot/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Error.invalidResponse
        }

        let directory = try decoder.decode(Directory.self, from: data)
        directoryCache = directory
        if let replayNonce = http.value(forHTTPHeaderField: "Replay-Nonce") {
            cachedNonce = replayNonce
        }
        return directory
    }

    private func nextNonce() async throws -> String {
        if let cachedNonce {
            self.cachedNonce = nil
            return cachedNonce
        }

        let nonceURL = try await directory().newNonce
        var request = URLRequest(url: nonceURL)
        request.httpMethod = "HEAD"
        request.setValue("SwiftBot/1.0", forHTTPHeaderField: "User-Agent")

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let replayNonce = http.value(forHTTPHeaderField: "Replay-Nonce") else {
            throw Error.missingReplayNonce
        }
        return replayNonce
    }

    private func fetchOrderDetails(orderURL: URL) async throws -> OrderResponse {
        try await fetchDecodedResource(url: orderURL, as: OrderResponse.self)
    }

    private func fetchDecodedResource<ResponseType: Decodable>(
        url: URL,
        as type: ResponseType.Type,
        attempts: Int = 5
    ) async throws -> ResponseType {
        for attempt in 0..<attempts {
            if let response = try await signedPOSTAsGET(url: url, as: type) {
                return response
            }

            if attempt < attempts - 1 {
                try await sleep(seconds: 1)
            }
        }

        throw Error.invalidResponse
    }

    private func signedPOSTAsGET<ResponseType: Decodable>(url: URL, as type: ResponseType.Type) async throws -> ResponseType? {
        let result = try await signedRawRequest(to: url, payload: nil)
        guard (200..<300).contains(result.response.statusCode) else {
            throw try problemDocument(from: result)
        }
        return try Self.decodeJSONIfPresent(type, from: result.data, using: decoder)
    }

    private func signedJSONRequest<Payload: Encodable>(
        to url: URL,
        payload: Payload,
        useJWK: Bool = false
    ) async throws -> HTTPResult {
        let payloadData = try encoder.encode(payload)
        let result = try await signedRawRequest(to: url, payload: payloadData, useJWK: useJWK)
        guard (200..<300).contains(result.response.statusCode) else {
            throw try problemDocument(from: result)
        }
        return result
    }

    private func signedRawRequest(
        to url: URL,
        payload: Data?,
        useJWK: Bool = false,
        accept: String = "application/json"
    ) async throws -> HTTPResult {
        var retriedBadNonce = false
        var retriedMissingAccount = false

        while true {
            let body = try await makeJWSBody(url: url, payload: payload, useJWK: useJWK)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/jose+json", forHTTPHeaderField: "Content-Type")
            request.setValue(accept, forHTTPHeaderField: "Accept")
            request.setValue("SwiftBot/1.0", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw Error.invalidResponse
            }

            if let replayNonce = http.value(forHTTPHeaderField: "Replay-Nonce") {
                cachedNonce = replayNonce
            }

            let result = HTTPResult(data: data, response: http)
            if let problem = try? problemDocumentIfPresent(from: result) {
                if problem.type == "urn:ietf:params:acme:error:badNonce", !retriedBadNonce {
                    retriedBadNonce = true
                    cachedNonce = nil
                    continue
                }

                if problem.type == "urn:ietf:params:acme:error:accountDoesNotExist", !useJWK, !retriedMissingAccount {
                    retriedMissingAccount = true
                    accountKeyID = nil
                    try saveAccountMetadata()
                    try await ensureAccount()
                    continue
                }
            }

            return result
        }
    }

    private func makeJWSBody(url: URL, payload: Data?, useJWK: Bool) async throws -> Data {
        let nonce = try await nextNonce()
        let accountKey = try loadOrCreateAccountKey()
        let header = ProtectedHeader(
            nonce: nonce,
            url: url.absoluteString,
            kid: useJWK ? nil : accountKeyID,
            jwk: useJWK ? try jwk(for: accountKey.publicKey) : nil
        )

        let protectedData = try encoder.encode(header)
        let protectedPart = base64URLEncode(protectedData)
        let payloadPart = payload.map(base64URLEncode) ?? ""
        let signingInput = Data("\(protectedPart).\(payloadPart)".utf8)
        let signature = try accountKey.signature(for: signingInput)

        let body = JWSBody(
            protected: protectedPart,
            payload: payloadPart,
            signature: base64URLEncode(signature.rawRepresentation)
        )
        return try encoder.encode(body)
    }

    private func problemDocument(from result: HTTPResult) throws -> ProblemDocument {
        if let problem = try? decoder.decode(ProblemDocument.self, from: result.data) {
            return problem
        }
        let body = String(data: result.data, encoding: .utf8) ?? ""
        return ProblemDocument(
            type: nil,
            detail: body.isEmpty ? "ACME request failed with HTTP \(result.response.statusCode)." : body,
            status: result.response.statusCode
        )
    }

    private func problemDocumentIfPresent(from result: HTTPResult) throws -> ProblemDocument {
        if (200..<300).contains(result.response.statusCode) {
            throw Error.invalidResponse
        }
        return try problemDocument(from: result)
    }

    private func decodeOrder(from data: Data) throws -> OrderResponse? {
        try Self.decodeJSONIfPresent(OrderResponse.self, from: data, using: decoder)
    }

    private func locationURL(from response: HTTPURLResponse) -> URL? {
        guard let location = response.value(forHTTPHeaderField: "Location") else {
            return nil
        }
        return URL(string: location)
    }

    private func ensureStorageDirectory() throws {
        try FileManager.default.createDirectory(
            at: storageDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    private func loadOrCreateAccountKey() throws -> P256.Signing.PrivateKey {
        if FileManager.default.fileExists(atPath: accountKeyURL.path) {
            let pem = try String(contentsOf: accountKeyURL, encoding: .utf8)
            return try P256.Signing.PrivateKey(pemRepresentation: pem)
        }

        let key = P256.Signing.PrivateKey()
        try key.pemRepresentation.write(to: accountKeyURL, atomically: true, encoding: .utf8)
        return key
    }

    private func loadAccountMetadataIfNeeded() {
        guard accountKeyID == nil,
              let data = try? Data(contentsOf: accountMetadataURL),
              let metadata = try? decoder.decode(AccountMetadata.self, from: data) else {
            return
        }
        accountKeyID = metadata.keyID
    }

    private func saveAccountMetadata() throws {
        guard let accountKeyID else {
            try? FileManager.default.removeItem(at: accountMetadataURL)
            return
        }
        let data = try encoder.encode(AccountMetadata(keyID: accountKeyID))
        try data.write(to: accountMetadataURL, options: .atomic)
    }

    private func accountJWKThumbprint() throws -> String {
        let key = try loadOrCreateAccountKey()
        let jwkData = try encoder.encode(jwk(for: key.publicKey))
        let digest = SHA256.hash(data: jwkData)
        return base64URLEncode(Data(digest))
    }

    private func jwk(for publicKey: P256.Signing.PublicKey) throws -> JWK {
        let x963 = publicKey.x963Representation
        guard x963.count == 65, x963.first == 0x04 else {
            throw Error.invalidResponse
        }

        let x = base64URLEncode(x963[1...32])
        let y = base64URLEncode(x963[33...64])
        return JWK(x: x, y: y)
    }

    private func base64URLEncode<Bytes: DataProtocol>(_ bytes: Bytes) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func sleep(seconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
    }

    static func decodeJSONIfPresent<ResponseType: Decodable>(
        _ type: ResponseType.Type,
        from data: Data,
        using decoder: JSONDecoder = JSONDecoder()
    ) throws -> ResponseType? {
        guard hasMeaningfulResponseBody(data) else {
            return nil
        }

        return try decoder.decode(ResponseType.self, from: data)
    }

    static func hasMeaningfulResponseBody(_ data: Data) -> Bool {
        data.contains { byte in
            switch byte {
            case 0x09, 0x0A, 0x0D, 0x20:
                return false
            default:
                return true
            }
        }
    }
}
