import AppKit
import RecordingsKit
import AVFoundation
import CryptoKit
import Foundation
import SwiftUI

extension AppModel {

    // MARK: - Media Library

    func localMediaLibrarySnapshot(ownerBaseURL: String? = nil) async -> MediaLibraryPayload {
        await ensureExportSourceConfigured()
        let configURL = await mediaLibraryConfigStore.fileURL()
        let ownerNodeName = settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "SwiftBot Node")
            : settings.clusterNodeName
        let payload = await mediaLibraryIndexer.snapshot(
            sources: effectiveMediaSources(),
            ownerNodeName: ownerNodeName,
            ownerBaseURL: ownerBaseURL,
            configFilePath: configURL.path
        )
        if ownerBaseURL == nil {
            let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
            recentMediaCount24h = payload.items.filter { $0.modifiedAt >= cutoff }.count
        }
        return payload
    }

    private func effectiveMediaSources() -> [MediaLibrarySource] {
        var sources = mediaLibrarySettings.sources
        guard mediaLibrarySettings.exportIncludeInLibrary else { return sources }
        let exportPath = mediaExportRootURL().path
        if exportPath.isEmpty { return sources }
        let exportID = mediaLibrarySettings.exportSourceID ?? UUID()
        if !sources.contains(where: { $0.id == exportID }) {
            let exportSource = MediaLibrarySource(
                id: exportID,
                name: "Exports",
                rootPath: exportPath,
                isEnabled: true,
                allowedExtensions: ["mp4", "mov", "m4v"]
            )
            sources.append(exportSource)
        }
        return sources
    }

    private func ensureExportSourceConfigured() async {
        guard mediaLibrarySettings.exportIncludeInLibrary else { return }
        let exportPath = mediaExportRootURL().path
        guard !exportPath.isEmpty else { return }
        if mediaLibrarySettings.exportSourceID == nil {
            mediaLibrarySettings.exportSourceID = UUID()
        }
        let exportID = mediaLibrarySettings.exportSourceID!
        if !mediaLibrarySettings.sources.contains(where: { $0.id == exportID }) {
            mediaLibrarySettings.sources.append(
                MediaLibrarySource(
                    id: exportID,
                    name: "Exports",
                    rootPath: exportPath,
                    isEnabled: true,
                    allowedExtensions: ["mp4", "mov", "m4v"]
                )
            )
            try? await mediaLibraryConfigStore.save(mediaLibrarySettings)
        } else if let index = mediaLibrarySettings.sources.firstIndex(where: { $0.id == exportID }) {
            if mediaLibrarySettings.sources[index].rootPath != exportPath {
                mediaLibrarySettings.sources[index].rootPath = exportPath
                try? await mediaLibraryConfigStore.save(mediaLibrarySettings)
            }
        }
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

    private func encodedMediaStreamToken(itemID: String, ownerNodeName: String, ownerBaseURL: String?) -> String {
        let descriptor = MediaStreamDescriptor(itemID: itemID, ownerNodeName: ownerNodeName, ownerBaseURL: ownerBaseURL)
        guard let data = try? JSONEncoder().encode(descriptor) else { return "" }
        return data
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func decodedMediaStreamToken(_ token: String) -> MediaStreamDescriptor? {
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

    private func parseByteRange(_ header: String?, fileSize: UInt64) -> (offset: UInt64, length: UInt64)? {
        guard let header = header?.trimmingCharacters(in: .whitespacesAndNewlines),
              header.lowercased().hasPrefix("bytes="),
              fileSize > 0 else { return nil }

        let rawRange = String(header.dropFirst("bytes=".count))
        let parts = rawRange.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }

        if parts[0].isEmpty, let suffixLength = UInt64(parts[1]) {
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
        if normalizedQuality == "low",
           let variantURL = await mediaTranscodeCache.variantURL(itemID: itemID, sourceURL: originalURL, quality: .low) {
            resolvedURL = variantURL
            resolvedSource = "low"
        } else if let optimizedURL = await mediaFastStartCache.optimizedURL(itemID: itemID, sourceURL: originalURL) {
            resolvedURL = optimizedURL
            resolvedSource = "faststart"
        } else {
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
        let requestedRange = parseByteRange(rangeHeader, fileSize: fileSize)
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
        let sourceURL = URL(fileURLWithPath: item.absolutePath)
        guard let playlistURL = await hlsPackager.playlistURL(itemID: itemID, sourceURL: sourceURL),
              let raw = try? String(contentsOf: playlistURL, encoding: .utf8) else {
            return nil
        }
        let rewritten = rewriteHLSPlaylist(raw, idToken: idToken, accessToken: accessToken)
        return BinaryHTTPResponse(
            status: "200 OK",
            contentType: "application/vnd.apple.mpegurl",
            headers: ["Cache-Control": "no-cache"],
            body: Data(rewritten.utf8)
        )
    }

    /// Serves a single HLS segment (init or media) for a local recording. The
    /// packager validates `segment` against path traversal.
    func localMediaHLSSegmentResponse(itemID: String, segment: String) async -> BinaryHTTPResponse? {
        guard let item = await localMediaItem(for: itemID) else { return nil }
        let sourceURL = URL(fileURLWithPath: item.absolutePath)
        guard let segmentURL = await hlsPackager.segmentURL(itemID: itemID, sourceURL: sourceURL, segment: segment),
              let data = try? Data(contentsOf: segmentURL) else {
            return nil
        }
        return BinaryHTTPResponse(
            status: "200 OK",
            contentType: "video/mp4",
            headers: [
                // Segments are content-addressed by source mtime, so they're
                // safe to cache aggressively.
                "Cache-Control": "public, max-age=31536000, immutable",
                "Content-Length": "\(data.count)"
            ],
            body: data
        )
    }

    /// Rewrites the bare segment names in a generated playlist into relative
    /// segment URLs (`hls-segment?id=…&seg=…&token=…`) that resolve against the
    /// playlist endpoint and carry auth.
    private func rewriteHLSPlaylist(_ playlist: String, idToken: String, accessToken: String?) -> String {
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
                lines.append("#EXT-X-MAP:URI=\"\(segmentURL(HLSPackager.initSegmentFileName))\"")
            } else if !line.hasPrefix("#") && line.hasSuffix(".m4s") {
                lines.append(segmentURL(line))
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
        selectedGame: String?
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
                    let sourceToken = "\(payload.nodeName)|\(item.sourceID.uuidString)"
                    if let selectedSourceID, !selectedSourceID.isEmpty, sourceToken != selectedSourceID {
                        return nil
                    }
                    if let minimumModifiedDate, item.modifiedAt < minimumModifiedDate {
                        return nil
                    }

                    let gameName = mediaGameName(for: item.fileName)
                    if let normalizedSelectedGame, !normalizedSelectedGame.isEmpty, normalizedGameKey(gameName) != normalizedSelectedGame {
                        return nil
                    }

                    let token = encodedMediaStreamToken(
                        itemID: item.id,
                        ownerNodeName: payload.nodeName,
                        ownerBaseURL: item.ownerBaseURL
                    )
                    return AdminWebMediaItemPayload(
                        id: "\(payload.nodeName)|\(item.id)",
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
                }
            }
            .sorted {
                if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
                return $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending
            }
    }

    private func mediaGameName(for fileName: String) -> String {
        let baseName = (fileName as NSString).deletingPathExtension
        let normalized = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return "Unlabeled" }

        let upper = normalized.uppercased()
        if upper.hasPrefix("THE_FINALS_") {
            return "THE FINALS"
        }

        if let range = normalized.range(of: "_replay_", options: [.caseInsensitive]) {
            let rawGame = String(normalized[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if rawGame.isEmpty {
                return "Unknown"
            }
            if rawGame.lowercased() == "unknown" {
                return "Unknown"
            }
            return rawGame.replacingOccurrences(of: "_", with: " ")
        }

        if normalized.lowercased().hasPrefix("replay_") {
            return "Unknown"
        }

        return "Unlabeled"
    }

    private func normalizedGameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func adminWebMediaLibrarySnapshot(query: [String: String] = [:]) async -> AdminWebMediaLibraryPayload {
        let local = await localMediaLibrarySnapshot()
        var payloads: [MediaLibraryPayload] = [local]

        if settings.clusterMode == .leader {
            let workers = await cluster.registeredNodeInfo()
            for (_, baseURL) in workers {
                if let remote = await cluster.fetchRemoteMediaLibrary(from: baseURL) {
                    payloads.append(
                        MediaLibraryPayload(
                            nodeName: remote.nodeName,
                            configFilePath: remote.configFilePath,
                            sources: remote.sources,
                            items: remote.items.map { item in
                                var copy = item
                                if copy.ownerBaseURL == nil || copy.ownerBaseURL?.isEmpty == true {
                                    copy.ownerBaseURL = baseURL
                                }
                                return copy
                            },
                            generatedAt: remote.generatedAt
                        )
                    )
                }
            }
        } else if settings.clusterMode == .standby,
                  let leaderBaseURL = await cluster.normalizedBaseURL(settings.clusterLeaderAddress, defaultPort: settings.clusterLeaderPort),
                  !leaderBaseURL.isEmpty,
                  let remote = await cluster.fetchRemoteMediaLibrary(from: leaderBaseURL) {
            payloads.append(
                MediaLibraryPayload(
                    nodeName: remote.nodeName,
                    configFilePath: remote.configFilePath,
                    sources: remote.sources,
                    items: remote.items.map { item in
                        var copy = item
                        if copy.ownerBaseURL == nil || copy.ownerBaseURL?.isEmpty == true {
                            copy.ownerBaseURL = leaderBaseURL
                        }
                        return copy
                    },
                    generatedAt: remote.generatedAt
                )
            )
        }

        let sourcePayloads: [AdminWebMediaSourcePayload] = payloads.flatMap { payload in
            payload.sources.map { source in
                AdminWebMediaSourcePayload(
                    id: "\(payload.nodeName)|\(source.id.uuidString)",
                    nodeName: payload.nodeName,
                    sourceName: source.name,
                    itemCount: payload.items.filter { $0.sourceID == source.id }.count
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
            selectedGame: nil
        )
        let availableGames = Array(Set(unfilteredForGames.map { $0.gameName }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        let filteredItems = filteredMediaItemPayloads(
            from: payloads,
            selectedSourceID: selectedSourceID,
            selectedDateRange: selectedDateRange,
            selectedGame: selectedGame
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
            selectedSourceID: selectedSourceID,
            selectedDateRange: selectedDateRange,
            selectedGame: selectedGame,
            page: clampedPage,
            pageSize: pageSize,
            totalItems: totalItems,
            totalPages: totalPages
        )
    }

    func adminWebMediaStreamResponse(token: String, rangeHeader: String?, quality: String? = nil) async -> BinaryHTTPResponse? {
        guard let descriptor = decodedMediaStreamToken(token) else { return nil }
        let localNodeName = settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "SwiftBot Node")
            : settings.clusterNodeName

        if descriptor.ownerNodeName != localNodeName,
           let ownerBaseURL = descriptor.ownerBaseURL,
           !ownerBaseURL.isEmpty {
            return await cluster.fetchRemoteMediaStream(from: ownerBaseURL, itemID: descriptor.itemID, rangeHeader: rangeHeader)
        }

        return await localMediaStreamResponse(itemID: descriptor.itemID, rangeHeader: rangeHeader, quality: quality)
    }

    func adminWebMediaThumbnailResponse(token: String) async -> BinaryHTTPResponse? {
        guard let descriptor = decodedMediaStreamToken(token) else { return nil }
        let localNodeName = settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "SwiftBot Node")
            : settings.clusterNodeName

        if descriptor.ownerNodeName != localNodeName,
           let ownerBaseURL = descriptor.ownerBaseURL,
           !ownerBaseURL.isEmpty {
            return await cluster.fetchRemoteMediaThumbnail(from: ownerBaseURL, itemID: descriptor.itemID)
        }

        return await localMediaThumbnailResponse(itemID: descriptor.itemID)
    }

    func adminWebMediaFrameResponse(token: String, atSeconds: Double) async -> BinaryHTTPResponse? {
        guard let descriptor = decodedMediaStreamToken(token) else { return nil }
        let localNodeName = settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "SwiftBot Node")
            : settings.clusterNodeName

        if descriptor.ownerNodeName != localNodeName,
           let ownerBaseURL = descriptor.ownerBaseURL,
           !ownerBaseURL.isEmpty {
            return await cluster.fetchRemoteMediaFrame(from: ownerBaseURL, itemID: descriptor.itemID, seconds: atSeconds)
        }

        return await localMediaFrameResponse(itemID: descriptor.itemID, atSeconds: atSeconds)
    }

    func adminWebMediaHLSPlaylistResponse(token: String, accessToken: String?) async -> BinaryHTTPResponse? {
        guard let descriptor = decodedMediaStreamToken(token) else { return nil }
        let localNodeName = settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "SwiftBot Node")
            : settings.clusterNodeName
        // HLS packaging is local-node only. For a remote-owned recording, return
        // nil so the browser falls back to the MP4 stream, which already proxies
        // via the mesh in adminWebMediaStreamResponse.
        if descriptor.ownerNodeName != localNodeName,
           let ownerBaseURL = descriptor.ownerBaseURL, !ownerBaseURL.isEmpty {
            return nil
        }
        return await localMediaHLSPlaylistResponse(itemID: descriptor.itemID, idToken: token, accessToken: accessToken)
    }

    func adminWebMediaHLSSegmentResponse(token: String, segment: String) async -> BinaryHTTPResponse? {
        guard let descriptor = decodedMediaStreamToken(token) else { return nil }
        let localNodeName = settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "SwiftBot Node")
            : settings.clusterNodeName
        if descriptor.ownerNodeName != localNodeName,
           let ownerBaseURL = descriptor.ownerBaseURL, !ownerBaseURL.isEmpty {
            return nil
        }
        return await localMediaHLSSegmentResponse(itemID: descriptor.itemID, segment: segment)
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

        if descriptor.ownerNodeName != localNodeName,
           let ownerBaseURL = descriptor.ownerBaseURL,
           !ownerBaseURL.isEmpty {
            let meshRequest = MeshMediaClipRequest(
                itemID: descriptor.itemID,
                startSeconds: request.startSeconds,
                endSeconds: request.endSeconds,
                name: request.name
            )
            if let job = await cluster.startRemoteMediaClip(from: ownerBaseURL, request: meshRequest) {
                await mediaExportCoordinator.recordExternalJob(job)
                return MediaExportJobResponse(job: job, error: nil)
            }
            return MediaExportJobResponse(job: nil, error: "Failed to start export on remote node.")
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

        if primaryDescriptor.ownerNodeName != secondaryDescriptor.ownerNodeName ||
            primaryDescriptor.ownerBaseURL != secondaryDescriptor.ownerBaseURL {
            return MediaExportJobResponse(job: nil, error: "Multiview clips must be on the same node.")
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

        if primaryDescriptor.ownerNodeName != localNodeName,
           let ownerBaseURL = primaryDescriptor.ownerBaseURL,
           !ownerBaseURL.isEmpty {
            let meshRequest = MeshMediaMultiViewRequest(
                primaryID: primaryDescriptor.itemID,
                secondaryID: secondaryDescriptor.itemID,
                layout: request.layout,
                audioSource: request.audioSource,
                startSeconds: request.startSeconds,
                endSeconds: request.endSeconds,
                name: request.name
            )
            if let job = await cluster.startRemoteMediaMultiView(from: ownerBaseURL, request: meshRequest) {
                await mediaExportCoordinator.recordExternalJob(job)
                return MediaExportJobResponse(job: job, error: nil)
            }
            return MediaExportJobResponse(job: nil, error: "Failed to start multiview export on remote node.")
        }

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

        let shouldScan = ruleStore.rules.contains { $0.isEnabled && $0.trigger == .mediaAdded }
        guard shouldScan else {
            lastSeenMediaItemIDs.removeAll()
            return
        }
        let payloads = await mediaPayloadsForTriggers()

        let allItems: [(payload: MediaLibraryPayload, item: MediaLibraryItem)] = payloads.flatMap { payload in
            payload.items.map { (payload, $0) }
        }
        let currentIDs = Set(allItems.map { "\($0.payload.nodeName)|\($0.item.id)" })

        if lastSeenMediaItemIDs.isEmpty {
            lastSeenMediaItemIDs = currentIDs
            return
        }

        let newItems = allItems.filter { !lastSeenMediaItemIDs.contains("\($0.payload.nodeName)|\($0.item.id)") }
        lastSeenMediaItemIDs = currentIDs

        guard !newItems.isEmpty else { return }
        for entry in newItems {
            await handleMediaAddedEvent(item: entry.item, nodeName: entry.payload.nodeName)
        }
    }

    private func prewarmLocalMediaFastStartCache() async {
        guard runtimeClusterMode != .standby else { return }

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

    private func mediaPayloadsForTriggers() async -> [MediaLibraryPayload] {
        var payloads: [MediaLibraryPayload] = [await localMediaLibrarySnapshot()]
        guard settings.clusterMode == .leader else { return payloads }

        let workers = await cluster.registeredNodeInfo()
        for (_, baseURL) in workers {
            if let remote = await cluster.fetchRemoteMediaLibrary(from: baseURL) {
                payloads.append(
                    MediaLibraryPayload(
                        nodeName: remote.nodeName,
                        configFilePath: remote.configFilePath,
                        sources: remote.sources,
                        items: remote.items.map { item in
                            var copy = item
                            if copy.ownerBaseURL == nil || copy.ownerBaseURL?.isEmpty == true {
                                copy.ownerBaseURL = baseURL
                            }
                            return copy
                        },
                        generatedAt: remote.generatedAt
                    )
                )
            }
        }
        return payloads
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
