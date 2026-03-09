import Foundation
import XCTest
@testable import SwiftBot

private final class MockCloudflareURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("Missing request handler for MockCloudflareURLProtocol.")
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func requestBodyData(from request: URLRequest) throws -> Data {
    if let body = request.httpBody {
        return body
    }

    if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let readCount = stream.read(buffer, maxLength: bufferSize)
            if readCount < 0 {
                throw stream.streamError ?? URLError(.cannotDecodeRawData)
            }
            if readCount == 0 {
                break
            }
            data.append(buffer, count: readCount)
        }

        return data
    }

    throw URLError(.badServerResponse)
}

final class CertificateManagerTests: XCTestCase {
    private struct TestACMEPayload: Decodable, Equatable {
        let status: String
    }

    func testHTTPSDomainNormalizationStripsSchemeAndWhitespace() {
        var settings = AdminWebUISettings()
        settings.httpsDomain = "  https://Admin.Example.com/dashboard  "

        XCTAssertEqual(settings.normalizedHTTPSDomain, "admin.example.com")
    }

    func testCloudflareRootZoneExtractionStripsSubdomainsBeforeLookup() {
        XCTAssertEqual(
            CloudflareDNSProvider.extractRootZone(from: "swiftbot.example.com"),
            "example.com"
        )

        XCTAssertEqual(
            CloudflareDNSProvider.extractRootZone(from: "api.admin.swiftbot.example.com"),
            "example.com"
        )

        XCTAssertEqual(
            CloudflareDNSProvider.extractRootZone(from: "test.example.co.nz"),
            "example.co.nz"
        )

        XCTAssertEqual(
            CloudflareDNSProvider.extractRootZone(from: "https://swiftbot.example.com/dashboard"),
            "example.com"
        )
    }

    func testACMEChallengeRecordNamePrefixesHostname() {
        XCTAssertEqual(
            CloudflareDNSProvider.acmeChallengeRecordName(for: "swiftbot.roon.nz"),
            "_acme-challenge.swiftbot.roon.nz"
        )

        XCTAssertEqual(
            CloudflareDNSProvider.acmeChallengeRecordName(for: "_acme-challenge.swiftbot.roon.nz"),
            "_acme-challenge.swiftbot.roon.nz"
        )
    }

    func testCloudflareZoneLookupDecodesSuccessfulResponseWithoutErrorsField() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockCloudflareURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            MockCloudflareURLProtocol.requestHandler = nil
            session.invalidateAndCancel()
        }

        MockCloudflareURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            let zoneQuery = components.queryItems?.first(where: { $0.name == "name" })?.value
            XCTAssertEqual(zoneQuery, "roon.nz")

            let data = """
            {
              "success": true,
              "result": [
                {
                  "id": "c59a1947ecd7d9a226e0c8411d62e8d7",
                  "name": "roon.nz",
                  "status": "active",
                  "paused": false
                }
              ],
              "result_info": {
                "count": 1
              }
            }
            """.data(using: .utf8)!

            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )

            return (response, data)
        }

        let provider = CloudflareDNSProvider(apiToken: "token-123", session: session)
        let zone = try await provider.findZone(for: "swiftbot.roon.nz")

        XCTAssertEqual(
            zone,
            CloudflareDNSProvider.ZoneSummary(
                id: "c59a1947ecd7d9a226e0c8411d62e8d7",
                name: "roon.nz"
            )
        )
    }

    func testCloudflareDNSRecordLookupDecodesSuccessfulResponseAndFindsMatchingRecord() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockCloudflareURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            MockCloudflareURLProtocol.requestHandler = nil
            session.invalidateAndCancel()
        }

        MockCloudflareURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")

            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.path, "/client/v4/zones/zone-123/dns_records")

            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let nameQuery = components.queryItems?.first(where: { $0.name == "name" })?.value
            XCTAssertEqual(nameQuery, "swiftbot.roon.nz")

            let data = """
            {
              "success": true,
              "result": [
                {
                  "id": "txt-1",
                  "type": "TXT",
                  "name": "swiftbot.roon.nz",
                  "content": "hello"
                },
                {
                  "id": "cname-1",
                  "type": "CNAME",
                  "name": "swiftbot.roon.nz",
                  "content": "target.example.com",
                  "proxied": false
                }
              ]
            }
            """.data(using: .utf8)!

            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )

            return (response, data)
        }

        let provider = CloudflareDNSProvider(apiToken: "token-123", session: session)
        let record = try await provider.findDNSRecord(
            zoneID: "zone-123",
            hostname: "swiftbot.roon.nz",
            allowedTypes: ["A", "AAAA", "CNAME"]
        )

        XCTAssertEqual(
            record,
            CloudflareDNSProvider.DNSRecordSummary(
                zoneID: "zone-123",
                recordID: "cname-1",
                type: "CNAME",
                name: "swiftbot.roon.nz",
                content: "target.example.com"
            )
        )
    }

    func testCloudflareACMEChallengeRecordCreationUsesTXTRecordForChallengeHostname() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockCloudflareURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            MockCloudflareURLProtocol.requestHandler = nil
            session.invalidateAndCancel()
        }

        var requestCount = 0
        MockCloudflareURLProtocol.requestHandler = { request in
            requestCount += 1
            let url = try XCTUnwrap(request.url)

            switch requestCount {
            case 1:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(url.path, "/client/v4/zones")

                let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
                let zoneQuery = components.queryItems?.first(where: { $0.name == "name" })?.value
                XCTAssertEqual(zoneQuery, "roon.nz")

                let data = """
                {
                  "success": true,
                  "result": [
                    {
                      "id": "zone-123",
                      "name": "roon.nz"
                    }
                  ]
                }
                """.data(using: .utf8)!

                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )
                )

                return (response, data)
            case 2:
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(url.path, "/client/v4/zones/zone-123/dns_records")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

                let bodyData = try requestBodyData(from: request)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
                XCTAssertEqual(body["type"] as? String, "TXT")
                XCTAssertEqual(body["name"] as? String, "_acme-challenge.swiftbot.roon.nz")
                XCTAssertEqual(body["content"] as? String, "challenge-token")
                XCTAssertEqual(body["ttl"] as? Int, 120)

                let data = """
                {
                  "success": true,
                  "result": {
                    "id": "record-123",
                    "zone_id": "zone-123",
                    "type": "TXT",
                    "name": "_acme-challenge.swiftbot.roon.nz",
                    "content": "challenge-token"
                  }
                }
                """.data(using: .utf8)!

                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )
                )

                return (response, data)
            default:
                XCTFail("Unexpected Cloudflare request: \(request)")
                throw URLError(.badServerResponse)
            }
        }

        let provider = CloudflareDNSProvider(apiToken: "token-123", session: session)
        let record = try await provider.createACMEChallengeRecord(
            for: "swiftbot.roon.nz",
            content: "challenge-token"
        )

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(
            record,
            CloudflareDNSProvider.TXTRecord(
                zoneID: "zone-123",
                recordID: "record-123",
                name: "_acme-challenge.swiftbot.roon.nz",
                content: "challenge-token",
                wasCreated: true
            )
        )
    }

    func testCloudflareACMEChallengeRecordReuseTreatsDuplicateAsSuccess() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockCloudflareURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            MockCloudflareURLProtocol.requestHandler = nil
            session.invalidateAndCancel()
        }

        var requestCount = 0
        MockCloudflareURLProtocol.requestHandler = { request in
            requestCount += 1
            let url = try XCTUnwrap(request.url)

            switch requestCount {
            case 1:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(url.path, "/client/v4/zones")

                let data = """
                {
                  "success": true,
                  "result": [
                    {
                      "id": "zone-123",
                      "name": "roon.nz"
                    }
                  ]
                }
                """.data(using: .utf8)!

                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )
                )

                return (response, data)
            case 2:
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(url.path, "/client/v4/zones/zone-123/dns_records")

                let data = """
                {
                  "success": false,
                  "errors": [
                    {
                      "code": 81057,
                      "message": "An identical record already exists."
                    }
                  ]
                }
                """.data(using: .utf8)!

                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: url,
                        statusCode: 409,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )
                )

                return (response, data)
            case 3:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(url.path, "/client/v4/zones/zone-123/dns_records")

                let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
                let nameQuery = components.queryItems?.first(where: { $0.name == "name" })?.value
                XCTAssertEqual(nameQuery, "_acme-challenge.swiftbot.roon.nz")

                let data = """
                {
                  "success": true,
                  "result": [
                    {
                      "id": "record-123",
                      "type": "TXT",
                      "name": "_acme-challenge.swiftbot.roon.nz",
                      "content": "challenge-token"
                    }
                  ]
                }
                """.data(using: .utf8)!

                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )
                )

                return (response, data)
            default:
                XCTFail("Unexpected Cloudflare request: \(request)")
                throw URLError(.badServerResponse)
            }
        }

        let provider = CloudflareDNSProvider(apiToken: "token-123", session: session)
        let record = try await provider.createACMEChallengeRecord(
            for: "swiftbot.roon.nz",
            content: "challenge-token"
        )

        XCTAssertEqual(requestCount, 3)
        XCTAssertEqual(
            record,
            CloudflareDNSProvider.TXTRecord(
                zoneID: "zone-123",
                recordID: "record-123",
                name: "_acme-challenge.swiftbot.roon.nz",
                content: "challenge-token",
                wasCreated: false
            )
        )
    }

    func testCloudflareDuplicateDNSRecordErrorMapsToReusableRecordState() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockCloudflareURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            MockCloudflareURLProtocol.requestHandler = nil
            session.invalidateAndCancel()
        }

        MockCloudflareURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(url.path, "/client/v4/zones/zone-123/dns_records")

            let data = """
            {
              "success": false,
              "errors": [
                {
                  "code": 81057,
                  "message": "An identical record already exists."
                }
              ]
            }
            """.data(using: .utf8)!

            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 409,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )

            return (response, data)
        }

        let provider = CloudflareDNSProvider(apiToken: "token-123", session: session)

        do {
            _ = try await provider.createDNSRecord(
                zoneID: "zone-123",
                type: "A",
                name: "swiftbot.roon.nz",
                content: "203.0.113.10"
            )
            XCTFail("Expected identical Cloudflare record to map to a reusable-record error.")
        } catch let error as CloudflareDNSProvider.Error {
            XCTAssertEqual(
                error.errorDescription,
                "The required DNS record already exists and will be reused for certificate provisioning."
            )
        }
    }

    func testACMEDNSPropagationParserExtractsTXTValuesFromDNSJSON() {
        let data = """
        {
          "Status": 0,
          "Answer": [
            {
              "name": "_acme-challenge.swiftbot.example.com",
              "type": 16,
              "TTL": 60,
              "data": "\\"challenge-token\\""
            },
            {
              "name": "_acme-challenge.swiftbot.example.com",
              "type": 16,
              "TTL": 60,
              "data": "\\"part-one\\" \\"part-two\\""
            },
            {
              "name": "_acme-challenge.swiftbot.example.com",
              "type": 1,
              "TTL": 60,
              "data": "203.0.113.10"
            }
          ]
        }
        """.data(using: .utf8)!

        XCTAssertEqual(
            ACMEClient.dnsTXTAnswerValues(from: data),
            ["challenge-token", "part-onepart-two"]
        )
    }

    func testACMEJSONDecodeIfPresentReturnsNilForEmptySuccessBody() throws {
        XCTAssertNil(try ACMEClient.decodeJSONIfPresent(TestACMEPayload.self, from: Data()))
        XCTAssertNil(try ACMEClient.decodeJSONIfPresent(TestACMEPayload.self, from: Data(" \n\t".utf8)))
    }

    func testACMEJSONDecodeIfPresentDecodesWhenBodyExists() throws {
        let data = Data(#"{"status":"valid"}"#.utf8)

        XCTAssertEqual(
            try ACMEClient.decodeJSONIfPresent(TestACMEPayload.self, from: data),
            TestACMEPayload(status: "valid")
        )
    }

    func testCertificateRenewalWindowUsesThirtyDays() {
        let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
        let renewSoon = referenceDate.addingTimeInterval(29 * 24 * 60 * 60)
        let renewLater = referenceDate.addingTimeInterval(31 * 24 * 60 * 60)

        XCTAssertTrue(CertificateManager.shouldRenew(expiresAt: renewSoon, referenceDate: referenceDate))
        XCTAssertFalse(CertificateManager.shouldRenew(expiresAt: renewLater, referenceDate: referenceDate))
    }

    func testAutomaticHTTPSValidationSummaryRequiresCloudflareChecks() {
        XCTAssertEqual(
            CertificateManager.validationSummaryState(
                tokenIsValid: true,
                zoneFound: true,
                dnsRecordFound: true,
                hostnameResolves: true
            ),
            .success
        )

        XCTAssertEqual(
            CertificateManager.validationSummaryState(
                tokenIsValid: true,
                zoneFound: true,
                dnsRecordFound: true,
                hostnameResolves: false
            ),
            .warning
        )

        XCTAssertEqual(
            CertificateManager.validationSummaryState(
                tokenIsValid: true,
                zoneFound: false,
                dnsRecordFound: true,
                hostnameResolves: true
            ),
            .error
        )
    }

    func testBundledCloudflaredDetectionFindsNestedResourcesFolderBinary() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleURL = tempRoot.appendingPathComponent("SwiftBot.app", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let nestedResourcesURL = contentsURL
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        let binaryURL = nestedResourcesURL.appendingPathComponent("cloudflared")
        let infoPlistURL = contentsURL.appendingPathComponent("Info.plist")

        defer {
            try? fileManager.removeItem(at: tempRoot)
        }

        try fileManager.createDirectory(at: nestedResourcesURL, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>com.example.SwiftBotTests</string>
            <key>CFBundleName</key>
            <string>SwiftBotTests</string>
        </dict>
        </plist>
        """.write(to: infoPlistURL, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: binaryURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)

        let bundle = try XCTUnwrap(Bundle(path: bundleURL.path))
        let installation = CertificateManager.detectCloudflaredInstallation(bundle: bundle, fileManager: fileManager)

        XCTAssertEqual(installation.detectedPath, binaryURL.path)
    }

    func testCloudflareTunnelClientCreatesTunnelWithAccountFallbackAndConfiguresIngress() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockCloudflareURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            MockCloudflareURLProtocol.requestHandler = nil
            session.invalidateAndCancel()
        }

        var requestCount = 0
        MockCloudflareURLProtocol.requestHandler = { request in
            requestCount += 1
            let url = try XCTUnwrap(request.url)

            switch requestCount {
            case 1:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(url.path, "/client/v4/zones/zone-123")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")

                let data = """
                {
                  "success": true,
                  "result": {
                    "account": {
                      "id": "account-456"
                    }
                  }
                }
                """.data(using: .utf8)!
                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )
                )
                return (response, data)
            case 2:
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(url.path, "/client/v4/accounts/account-456/cfd_tunnel")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

                let bodyData = try requestBodyData(from: request)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
                XCTAssertEqual(body["name"] as? String, "swiftbot-swiftbot-example-com")
                XCTAssertEqual(body["config_src"] as? String, "cloudflare")

                let data = """
                {
                  "success": true,
                  "result": {
                    "id": "tunnel-789",
                    "name": "swiftbot-swiftbot-example-com"
                  }
                }
                """.data(using: .utf8)!
                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )
                )
                return (response, data)
            case 3:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(url.path, "/client/v4/accounts/account-456/cfd_tunnel/tunnel-789/token")

                let data = """
                {
                  "success": true,
                  "result": "token-abc"
                }
                """.data(using: .utf8)!
                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )
                )
                return (response, data)
            case 4:
                XCTAssertEqual(request.httpMethod, "PUT")
                XCTAssertEqual(url.path, "/client/v4/accounts/account-456/cfd_tunnel/tunnel-789/configurations")

                let bodyData = try requestBodyData(from: request)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
                let config = try XCTUnwrap(body["config"] as? [String: Any])
                let ingress = try XCTUnwrap(config["ingress"] as? [[String: Any]])
                XCTAssertEqual(ingress.count, 2)
                XCTAssertEqual(ingress.first?["hostname"] as? String, "swiftbot.example.com")
                XCTAssertEqual(ingress.first?["service"] as? String, "http://127.0.0.1:38888")
                XCTAssertEqual(ingress.last?["service"] as? String, "http_status:404")

                let data = """
                {
                  "success": true,
                  "result": {
                    "config": {
                      "ingress": []
                    }
                  }
                }
                """.data(using: .utf8)!
                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )
                )
                return (response, data)
            default:
                XCTFail("Unexpected Cloudflare request: \(request)")
                throw URLError(.badServerResponse)
            }
        }

        let client = CloudflareTunnelClient(apiToken: "token-123", session: session)
        let tunnel = try await client.createTunnel(
            hostname: "swiftbot.example.com",
            zone: .init(id: "zone-123", name: "example.com")
        )

        XCTAssertEqual(
            tunnel,
            .init(
                accountID: "account-456",
                id: "tunnel-789",
                name: "swiftbot-swiftbot-example-com",
                token: "token-abc"
            )
        )

        try await client.configureTunnel(
            tunnel,
            hostname: "swiftbot.example.com",
            originURL: "http://127.0.0.1:38888"
        )

        XCTAssertEqual(requestCount, 4)
    }
}
