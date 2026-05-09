import Foundation

// MARK: - SwiftMiner DM Style
//
// Semantic styling for SwiftMiner DM embeds.
// Centralizes colors, accent semantics, and debug/preview treatments.

enum SwiftMinerDMStyle {
    case success
    case warning
    case info
    case recovery
    case neutral

    /// Discord embed color integer.
    var color: Int {
        switch self {
        case .success:  return 3_062_954   // green
        case .warning:  return 15_179_008  // orange
        case .info:     return 3_447_003   // blue
        case .recovery: return 15_132_320  // red
        case .neutral:  return 3_062_954   // green (default)
        }
    }

    /// Optional accent emoji prefix for titles.
    var titleEmoji: String? {
        switch self {
        case .success:  return "⚡"
        case .warning:  return "🔒"
        case .info:     return "🔗"
        case .recovery: return "⚠️"
        case .neutral:  return nil
        }
    }
}

// MARK: - Debug / Preview Styling

enum SwiftMinerDMDebugStyle {
    static let titlePrefix = "[TEST] "
    static let footerSuffix = " • TEST MESSAGE"
}
