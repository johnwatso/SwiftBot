import Foundation

/// Tracks the wait for Discord's acknowledgement of a voice-channel leave
/// (our own VOICE_STATE_UPDATE with a null channel) during a rejoin.
enum VoiceLeaveAckState: Sendable, Equatable {
    case none
    case pending
    case received
}

/// State for the voice auto-recovery backoff: how many rejoin attempts have
/// been made since the last successful connection, whether one is in flight,
/// and what delay the next one gets. Pure state — the owner performs the
/// actual disconnect/reconnect — so the invariants are unit-testable.
struct VoiceRecoveryBackoff: Sendable, Equatable {
    /// Delay before each attempt; the count is the retry budget between
    /// successful connections.
    let schedule: [Duration]
    private(set) var attemptsMade: Int = 0
    private(set) var inProgress: Bool = false

    /// The first attempt is fast — it's the one users feel — and the later
    /// ones escalate to avoid hammering a flapping connection.
    init(schedule: [Duration] = [.milliseconds(750), .seconds(5), .seconds(15)]) {
        self.schedule = schedule
    }

    var attemptsAllowed: Int { schedule.count }

    /// Consume the next attempt and return its delay, or nil when the budget
    /// is exhausted or an attempt is already in flight.
    mutating func beginAttempt() -> Duration? {
        guard !inProgress, attemptsMade < schedule.count else { return nil }
        let delay = schedule[attemptsMade]
        attemptsMade += 1
        inProgress = true
        return delay
    }

    /// Close out the in-flight attempt without refunding it. The owner restores
    /// the budget only after the recovered connection remains healthy for its
    /// stability window; otherwise a briefly successful but still-flapping
    /// session could loop forever on attempt one.
    mutating func finishAttempt() {
        inProgress = false
    }

    /// Abandon the in-flight attempt without touching the budget (e.g. the
    /// user manually disconnected mid-recovery).
    mutating func cancel() {
        inProgress = false
    }

    /// Restore the full budget (e.g. a fresh user-initiated connect).
    mutating func reset() {
        attemptsMade = 0
        inProgress = false
    }
}

/// A short, explicit cool-off after the bounded recovery budget is exhausted.
/// It stops independent auto-join triggers from immediately rebuilding the
/// same flapping voice session. A manual join or rejoin always clears it.
struct AnnouncerRecoveryCircuitBreaker: Sendable, Equatable {
    private(set) var openedAt: Date?
    private(set) var resumesAt: Date?
    private(set) var reason: String?
    private(set) var exhaustedAttempts: Int = 0

    var isOpen: Bool {
        guard let resumesAt else { return false }
        return Date() < resumesAt
    }

    mutating func trip(reason: String, attempts: Int, now: Date = Date(), cooldown: TimeInterval = 5 * 60) {
        openedAt = now
        resumesAt = now.addingTimeInterval(cooldown)
        self.reason = reason
        exhaustedAttempts = attempts
    }

    mutating func reset() {
        openedAt = nil
        resumesAt = nil
        reason = nil
        exhaustedAttempts = 0
    }

    func remainingSeconds(now: Date = Date()) -> Int {
        guard let resumesAt else { return 0 }
        return max(0, Int(resumesAt.timeIntervalSince(now).rounded(.up)))
    }
}
