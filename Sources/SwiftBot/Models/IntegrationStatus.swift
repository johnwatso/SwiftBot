import SwiftUI

/// Connection state shown on a row in Settings › Integrations.
///
/// Deliberately small and restrained: the overview only answers "is this
/// connected, and does it need attention?". Anything more detailed belongs
/// inside that integration's configuration sheet. An integration that has
/// simply never been set up is *not* an error state — it reports
/// `notConfigured`, never `connectionFailed`.
enum IntegrationConnectionStatus: Hashable, Sendable {
    /// No credentials have ever been supplied.
    case notConfigured
    /// Configurable, but currently not linked or switched off.
    case notConnected
    /// Credentials exist, but the connection is still missing something.
    case setupRequired
    case connected
    /// A real connection attempt failed. Only ever set after an attempt.
    case connectionFailed

    var label: String {
        switch self {
        case .notConfigured: return "Not Configured"
        case .notConnected: return "Not Connected"
        case .setupRequired: return "Setup Required"
        case .connected: return "Connected"
        case .connectionFailed: return "Connection Failed"
        }
    }

    var symbolName: String {
        switch self {
        case .notConfigured, .notConnected: return "circle.dashed"
        case .setupRequired: return "exclamationmark.circle"
        case .connected: return "checkmark.circle.fill"
        case .connectionFailed: return "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .notConfigured, .notConnected: return .secondary
        case .setupRequired: return .orange
        case .connected: return .green
        case .connectionFailed: return .red
        }
    }

    /// Whether the row should draw the operator's eye. Keeps "needs attention"
    /// in one place instead of scattering colour comparisons through views.
    var needsAttention: Bool {
        switch self {
        case .setupRequired, .connectionFailed: return true
        case .notConfigured, .notConnected, .connected: return false
        }
    }
}

extension IntegrationConnectionStatus {
    /// Status for a Game Tracking data provider.
    ///
    /// `lastFailure` is the message from the most recent failed call to this
    /// provider, if any — a provider that has never been contacted can only
    /// report a configuration state, never a failure.
    static func gameProvider(
        connection: GameProviderConnectionSettings,
        descriptor: GameProviderDescriptor,
        lastFailure: String? = nil
    ) -> IntegrationConnectionStatus {
        switch connection.issue(for: descriptor) {
        case .missingCredential:
            return .notConfigured
        case .invalidBaseURL, .missingRankEndpointContract:
            return .setupRequired
        case nil:
            return lastFailure == nil ? .connected : .connectionFailed
        }
    }

    /// Status for a companion app that pairs rather than authenticates.
    static func companionApp(isPaired: Bool, isEnabled: Bool) -> IntegrationConnectionStatus {
        isPaired && isEnabled ? .connected : .notConnected
    }
}
