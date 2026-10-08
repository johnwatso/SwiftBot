import Foundation
import AVFoundation
import RecordingsKit

/// Works out who was in a clip from voice history: the people sharing a
/// voice channel with whoever recorded it, while it was recording.
enum ClipPeopleMatcher {
    /// Assumed length when the real one isn't known yet (clips on another
    /// node, or not read yet). Most clips are short highlights.
    static let assumedClipLength: TimeInterval = 90

    /// `ownerID` is the folder's "Recorded by" member. With one, it's whoever
    /// shared their voice channel during the clip, plus them. Without one,
    /// it's everyone in voice, but only if a single channel was active;
    /// otherwise nobody, rather than a guess.
    static func people(
        window: DateInterval,
        sessions: [VoiceSession],
        ownerID: String?,
        excluding excluded: Set<String> = [],
        now: Date = Date()
    ) -> [String] {
        let overlapping = sessions.filter { $0.joinedAt < window.end && ($0.leftAt ?? now) > window.start }
        let channelKey = { (session: VoiceSession) in "\(session.guildId)|\(session.channelId)" }
        var people: Set<String> = []
        if let ownerID, !ownerID.isEmpty {
            let ownerChannels = Set(overlapping.filter { $0.userId == ownerID }.map(channelKey))
            people.insert(ownerID)
            for session in overlapping where ownerChannels.contains(channelKey(session)) {
                people.insert(session.userId)
            }
        } else {
            let channels = Set(overlapping.map(channelKey))
            guard channels.count == 1 else { return [] }
            people = Set(overlapping.map(\.userId))
        }
        return people.subtracting(excluded).sorted()
    }
}

extension AppModel {
    /// "node|itemID" → the Discord IDs of everyone in that clip.
    func clipPeopleIndex(payloads: [MediaLibraryPayload]? = nil, now: Date = Date()) async -> [String: [String]] {
        if let cached = clipPeopleCache, now.timeIntervalSince(cached.builtAt) < 60 {
            return cached.people
        }
        let payloads: [MediaLibraryPayload] = await {
            if let payloads { return payloads }
            return await allMediaLibraryPayloads()
        }()
        let localNode = localMediaNodeName
        let excluded = knownBotUserIds.union(botUserId.map { [$0] } ?? [])
        var index: [String: [String]] = [:]
        var unread: [MediaLibraryItem] = []

        // One trip to the voice history for the whole library, rather than
        // one per clip: big libraries made the Recordings page slow.
        let allItems = payloads.flatMap(\.items)
        guard let earliest = allItems.map(\.modifiedAt).min(), let latest = allItems.map(\.modifiedAt).max() else {
            clipPeopleCache = (now, [:])
            return [:]
        }
        let span = DateInterval(start: earliest.addingTimeInterval(-4 * 3_600), end: max(latest, earliest))
        let history = await voiceSessionStore.sessions(overlapping: span, now: now)

        for payload in payloads {
            for item in payload.items {
                let isLocal = payload.nodeID.map { $0 == meshLocalNodeID } ?? (payload.nodeName == localNode)
                let length = clipDurationCache[item.id] ?? ClipPeopleMatcher.assumedClipLength
                if isLocal, clipDurationCache[item.id] == nil { unread.append(item) }
                let window = DateInterval(start: item.modifiedAt.addingTimeInterval(-length), end: item.modifiedAt)
                let sessions = history.filter { $0.joinedAt < window.end && ($0.leftAt ?? now) > window.start }
                guard !sessions.isEmpty else { continue }
                let owner = settings.recordingSourceOwners["\(payload.identity)|\(item.sourceID.uuidString)"]
                    ?? settings.recordingSourceOwners["\(payload.nodeName)|\(item.sourceID.uuidString)"]
                let people = ClipPeopleMatcher.people(window: window, sessions: sessions, ownerID: owner, excluding: excluded, now: now)
                if !people.isEmpty { index["\(payload.identity)|\(item.id)"] = people }
            }
        }
        clipPeopleCache = (now, index)
        if !unread.isEmpty { readClipDurations(unread) }
        return index
    }

    private var localMediaNodeName: String {
        settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "SwiftBot Node")
            : settings.clusterNodeName
    }

    /// Reads real clip lengths in the background (a few hundred at a time),
    /// then lets the next index use them.
    private func readClipDurations(_ items: [MediaLibraryItem]) {
        let batch = Array(items.prefix(300))
        Task { [weak self] in
            // The reading happens off the main actor and never touches self,
            // which older compilers (Xcode 26) insist on.
            let found = await Task.detached(priority: .utility) { () -> [String: TimeInterval] in
                var found: [String: TimeInterval] = [:]
                for item in batch {
                    let asset = AVURLAsset(url: URL(fileURLWithPath: item.absolutePath))
                    if let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0 {
                        found[item.id] = min(duration.seconds, 4 * 3_600)
                    }
                }
                return found
            }.value
            guard let self, !found.isEmpty else { return }
            self.clipDurationCache.merge(found) { _, new in new }
            self.clipPeopleCache = nil
        }
    }

    /// A member's clips: only the ones they were in, without node or folder
    /// details.
    func memberClips(userID: String, query: [String: String]) async -> AdminWebMediaLibraryPayload {
        let payloads = await allMediaLibraryPayloads()
        let people = await clipPeopleIndex(payloads: payloads)
        let mine = Set(people.filter { $0.value.contains(userID) }.keys)
        var memberQuery = query
        memberQuery["source"] = nil
        memberQuery["person"] = nil
        let library = adminWebMediaLibrarySnapshot(payloads: payloads, query: memberQuery, people: people, onlyItems: mine)
        return AdminWebMediaLibraryPayload(
            generatedAt: library.generatedAt,
            sources: [],
            items: library.items.map { item in
                var copy = AdminWebMediaItemPayload(
                    id: item.id, nodeName: "", sourceName: "", gameName: item.gameName,
                    fileName: item.fileName, relativePath: "", fileExtension: item.fileExtension,
                    sizeBytes: item.sizeBytes, modifiedAt: item.modifiedAt,
                    thumbnailURL: item.thumbnailURL, streamURL: item.streamURL
                )
                copy.available = item.available
                copy.people = item.people
                copy.recordedByID = item.recordedByID
                return copy
            },
            games: library.games,
            gameSummaries: library.gameSummaries,
            selectedSourceID: nil,
            selectedDateRange: library.selectedDateRange,
            selectedGame: library.selectedGame,
            page: library.page,
            pageSize: library.pageSize,
            totalItems: library.totalItems,
            totalPages: library.totalPages
        )
    }

    /// Whether a playback token (`/api/media/stream?id=…`) is for a clip
    /// this member was in. The web server asks before any member playback.
    func memberMayPlay(userID: String, token: String) async -> Bool {
        guard let descriptor = decodedMediaStreamToken(token) else { return false }
        guard await recordingRoute(for: descriptor) != nil else { return false }
        let people = await clipPeopleIndex()
        return people["\(descriptor.ownerNodeID ?? descriptor.ownerNodeName)|\(descriptor.itemID)"]?.contains(userID) == true
    }

    /// Admin: who records into a folder. Empty clears it.
    func setRecordingSourceOwner(sourceKey: String, userID: String) -> Bool {
        let key = sourceKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.contains("|") else { return false }
        let user = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        if user.isEmpty {
            settings.recordingSourceOwners[key] = nil
        } else {
            guard user.allSatisfy(\.isNumber) else { return false }
            settings.recordingSourceOwners[key] = user
        }
        clipPeopleCache = nil
        saveSettings()
        return true
    }
}
