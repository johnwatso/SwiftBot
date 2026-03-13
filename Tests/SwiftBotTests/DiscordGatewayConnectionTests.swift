import Foundation
import XCTest
@testable import SwiftBot

final class DiscordGatewayConnectionTests: XCTestCase {
    func testConnectWithEmptyTokenStopsWithoutOpeningSocket() async {
        let factory = SocketFactoryQueue(sockets: [FakeGatewaySocket()])
        let recorder = EventRecorder()
        let connection = makeConnection(factory: factory)

        await connection.setOnConnectionState { state in
            await recorder.record(state: state)
        }

        await connection.connect(token: "   ")

        let states = await recorder.states()
        let createdCount = await factory.createdCount()
        XCTAssertEqual(states, [.stopped])
        XCTAssertEqual(createdCount, 0)
    }

    func testHelloPayloadSendsIdentifyAndTransitionsRunning() async {
        let socket = FakeGatewaySocket(
            scriptedResults: [
                .success(#"{"op":10,"d":{"heartbeat_interval":60000}}"#)
            ]
        )
        let factory = SocketFactoryQueue(sockets: [socket])
        let recorder = EventRecorder()
        let connection = makeConnection(factory: factory)

        await connection.setOnConnectionState { state in
            await recorder.record(state: state)
        }

        await connection.connect(token: "bot-token")

        let ready = await waitUntil {
            let states = await recorder.states()
            let sent = await socket.sentTexts()
            return states.contains(.running) && sent.contains(where: { $0.contains("\"op\":2") })
        }

        XCTAssertTrue(ready)
        let states = await recorder.states()
        XCTAssertEqual(states, [.connecting, .running])
        let sent = await socket.sentTexts()
        XCTAssertTrue(sent.contains(where: { $0.contains("\"op\":2") && $0.contains("bot-token") }))

        await connection.disconnect()
    }

    func testHeartbeatAckReportsLatencyAfterHeartbeatRequest() async {
        let dateProvider = FixedDateProvider(
            dates: [
                Date(timeIntervalSince1970: 10),
                Date(timeIntervalSince1970: 10.25)
            ]
        )
        let socket = FakeGatewaySocket(
            scriptedResults: [
                .success(#"{"op":10,"d":{"heartbeat_interval":60000}}"#),
                .success(#"{"op":1,"d":null}"#),
                .success(#"{"op":11,"d":null}"#)
            ]
        )
        let factory = SocketFactoryQueue(sockets: [socket])
        let recorder = EventRecorder()
        let connection = makeConnection(factory: factory, dateProvider: { dateProvider.next() })

        await connection.setOnHeartbeatLatency { latencyMs in
            await recorder.record(latency: latencyMs)
        }

        await connection.connect(token: "bot-token")

        let reported = await waitUntil {
            await recorder.latencies().count == 1
        }

        XCTAssertTrue(reported)
        let latencies = await recorder.latencies()
        XCTAssertEqual(latencies, [250])
        let sent = await socket.sentTexts()
        XCTAssertTrue(sent.contains(where: { $0.contains("\"op\":2") }))
        XCTAssertTrue(sent.contains(where: { $0.contains("\"op\":1") }))

        await connection.disconnect()
    }

    func testReceiveFailureReportsCloseCodeAndReconnects() async {
        let failingSocket = FakeGatewaySocket(
            scriptedResults: [.failure(SocketFailure.disconnected)],
            closeCodeOnFailure: .protocolError
        )
        let replacementSocket = FakeGatewaySocket()
        let factory = SocketFactoryQueue(sockets: [failingSocket, replacementSocket])
        let recorder = EventRecorder()
        let connection = makeConnection(
            factory: factory,
            sleep: { _ in }
        )

        await connection.setOnConnectionState { state in
            await recorder.record(state: state)
        }
        await connection.setOnGatewayClose { code in
            await recorder.record(closeCode: code)
        }

        await connection.connect(token: "bot-token")

        let reconnected = await waitUntil {
            await factory.createdCount() == 2
        }

        XCTAssertTrue(reconnected)
        let states = await recorder.states()
        let closeCodes = await recorder.closeCodes()
        XCTAssertTrue(states.contains(.reconnecting))
        XCTAssertEqual(closeCodes, [URLSessionWebSocketTask.CloseCode.protocolError.rawValue])

        await connection.disconnect()
    }

    private func makeConnection(
        factory: SocketFactoryQueue,
        dateProvider: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) -> DiscordGatewayConnection {
        DiscordGatewayConnection(
            session: URLSession(configuration: .ephemeral),
            gatewayURL: URL(string: "wss://gateway.discord.gg/?v=10&encoding=json")!,
            dependencies: .init(
                socketFactory: { _, _ in
                    await factory.nextSocket()
                },
                dateProvider: dateProvider,
                sleep: sleep
            )
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_500_000_000,
        intervalNanoseconds: UInt64 = 20_000_000,
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().timeIntervalSince1970 + (Double(timeoutNanoseconds) / 1_000_000_000)
        while Date().timeIntervalSince1970 < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        return await condition()
    }
}

private enum SocketFailure: Error {
    case disconnected
}

private actor EventRecorder {
    private var recordedStates: [BotStatus] = []
    private var recordedLatencies: [Int] = []
    private var recordedCloseCodes: [Int] = []

    func record(state: BotStatus) {
        recordedStates.append(state)
    }

    func record(latency: Int) {
        recordedLatencies.append(latency)
    }

    func record(closeCode: Int) {
        recordedCloseCodes.append(closeCode)
    }

    func states() -> [BotStatus] {
        recordedStates
    }

    func latencies() -> [Int] {
        recordedLatencies
    }

    func closeCodes() -> [Int] {
        recordedCloseCodes
    }
}

private actor SocketFactoryQueue {
    private var sockets: [FakeGatewaySocket]
    private var created = 0

    init(sockets: [FakeGatewaySocket]) {
        self.sockets = sockets
    }

    func nextSocket() -> FakeGatewaySocket {
        created += 1
        if sockets.isEmpty {
            return FakeGatewaySocket()
        }
        return sockets.removeFirst()
    }

    func createdCount() -> Int {
        created
    }
}

private final class FakeGatewaySocket: DiscordGatewayConnection.Socket, @unchecked Sendable {
    private actor State {
        private var scriptedResults: [Result<String, Error>]
        private var sentTexts: [String] = []

        init(scriptedResults: [Result<String, Error>]) {
            self.scriptedResults = scriptedResults
        }

        func nextResult() async -> Result<String, Error>? {
            guard !scriptedResults.isEmpty else { return nil }
            return scriptedResults.removeFirst()
        }

        func recordSent(_ text: String) {
            sentTexts.append(text)
        }

        func snapshotSentTexts() -> [String] {
            sentTexts
        }
    }

    private let state: State
    private let closeCodeOnFailure: URLSessionWebSocketTask.CloseCode
    private let lock = NSLock()
    private var storedCloseCode: URLSessionWebSocketTask.CloseCode = .invalid

    init(
        scriptedResults: [Result<String, Error>] = [],
        closeCodeOnFailure: URLSessionWebSocketTask.CloseCode = .invalid
    ) {
        state = State(scriptedResults: scriptedResults)
        self.closeCodeOnFailure = closeCodeOnFailure
    }

    var closeCode: URLSessionWebSocketTask.CloseCode {
        lock.lock()
        defer { lock.unlock() }
        return storedCloseCode
    }

    func resume() {}

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.lock()
        storedCloseCode = closeCode
        lock.unlock()
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        if let next = await state.nextResult() {
            switch next {
            case .success(let text):
                return .string(text)
            case .failure(let error):
                setStoredCloseCode(closeCodeOnFailure)
                throw error
            }
        }

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        throw CancellationError()
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case .string(let text) = message else { return }
        await state.recordSent(text)
    }

    func sentTexts() async -> [String] {
        await state.snapshotSentTexts()
    }

    private func setStoredCloseCode(_ closeCode: URLSessionWebSocketTask.CloseCode) {
        lock.lock()
        storedCloseCode = closeCode
        lock.unlock()
    }
}

private final class FixedDateProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date]
    private var fallback: Date

    init(dates: [Date]) {
        self.dates = dates
        fallback = dates.last ?? Date(timeIntervalSince1970: 0)
    }

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        guard !dates.isEmpty else { return fallback }
        let nextDate = dates.removeFirst()
        fallback = nextDate
        return nextDate
    }
}
