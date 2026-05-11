import AppKit
import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

actor MediaLibraryIndexer {
    private struct CacheEntry {
        let signature: String
        let payload: MediaLibraryPayload
        let createdAt: Date
    }

    private var cachedEntry: CacheEntry?
    private let cacheTTL: TimeInterval = 30

    func cachedItem(for id: String) -> MediaLibraryItem? {
        cachedEntry?.payload.items.first(where: { $0.id == id })
    }

    func invalidate() {
        cachedEntry = nil
    }

    func snapshot(
        sources: [MediaLibrarySource],
        ownerNodeName: String,
        ownerBaseURL: String?,
        configFilePath: String
    ) async -> MediaLibraryPayload {
        let signature = makeSignature(sources: sources, ownerNodeName: ownerNodeName, ownerBaseURL: ownerBaseURL, configFilePath: configFilePath)
        if let cachedEntry, cachedEntry.signature == signature, Date().timeIntervalSince(cachedEntry.createdAt) < cacheTTL {
            return cachedEntry.payload
        }

        let payload = MediaLibraryPayload(
            nodeName: ownerNodeName,
            configFilePath: configFilePath,
            sources: sources,
            items: await scanItems(sources: sources, ownerNodeName: ownerNodeName, ownerBaseURL: ownerBaseURL),
            generatedAt: Date()
        )
        cachedEntry = CacheEntry(signature: signature, payload: payload, createdAt: Date())
        return payload
    }

    private func makeSignature(
        sources: [MediaLibrarySource],
        ownerNodeName: String,
        ownerBaseURL: String?,
        configFilePath: String
    ) -> String {
        let sourceSignature = sources.map {
            "\($0.id.uuidString)|\($0.name)|\($0.normalizedRootPath)|\($0.isEnabled)|\($0.normalizedExtensions.joined(separator: ","))"
        }.joined(separator: "||")
        return "\(ownerNodeName)|\(ownerBaseURL ?? "")|\(configFilePath)|\(sourceSignature)"
    }

    private func scanItems(
        sources: [MediaLibrarySource],
        ownerNodeName: String,
        ownerBaseURL: String?
    ) async -> [MediaLibraryItem] {
        let fileManager = FileManager.default
        var items: [MediaLibraryItem] = []

        for source in sources where source.isEnabled {
            let root = source.normalizedRootPath
            guard !root.isEmpty else { continue }

            let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            guard let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            let allowedExtensions = Set(source.normalizedExtensions)
            let fileURLs = enumerator.allObjects.compactMap { $0 as? URL }
            for fileURL in fileURLs {
                let ext = fileURL.pathExtension.lowercased()
                guard allowedExtensions.isEmpty || allowedExtensions.contains(ext) else { continue }
                guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                      values.isRegularFile == true else { continue }

                // Exclude AV1 and other unsupported codecs from the WebUI
                if await isCodecUnsupported(at: fileURL) { continue }

                let relativePath = fileURL.path.replacingOccurrences(of: rootURL.path + "/", with: "")
                let id = "\(source.id.uuidString)|\(relativePath)"
                items.append(
                    MediaLibraryItem(
                        id: id,
                        sourceID: source.id,
                        sourceName: source.name,
                        fileName: fileURL.lastPathComponent,
                        relativePath: relativePath,
                        absolutePath: fileURL.path,
                        fileExtension: ext,
                        sizeBytes: Int64(values.fileSize ?? 0),
                        modifiedAt: values.contentModificationDate ?? .distantPast,
                        ownerNodeName: ownerNodeName,
                        ownerBaseURL: ownerBaseURL
                    )
                )
            }
        }

        return items.sorted {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending
        }
    }

    private func isCodecUnsupported(at url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return false }

        guard let descriptions = try? await track.load(.formatDescriptions) else { return false }
        for desc in descriptions {
            let codecType = CMFormatDescriptionGetMediaSubType(desc)
            // Exclude codecs this Mac cannot hardware decode (e.g. AV1 on M1/M2)
            if !VTIsHardwareDecodeSupported(codecType) {
                return true
            }
        }
        return false
    }
}
