import AppKit
import AVFoundation
import Foundation

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
    ) -> MediaLibraryPayload {
        let signature = makeSignature(sources: sources, ownerNodeName: ownerNodeName, ownerBaseURL: ownerBaseURL, configFilePath: configFilePath)
        if let cachedEntry, cachedEntry.signature == signature, Date().timeIntervalSince(cachedEntry.createdAt) < cacheTTL {
            return cachedEntry.payload
        }

        let payload = MediaLibraryPayload(
            nodeName: ownerNodeName,
            configFilePath: configFilePath,
            sources: sources,
            items: scanItems(sources: sources, ownerNodeName: ownerNodeName, ownerBaseURL: ownerBaseURL),
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
    ) -> [MediaLibraryItem] {
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
            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                guard allowedExtensions.isEmpty || allowedExtensions.contains(ext) else { continue }
                guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                      values.isRegularFile == true else { continue }

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
}
