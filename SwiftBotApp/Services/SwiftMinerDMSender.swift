import Foundation
import OSLog

// MARK: - SwiftMiner DM Sender
//
// Encapsulates the full lifecycle of sending a SwiftMiner DM:
// - first-interaction onboarding prepend (welcome → discord linked)
// - embed routing by message type
// - event deduplication (persistent across relaunches)
// - debug isolation (no state mutation)
// - state tracking (welcome sent, onboarding completed)
// - analytics logging
//
// Designed to be instantiated inside AppModel but testable in isolation.

struct SwiftMinerDMSender: Sendable {

    struct Dependencies: Sendable {
        /// Sends an embed DM to the given Discord user ID.
        let sendDMEmbed: @Sendable (String, [String: Any]) async throws -> Void
        /// Looks up the Discord display name for a user ID.
        let discordNameForUserId: @Sendable (String) async -> String?
        /// Reads whether the user has already been welcomed.
        let hasUserBeenWelcomed: @Sendable (String) async -> Bool
        /// Reads whether the user has completed onboarding.
        let hasUserCompletedOnboarding: @Sendable (String) async -> Bool
        /// Marks the user as welcomed.
        let markUserWelcomed: @Sendable (String) async -> Void
        /// Marks the user as having completed onboarding.
        let markUserCompletedOnboarding: @Sendable (String) async -> Void
        /// Checks whether a specific event signature has already been delivered.
        let hasEventBeenSent: @Sendable (String) async -> Bool
        /// Records an event signature as delivered.
        let markEventSent: @Sendable (String) async -> Void
        /// Logs an analytics/info message.
        let logInfo: @Sendable (String) async -> Void
        /// Logs an analytics/error message.
        let logError: @Sendable (String) async -> Void
        /// Records an activity event for the admin UI.
        let recordEvent: @Sendable (String) async -> Void
    }

    private let dependencies: Dependencies
    private let router: SwiftMinerDMRouter

    init(
        dependencies: Dependencies,
        theme: SwiftMinerDMTheme = .default
    ) {
        self.dependencies = dependencies
        self.router = SwiftMinerDMRouter(theme: theme)
    }

    // MARK: - Public API

    /// Sends a typed SwiftMiner DM, handling onboarding prepend, deduplication,
    /// debug isolation, and onboarding state transitions.
    func send(request: SwiftMinerDMRequest, discordUserId: String) async -> Bool {
        let discordName = await dependencies.discordNameForUserId(discordUserId)

        // First-interaction flow: prepend welcome → discord linked for setup/linked if never welcomed.
        await maybePrependOnboarding(
            request: request,
            discordUserId: discordUserId,
            discordName: discordName
        )

        // Persistent deduplication: skip if this exact event was already delivered.
        if let eventId = request.eventId, !request.debug {
            let signature = "\(discordUserId)|\(eventId)"
            let alreadySent = await dependencies.hasEventBeenSent(signature)
            if alreadySent {
                await dependencies.logInfo(
                    "SwiftMiner \(request.messageType.rawValue) DM deduped for \(discordUserId) — already sent"
                )
                return true
            }
        }

        // Route and send the primary DM.
        let result = router.route(request: request, discordName: discordName)

        do {
            try await dependencies.sendDMEmbed(discordUserId, result.embed)
            await applyStateTransitions(
                request: request,
                result: result,
                discordUserId: discordUserId
            )
            if let eventId = request.eventId, !request.debug {
                let signature = "\(discordUserId)|\(eventId)"
                await dependencies.markEventSent(signature)
            }
            let debugTag = request.debug ? " [DEBUG]" : ""
            await dependencies.recordEvent("SwiftMiner \(result.analyticsDescription) DM sent to \(discordUserId)\(debugTag)")
            await dependencies.logInfo("SwiftMiner \(result.analyticsDescription) DM sent successfully to \(discordUserId)\(debugTag)")
            return true
        } catch {
            await dependencies.logError("SwiftMiner \(result.analyticsDescription) DM failed for \(discordUserId): \(error.localizedDescription)")
            return false
        }
    }

    /// Returns the embed that would be sent, without sending it or mutating state.
    func preview(request: SwiftMinerDMRequest, discordUserId: String) async -> [String: Any] {
        let discordName = await dependencies.discordNameForUserId(discordUserId)
        return router.route(request: request, discordName: discordName).embed
    }

    // MARK: - Private Helpers

    /// If this is a first meaningful interaction (setup or linked) and the user
    /// has never been welcomed, send the onboarding sequence: welcome → discord linked.
    private func maybePrependOnboarding(
        request: SwiftMinerDMRequest,
        discordUserId: String,
        discordName: String?
    ) async {
        let isFirstInteraction = (request.messageType == .setup || request.messageType == .linked)
        guard isFirstInteraction, !request.debug else { return }
        let hasBeenWelcomed = await dependencies.hasUserBeenWelcomed(discordUserId)
        guard !hasBeenWelcomed else { return }

        // 1. Welcome
        let welcomeRequest = SwiftMinerDMRequest(messageType: .welcome, debug: request.debug)
        let welcomeResult = router.route(request: welcomeRequest, discordName: discordName)

        do {
            try await dependencies.sendDMEmbed(discordUserId, welcomeResult.embed)
            await dependencies.markUserWelcomed(discordUserId)
            await dependencies.logInfo("SwiftMiner welcome DM sent to \(discordUserId)")
        } catch {
            await dependencies.logError("SwiftMiner welcome DM failed for \(discordUserId): \(error.localizedDescription)")
            // Continue to send the rest even if welcome fails.
        }

        // 2. Discord Linked explanation
        let discordLinkedRequest = SwiftMinerDMRequest(messageType: .discordLinked, debug: request.debug)
        let discordLinkedResult = router.route(request: discordLinkedRequest, discordName: discordName)

        do {
            try await dependencies.sendDMEmbed(discordUserId, discordLinkedResult.embed)
            await dependencies.logInfo("SwiftMiner discordLinked DM sent to \(discordUserId)")
        } catch {
            await dependencies.logError("SwiftMiner discordLinked DM failed for \(discordUserId): \(error.localizedDescription)")
        }
    }

    /// Applies onboarding state transitions based on the routed result,
    /// but only when not in debug mode.
    private func applyStateTransitions(
        request: SwiftMinerDMRequest,
        result: SwiftMinerDMResult,
        discordUserId: String
    ) async {
        guard !request.debug else { return }

        if result.shouldTrackWelcome {
            await dependencies.markUserWelcomed(discordUserId)
        }
        if result.shouldTrackCompletion {
            await dependencies.markUserCompletedOnboarding(discordUserId)
        }
    }
}
