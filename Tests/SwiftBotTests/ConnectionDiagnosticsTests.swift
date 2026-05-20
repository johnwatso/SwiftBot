import XCTest
@testable import SwiftBot

final class ConnectionDiagnosticsTests: XCTestCase {
    func testHeartbeatLatencyUsesRollingMedian() {
        var diagnostics = ConnectionDiagnostics()

        [320, 340, 1_800, 360, 380].forEach {
            diagnostics.recordHeartbeatLatency($0)
        }

        XCTAssertEqual(diagnostics.heartbeatLatencyMs, 360)
    }

    func testGatewayHeartbeatThresholdsAllowLongHaulNormalLatency() {
        XCTAssertFalse(ConnectionDiagnostics.isGatewayHeartbeatWarning(300))
        XCTAssertFalse(ConnectionDiagnostics.isGatewayHeartbeatWarning(500))
        XCTAssertTrue(ConnectionDiagnostics.isGatewayHeartbeatWarning(750))
        XCTAssertTrue(ConnectionDiagnostics.isGatewayHeartbeatCritical(1_500))
    }
}
