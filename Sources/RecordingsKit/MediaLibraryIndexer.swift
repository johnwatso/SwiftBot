import Foundation

public actor MediaLibraryIndexer {
    private struct CacheEntry {
        let signature: String
        let payload: MediaLibraryPayload
        let createdAt: Date
    }

    private var cachedEntry: CacheEntry?
    private let cacheTTL: TimeInterval

    public init(cacheTTL: TimeInterval = 30) {
        self.cacheTTL = cacheTTL
    }

    public func cachedItem(for id: String) -> MediaLibraryItem? {
        cachedEntry?.payload.items.first(where: { $0.id == id })
    }

    public func invalidate() {
        cachedEntry = nil
    }

    public func snapshot(
        sources: [MediaLibrarySource],
        ownerNodeName: String,
        ownerBaseURL: String?,
        configFilePath: String
    ) async -> MediaLibraryPayload {
        let signature = makeSignature(sources: sources, ownerNodeName: ownerNodeName, ownerBaseURL: ownerBaseURL, configFilePath: configFilePath)
        if let cachedEntry, cachedEntry.signature == signature, Date().timeIntervalSince(cachedEntry.createdAt) < cacheTTL {
            return cachedEntry.payload
        }

        var unavailable: [UUID] = []
        let items = scanItems(sources: sources, ownerNodeName: ownerNodeName, ownerBaseURL: ownerBaseURL,
                              previousItems: cachedEntry?.signature == signature ? cachedEntry?.payload.items ?? [] : [],
                              unavailable: &unavailable)
        let payload = MediaLibraryPayload(
            nodeName: ownerNodeName,
            configFilePath: configFilePath,
            sources: sources,
            items: items,
            generatedAt: Date(),
            unavailableSourceIDs: unavailable
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
        ownerBaseURL: String?,
        previousItems: [MediaLibraryItem],
        unavailable: inout [UUID]
    ) -> [MediaLibraryItem] {
        let fileManager = FileManager.default
        var items: [MediaLibraryItem] = []

        for source in sources where source.isEnabled {
            let root = source.normalizedRootPath
            guard !root.isEmpty else { continue }

            let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            var scanFailed = false
            guard (try? rootURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in scanFailed = true; return true }
            ) else {
                unavailable.append(source.id)
                items.append(contentsOf: previousItems.filter { $0.sourceID == source.id })
                continue
            }

            let allowedExtensions = Set(source.normalizedExtensions)
            var sourceItems: [MediaLibraryItem] = []
            while let fileURL = enumerator.nextObject() as? URL {
                let ext = fileURL.pathExtension.lowercased()
                guard allowedExtensions.isEmpty || allowedExtensions.contains(ext) else { continue }
                guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                else { scanFailed = true; continue }
                guard values.isRegularFile == true else { continue }

                let relativePath = String(fileURL.path.dropFirst(rootURL.path.count + 1))
                let id = "\(source.id.uuidString)|\(relativePath)"
                sourceItems.append(
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
            // A disconnected volume or incomplete traversal is not a deletion.
            if scanFailed {
                unavailable.append(source.id)
                let discovered = Set(sourceItems.map(\.id))
                sourceItems.append(contentsOf: previousItems.filter {
                    $0.sourceID == source.id && !discovered.contains($0.id)
                })
            }
            items.append(contentsOf: sourceItems)
        }

        return items.sorted {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending
        }
    }

}
