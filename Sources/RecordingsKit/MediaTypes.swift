import Foundation

// MARK: - Media library model
//
// These value types describe the recordings media library and its export
// jobs. They were extracted from the SwiftBot app target into RecordingsKit so
// the recordings subsystem compiles independently. They are deliberately pure
// (Foundation-only) and carry explicit `public` memberwise initializers plus
// `Sendable` conformance, both of which the in-app, non-public versions got
// for free.

public struct MediaStreamDescriptor: Codable, Hashable, Sendable {
    public var itemID: String
    public var ownerNodeName: String
    public var ownerBaseURL: String?

    public init(itemID: String, ownerNodeName: String, ownerBaseURL: String? = nil) {
        self.itemID = itemID
        self.ownerNodeName = ownerNodeName
        self.ownerBaseURL = ownerBaseURL
    }
}

public struct MediaLibrarySettings: Codable, Hashable, Sendable {
    public var sources: [MediaLibrarySource]
    public var exportRootPath: String
    public var exportIncludeInLibrary: Bool
    public var exportSourceID: UUID?

    public init(
        sources: [MediaLibrarySource] = [],
        exportRootPath: String = "",
        exportIncludeInLibrary: Bool = true,
        exportSourceID: UUID? = nil
    ) {
        self.sources = sources
        self.exportRootPath = exportRootPath
        self.exportIncludeInLibrary = exportIncludeInLibrary
        self.exportSourceID = exportSourceID
    }
}

public struct MediaLibrarySource: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var rootPath: String
    public var isEnabled: Bool
    public var allowedExtensions: [String]

    public init(
        id: UUID = UUID(),
        name: String = "Gameplay",
        rootPath: String = "",
        isEnabled: Bool = true,
        allowedExtensions: [String] = ["mp4", "mov", "m4v"]
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.isEnabled = isEnabled
        self.allowedExtensions = allowedExtensions
    }

    public var normalizedRootPath: String {
        let trimmed = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let unquoted = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let unescaped = unquoted.replacingOccurrences(of: "\\ ", with: " ")
        return (unescaped as NSString).expandingTildeInPath
    }

    public var normalizedExtensions: [String] {
        allowedExtensions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }
}

public struct MediaLibraryItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var sourceID: UUID
    public var sourceName: String
    public var fileName: String
    public var relativePath: String
    public var absolutePath: String
    public var fileExtension: String
    public var sizeBytes: Int64
    public var modifiedAt: Date
    public var ownerNodeName: String
    public var ownerBaseURL: String?

    public init(
        id: String,
        sourceID: UUID,
        sourceName: String,
        fileName: String,
        relativePath: String,
        absolutePath: String,
        fileExtension: String,
        sizeBytes: Int64,
        modifiedAt: Date,
        ownerNodeName: String,
        ownerBaseURL: String? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.fileName = fileName
        self.relativePath = relativePath
        self.absolutePath = absolutePath
        self.fileExtension = fileExtension
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.ownerNodeName = ownerNodeName
        self.ownerBaseURL = ownerBaseURL
    }
}

public struct MediaLibraryPayload: Codable, Hashable, Sendable {
    public var nodeName: String
    public var configFilePath: String
    public var sources: [MediaLibrarySource]
    public var items: [MediaLibraryItem]
    public var generatedAt: Date

    public init(
        nodeName: String,
        configFilePath: String,
        sources: [MediaLibrarySource],
        items: [MediaLibraryItem],
        generatedAt: Date
    ) {
        self.nodeName = nodeName
        self.configFilePath = configFilePath
        self.sources = sources
        self.items = items
        self.generatedAt = generatedAt
    }
}

public struct MediaExportStatus: Codable, Hashable, Sendable {
    public var installed: Bool
    public var version: String?
    public var path: String?

    public init(installed: Bool, version: String? = nil, path: String? = nil) {
        self.installed = installed
        self.version = version
        self.path = path
    }
}

public struct MediaExportJob: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case clip
        case multiview
    }

    public enum Status: String, Codable, Sendable {
        case queued
        case running
        case finished
        case failed
    }

    public var id: String
    public var kind: Kind
    public var status: Status
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var message: String?
    public var outputFileName: String?
    public var outputPath: String?
    public var nodeName: String

    public init(
        id: String,
        kind: Kind,
        status: Status,
        createdAt: Date,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        message: String? = nil,
        outputFileName: String? = nil,
        outputPath: String? = nil,
        nodeName: String
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.message = message
        self.outputFileName = outputFileName
        self.outputPath = outputPath
        self.nodeName = nodeName
    }
}

public struct MediaExportClipRequest: Codable, Hashable, Sendable {
    public var token: String
    public var startSeconds: Double
    public var endSeconds: Double
    public var name: String?
    public var thumbnailAtSeconds: Double?

    public init(
        token: String,
        startSeconds: Double,
        endSeconds: Double,
        name: String? = nil,
        thumbnailAtSeconds: Double? = nil
    ) {
        self.token = token
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.name = name
        self.thumbnailAtSeconds = thumbnailAtSeconds
    }
}

public struct MediaExportMultiViewRequest: Codable, Hashable, Sendable {
    public var primaryToken: String
    public var secondaryToken: String
    public var layout: String
    public var audioSource: String
    public var startSeconds: Double?
    public var endSeconds: Double?
    public var name: String?

    public init(
        primaryToken: String,
        secondaryToken: String,
        layout: String,
        audioSource: String,
        startSeconds: Double? = nil,
        endSeconds: Double? = nil,
        name: String? = nil
    ) {
        self.primaryToken = primaryToken
        self.secondaryToken = secondaryToken
        self.layout = layout
        self.audioSource = audioSource
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.name = name
    }
}

public struct MeshMediaClipRequest: Codable, Hashable, Sendable {
    public var itemID: String
    public var startSeconds: Double
    public var endSeconds: Double
    public var name: String?

    public init(itemID: String, startSeconds: Double, endSeconds: Double, name: String? = nil) {
        self.itemID = itemID
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.name = name
    }
}

public struct MeshMediaMultiViewRequest: Codable, Hashable, Sendable {
    public var primaryID: String
    public var secondaryID: String
    public var layout: String
    public var audioSource: String
    public var startSeconds: Double?
    public var endSeconds: Double?
    public var name: String?

    public init(
        primaryID: String,
        secondaryID: String,
        layout: String,
        audioSource: String,
        startSeconds: Double? = nil,
        endSeconds: Double? = nil,
        name: String? = nil
    ) {
        self.primaryID = primaryID
        self.secondaryID = secondaryID
        self.layout = layout
        self.audioSource = audioSource
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.name = name
    }
}

public struct MediaExportJobsPayload: Codable, Hashable, Sendable {
    public var jobs: [MediaExportJob]

    public init(jobs: [MediaExportJob]) {
        self.jobs = jobs
    }
}

public struct MediaExportJobResponse: Codable, Hashable, Sendable {
    public var job: MediaExportJob?
    public var error: String?

    public init(job: MediaExportJob? = nil, error: String? = nil) {
        self.job = job
        self.error = error
    }
}
