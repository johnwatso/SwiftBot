import AVFoundation
import Foundation

actor MediaExportCoordinator {
    private var jobs: [String: MediaExportJob] = [:]
    private var onJobFinished: (@Sendable (MediaExportJob) async -> Void)?

    func exportStatus() async -> MediaExportStatus {
        MediaExportStatus(installed: true, version: "Apple AVFoundation", path: nil)
    }

    func listJobs() async -> [MediaExportJob] {
        jobs.values.sorted { $0.createdAt > $1.createdAt }
    }

    func recordExternalJob(_ job: MediaExportJob) async {
        jobs[job.id] = job
    }

    func setOnJobFinished(_ handler: @escaping @Sendable (MediaExportJob) async -> Void) async {
        onJobFinished = handler
    }

    func startClip(
        item: MediaLibraryItem,
        request: MediaExportClipRequest,
        exportRoot: URL,
        nodeName: String
    ) async -> MediaExportJob {
        let job = createJob(kind: .clip, nodeName: nodeName)
        jobs[job.id] = job
        Task.detached { [weak self] in
            await self?.runClip(jobID: job.id, item: item, request: request, exportRoot: exportRoot)
        }
        return job
    }

    func startMultiView(
        primary: MediaLibraryItem,
        secondary: MediaLibraryItem,
        request: MediaExportMultiViewRequest,
        exportRoot: URL,
        nodeName: String
    ) async -> MediaExportJob {
        let job = createJob(kind: .multiview, nodeName: nodeName)
        jobs[job.id] = job
        Task.detached { [weak self] in
            await self?.runMultiView(jobID: job.id, primary: primary, secondary: secondary, request: request, exportRoot: exportRoot)
        }
        return job
    }

    private func createJob(kind: MediaExportJob.Kind, nodeName: String) -> MediaExportJob {
        MediaExportJob(
            id: UUID().uuidString,
            kind: kind,
            status: .queued,
            createdAt: Date(),
            startedAt: nil,
            finishedAt: nil,
            message: nil,
            outputFileName: nil,
            outputPath: nil,
            nodeName: nodeName
        )
    }

    private func runClip(jobID: String, item: MediaLibraryItem, request: MediaExportClipRequest, exportRoot: URL) async {
        let start = max(0, request.startSeconds)
        let end = max(start, request.endSeconds)
        let duration = end - start

        let sourceURL = URL(fileURLWithPath: item.absolutePath)
        let asset = AVURLAsset(url: sourceURL)

        guard let passthroughSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            await markJobFailed(jobID, message: "Failed to create export session")
            return
        }

        let baseName = request.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? request.name!
            : item.fileName
        let timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )

        guard let passthroughTarget = exportTargetURL(
            exportRoot: exportRoot,
            baseName: baseName,
            supportedFileTypes: passthroughSession.supportedFileTypes,
            preferredFileTypes: [.mp4, .mov, .m4v]
        ) else {
            await markJobFailed(jobID, message: "This clip cannot be exported with native passthrough on this Mac")
            return
        }

        passthroughSession.timeRange = timeRange
        await markJobRunning(jobID, outputURL: passthroughTarget.url)

        do {
            try await exportSession(
                passthroughSession,
                to: passthroughTarget.url,
                as: passthroughTarget.fileType
            )
            await markJobFinished(jobID, message: "Clip exported")
            return
        } catch let passthroughError {
            try? FileManager.default.removeItem(at: passthroughTarget.url)

            guard let transcodeSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
                await markJobFailed(jobID, message: passthroughError.localizedDescription)
                return
            }

            guard let transcodeTarget = exportTargetURL(
                exportRoot: exportRoot,
                baseName: baseName,
                supportedFileTypes: transcodeSession.supportedFileTypes,
                preferredFileTypes: [.mp4, .mov, .m4v]
            ) else {
                await markJobFailed(jobID, message: passthroughError.localizedDescription)
                return
            }

            transcodeSession.timeRange = timeRange
            transcodeSession.shouldOptimizeForNetworkUse = true
            await markJobRunning(jobID, outputURL: transcodeTarget.url)

            do {
                try await exportSession(
                    transcodeSession,
                    to: transcodeTarget.url,
                    as: transcodeTarget.fileType
                )
                await markJobFinished(jobID, message: "Clip exported")
            } catch {
                try? FileManager.default.removeItem(at: transcodeTarget.url)
                await markJobFailed(
                    jobID,
                    message: "Passthrough failed: \(passthroughError.localizedDescription). Transcode failed: \(error.localizedDescription)"
                )
            }
        }
    }

    private func runMultiView(
        jobID: String,
        primary: MediaLibraryItem,
        secondary: MediaLibraryItem,
        request: MediaExportMultiViewRequest,
        exportRoot: URL
    ) async {
        let outputURL = exportRoot.appendingPathComponent(
            sanitizedExportName(request.name, fallback: "Multiview_\(primary.fileName)", defaultExtension: "mp4")
        )
        let layout = request.layout.lowercased()
        let isSideBySide = layout == "side-by-side"

        let primaryURL = URL(fileURLWithPath: primary.absolutePath)
        let secondaryURL = URL(fileURLWithPath: secondary.absolutePath)
        let primaryAsset = AVURLAsset(url: primaryURL)
        let secondaryAsset = AVURLAsset(url: secondaryURL)

        do {
            async let primaryTracksAsync = primaryAsset.load(.tracks)
            async let secondaryTracksAsync = secondaryAsset.load(.tracks)
            async let primaryDurationAsync = primaryAsset.load(.duration)
            async let secondaryDurationAsync = secondaryAsset.load(.duration)

            let primaryTracks = try await primaryTracksAsync
            let secondaryTracks = try await secondaryTracksAsync
            let primaryDuration = try await primaryDurationAsync
            let secondaryDuration = try await secondaryDurationAsync

            guard let primaryVideoTrack = primaryTracks.first(where: { $0.mediaType == .video }),
                  let secondaryVideoTrack = secondaryTracks.first(where: { $0.mediaType == .video }) else {
                await markJobFailed(jobID, message: "Missing video track")
                return
            }

            // Determine trimmed time range
            let startTime = CMTime(seconds: request.startSeconds ?? 0, preferredTimescale: 600)
            let requestedEnd: CMTime?
            if let end = request.endSeconds {
                requestedEnd = CMTime(seconds: end, preferredTimescale: 600)
            } else {
                requestedEnd = nil
            }

            let primaryEnd = requestedEnd.map { CMTimeMinimum($0, primaryDuration) } ?? primaryDuration
            let secondaryEnd = requestedEnd.map { CMTimeMinimum($0, secondaryDuration) } ?? secondaryDuration
            let primaryTrimmed = CMTimeMaximum(.zero, primaryEnd - startTime)
            let secondaryTrimmed = CMTimeMaximum(.zero, secondaryEnd - startTime)
            let exportDuration = CMTimeMinimum(primaryTrimmed, secondaryTrimmed)

            guard exportDuration > .zero else {
                await markJobFailed(jobID, message: "Invalid time range")
                return
            }

            // Build composition
            let composition = AVMutableComposition()

            guard let compositionVideoTrack0 = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let compositionVideoTrack1 = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                await markJobFailed(jobID, message: "Failed to create composition tracks")
                return
            }

            try compositionVideoTrack0.insertTimeRange(
                CMTimeRange(start: startTime, duration: exportDuration),
                of: primaryVideoTrack,
                at: .zero
            )
            try compositionVideoTrack1.insertTimeRange(
                CMTimeRange(start: startTime, duration: exportDuration),
                of: secondaryVideoTrack,
                at: .zero
            )

            // Audio
            let audioAsset = request.audioSource.lowercased() == "secondary" ? secondaryAsset : primaryAsset
            let audioTracks = try await audioAsset.load(.tracks)
            if let audioTrack = audioTracks.first(where: { $0.mediaType == .audio }),
               let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                do {
                    try compositionAudioTrack.insertTimeRange(
                        CMTimeRange(start: startTime, duration: exportDuration),
                        of: audioTrack,
                        at: .zero
                    )
                } catch {
                    // Audio is non-critical for multiview
                }
            }

            // Video composition
            let renderSize: CGSize = isSideBySide
                ? CGSize(width: 1920, height: 540)
                : CGSize(width: 960, height: 1080)

            let nominalFrameRate = try await primaryVideoTrack.load(.nominalFrameRate)
            let frameDuration = nominalFrameRate > 0
                ? CMTime(value: 1, timescale: Int32(nominalFrameRate.rounded()))
                : CMTime(value: 1, timescale: 30)

            let transform0 = try await transformForTrack(primaryVideoTrack, targetRect: isSideBySide
                ? CGRect(x: 0, y: 0, width: renderSize.width / 2, height: renderSize.height)
                : CGRect(x: 0, y: 0, width: renderSize.width, height: renderSize.height / 2))
            let transform1 = try await transformForTrack(secondaryVideoTrack, targetRect: isSideBySide
                ? CGRect(x: renderSize.width / 2, y: 0, width: renderSize.width / 2, height: renderSize.height)
                : CGRect(x: 0, y: renderSize.height / 2, width: renderSize.width, height: renderSize.height / 2))

            var layerConfig0 = AVVideoCompositionLayerInstruction.Configuration(assetTrack: compositionVideoTrack0)
            layerConfig0.setTransform(transform0, at: .zero)
            let layerInstruction0 = AVVideoCompositionLayerInstruction(configuration: layerConfig0)

            var layerConfig1 = AVVideoCompositionLayerInstruction.Configuration(assetTrack: compositionVideoTrack1)
            layerConfig1.setTransform(transform1, at: .zero)
            let layerInstruction1 = AVVideoCompositionLayerInstruction(configuration: layerConfig1)

            let instructionConfig = AVVideoCompositionInstruction.Configuration(
                layerInstructions: [layerInstruction0, layerInstruction1],
                timeRange: CMTimeRange(start: .zero, duration: exportDuration)
            )
            let instruction = AVVideoCompositionInstruction(configuration: instructionConfig)

            let videoConfig = AVVideoComposition.Configuration(
                frameDuration: frameDuration,
                instructions: [instruction],
                renderSize: renderSize
            )
            let videoComposition = AVVideoComposition(configuration: videoConfig)

            // Export
            guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPreset1920x1080) else {
                await markJobFailed(jobID, message: "Failed to create export session")
                return
            }

            session.videoComposition = videoComposition
            session.shouldOptimizeForNetworkUse = true

            await markJobRunning(jobID, outputURL: outputURL)
            try await session.export(to: outputURL, as: .mp4)
            await markJobFinished(jobID, message: "Multiview exported")
        } catch {
            await markJobFailed(jobID, message: error.localizedDescription)
        }
    }

    private func transformForTrack(_ track: AVAssetTrack, targetRect: CGRect) async throws -> CGAffineTransform {
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)

        // Calculate bounding box after preferred transform
        let videoRect = CGRect(origin: .zero, size: naturalSize)
        let transformedRect = videoRect.applying(preferredTransform)

        // Scale to fit target while maintaining aspect ratio
        let scale = min(
            targetRect.width / abs(transformedRect.width),
            targetRect.height / abs(transformedRect.height)
        )

        // Calculate where the scaled video sits
        let scaledRect = transformedRect.applying(CGAffineTransform(scaleX: scale, y: scale))

        // Translate to center in target rect
        let offsetX = targetRect.midX - scaledRect.midX
        let offsetY = targetRect.midY - scaledRect.midY

        // Build: preferredTransform -> scale -> translate
        var transform = preferredTransform
        transform = transform.scaledBy(x: scale, y: scale)
        transform = transform.translatedBy(x: offsetX, y: offsetY)

        return transform
    }

    private func markJobRunning(_ jobID: String, outputURL: URL) async {
        guard var job = jobs[jobID] else { return }
        job.status = .running
        job.startedAt = Date()
        job.outputFileName = outputURL.lastPathComponent
        job.outputPath = outputURL.path
        jobs[jobID] = job
    }

    private func markJobFinished(_ jobID: String, message: String) async {
        guard var job = jobs[jobID] else { return }
        job.status = .finished
        job.finishedAt = Date()
        job.message = message
        jobs[jobID] = job
        if let onJobFinished {
            Task { await onJobFinished(job) }
        }
    }

    private func markJobFailed(_ jobID: String, message: String) async {
        guard var job = jobs[jobID] else { return }
        job.status = .failed
        job.finishedAt = Date()
        job.message = message
        jobs[jobID] = job
        if let onJobFinished {
            Task { await onJobFinished(job) }
        }
    }

    private func exportSession(_ session: AVAssetExportSession, to url: URL, as fileType: AVFileType) async throws {
        try? FileManager.default.removeItem(at: url)
        try await session.export(to: url, as: fileType)
    }

    private func exportTargetURL(
        exportRoot: URL,
        baseName: String,
        supportedFileTypes: [AVFileType],
        preferredFileTypes: [AVFileType]
    ) -> (url: URL, fileType: AVFileType)? {
        guard let fileType = preferredExportFileType(
            supportedFileTypes: supportedFileTypes,
            preferredFileTypes: preferredFileTypes
        ) else {
            return nil
        }

        let pathExtension = fileExtension(for: fileType)
        let fileName = sanitizedExportName(baseName, fallback: baseName, defaultExtension: pathExtension)
        return (exportRoot.appendingPathComponent(fileName), fileType)
    }

    private func preferredExportFileType(
        supportedFileTypes: [AVFileType],
        preferredFileTypes: [AVFileType]
    ) -> AVFileType? {
        for fileType in preferredFileTypes where supportedFileTypes.contains(fileType) {
            return fileType
        }
        return supportedFileTypes.first
    }

    private func fileExtension(for fileType: AVFileType) -> String {
        switch fileType {
        case .mp4:
            return "mp4"
        case .mov:
            return "mov"
        case .m4v:
            return "m4v"
        default:
            return "mov"
        }
    }

    private func sanitizedExportName(_ rawName: String?, fallback: String, defaultExtension: String) -> String {
        let base = (rawName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? rawName!
            : fallback
        let cleaned = base
        .replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ":", with: "-")
        .replacingOccurrences(of: "|", with: "-")
        .replacingOccurrences(of: "\\", with: "-")
        if !URL(fileURLWithPath: cleaned).pathExtension.isEmpty {
            return cleaned
        }
        return cleaned + "." + defaultExtension
    }
}
