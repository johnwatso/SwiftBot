import Foundation

/// Ruru's Preferred Primary for this service: `POST /v1/service/policy`,
/// version 1 (Ruru `Documentation/PRIMARY_PREFERENCE.md`). Advisory intent
/// only. It never grants ownership; leases still decide who may act.
struct MeshPrimaryPolicy: Equatable, Sendable {
    /// A stable enrollment node ID (the witness `nodeID`), or nil for none.
    let preferredPrimaryNodeID: String?
    /// Increments on each selection or clear. Not a lease term.
    let revision: Int64

    static let supportedVersion = 1

    /// Ruru's rules: 1–128 UTF-8 bytes, no control characters, no
    /// surrounding whitespace. Case-sensitive.
    static func isValidNodeID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128
            && id == id.trimmingCharacters(in: .whitespacesAndNewlines)
            && id.rangeOfCharacter(from: .controlCharacters) == nil
    }

    /// Strict decode of a 200 body. `preferredPrimaryNodeID` must be present:
    /// explicit null means "no preference", a missing key is malformed.
    static func decode(_ data: Data, expectedClusterID: String) -> MeshPrimaryPolicy? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = integer(object["version"]), version == Int64(supportedVersion),
              object["clusterID"] as? String == expectedClusterID,
              let revision = integer(object["preferenceRevision"]), revision >= 0,
              let rawID = object["preferredPrimaryNodeID"] else { return nil }
        if rawID is NSNull { return MeshPrimaryPolicy(preferredPrimaryNodeID: nil, revision: revision) }
        guard let id = rawID as? String, isValidNodeID(id) else { return nil }
        return MeshPrimaryPolicy(preferredPrimaryNodeID: id, revision: revision)
    }

    /// JSON integers only: rejects booleans, fractions and out-of-range values.
    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, abs(double) < 9.2e18 else { return nil }
        return number.int64Value
    }
}

enum MeshPrimaryPolicyFetch: Equatable, Sendable {
    case policy(MeshPrimaryPolicy)
    /// 404: a Ruru without the policy route. Legacy behaviour applies.
    case unsupported
    /// Network failure, 401/403/400/5xx, or a malformed or unknown-version body.
    case unavailable
}

/// What this Mac currently knows of Ruru's preference.
struct MeshPrimaryPreference: Equatable, Sendable {
    enum Status: String, Sendable {
        /// No witness, or SwiftMesh is standalone.
        case notConfigured
        /// Witness configured; no usable read yet under this configuration.
        case checking
        case current
        case unsupported
        case unavailable
    }

    var status: Status = .notConfigured
    /// The last accepted policy under the current configuration. Kept for
    /// display while unavailable, but only acted on while fresh.
    var policy: MeshPrimaryPolicy?
    var receivedAt: ContinuousClock.Instant?
    /// Ruru's `/health` reports ready (not unreachable or in restart quarantine).
    var authorityReady = false

    /// Ruru is polled every 5 s; a read older than this is stale intent.
    static let freshness: Duration = .seconds(15)

    func isFresh(at now: ContinuousClock.Instant) -> Bool {
        guard status == .current, let receivedAt else { return false }
        return now - receivedAt <= Self.freshness
    }

    /// The node Ruru prefers, from a fresh read only.
    func freshPreferredNodeID(at now: ContinuousClock.Instant) -> String? {
        isFresh(at: now) ? policy?.preferredPrimaryNodeID : nil
    }
}

/// Folds poll results into a `MeshPrimaryPreference`, dropping results from an
/// earlier configuration, out-of-order revisions, and contradictory reads.
struct MeshPrimaryPreferenceTracker: Sendable {
    private(set) var preference = MeshPrimaryPreference()
    private(set) var generation = 0

    /// Call whenever the endpoint, cluster ID or token may have changed, and
    /// on stop. Clears all cached intent. Returns the new generation, which
    /// in-flight polls must present to be accepted.
    @discardableResult
    mutating func reset(configured: Bool) -> Int {
        generation += 1
        let ready = preference.authorityReady
        preference = MeshPrimaryPreference(status: configured ? .checking : .notConfigured)
        preference.authorityReady = configured && ready
        return generation
    }

    mutating func setAuthorityReady(_ ready: Bool) {
        preference.authorityReady = preference.status != .notConfigured && ready
    }

    /// Returns whether the result was applied.
    @discardableResult
    mutating func ingest(_ fetch: MeshPrimaryPolicyFetch, generation: Int, at now: ContinuousClock.Instant) -> Bool {
        guard generation == self.generation, preference.status != .notConfigured else { return false }
        switch fetch {
        case .policy(let policy):
            if let last = preference.policy {
                // A delayed response from before a change: keep the newer one.
                if policy.revision < last.revision { return false }
                // Same revision, different answer: Ruru never does this, so
                // trust neither until a consistent read arrives.
                if policy.revision == last.revision, policy.preferredPrimaryNodeID != last.preferredPrimaryNodeID {
                    preference.status = .unavailable
                    return false
                }
            }
            preference.policy = policy
            preference.status = .current
            preference.receivedAt = now
        case .unsupported:
            preference.policy = nil
            preference.status = .unsupported
            preference.receivedAt = now
        case .unavailable:
            preference.status = .unavailable
        }
        return true
    }
}

/// Who may start an automatic handback, and who the current owner accepts.
/// Failover after a dead Primary does not consult this at all.
enum MeshPrimaryPreferenceDecision {
    /// Whether this Standby may start an automatic handback toward itself.
    /// A fresh Ruru preference replaces the configured-Primary rule; with no
    /// preference (null), no witness, or an older Ruru (404), the configured
    /// Primary reclaims as before. Unknown or stale intent starts nothing.
    static func mayReclaimAutomatically(
        _ preference: MeshPrimaryPreference,
        localNodeID: String,
        localMode: ClusterMode,
        isConfiguredPrimary: Bool,
        now: ContinuousClock.Instant
    ) -> Bool {
        // Workers never become Primary from a preference.
        guard localMode == .standby else { return false }
        switch preference.status {
        case .notConfigured, .unsupported:
            return isConfiguredPrimary
        case .checking, .unavailable:
            return false
        case .current:
            guard preference.isFresh(at: now), preference.authorityReady, let policy = preference.policy else { return false }
            guard let preferred = policy.preferredPrimaryNodeID else { return isConfiguredPrimary }
            return !localNodeID.isEmpty && preferred == localNodeID
        }
    }

    /// Whether the current owner accepts an automatic handback to a node whose
    /// identity was verified from its enrollment signature. When the owner has
    /// a fresh preference naming someone, only that node is accepted; that is
    /// what stops a configured Primary and a Ruru choice reclaiming in turn.
    /// Otherwise the requester's own fresh decision stands.
    static func acceptsAutomaticHandback(
        _ preference: MeshPrimaryPreference,
        verifiedTargetNodeID: String?,
        now: ContinuousClock.Instant
    ) -> Bool {
        guard let preferred = preference.freshPreferredNodeID(at: now) else { return true }
        return verifiedTargetNodeID == preferred
    }
}
