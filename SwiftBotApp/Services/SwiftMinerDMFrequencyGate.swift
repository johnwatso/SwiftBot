import Foundation

// MARK: - SwiftMiner DM Frequency Gate
//
// Lightweight notification throttle that prevents DM bombardment.
// Onboarding messages (welcome, discordLinked, setup, linked) bypass the gate.
// Event notifications (dropClaimed, campaignCompleted, etc.) are gated by cooldown.

actor SwiftMinerDMFrequencyGate {
    private let config: SwiftMinerDMFrequencyConfig
    private var lastSentByKey: [String: Date] = [:]

    init(config: SwiftMinerDMFrequencyConfig) {
        self.config = config
    }

    /// Returns true if the DM should be sent, false if it should be suppressed.
    func shouldSend(messageType: SwiftMinerDMMessageType, discordUserId: String) -> Bool {
        guard config.enabled else { return true }

        // Onboarding messages always pass through.
        switch messageType {
        case .welcome, .discordLinked, .setup, .linked:
            return true
        default:
            break
        }

        let now = Date()

        // Check per-type cooldown.
        let typeKey = "\(discordUserId):\(messageType.rawValue)"
        let typeCooldown = cooldown(for: messageType)
        if typeCooldown > 0 {
            if let last = lastSentByKey[typeKey], now.timeIntervalSince(last) < typeCooldown {
                return false
            }
        }

        // Check global cooldown.
        let globalKey = "\(discordUserId):global"
        if config.globalCooldownSeconds > 0 {
            if let last = lastSentByKey[globalKey], now.timeIntervalSince(last) < TimeInterval(config.globalCooldownSeconds) {
                return false
            }
        }

        // Record send timestamps.
        lastSentByKey[typeKey] = now
        lastSentByKey[globalKey] = now
        return true
    }

    private func cooldown(for messageType: SwiftMinerDMMessageType) -> TimeInterval {
        switch messageType {
        case .dropClaimed:
            return TimeInterval(config.dropClaimedCooldownSeconds)
        case .campaignCompleted:
            return TimeInterval(config.campaignCompletedCooldownSeconds)
        case .welcomeBack:
            return TimeInterval(config.welcomeBackCooldownSeconds)
        case .reauth:
            return TimeInterval(config.connectionExpiredCooldownSeconds)
        default:
            return 0
        }
    }
}
