import Foundation
import Network
import CryptoKit
@testable import SwiftBot

// Note: AITestOverrides is now in Sources/SwiftBot/TestSupport.swift (wrapped in #if DEBUG)
// so it's available to both production code (in Debug) and tests via @testable.

extension ClusterCoordinator {
    func testIsSSRFSafeHost(_ host: String) -> Bool {
        isSSRFSafeHost(host)
    }

    func testNormalizedBaseURL(_ raw: String) -> String? {
        normalizedBaseURL(raw, defaultPort: leaderPort)
    }

    func testProcessHTTPRequest(_ data: Data) async -> Data {
        await processHTTPRequest(data)
    }

    func testProcessHTTPRequest(_ data: Data, remoteHost: String?) async -> Data {
        await processHTTPRequest(data, remoteHost: remoteHost)
    }

    func testExceedsHTTPRequestSizeCap(_ contentLength: Int) -> Bool {
        contentLength > ClusterCoordinator.maxHTTPRequestSize
    }

    func testCurrentMode() -> ClusterMode { mode }
    func testCurrentSnapshot() -> ClusterSnapshot { snapshot }
    func testCurrentLeaderTerm() -> Int { leaderTerm }
    func testCurrentLeaderAddress() -> String { leaderAddress }
    func testReplicationCursors() -> [String: ReplicationCursor] { replicationCursors }
    func testMaxSyncBatchSize() -> Int { ClusterCoordinator.maxSyncBatchSize }

    /// Returns HTTP headers (nonce, timestamp, signature) for a request with the given method, path, and body.
    /// Used by tests to construct properly signed requests against the coordinator's current sharedSecret.
    func testMakeHMACHeaders(method: String = "POST", path: String, body: Data = Data()) -> [String: String] {
        let nonce = UUID().uuidString
        let timestamp = Int(Date().timeIntervalSince1970)
        let sig = meshSignature(method: method, nonce: nonce, timestamp: timestamp, path: path, body: body)
        return [
            "X-Mesh-Nonce": nonce,
            "X-Mesh-Timestamp": String(timestamp),
            "X-Mesh-Signature": sig
        ]
    }

    /// Inserts a fake registered-worker entry without going through the real
    /// /cluster/register handshake. Used by integration-style failover tests
    /// that need the leader to push to a peer at a known address.
    func testInjectRegisteredWorker(nodeName: String, baseURL: String, listenPort: Int) {
        injectRegisteredWorkerForTesting(
            nodeName: nodeName,
            baseURL: baseURL,
            listenPort: listenPort
        )
    }

}
