import Foundation
import Network
import CryptoKit
@testable import SwiftBot

// Note: AITestOverrides is now in SwiftBotApp/TestSupport.swift (wrapped in #if DEBUG)
// so it's available to both production code (in Debug) and tests via @testable.

extension ClusterCoordinator {
    func testIsSSRFSafeHost(_ host: String) -> Bool {
        isSSRFSafeHost(host)
    }

    func testNormalizedBaseURL(_ raw: String) -> String? {
        normalizedBaseURL(raw)
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

    /// Simulates a single leader health miss without making a network call.
    /// Increments the miss counter and triggers promotion if threshold is reached.
    func testSimulateLeaderHealthMiss() async {
        standbyHealthMisses += 1
        snapshot.workerStatusText = "Primary unreachable (\(standbyHealthMisses)/\(ClusterCoordinator.standbyPromotionThreshold))"
        snapshot.diagnostics = "Simulated health miss \(standbyHealthMisses)"
        await publishSnapshot()
        if standbyHealthMisses >= ClusterCoordinator.standbyPromotionThreshold {
            await promoteToLeader()
        }
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

    /// Injects a list of DiscoveredPeer values into the discovery table, applying the same
    /// deterministic collision rule as handleDiscoveryResults (lexicographically smallest baseURL
    /// wins when two entries share the same nodeName).
    func testInjectDiscoveredPeers(_ peers: [DiscoveredPeer]) {
        var result: [String: DiscoveredPeer] = [:]
        for peer in peers {
            if let existing = result[peer.nodeName] {
                if peer.baseURL < existing.baseURL {
                    result[peer.nodeName] = DiscoveredPeer(
                        nodeName: peer.nodeName,
                        baseURL: peer.baseURL,
                        discoveredAt: existing.discoveredAt
                    )
                }
            } else {
                result[peer.nodeName] = peer
            }
        }
        discoveredPeers = result
    }
}
