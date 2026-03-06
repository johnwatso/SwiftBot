import Foundation

struct ConnectionDiagnostics {
    enum RESTHealth {
        case unknown
        case ok
        case error(Int, String)
    }

    var heartbeatLatencyMs: Int? = nil
    var restHealth: RESTHealth = .unknown
    var rateLimitRemaining: Int? = nil
    var lastTestAt: Date? = nil
    var lastTestMessage: String = ""
    /// Last non-normal WebSocket close code from Discord (e.g. 4004, 4014). Nil = no abnormal close.
    var lastGatewayCloseCode: Int? = nil
}
