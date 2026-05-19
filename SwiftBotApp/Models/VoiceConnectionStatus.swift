import Foundation

/// UI-facing mirror of `VoicePlaybackService.Status`, suitable for use as a
/// `@Published` value on `AppModel`.
enum VoiceConnectionStatus: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case disconnecting
    case failed(String)

    var displayLabel: String {
        switch self {
        case .idle: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .disconnecting: return "Disconnecting"
        case .failed: return "Failed"
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var failureReason: String? {
        if case .failed(let reason) = self { return reason }
        return nil
    }
}
