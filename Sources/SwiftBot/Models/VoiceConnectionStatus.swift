import Foundation

/// UI-facing mirror of `VoicePlaybackService.Status`, suitable for use as a
/// `@Published` value on `AppModel`.
enum VoiceConnectionStatus: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case recovering(String)
    case disconnecting
    case failed(String)

    var displayLabel: String {
        switch self {
        case .idle: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .recovering: return "Recovering"
        case .disconnecting: return "Disconnecting"
        case .failed: return "Failed"
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var canQueueAnnouncements: Bool {
        switch self {
        case .connected, .recovering:
            return true
        case .idle, .connecting, .disconnecting, .failed:
            return false
        }
    }

    var isWaitingForConnectionData: Bool {
        switch self {
        case .connecting, .recovering:
            return true
        case .idle, .connected, .disconnecting, .failed:
            return false
        }
    }

    var failureReason: String? {
        if case .failed(let reason) = self { return reason }
        return nil
    }
}
