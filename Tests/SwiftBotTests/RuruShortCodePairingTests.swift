import XCTest
@testable import SwiftBot

/// Ruru short-code pairing (`POST /v1/pair`, `/v1/pair/status`) against a stub.
final class RuruShortCodePairingTests: XCTestCase {
    override func tearDown() {
        ShortCodeStub.replies = []
        ShortCodeStub.requests = []
        super.tearDown()
    }

    private var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShortCodeStub.self]
        return URLSession(configuration: configuration)
    }

    func testShortCodesAreRecognisedLeniently() {
        XCTAssertEqual(RuruShortCodePairing.normalized("mvcp 6jh9"), "MVCP-6JH9")
        XCTAssertEqual(RuruShortCodePairing.normalized(" MVCP-6JH9\n"), "MVCP-6JH9")
        XCTAssertNil(RuruShortCodePairing.normalized("MVCP-6JH0"), "0 is not in Ruru's alphabet")
        XCTAssertNil(RuruShortCodePairing.normalized("MVCP-6JH"))
        XCTAssertNil(RuruShortCodePairing.normalized("RURU1:eyJ2ZXJzaW9uIjoxfQ"))
    }

    func testApprovedPairingReturnsConnectionDetailsWithoutSavingThem() async throws {
        let token = String(repeating: "t", count: 43)
        ShortCodeStub.replies = [
            (202, #"{"pairingID":"abc","status":"pending","retryAfter":1}"#),
            (202, #"{"status":"pending","retryAfter":1}"#),
            (200, #"{"status":"approved","clusterID":"swiftbot","token":"\#(token)","leaseSeconds":30}"#)
        ]
        let configuration = try await RuruShortCodePairing.pair(endpoint: "https://ruru.example.com/", code: "mvcp6jh9",
                                                                nodeID: "node-a", nodeName: "Home Mac", session: session)
        XCTAssertEqual(configuration, MeshWitnessConfiguration(endpoint: "https://ruru.example.com", clusterID: "swiftbot", token: token))
        let claim = try XCTUnwrap(ShortCodeStub.requests.first)
        XCTAssertEqual(claim.url?.path, "/v1/pair")
        XCTAssertNil(claim.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: claim.httpBody ?? Data()) as? [String: String])
        XCTAssertEqual(body, ["code": "MVCP-6JH9", "nodeID": "node-a", "nodeName": "Home Mac"])
        XCTAssertEqual(ShortCodeStub.requests.last?.url?.path, "/v1/pair/status")
    }

    func testRuruAnswersMapToClearFailures() async {
        let cases: [(Int, String, RuruShortCodePairing.Failure)] = [
            (404, #"{"error":"invalid_code"}"#, .invalidCode),
            (404, #"{"error":"not_found"}"#, .unsupported),
            (429, #"{"error":"too_many_attempts"}"#, .throttled)
        ]
        for (status, body, expected) in cases {
            ShortCodeStub.replies = [(status, body)]
            do {
                _ = try await RuruShortCodePairing.pair(endpoint: "https://ruru.example.com", code: "MVCP-6JH9",
                                                        nodeID: "node-a", nodeName: "", session: session)
                XCTFail("Expected \(expected)")
            } catch { XCTAssertEqual(error as? RuruShortCodePairing.Failure, expected) }
        }
        ShortCodeStub.replies = [(202, #"{"pairingID":"abc"}"#), (403, #"{"error":"pairing_rejected"}"#)]
        do {
            _ = try await RuruShortCodePairing.pair(endpoint: "https://ruru.example.com", code: "MVCP-6JH9",
                                                    nodeID: "node-a", nodeName: "", session: session)
            XCTFail("Expected rejection")
        } catch { XCTAssertEqual(error as? RuruShortCodePairing.Failure, .rejected) }
        do {
            _ = try await RuruShortCodePairing.pair(endpoint: "http://ruru.example.com", code: "MVCP-6JH9",
                                                    nodeID: "node-a", nodeName: "", session: session)
            XCTFail("Plain HTTP to a remote host must be refused")
        } catch { XCTAssertEqual(error as? RuruShortCodePairing.Failure, .invalidAddress) }
    }
}

private final class ShortCodeStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var replies: [(Int, String)] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var recorded = request
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            recorded.httpBody = data
        }
        Self.requests.append(recorded)
        let (status, body) = Self.replies.isEmpty ? (500, "{}") : Self.replies.removeFirst()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
