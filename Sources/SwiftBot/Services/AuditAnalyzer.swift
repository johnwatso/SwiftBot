import Foundation

// MARK: - Detector protocol

/// A single analysis rule. Pure and side-effect free: given a snapshot it
/// returns findings. New finding types (drift, unused, hierarchy, AI summaries…)
/// are added by writing a new `Detector` — nothing else in the pipeline changes.
protocol Detector: Sendable {
    var category: FindingCategory { get }
    func evaluate(_ snapshot: ServerSnapshot) -> [Finding]
}

// MARK: - Analyzer

/// Owns the detector registry and runs them over a snapshot. Actor-isolated so
/// analysis never touches the main thread or shares mutable state.
actor AuditAnalyzer {
    private let detectors: [any Detector]

    init(detectors: [any Detector] = AuditAnalyzer.defaultDetectors) {
        self.detectors = detectors
    }

    /// Phase 1 ships the two highest-signal, lowest-false-positive detectors.
    static let defaultDetectors: [any Detector] = [
        DangerousPermissionDetector(),
        DuplicateRoleDetector()
    ]

    func analyze(_ snapshot: ServerSnapshot) -> [Finding] {
        let raw = detectors.flatMap { $0.evaluate(snapshot) }
        let correlated = raw.map { finding -> Finding in
            var copy = finding
            copy.evidence = AuditCorrelator.evidence(for: finding, in: snapshot)
            return copy
        }
        return correlated.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            if $0.category != $1.category { return $0.category.rawValue < $1.category.rawValue }
            return $0.title < $1.title
        }
    }
}

// MARK: - Fingerprint

enum FindingFingerprint {
    /// Stable id from category + subject roles + a semantic discriminator. The
    /// discriminator should encode anything whose change *should* resurface a
    /// dismissed finding (e.g. severity escalation), and exclude volatile noise
    /// (exact counts, timestamps).
    static func make(category: FindingCategory, subjectRoleIDs: [String], discriminator: String) -> String {
        let roles = subjectRoleIDs.sorted().joined(separator: ",")
        return "\(category.rawValue)|\(roles)|\(discriminator)"
    }
}

// MARK: - Correlator

/// Pairs a finding's subject roles with the recent audit events about them.
enum AuditCorrelator {
    static let maxEvidence = 5

    static func evidence(for finding: Finding, in snapshot: ServerSnapshot) -> [DiscordAuditEvent] {
        let subjects = Set(finding.subjectRoleIDs)
        let matched = snapshot.recentEvents
            .filter { event in
                guard let target = event.targetID else { return false }
                return subjects.contains(target)
            }
            .sorted { $0.createdAt > $1.createdAt }
        return Array(matched.prefix(maxEvidence))
    }
}

// MARK: - Dangerous permissions

/// Flags roles holding elevated permissions, escalating when the role is also
/// broadly reachable (mentionable) — the "Temp Staff has Administrator and is
/// mentionable by everyone" case.
struct DangerousPermissionDetector: Detector {
    let category: FindingCategory = .permissionRisk

    private static let elevatedBits: [(name: String, mask: UInt64)] = [
        ("Administrator", DiscordPermissionCatalog.administrator),
        ("Manage Server", 1 << 5),
        ("Manage Roles", 1 << 28),
        ("Ban Members", 1 << 2),
        ("Kick Members", 1 << 1)
    ]

    func evaluate(_ snapshot: ServerSnapshot) -> [Finding] {
        snapshot.roles.compactMap { role -> Finding? in
            guard role.name != "@everyone", !role.managed else { return nil }

            let flagged = Self.elevatedBits.filter { role.permissions & $0.mask != 0 }
            guard !flagged.isEmpty else { return nil }

            let hasAdmin = role.hasAdministrator
            // Administrator subsumes everything else — don't also list the
            // individual elevated bits when admin is set.
            let names = hasAdmin ? ["Administrator"] : flagged.map(\.name)

            let severity: Severity
            if hasAdmin && role.mentionable {
                severity = .critical
            } else if hasAdmin {
                severity = .warning
            } else {
                severity = .notice
            }

            let summary: String
            if hasAdmin && role.mentionable {
                summary = "\(role.name) has Administrator and is mentionable by everyone."
            } else if hasAdmin {
                summary = "\(role.name) has Administrator — full access to the server."
            } else {
                summary = "\(role.name) holds \(names.joined(separator: ", "))."
            }

            let discriminator = "admin:\(hasAdmin)|mention:\(role.mentionable)"
            let flaggedMasks = hasAdmin
                ? [DiscordPermissionCatalog.administrator]
                : flagged.map(\.mask)

            return Finding(
                id: FindingFingerprint.make(category: category, subjectRoleIDs: [role.id], discriminator: discriminator),
                category: category,
                severity: severity,
                title: "\(role.name) has elevated permissions",
                summary: summary,
                subjectRoleIDs: [role.id],
                evidence: [],
                actions: [.review, .ignore],
                detail: .permissionRisk(role: role, flaggedBits: flaggedMasks)
            )
        }
    }
}

// MARK: - Duplicate roles

/// Clusters roles that look like duplicates — same permissions plus either a
/// matching colour or a closely similar name ("Moderator" / "Mods").
struct DuplicateRoleDetector: Detector {
    let category: FindingCategory = .duplicateRoles

    private static let nameSimilarityThreshold = 0.7

    func evaluate(_ snapshot: ServerSnapshot) -> [Finding] {
        let candidates = snapshot.roles.filter { $0.name != "@everyone" && !$0.managed }

        // Union-find over candidate indices; union two roles when they share
        // identical permissions AND (same colour OR similar names).
        var parent = Array(candidates.indices)
        func find(_ i: Int) -> Int {
            var r = i
            while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }
            return r
        }
        func union(_ a: Int, _ b: Int) { parent[find(a)] = find(b) }

        for i in candidates.indices {
            for j in (i + 1)..<candidates.count {
                let a = candidates[i], b = candidates[j]
                guard a.permissions == b.permissions else { continue }
                let colourMatch = a.colorRGB == b.colorRGB
                let nameMatch = Self.nameSimilarity(a.name, b.name) >= Self.nameSimilarityThreshold
                if colourMatch || nameMatch { union(i, j) }
            }
        }

        var clusters: [Int: [AuditRole]] = [:]
        for i in candidates.indices {
            clusters[find(i), default: []].append(candidates[i])
        }

        return clusters.values.compactMap { group -> Finding? in
            guard group.count >= 2 else { return nil }
            let sorted = group.sorted { $0.position > $1.position }
            let primary = sorted[0]
            let others = Array(sorted.dropFirst())
            let names = sorted.map(\.name)

            let reasons = duplicateReasons(sorted)
            let summary = "\(names.joined(separator: " and ")) look like duplicates — \(reasons)."

            return Finding(
                id: FindingFingerprint.make(category: category, subjectRoleIDs: sorted.map(\.id), discriminator: "dup"),
                category: category,
                severity: .notice,
                title: "\(names.joined(separator: " / ")) may be duplicates",
                summary: summary,
                subjectRoleIDs: sorted.map(\.id),
                evidence: [],
                actions: [.compare, .review, .ignore],
                detail: .duplicate(primary: primary, others: others)
            )
        }
    }

    private func duplicateReasons(_ roles: [AuditRole]) -> String {
        var reasons: [String] = ["same permissions"]
        if Set(roles.map(\.colorRGB)).count == 1 { reasons.append("same colour") }
        let positions = roles.map(\.position).sorted()
        if let lo = positions.first, let hi = positions.last, hi - lo <= 2 { reasons.append("adjacent hierarchy") }
        return reasons.joined(separator: ", ")
    }

    /// Normalised similarity in 0...1 based on Levenshtein distance over the
    /// lowercased names. Cheap and good enough for "Moderator"/"Mods".
    static func nameSimilarity(_ a: String, _ b: String) -> Double {
        let x = a.lowercased(), y = b.lowercased()
        if x == y { return 1 }
        let distance = levenshtein(Array(x), Array(y))
        let longest = max(x.count, y.count)
        guard longest > 0 else { return 1 }
        return 1 - (Double(distance) / Double(longest))
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = Swift.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }
}

// MARK: - Snapshot builder

/// Assembles a `ServerSnapshot` from live ingestion. Off the main actor.
struct AuditSnapshotBuilder {
    let client: DiscordAuditRESTClient

    init(session: URLSession) {
        self.client = DiscordAuditRESTClient(session: session)
    }

    func build(guildID: String, guildName: String, token: String, botHighestPosition: Int = Int.max) async throws -> ServerSnapshot {
        async let roles = client.fetchRoles(guildID: guildID, token: token)
        async let events = client.fetchAuditLog(guildID: guildID, token: token)
        return ServerSnapshot(
            guildID: guildID,
            guildName: guildName,
            capturedAt: Date(),
            botHighestPosition: botHighestPosition,
            roles: try await roles,
            recentEvents: try await events
        )
    }
}
