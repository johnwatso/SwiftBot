import AppKit
import RecordingsKit
import AVFoundation
import CryptoKit
import Foundation
import SwiftUI

extension AppModel {

    // MARK: - Media Library

    func localMediaLibrarySnapshot(ownerBaseURL: String? = nil) async -> MediaLibraryPayload {
        let configURL = await mediaLibraryConfigStore.fileURL()
        let ownerNodeName = settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "SwiftBot Node")
            : settings.clusterNodeName
        var payload = await mediaLibraryIndexer.snapshot(
            sources: localRecordingSources,
            ownerNodeName: ownerNodeName,
            ownerBaseURL: ownerBaseURL,
            configFilePath: configURL.path
        )
        payload.nodeID = meshLocalNodeID.isEmpty ? nil : meshLocalNodeID
        payload.fresh = true
        if ownerBaseURL == nil {
            let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
            recentMediaCount24h = payload.items.filter { $0.modifiedAt >= cutoff }.count
        }
        // Lighter copies of the newest clips, made in the background so
        // they play smoothly the first time over a slow link.
        for item in payload.items.sorted(by: { $0.modifiedAt > $1.modifiedAt }).prefix(3)
        where item.modifiedAt < Date().addingTimeInterval(-60) {
            await mediaTranscodeCache.prepareInBackground(itemID: item.id, sourceURL: URL(fileURLWithPath: item.absolutePath), quality: .standard)
        }
        return payload
    }

    /// The automatically managed export source is hidden until exporting is ready.
    /// Keep its saved configuration and files intact so it can return later.
    var localRecordingSources: [MediaLibrarySource] {
        mediaLibrarySettings.sources.filter { $0.id != mediaLibrarySettings.exportSourceID }
    }

    private func mediaExportRootURL() -> URL {
        let trimmed = mediaLibrarySettings.exportRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return SwiftBotStorage.folderURL()
                .appendingPathComponent("recordings", isDirectory: true)
                .appendingPathComponent("exports", isDirectory: true)
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    private func mediaFastStartOutputURL(for settings: MediaLibrarySettings? = nil) -> URL? {
        let activeSettings = settings ?? mediaLibrarySettings
        guard activeSettings.fastStartOptimizationEnabled else { return nil }
        let trimmed = activeSettings.fastStartOutputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    private func prepareMediaFastStartCacheIfEnabled() async -> Bool {
        guard let outputURL = mediaFastStartOutputURL() else { return false }
        await mediaFastStartCache.updateCacheRoot(outputURL)
        return true
    }

    private func removeLegacyMediaFastStartCache(excluding outputURL: URL?) {
        let legacyURL = Self.defaultMediaFastStartCacheRoot.standardizedFileURL
        if outputURL?.standardizedFileURL == legacyURL {
            return
        }
        try? FileManager.default.removeItem(at: legacyURL)
    }

    private func encodedMediaStreamToken(itemID: String, ownerNodeName: String, ownerNodeID: String?) -> String {
        let descriptor = MediaStreamDescriptor(itemID: itemID, ownerNodeName: ownerNodeName, ownerNodeID: ownerNodeID)
        guard let data = try? JSONEncoder().encode(descriptor) else { return "" }
        return data
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func decodedMediaStreamToken(_ token: String) -> MediaStreamDescriptor? {
        var base64 = token
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        if padding > 0 {
            base64 += String(repeating: "=", count: padding)
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONDecoder().decode(MediaStreamDescriptor.self, from: data)
    }

    private func mediaContentType(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "m4v": return "video/x-m4v"
        case "webm": return "video/webm"
        case "mkv": return "video/x-matroska"
        default: return "application/octet-stream"
        }
    }

    nonisolated static func parseByteRange(_ header: String?, fileSize: UInt64) -> (offset: UInt64, length: UInt64)? {
        guard let header = header?.trimmingCharacters(in: .whitespacesAndNewlines),
              header.lowercased().hasPrefix("bytes="),
              fileSize > 0 else { return nil }

        let rawRange = String(header.dropFirst("bytes=".count))
        let parts = rawRange.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }

        if parts[0].isEmpty, let suffixLength = UInt64(parts[1]) {
            guard suffixLength > 0 else { return nil }
            let length = min(suffixLength, fileSize)
            return (offset: fileSize - length, length: length)
        }

        guard let start = UInt64(parts[0]), start < fileSize else { return nil }
        let end: UInt64
        if parts[1].isEmpty {
            end = fileSize - 1
        } else if let parsedEnd = UInt64(parts[1]) {
            end = min(parsedEnd, fileSize - 1)
        } else {
            return nil
        }

        guard end >= start else { return nil }
        return (offset: start, length: end - start + 1)
    }

    private func localMediaItem(for itemID: String) async -> MediaLibraryItem? {
        if let cached = await mediaLibraryIndexer.cachedItem(for: itemID) {
            return cached
        }
        let snapshot = await localMediaLibrarySnapshot()
        return snapshot.items.first(where: { $0.id == itemID })
    }

    func localMediaStreamResponse(itemID: String, rangeHeader: String?, quality: String? = nil) async -> BinaryHTTPResponse? {
        guard let item = await localMediaItem(for: itemID) else { return nil }

        let originalURL = URL(fileURLWithPath: item.absolutePath)
        let normalizedQuality = quality?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let resolvedURL: URL
        let resolvedSource: String
        // Only a copy that's already prepared is used; playback never waits
        // for an encode (see mediaPlaybackChoice).
        if normalizedQuality == "low" || normalizedQuality == "standard" {
            guard let variantURL = await mediaTranscodeCache.cachedVariantURL(
                itemID: item.id, sourceURL: originalURL,
                quality: normalizedQuality == "low" ? .low : .standard
            ) else { return nil }
            resolvedURL = variantURL
            resolvedSource = normalizedQuality ?? "standard"
        } else if normalizedQuality == "faststart" {
            guard await prepareMediaFastStartCacheIfEnabled(),
                  let optimizedURL = await mediaFastStartCache.cachedOptimizedURL(itemID: item.id, sourceURL: originalURL)
            else { return nil }
            resolvedURL = optimizedURL
            resolvedSource = "faststart"
        } else {
            // Keep byte offsets tied to the original for the whole playback.
            resolvedURL = originalURL
            resolvedSource = "raw"
        }
        let fileURL = resolvedURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSizeNumber = attributes[.size] as? NSNumber else {
            return nil
        }

        let fileSize = fileSizeNumber.uint64Value
        let contentType = mediaContentType(for: fileURL.path)
        let requestedRange = Self.parseByteRange(rangeHeader, fileSize: fileSize)
        if rangeHeader != nil && requestedRange == nil {
            return BinaryHTTPResponse(status: "416 Range Not Satisfiable", contentType: contentType,
                                      headers: ["Content-Range": "bytes */\(fileSize)", "Accept-Ranges": "bytes"], body: Data())
        }
        // Serve modest chunks so we don't load hundreds of MB into RAM
        // before the first byte hits the wire. Browsers will issue follow-up
        // range requests as the playback buffer drains, and each request
        // returns quickly instead of stalling for seconds.
        let chunkLength: UInt64 = 8 * 1024 * 1024
        let initialChunkLength = min(fileSize, chunkLength)
        let maxRangeResponseLength = min(fileSize, chunkLength)
        let effectiveRange: (offset: UInt64, length: UInt64)
        let responseStatus: String
        if let requestedRange {
            effectiveRange = (offset: requestedRange.offset, length: min(requestedRange.length, maxRangeResponseLength))
            responseStatus = "206 Partial Content"
        } else if fileSize <= initialChunkLength {
            effectiveRange = (offset: 0, length: fileSize)
            responseStatus = "200 OK"
        } else {
            effectiveRange = (offset: 0, length: initialChunkLength)
            responseStatus = "206 Partial Content"
        }

        let debugStream = StreamDebug.enabled
        let debugContext = StreamDebug.context(itemID: itemID, source: resolvedSource, rangeHeader: rangeHeader)
        let debugStart = debugStream ? Date() : nil
        let isPartialResponse = responseStatus == "206 Partial Content"
        // Task.detached is intentional here: FileHandle I/O is synchronous and must not
        // block the MainActor. All captures are value types (no self), so there is no
        // object-lifecycle race. This is the one justified Task.detached in the codebase.
        return await Task.detached(priority: .utility) { [fileURL, fileSize, contentType, effectiveRange, isPartialResponse, responseStatus, debugStream, debugContext, debugStart] in
            do {
                let handle = try FileHandle(forReadingFrom: fileURL)
                defer { try? handle.close() }

                try handle.seek(toOffset: effectiveRange.offset)
                let data = try handle.read(upToCount: Int(effectiveRange.length)) ?? Data()
                if debugStream, let started = debugStart {
                    StreamDebug.log(
                        context: debugContext,
                        offset: effectiveRange.offset,
                        requestedLength: effectiveRange.length,
                        deliveredLength: UInt64(data.count),
                        fileSize: fileSize,
                        status: responseStatus,
                        elapsedMs: Date().timeIntervalSince(started) * 1000.0
                    )
                }
                if isPartialResponse {
                    let end = data.isEmpty
                        ? effectiveRange.offset
                        : effectiveRange.offset + UInt64(data.count) - 1
                    return BinaryHTTPResponse(
                        status: responseStatus,
                        contentType: contentType,
                        headers: [
                            "Accept-Ranges": "bytes",
                            "Content-Range": "bytes \(effectiveRange.offset)-\(end)/\(fileSize)",
                            "Content-Length": "\(data.count)"
                        ],
                        body: data
                    )
                } else {
                    return BinaryHTTPResponse(
                        status: responseStatus,
                        contentType: contentType,
                        headers: [
                            "Accept-Ranges": "bytes",
                            "Content-Length": "\(data.count)"
                        ],
                        body: data
                    )
                }
            } catch {
                return BinaryHTTPResponse(
                    status: "500 Internal Server Error",
                    contentType: "application/json",
                    headers: [:],
                    body: Data("{\"error\":\"media read failed\"}".utf8)
                )
            }
        }.value
    }

    // MARK: - HLS streaming

    /// Serves the HLS playlist for a local recording, packaging it into fMP4
    /// segments on first request. The on-disk playlist references segments by
    /// bare file name; here we rewrite those into authorized segment URLs the
    /// browser's player can fetch, reusing the same `id` token the playlist was
    /// requested with plus the caller's short-lived access token.
    func localMediaHLSPlaylistResponse(itemID: String, idToken: String, accessToken: String?) async -> BinaryHTTPResponse? {
        guard let item = await localMediaItem(for: itemID) else { return nil }
        let originalURL = URL(fileURLWithPath: item.absolutePath)
        var variants: [String] = ["#EXTM3U", "#EXT-X-VERSION:7"]
        for quality in [MediaTranscodeCache.Quality.low, .standard] {
            guard let source = await mediaTranscodeCache.variantURL(itemID: itemID, sourceURL: originalURL, quality: quality),
                  await hlsPackager.playlistURL(itemID: itemID + "_" + quality.rawValue, sourceURL: source) != nil else { continue }
            let bandwidth = quality == .low ? 3_800_000 : 9_800_000
            variants.append("#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth)")
            variants.append(quality.rawValue + "-playlist.m3u8")
        }
        guard variants.count > 2 else { return nil }
        let rewritten = rewriteHLSPlaylist(variants.joined(separator: "\n"), idToken: idToken, accessToken: accessToken)
        return BinaryHTTPResponse(status: "200 OK", contentType: "application/vnd.apple.mpegurl",
                                  headers: ["Cache-Control": "no-cache"], body: Data(rewritten.utf8))
    }

    /// Serves a rendition playlist or segment using the same authorization as the master.
    func localMediaHLSSegmentResponse(itemID: String, segment: String, idToken: String, accessToken: String?) async -> BinaryHTTPResponse? {
        guard let separator = segment.firstIndex(of: "-"),
              let quality = MediaTranscodeCache.Quality(rawValue: String(segment[..<separator])),
              let item = await localMediaItem(for: itemID) else { return nil }
        let name = String(segment[segment.index(after: separator)...])
        let originalURL = URL(fileURLWithPath: item.absolutePath)
        guard let sourceURL = await mediaTranscodeCache.variantURL(itemID: itemID, sourceURL: originalURL, quality: quality) else { return nil }
        let variantID = itemID + "_" + quality.rawValue
        if name == HLSPackager.playlistFileName {
            guard let url = await hlsPackager.playlistURL(itemID: variantID, sourceURL: sourceURL),
                  let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let rewritten = rewriteHLSPlaylist(raw, idToken: idToken, accessToken: accessToken, prefix: quality.rawValue + "-")
            return BinaryHTTPResponse(status: "200 OK", contentType: "application/vnd.apple.mpegurl",
                                      headers: ["Cache-Control": "no-cache"], body: Data(rewritten.utf8))
        }
        guard let segmentURL = await hlsPackager.segmentURL(itemID: variantID, sourceURL: sourceURL, segment: name),
              let data = try? Data(contentsOf: segmentURL) else { return nil }
        return BinaryHTTPResponse(status: "200 OK", contentType: "video/mp4",
                                  headers: ["Cache-Control": "private, max-age=300", "Content-Length": "\(data.count)"], body: data)
    }

    /// Rewrites the bare segment names in a generated playlist into relative
    /// segment URLs (`hls-segment?id=…&seg=…&token=…`) that resolve against the
    /// playlist endpoint and carry auth.
    private func rewriteHLSPlaylist(_ playlist: String, idToken: String, accessToken: String?, prefix: String = "") -> String {
        func encode(_ value: String) -> String {
            let allowed = CharacterSet(charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        }
        func segmentURL(_ name: String) -> String {
            var url = "hls-segment?id=\(encode(idToken))&seg=\(encode(name))"
            if let accessToken, !accessToken.isEmpty {
                url += "&token=\(encode(accessToken))"
            }
            return url
        }

        var lines: [String] = []
        for rawLine in playlist.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("#EXT-X-MAP:URI=\"") {
                lines.append("#EXT-X-MAP:URI=\"\(segmentURL(prefix + HLSPackager.initSegmentFileName))\"")
            } else if !line.hasPrefix("#") && (line.hasSuffix(".m4s") || line.hasSuffix(".m3u8")) {
                lines.append(segmentURL(prefix + line))
            } else {
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    func adminWebRecordMediaPlayback(_ patch: AdminWebMediaPlaybackPatch) async -> Bool {
        let normalizedEvent = patch.event.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let watchedSeconds = max(0, patch.watchedSeconds ?? 0)

        mediaPlaybackViewedItemIDs.insert(patch.itemID)
        mediaPlaybackUniqueItemCount = mediaPlaybackViewedItemIDs.count

        if normalizedEvent == "started",
           mediaPlaybackStartedSessionIDs.insert(patch.sessionID).inserted {
            mediaPlaybackStarts += 1
        }

        if normalizedEvent == "progress" || normalizedEvent == "completed" {
            let lastReported = mediaPlaybackLastSecondsBySession[patch.sessionID] ?? 0
            if watchedSeconds > lastReported {
                mediaPlaybackTotalSeconds += watchedSeconds - lastReported
                mediaPlaybackLastSecondsBySession[patch.sessionID] = watchedSeconds
            }
        }

        if normalizedEvent == "completed",
           mediaPlaybackCompletedSessionIDs.insert(patch.sessionID).inserted {
            mediaPlaybackCompletedViews += 1
        }

        return true
    }

    func localMediaThumbnailResponse(itemID: String) async -> BinaryHTTPResponse? {
        guard let item = await localMediaItem(for: itemID) else { return nil }
        return await mediaThumbnailCache.thumbnailResponse(for: item)
    }

    func localMediaFrameResponse(itemID: String, atSeconds: Double) async -> BinaryHTTPResponse? {
        guard let item = await localMediaItem(for: itemID) else { return nil }
        return await mediaThumbnailCache.frameResponse(for: item, atSeconds: atSeconds)
    }

    private func parsedPositiveInt(_ value: String?, default defaultValue: Int, max: Int) -> Int {
        guard let value,
              let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              parsed > 0 else {
            return defaultValue
        }
        return min(parsed, max)
    }

    private func filteredMediaItemPayloads(
        from payloads: [MediaLibraryPayload],
        selectedSourceID: String?,
        selectedDateRange: String,
        selectedGame: String?,
        people: [String: [String]] = [:],
        selectedPerson: String? = nil,
        onlyItems allowed: Set<String>? = nil
    ) -> [AdminWebMediaItemPayload] {
        let normalizedSelectedGame = selectedGame?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let minimumModifiedDate: Date? = {
            switch selectedDateRange {
            case "7d":
                return Calendar.current.date(byAdding: .day, value: -7, to: Date())
            case "30d":
                return Calendar.current.date(byAdding: .day, value: -30, to: Date())
            case "90d":
                return Calendar.current.date(byAdding: .day, value: -90, to: Date())
            default:
                return nil
            }
        }()

        return payloads
            .flatMap { payload in
                payload.items.compactMap { item in
                    let itemKey = "\(payload.identity)|\(item.id)"
                    if let allowed, !allowed.contains(itemKey) { return nil }
                    let itemPeople = people[itemKey] ?? []
                    if let selectedPerson, !itemPeople.contains(selectedPerson) { return nil }
                    let sourceToken = "\(payload.identity)|\(item.sourceID.uuidString)"
                    if let selectedSourceID, !selectedSourceID.isEmpty, sourceToken != selectedSourceID {
                        return nil
                    }
                    if let minimumModifiedDate, item.modifiedAt < minimumModifiedDate {
                        return nil
                    }

                    let detectedGame = mediaGameName(for: item.fileName)
                    let legacyKey = "\(payload.nodeName)|\(item.id)"
                    let gameName = resolvedMediaGameName(itemKey: itemKey, detected: detectedGame, legacyItemKey: legacyKey)
                    if let normalizedSelectedGame, !normalizedSelectedGame.isEmpty, normalizedGameKey(gameName) != normalizedSelectedGame {
                        return nil
                    }

                    let token = encodedMediaStreamToken(
                        itemID: item.id,
                        ownerNodeName: payload.nodeName,
                        ownerNodeID: payload.nodeID
                    )
                    var result = AdminWebMediaItemPayload(
                        id: itemKey,
                        nodeName: payload.nodeName,
                        sourceName: item.sourceName,
                        gameName: gameName,
                        fileName: item.fileName,
                        relativePath: item.relativePath,
                        fileExtension: item.fileExtension,
                        sizeBytes: item.sizeBytes,
                        modifiedAt: item.modifiedAt,
                        thumbnailURL: "/api/media/thumbnail?id=\(token)",
                        streamURL: "/api/media/stream?id=\(token)"
                    )
                    result.available = payload.isAvailable(item)
                    result.people = itemPeople.map { AdminWebSimpleOption(id: $0, name: knownUsersById[$0] ?? "Member") }
                    result.recordedByID = settings.recordingSourceOwners[sourceToken]
                        ?? settings.recordingSourceOwners["\(payload.nodeName)|\(item.sourceID.uuidString)"]
                    result.detectedGameName = detectedGame
                    result.gameMatch = (settings.recordingGameOverrides[itemKey] ?? settings.recordingGameOverrides[legacyKey]) != nil ? "clip"
                        : gameName != detectedGame ? "detected" : nil
                    return result
                }
            }
            .sorted {
                if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
                return $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending
            }
    }

    func mediaGameName(for fileName: String) -> String {
        let baseName = (fileName as NSString).deletingPathExtension
        let normalized = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return "Unlabeled" }

        let upper = normalized.uppercased()
        if upper.hasPrefix("THE_FINALS_") {
            return "THE FINALS"
        }

        if let range = normalized.range(of: "_replay_", options: [.caseInsensitive]) {
            let rawGame = String(normalized[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            return Self.canonicalMediaGameName(rawGame.replacingOccurrences(of: "_", with: " "))
        }

        // "Unknown" (a replay with no game) and "Unlabeled" both mean there's
        // no game to file it under, so they share one filter entry.
        return "Unlabeled"
    }

    /// The game a clip is filed under: a Fix Match for this clip, then one
    /// for every clip detected as the same game, then the filename's game.
    func resolvedMediaGameName(itemKey: String, detected: String, legacyItemKey: String? = nil) -> String {
        if let fixed = settings.recordingGameOverrides[itemKey] { return fixed }
        if let legacyItemKey, let fixed = settings.recordingGameOverrides[legacyItemKey] { return fixed }
        if let alias = settings.recordingGameAliases[normalizedGameKey(detected)] { return alias }
        return detected
    }

    func resolvedMediaGameName(for item: MediaLibraryItem, nodeName: String) -> String {
        resolvedMediaGameName(itemKey: "\(nodeName)|\(item.id)", detected: mediaGameName(for: item.fileName))
    }

    /// Admin Fix Match. An empty `gameName` returns the clip (or every clip
    /// detected as its game) to the filename's game. With `applyToDetected`,
    /// the match covers every clip whose filename names the same game,
    /// including future ones, and this clip's own fix is cleared.
    func fixMediaGameMatch(itemKey rawKey: String, gameName rawName: String, steamAppID: String?, applyToDetected: Bool) async -> Bool {
        let itemKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // Kept as picked, only tidied: it's a deliberate name.
        let gameName = Self.tidiedMediaGameName(rawName)
        let isReset = gameName.isEmpty
        guard itemKey.contains("|"), gameName.count <= 120 else { return false }
        guard let item = await allMediaLibraryPayloads()
            .lazy
            .compactMap({ payload in payload.items.first { "\(payload.identity)|\($0.id)" == itemKey } })
            .first else { return false }
        let detectedKey = normalizedGameKey(mediaGameName(for: item.fileName))

        if applyToDetected {
            guard detectedKey != "unlabeled" else { return false }
            settings.recordingGameAliases[detectedKey] = isReset || normalizedGameKey(gameName) == detectedKey ? nil : gameName
            settings.recordingGameOverrides[itemKey] = nil
        } else {
            settings.recordingGameOverrides[itemKey] = isReset ? nil : gameName
        }
        if !isReset, let appID = steamAppID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !appID.isEmpty, appID.allSatisfy(\.isNumber) {
            // Pin the artwork to the title that was picked, so the poster
            // matches even when the name alone would find another game.
            await RecordingSteamArtworkService.shared.setManualAppID(for: gameName, appID: appID)
        }
        saveSettings()
        return true
    }

    /// Fix Match for a whole game in the library: every clip filed under
    /// `fromGame` moves to `gameName`, and so do future clips detected as
    /// the same games. Clips fixed one at a time follow along.
    func renameMediaGame(from rawFrom: String, to rawName: String, steamAppID: String?) async -> Bool {
        let from = rawFrom.trimmingCharacters(in: .whitespacesAndNewlines)
        let gameName = Self.tidiedMediaGameName(rawName)
        // "Unlabeled" is every clip with no game; filing them all under one
        // would also catch every future unlabeled clip.
        guard !from.isEmpty, from != "Unlabeled", !gameName.isEmpty, gameName.count <= 120 else { return false }

        for payload in await allMediaLibraryPayloads() {
            for item in payload.items {
                let itemKey = "\(payload.identity)|\(item.id)"
                let legacyKey = "\(payload.nodeName)|\(item.id)"
                if let fixed = settings.recordingGameOverrides[itemKey] ?? settings.recordingGameOverrides[legacyKey] {
                    if fixed == from { settings.recordingGameOverrides[itemKey] = gameName }
                    continue
                }
                let detected = mediaGameName(for: item.fileName)
                guard detected != "Unlabeled", resolvedMediaGameName(itemKey: itemKey, detected: detected) == from else { continue }
                let key = normalizedGameKey(detected)
                settings.recordingGameAliases[key] = key == normalizedGameKey(gameName) ? nil : gameName
            }
        }
        // Detected names with no clips right now still follow, for later clips.
        for (key, value) in settings.recordingGameAliases where value == from {
            settings.recordingGameAliases[key] = key == normalizedGameKey(gameName) ? nil : gameName
        }
        if let appID = steamAppID?.trimmingCharacters(in: .whitespacesAndNewlines), !appID.isEmpty, appID.allSatisfy(\.isNumber) {
            await RecordingSteamArtworkService.shared.setManualAppID(for: gameName, appID: appID)
        }
        saveSettings()
        return true
    }

    /// Whitespace collapsed and trademark marks dropped, so "Call of Duty®:
    /// Black Ops 6" from Steam and a recorder's "Call of Duty: Black Ops 6"
    /// file under one game.
    static func tidiedMediaGameName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "[®™©]", with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Folds the names recorders write for one game into a single filter
    /// entry: "cod" shorthand, and Call of Duty HQ's launcher names that list
    /// every bundled title ("Call of Duty Modern Warfare II Call of Duty
    /// Modern Warfare III Warzone 2.0") or tack Warzone onto one.
    static func canonicalMediaGameName(_ raw: String) -> String {
        // A beta is the same game: "Call of Duty Modern Warfare 4 - Beta".
        let name = tidiedMediaGameName(raw)
            .replacingOccurrences(of: #"\s*[-–(]?\s*\b(open\s+)?beta\)?$"#, with: "", options: [.regularExpression, .caseInsensitive])
        let lower = name.lowercased()
        if name.isEmpty || lower == "unknown" { return "Unlabeled" }
        if lower == "cod" { return "Call of Duty" }
        guard lower.hasPrefix("call of duty ") else { return name }
        if lower.components(separatedBy: "call of duty").count > 2 { return "Call of Duty" }
        let warzoneSuffix = " warzone 2.0"
        if lower.hasSuffix(warzoneSuffix), lower.count > "call of duty".count + warzoneSuffix.count {
            return String(name.dropLast(warzoneSuffix.count))
        }
        return name
    }

    private func normalizedGameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func adminWebMediaLibrarySnapshot(query: [String: String] = [:]) async -> AdminWebMediaLibraryPayload {
        let payloads = await allMediaLibraryPayloads()
        let people = await clipPeopleIndex(payloads: payloads)
        return adminWebMediaLibrarySnapshot(payloads: payloads, query: query, people: people)
    }

    /// All reported libraries, independent of Discord leadership.
    func allMediaLibraryPayloads() async -> [MediaLibraryPayload] {
        await coordinatedMediaLibraries()
    }

    func adminWebMediaLibrarySnapshot(
        payloads: [MediaLibraryPayload],
        query: [String: String],
        people: [String: [String]],
        onlyItems allowed: Set<String>? = nil
    ) -> AdminWebMediaLibraryPayload {
        let rawSelectedPerson = query["person"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selectedPerson = rawSelectedPerson.isEmpty ? nil : rawSelectedPerson
        let sourcePayloads: [AdminWebMediaSourcePayload] = payloads.flatMap { payload in
            payload.sources.map { source in
                AdminWebMediaSourcePayload(
                    id: "\(payload.identity)|\(source.id.uuidString)",
                    nodeName: payload.nodeName,
                    sourceName: source.name,
                    itemCount: payload.items.filter { $0.sourceID == source.id }.count,
                    ownerID: settings.recordingSourceOwners["\(payload.identity)|\(source.id.uuidString)"]
                        ?? settings.recordingSourceOwners["\(payload.nodeName)|\(source.id.uuidString)"]
                )
            }
        }

        let rawSelectedSourceID = query["source"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selectedSourceID = rawSelectedSourceID.isEmpty ? nil : rawSelectedSourceID
        let rawSelectedDateRange = query["dateRange"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selectedDateRange = rawSelectedDateRange.isEmpty ? "all" : rawSelectedDateRange
        let rawSelectedGame = query["game"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selectedGame = rawSelectedGame.isEmpty ? nil : rawSelectedGame
        let pageSize = parsedPositiveInt(query["pageSize"], default: 24, max: 96)
        let page = parsedPositiveInt(query["page"], default: 1, max: 10_000)

        let unfilteredForGames = filteredMediaItemPayloads(
            from: payloads,
            selectedSourceID: selectedSourceID,
            selectedDateRange: selectedDateRange,
            selectedGame: nil,
            people: people,
            selectedPerson: selectedPerson,
            onlyItems: allowed
        )
        let availableGames = Array(Set(unfilteredForGames.map { $0.gameName }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let gameSummaries = Dictionary(grouping: unfilteredForGames, by: \.gameName)
            .map { name, entries in
                AdminWebMediaGameSummary(
                    name: name,
                    clipCount: entries.count,
                    latestAt: entries.map(\.modifiedAt).max(),
                    totalBytes: entries.reduce(0) { $0 + $1.sizeBytes }
                )
            }
            .sorted { lhs, rhs in
                // Most recently played first, like a "continue watching" row.
                (lhs.latestAt ?? .distantPast) > (rhs.latestAt ?? .distantPast)
            }

        let filteredItems = filteredMediaItemPayloads(
            from: payloads,
            selectedSourceID: selectedSourceID,
            selectedDateRange: selectedDateRange,
            selectedGame: selectedGame,
            people: people,
            selectedPerson: selectedPerson,
            onlyItems: allowed
        )
        let totalItems = filteredItems.count
        let totalPages = max(1, Int(ceil(Double(max(totalItems, 1)) / Double(pageSize))))
        let clampedPage = min(page, totalPages)
        let startIndex = max(0, (clampedPage - 1) * pageSize)
        let endIndex = min(filteredItems.count, startIndex + pageSize)
        let pagedItems = Array(filteredItems[startIndex..<endIndex])

        return AdminWebMediaLibraryPayload(
            generatedAt: Date(),
            sources: sourcePayloads.sorted { lhs, rhs in
                if lhs.nodeName != rhs.nodeName {
                    return lhs.nodeName.localizedCaseInsensitiveCompare(rhs.nodeName) == .orderedAscending
                }
                return lhs.sourceName.localizedCaseInsensitiveCompare(rhs.sourceName) == .orderedAscending
            },
            items: pagedItems,
            games: availableGames,
            gameSummaries: gameSummaries,
            selectedSourceID: selectedSourceID,
            selectedDateRange: selectedDateRange,
            selectedGame: selectedGame,
            page: clampedPage,
            pageSize: pageSize,
            totalItems: totalItems,
            totalPages: totalPages,
            coordinationStatus: mediaLibrarySettings.sharedLibraryEnabled ? recordingCoordinationStatus : nil
        )
    }

    /// Which file a playback should use, decided once before it starts so it
    /// never switches mid-play: the lighter "standard" copy (8 Mbps, up to
    /// 1080p) when it's ready, otherwise the original, while the copy is
    /// made in the background for next time. Remote nodes choose their own
    /// prepared copy through the authenticated mesh route.
    func mediaPlaybackChoice(token: String) async -> (quality: String, preparing: Bool)? {
        guard let descriptor = decodedMediaStreamToken(token), let route = await recordingRoute(for: descriptor) else { return nil }
        switch route {
        case .local: return await localMediaPlaybackChoice(itemID: descriptor.itemID)
        case .remote(let baseURL):
            return await cluster.fetchRemoteMediaPlaybackChoice(from: baseURL, itemID: descriptor.itemID)
        }
    }

    func localMediaPlaybackChoice(itemID: String) async -> (quality: String, preparing: Bool)? {
        guard let item = await localMediaItem(for: itemID) else { return nil }
        let source = URL(fileURLWithPath: item.absolutePath)
        if await mediaTranscodeCache.cachedVariantURL(itemID: item.id, sourceURL: source, quality: .standard) != nil {
            return ("standard", false)
        }
        await mediaTranscodeCache.prepareInBackground(itemID: item.id, sourceURL: source, quality: .standard)
        if await prepareMediaFastStartCacheIfEnabled(),
           await mediaFastStartCache.cachedOptimizedURL(itemID: item.id, sourceURL: source) != nil {
            return ("faststart", true)
        }
        return ("original", true)
    }

    func adminWebMediaStreamResponse(token: String, rangeHeader: String?, quality: String? = nil) async -> BinaryHTTPResponse? {
        guard let descriptor = decodedMediaStreamToken(token), let route = await recordingRoute(for: descriptor) else { return nil }
        switch route {
        case .local: return await localMediaStreamResponse(itemID: descriptor.itemID, rangeHeader: rangeHeader, quality: quality)
        case .remote(let baseURL):
            return await cluster.fetchRemoteMediaStream(from: baseURL, itemID: descriptor.itemID, rangeHeader: rangeHeader, quality: quality)
        }
    }

    func adminWebMediaThumbnailResponse(token: String) async -> BinaryHTTPResponse? {
        guard let descriptor = decodedMediaStreamToken(token), let route = await recordingRoute(for: descriptor) else { return nil }
        switch route {
        case .local: return await localMediaThumbnailResponse(itemID: descriptor.itemID)
        case .remote(let baseURL): return await cluster.fetchRemoteMediaThumbnail(from: baseURL, itemID: descriptor.itemID)
        }
    }

    func adminWebMediaFrameResponse(token: String, atSeconds: Double) async -> BinaryHTTPResponse? {
        guard let descriptor = decodedMediaStreamToken(token), let route = await recordingRoute(for: descriptor) else { return nil }
        switch route {
        case .local: return await localMediaFrameResponse(itemID: descriptor.itemID, atSeconds: atSeconds)
        case .remote(let baseURL): return await cluster.fetchRemoteMediaFrame(from: baseURL, itemID: descriptor.itemID, seconds: atSeconds)
        }
    }

    func adminWebMediaHLSPlaylistResponse(token: String, accessToken: String?) async -> BinaryHTTPResponse? {
        guard let descriptor = decodedMediaStreamToken(token), case .local? = await recordingRoute(for: descriptor) else { return nil }
        return await localMediaHLSPlaylistResponse(itemID: descriptor.itemID, idToken: token, accessToken: accessToken)
    }

    func adminWebMediaHLSSegmentResponse(token: String, segment: String, accessToken: String?) async -> BinaryHTTPResponse? {
        guard let descriptor = decodedMediaStreamToken(token), case .local? = await recordingRoute(for: descriptor) else { return nil }
        return await localMediaHLSSegmentResponse(itemID: descriptor.itemID, segment: segment, idToken: token, accessToken: accessToken)
    }

    func adminWebMediaExportStatus() async -> MediaExportStatus {
        await mediaExportCoordinator.exportStatus()
    }

    func adminWebMediaExportJobs() async -> MediaExportJobsPayload {
        let jobs = await mediaExportCoordinator.listJobs()
        await MainActor.run { self.mediaExportJobs = jobs }
        return MediaExportJobsPayload(jobs: jobs)
    }

    func adminWebStartMediaClipExport(request: MediaExportClipRequest) async -> MediaExportJobResponse {
        guard request.endSeconds > request.startSeconds else {
            return MediaExportJobResponse(job: nil, error: "End time must be after start time.")
        }
        guard request.endSeconds - request.startSeconds <= maxMediaClipDurationSeconds else {
            return MediaExportJobResponse(job: nil, error: "Clip length exceeds 15 minutes.")
        }
        guard let descriptor = decodedMediaStreamToken(request.token) else {
            return MediaExportJobResponse(job: nil, error: "Invalid media token.")
        }

        let localNodeName = settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "SwiftBot Node")
            : settings.clusterNodeName

        guard case .local? = await recordingRoute(for: descriptor) else {
            return MediaExportJobResponse(job: nil, error: "Export a shared recording on the Mac that stores it.")
        }

        guard let item = await localMediaItem(for: descriptor.itemID) else {
            return MediaExportJobResponse(job: nil, error: "Media item not found.")
        }

        let exportRoot = mediaExportRootURL()
        try? FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        let job = await mediaExportCoordinator.startClip(
            item: item,
            request: request,
            exportRoot: exportRoot,
            nodeName: localNodeName
        )
        await mediaLibraryIndexer.invalidate()
        return MediaExportJobResponse(job: job, error: nil)
    }

    func adminWebStartMediaMultiViewExport(request: MediaExportMultiViewRequest) async -> MediaExportJobResponse {
        guard let primaryDescriptor = decodedMediaStreamToken(request.primaryToken),
              let secondaryDescriptor = decodedMediaStreamToken(request.secondaryToken) else {
            return MediaExportJobResponse(job: nil, error: "Invalid media token.")
        }

        guard primaryDescriptor.ownerNodeID == secondaryDescriptor.ownerNodeID,
              case .local? = await recordingRoute(for: primaryDescriptor),
              case .local? = await recordingRoute(for: secondaryDescriptor) else {
            return MediaExportJobResponse(job: nil, error: "Export multiview recordings on the Mac that stores both files.")
        }
        if let start = request.startSeconds, let end = request.endSeconds {
            guard end > start else {
                return MediaExportJobResponse(job: nil, error: "End time must be after start time.")
            }
            guard end - start <= maxMediaClipDurationSeconds else {
                return MediaExportJobResponse(job: nil, error: "Clip length exceeds 15 minutes.")
            }
        }

        let localNodeName = settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "SwiftBot Node")
            : settings.clusterNodeName

        guard let primary = await localMediaItem(for: primaryDescriptor.itemID),
              let secondary = await localMediaItem(for: secondaryDescriptor.itemID) else {
            return MediaExportJobResponse(job: nil, error: "Media item not found.")
        }

        let exportRoot = mediaExportRootURL()
        try? FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        let job = await mediaExportCoordinator.startMultiView(
            primary: primary,
            secondary: secondary,
            request: request,
            exportRoot: exportRoot,
            nodeName: localNodeName
        )
        await mediaLibraryIndexer.invalidate()
        return MediaExportJobResponse(job: job, error: nil)
    }

    func localMediaClipExport(request: MeshMediaClipRequest) async -> MediaExportJob? {
        guard request.endSeconds > request.startSeconds else { return nil }
        guard request.endSeconds - request.startSeconds <= maxMediaClipDurationSeconds else { return nil }
        guard let item = await localMediaItem(for: request.itemID) else { return nil }
        let exportRoot = mediaExportRootURL()
        try? FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        let localNodeName = settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "SwiftBot Node")
            : settings.clusterNodeName
        let job = await mediaExportCoordinator.startClip(
            item: item,
            request: MediaExportClipRequest(
                token: "",
                startSeconds: request.startSeconds,
                endSeconds: request.endSeconds,
                name: request.name
            ),
            exportRoot: exportRoot,
            nodeName: localNodeName
        )
        await mediaLibraryIndexer.invalidate()
        return job
    }

    func localMediaMultiViewExport(request: MeshMediaMultiViewRequest) async -> MediaExportJob? {
        if let start = request.startSeconds, let end = request.endSeconds {
            guard end > start, end - start <= maxMediaClipDurationSeconds else { return nil }
        }
        guard let primary = await localMediaItem(for: request.primaryID),
              let secondary = await localMediaItem(for: request.secondaryID) else { return nil }
        let exportRoot = mediaExportRootURL()
        try? FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        let localNodeName = settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "SwiftBot Node")
            : settings.clusterNodeName
        let job = await mediaExportCoordinator.startMultiView(
            primary: primary,
            secondary: secondary,
            request: MediaExportMultiViewRequest(
                primaryToken: "",
                secondaryToken: "",
                layout: request.layout,
                audioSource: request.audioSource,
                startSeconds: request.startSeconds,
                endSeconds: request.endSeconds,
                name: request.name
            ),
            exportRoot: exportRoot,
            nodeName: localNodeName
        )
        await mediaLibraryIndexer.invalidate()
        return job
    }

    func startMediaMonitor() {
        guard mediaMonitorTask == nil else { return }
        mediaMonitorTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.scanMediaForNewItems()
                do {
                    try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                } catch {
                    break
                }
            }
        }
    }

    func stopMediaMonitor() {
        mediaMonitorTask?.cancel()
        mediaMonitorTask = nil
        lastSeenMediaItemIDs.removeAll()
        attemptedFastStartPrewarmKeys.removeAll()
    }

    private func scanMediaForNewItems() async {
        guard runtimeClusterMode != .standby else { return }
        let hasLocalSources = mediaLibrarySettings.sources.contains { $0.isEnabled && !$0.normalizedRootPath.isEmpty }
        if !hasLocalSources && runtimeClusterMode != .leader {
            return
        }

        await prewarmLocalMediaFastStartCache()

        let shouldScan = automationStore.rules.contains { $0.enabled && $0.trigger.kind == .mediaAdded }
        guard shouldScan else {
            lastSeenMediaItemIDs.removeAll()
            return
        }
        let payloads = await mediaPayloadsForTriggers()

        let allItems: [(payload: MediaLibraryPayload, item: MediaLibraryItem)] = payloads.flatMap { payload in
            payload.items.map { (payload, $0) }
        }
        let currentIDs = Set(allItems.map { "\($0.payload.identity)|\($0.item.id)" })

        if lastSeenMediaItemIDs.isEmpty {
            lastSeenMediaItemIDs = currentIDs
            return
        }

        let newItems = allItems.filter { !lastSeenMediaItemIDs.contains("\($0.payload.identity)|\($0.item.id)") }
        lastSeenMediaItemIDs = currentIDs

        guard !newItems.isEmpty else { return }
        for entry in newItems {
            await handleMediaAddedEvent(item: entry.item, nodeName: entry.payload.nodeName)
        }
    }

    private func prewarmLocalMediaFastStartCache() async {
        guard runtimeClusterMode != .standby,
              await prepareMediaFastStartCacheIfEnabled() else {
            attemptedFastStartPrewarmKeys.removeAll()
            return
        }

        let payload = await localMediaLibrarySnapshot()
        let settleCutoff = Date().addingTimeInterval(-2 * 60)
        let batchLimit = 2
        var warmedCount = 0

        for item in payload.items where warmedCount < batchLimit {
            guard item.fileExtension.lowercased() == "mp4",
                  item.modifiedAt < settleCutoff else {
                continue
            }

            let mtimeStamp = Int(item.modifiedAt.timeIntervalSince1970)
            let prewarmKey = "\(item.id)|\(mtimeStamp)"
            guard !attemptedFastStartPrewarmKeys.contains(prewarmKey) else {
                continue
            }

            attemptedFastStartPrewarmKeys.insert(prewarmKey)
            warmedCount += 1
            _ = await mediaFastStartCache.optimizedURL(
                itemID: item.id,
                sourceURL: URL(fileURLWithPath: item.absolutePath)
            )
        }
    }

    func reconcileMediaFastStartCachePolicy(for settings: MediaLibrarySettings? = nil) async {
        let activeSettings = settings ?? mediaLibrarySettings
        attemptedFastStartPrewarmKeys.removeAll()
        guard let outputURL = mediaFastStartOutputURL(for: activeSettings) else {
            await mediaFastStartCache.updateCacheRoot(Self.defaultMediaFastStartCacheRoot)
            await mediaFastStartCache.removeAllCachedFiles()
            return
        }
        await mediaFastStartCache.updateCacheRoot(outputURL)
        removeLegacyMediaFastStartCache(excluding: outputURL)
    }

    private func mediaPayloadsForTriggers() async -> [MediaLibraryPayload] {
        // Only the output owner evaluates shared media automations. Serving and
        // browsing libraries is independent of this exclusive-work permission.
        guard runtimeClusterMode == .leader else { return [await localMediaLibrarySnapshot()] }
        return await allMediaLibraryPayloads().map { payload in
            var copy = payload
            copy.items = payload.items.filter { payload.isAvailable($0) }
            return copy
        }
    }

    private func handleMediaAddedEvent(item: MediaLibraryItem, nodeName: String) async {
        let event = SwiftBotEvent.mediaAdded(
            SwiftBotEvent.MediaPayload(
                guildId: nodeName,
                userId: botUserId ?? "0",
                username: nodeName,
                fileName: item.fileName,
                relativePath: item.relativePath,
                sourceName: item.sourceName,
                nodeName: nodeName
            )
        )

        await fireAutomations(for: event)
    }

    func saveMeshCursors(_ cursors: [String: ReplicationCursor]) async {
        do {
            try await meshCursorStore.save(cursors)
        } catch {
            logs.append("⚠️ Failed to save mesh cursors: \(error.localizedDescription)")
        }
    }

}
