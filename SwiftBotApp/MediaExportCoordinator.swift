import Foundation

actor MediaExportCoordinator {
    private var jobs: [String: MediaExportJob] = [:]
    private var cachedStatus: MediaExportStatus?
    private var cachedStatusAt: Date?
    private var onJobFinished: (@Sendable (MediaExportJob) async -> Void)?

    private let statusTTL: TimeInterval = 15

    func ffmpegStatus() async -> MediaExportStatus {
        let now = Date()
        if let cachedStatus, let cachedStatusAt, now.timeIntervalSince(cachedStatusAt) < statusTTL {
            return cachedStatus
        }

        let path = resolveFFmpegPath()
        guard let path else {
            let status = MediaExportStatus(installed: false, version: nil, path: nil)
            cachedStatus = status
            cachedStatusAt = now
            return status
        }

        let version = runFFmpegVersion(path: path)
        let status = MediaExportStatus(installed: true, version: version, path: path)
        cachedStatus = status
        cachedStatusAt = now
        return status
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
        guard let ffmpegPath = resolveFFmpegPath() else {
            await markJobFailed(jobID, message: "FFmpeg not installed")
            return
        }

        let outputURL = exportRoot.appendingPathComponent(sanitizedExportName(request.name, fallback: item.fileName))
        let start = max(0, request.startSeconds)
        let end = max(start, request.endSeconds)

        let args: [String] = [
            "-y",
            "-ss", String(format: "%.3f", start),
            "-to", String(format: "%.3f", end),
            "-i", item.absolutePath,
            "-c", "copy",
            "-movflags", "+faststart",
            outputURL.path
        ]

        await markJobRunning(jobID, outputURL: outputURL)
        let result = runFFmpeg(path: ffmpegPath, arguments: args)
        if result.ok {
            await markJobFinished(jobID, message: "Clip exported")
        } else {
            await markJobFailed(jobID, message: result.message ?? "Export failed")
        }
    }

    private func runMultiView(
        jobID: String,
        primary: MediaLibraryItem,
        secondary: MediaLibraryItem,
        request: MediaExportMultiViewRequest,
        exportRoot: URL
    ) async {
        guard let ffmpegPath = resolveFFmpegPath() else {
            await markJobFailed(jobID, message: "FFmpeg not installed")
            return
        }

        let outputURL = exportRoot.appendingPathComponent(sanitizedExportName(request.name, fallback: "Multiview_\(primary.fileName)"))
        let layout = request.layout.lowercased()
        let audioSource = request.audioSource.lowercased()
        let audioMap = audioSource == "secondary" ? "1:a?" : "0:a?"
        let filter: String

        switch layout {
        case "side-by-side":
            filter = "[0:v]scale=960:-1[v0];[1:v]scale=960:-1[v1];[v0][v1]hstack=inputs=2[v]"
        default:
            filter = "[0:v]scale=-1:540[v0];[1:v]scale=-1:540[v1];[v0][v1]vstack=inputs=2[v]"
        }

        var args: [String] = ["-y"]
        if let start = request.startSeconds {
            args += ["-ss", String(format: "%.3f", max(0, start))]
        }
        if let end = request.endSeconds {
            args += ["-to", String(format: "%.3f", max(0, end))]
        }
        args += [
            "-i", primary.absolutePath,
            "-i", secondary.absolutePath,
            "-filter_complex", filter,
            "-map", "[v]",
            "-map", audioMap,
            "-c:v", "libx264",
            "-preset", "veryfast",
            "-crf", "23",
            "-c:a", "aac",
            "-b:a", "160k",
            "-shortest",
            "-movflags", "+faststart",
            outputURL.path
        ]

        await markJobRunning(jobID, outputURL: outputURL)
        let result = runFFmpeg(path: ffmpegPath, arguments: args)
        if result.ok {
            await markJobFinished(jobID, message: "Multiview exported")
        } else {
            await markJobFailed(jobID, message: result.message ?? "Export failed")
        }
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

    private func sanitizedExportName(_ rawName: String?, fallback: String) -> String {
        let base = (rawName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? rawName!
            : fallback
        let cleaned = base
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "|", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        if cleaned.lowercased().hasSuffix(".mp4") { return cleaned }
        return cleaned + ".mp4"
    }

    private func resolveFFmpegPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        let whichPath = runWhich()
        if let whichPath, FileManager.default.isExecutableFile(atPath: whichPath) {
            return whichPath
        }
        return nil
    }

    private func runWhich() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["ffmpeg"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else { return nil }
        return output
    }

    private func runFFmpegVersion(path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        return output.components(separatedBy: .newlines).first
    }

    private func runFFmpeg(path: String, arguments: [String]) -> (ok: Bool, message: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (false, "Failed to launch ffmpeg")
        }
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (false, message)
        }
        return (true, nil)
    }

    func generateThumbnailBytes(path: String, atSeconds: Double) -> Data? {
        guard let ffmpegPath = resolveFFmpegPath() else { return nil }
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let fileName = "thumb_\(UUID().uuidString).jpg"
        let outURL = tempDir.appendingPathComponent(fileName)
        let args: [String] = [
            "-y",
            "-ss", String(format: "%.3f", max(0, atSeconds)),
            "-i", path,
            "-frames:v", "1",
            "-q:v", "4",
            outURL.path
        ]
        let result = runFFmpeg(path: ffmpegPath, arguments: args)
        guard result.ok, let data = try? Data(contentsOf: outURL) else { return nil }
        try? FileManager.default.removeItem(at: outURL)
        return data
    }
}
