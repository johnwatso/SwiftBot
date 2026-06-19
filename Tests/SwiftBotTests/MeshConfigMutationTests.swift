import XCTest
@testable import SwiftBot

/// Bidirectional config-mutation channel tests (Failover GUI → Primary).
/// Covers: leader applies + acks, leader-only gating (409 on a follower),
/// and idempotency (a retried mutation with the same client id applies once).
final class MeshConfigMutationTests: XCTestCase {

    private actor MutationRecorder {
        private(set) var requests: [MeshConfigMutationRequest] = []
        func record(_ r: MeshConfigMutationRequest) { requests.append(r) }
        var count: Int { requests.count }
    }

    private func makeCoordinator(mode: ClusterMode, port: Int) async -> ClusterCoordinator {
        let c = ClusterCoordinator()
        await c.applySettings(
            mode: mode,
            nodeName: mode == .leader ? "Leader" : "Failover",
            leaderAddress: mode == .leader ? "" : "http://127.0.0.1:\(port + 1)",
            listenPort: port,
            sharedSecret: "s",
            leaderTerm: 1
        )
        await c.configureHandlers(
            aiHandler: { _, _, _, _ in nil },
            wikiHandler: { _, _ in nil },
            onSnapshot: { _ in },
            onJobLog: { _ in },
            onSync: { _ in },
            meshHandler: { _ in nil },
            conversationFetcher: { _, _ in ([], false) },
            onPromotion: {}
        )
        return c
    }

    private func makeHTTPRequest(method: String, path: String, headers: [String: String], body: Data) -> Data {
        var raw = "\(method) \(path) HTTP/1.1\r\n"
        raw += "Host: localhost\r\n"
        for (k, v) in headers { raw += "\(k): \(v)\r\n" }
        raw += "Content-Length: \(body.count)\r\n\r\n"
        var data = Data(raw.utf8)
        data.append(body)
        return data
    }

    private func statusCode(from response: Data) -> Int {
        guard let text = String(data: response, encoding: .utf8),
              let first = text.components(separatedBy: "\r\n").first else { return -1 }
        let parts = first.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else { return -1 }
        return code
    }

    private func decodeResponse(_ response: Data) -> MeshConfigMutationResponse? {
        guard let marker = response.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let bodyData = Data(response[marker.upperBound...])
        return try? JSONDecoder().decode(MeshConfigMutationResponse.self, from: bodyData)
    }

    /// POST a mutation envelope to a coordinator, re-signing with a fresh nonce
    /// each call (so retries aren't rejected by the replay cache).
    private func postMutation(to c: ClusterCoordinator, _ request: MeshConfigMutationRequest) async -> Data {
        let body = (try? JSONEncoder().encode(request)) ?? Data()
        let headers = await c.testMakeHMACHeaders(path: "/v1/mesh/config/mutate", body: body)
        let raw = makeHTTPRequest(method: "POST", path: "/v1/mesh/config/mutate", headers: headers, body: body)
        return await c.testProcessHTTPRequest(raw)
    }

    // MARK: - Tests

    func testLeaderAppliesAndAcksMutation() async {
        let recorder = MutationRecorder()
        let leader = await makeCoordinator(mode: .leader, port: 39600)
        await leader.setConfigMutationHandler { request in
            await recorder.record(request)
            return MeshConfigMutationResponse(applied: true, reason: nil)
        }

        let request = MeshConfigMutationRequest(
            mutation: .patchyDeleteTarget(UUID()),
            originNodeName: "Failover"
        )
        let response = await postMutation(to: leader, request)

        XCTAssertEqual(statusCode(from: response), 200)
        XCTAssertEqual(decodeResponse(response)?.applied, true)
        let count = await recorder.count
        XCTAssertEqual(count, 1, "handler should be invoked exactly once")
    }

    func testFollowerRejectsMutationWith409() async {
        let recorder = MutationRecorder()
        let standby = await makeCoordinator(mode: .standby, port: 39602)
        await standby.setConfigMutationHandler { request in
            await recorder.record(request)
            return MeshConfigMutationResponse(applied: true, reason: nil)
        }

        let request = MeshConfigMutationRequest(
            mutation: .patchyDeleteTarget(UUID()),
            originNodeName: "Failover"
        )
        let response = await postMutation(to: standby, request)

        XCTAssertEqual(statusCode(from: response), 409, "only the Primary may apply config mutations")
        let count = await recorder.count
        XCTAssertEqual(count, 0, "a non-leader must not apply the mutation")
    }

    func testEveryMutationCaseRoundTripsThroughCodable() throws {
        // Guards the enum's auto-synthesised Codable against case/key collisions
        // as cases accumulate. Encode → decode → must equal the original.
        let cases: [MeshConfigMutation] = [
            .patchyDeleteTarget(UUID()),
            .patchySetTargetEnabled(UUID(), true),
            .automationDeleteRule(UUID().uuidString),
            .automationToggleRule(UUID().uuidString),
            .commandSetEnabled(name: "ping", surfaces: ["slash", "prefix"], enabled: false),
            .replaceWelcomeFlow(WelcomeFlowSettings()),
            .replaceVoice(VoiceSettings()),
            .replaceWikiBot(WikiBotSettings()),
            .sweepDeletePolicy(UUID()),
            .sweepSetPolicyEnabled(UUID(), true),
            .sweepSetGlobalPaused(true)
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for original in cases {
            let data = try encoder.encode(original)
            let decoded = try decoder.decode(MeshConfigMutation.self, from: data)
            XCTAssertEqual(decoded, original, "round-trip mismatch for \(original.auditDescription)")
        }
    }

    func testDuplicateMutationAppliesOnce() async {
        let recorder = MutationRecorder()
        let leader = await makeCoordinator(mode: .leader, port: 39604)
        await leader.setConfigMutationHandler { request in
            await recorder.record(request)
            return MeshConfigMutationResponse(applied: true, reason: nil)
        }

        // Same clientMutationID across both sends → idempotent.
        let request = MeshConfigMutationRequest(
            mutation: .patchyDeleteTarget(UUID()),
            originNodeName: "Failover",
            clientMutationID: UUID()
        )

        let first = await postMutation(to: leader, request)
        let second = await postMutation(to: leader, request)

        XCTAssertEqual(statusCode(from: first), 200)
        XCTAssertEqual(statusCode(from: second), 200)
        XCTAssertEqual(decodeResponse(second)?.applied, true, "duplicate is acked as applied")
        let count = await recorder.count
        XCTAssertEqual(count, 1, "the handler must run only once for a repeated client mutation id")
    }
}
