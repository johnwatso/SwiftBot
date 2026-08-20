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

    func testOnlyConfigurationCloseCodesDemandOperatorAction() {
        XCTAssertFalse(ConnectionDiagnostics.isUnrecoverableGatewayCloseCode(nil))
        XCTAssertFalse(ConnectionDiagnostics.isUnrecoverableGatewayCloseCode(1001))
        XCTAssertFalse(ConnectionDiagnostics.isUnrecoverableGatewayCloseCode(1006))
        XCTAssertFalse(ConnectionDiagnostics.isUnrecoverableGatewayCloseCode(4008))
        XCTAssertTrue(ConnectionDiagnostics.isUnrecoverableGatewayCloseCode(4004))
        XCTAssertTrue(ConnectionDiagnostics.isUnrecoverableGatewayCloseCode(4014))
    }

    func testCloseRemedyNamesTheFixForConfigurationFailures() {
        XCTAssertTrue(ConnectionDiagnostics.gatewayCloseRemedy(for: 4004).contains("token"))
        XCTAssertTrue(ConnectionDiagnostics.gatewayCloseRemedy(for: 4014).contains("privileged intents"))
        XCTAssertTrue(ConnectionDiagnostics.gatewayCloseRemedy(for: 1006).contains("reconnected automatically"))
    }

    func testGatewayHeartbeatThresholdsAllowLongHaulNormalLatency() {
        XCTAssertFalse(ConnectionDiagnostics.isGatewayHeartbeatWarning(300))
        XCTAssertFalse(ConnectionDiagnostics.isGatewayHeartbeatWarning(500))
        XCTAssertTrue(ConnectionDiagnostics.isGatewayHeartbeatWarning(750))
        XCTAssertTrue(ConnectionDiagnostics.isGatewayHeartbeatCritical(1_500))
    }
}
