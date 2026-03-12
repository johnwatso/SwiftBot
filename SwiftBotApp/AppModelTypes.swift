import Foundation

struct ConnectionDiagnostics {
    enum RESTHealth {
        case unknown
        case ok
        case error(Int, String)
    }

    var heartbeatLatencyMs: Int? = nil
    var restHealth: RESTHealth = .unknown
    var rateLimitRemaining: Int? = nil
    var lastTestAt: Date? = nil
    var lastTestMessage: String = ""
    /// Last non-normal WebSocket close code from Discord (e.g. 4004, 4014). Nil = no abnormal close.
    var lastGatewayCloseCode: Int? = nil
}

struct BinaryHTTPResponse: Sendable {
    var status: String
    var contentType: String
    var headers: [String: String]
    var body: Data
}

struct MediaStreamDescriptor: Codable, Hashable {
    var itemID: String
    var ownerNodeName: String
    var ownerBaseURL: String?
}

struct MediaLibrarySettings: Codable, Hashable {
    var sources: [MediaLibrarySource] = []
    var exportRootPath: String = ""
    var exportIncludeInLibrary: Bool = true
    var exportSourceID: UUID? = nil
}

struct MediaLibrarySource: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var name: String = "Gameplay"
    var rootPath: String = ""
    var isEnabled: Bool = true
    var allowedExtensions: [String] = ["mp4", "mov", "m4v"]

    var normalizedRootPath: String {
        let trimmed = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let unquoted = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let unescaped = unquoted.replacingOccurrences(of: "\\ ", with: " ")
        return (unescaped as NSString).expandingTildeInPath
    }

    var normalizedExtensions: [String] {
        allowedExtensions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }
}

struct MediaLibraryItem: Codable, Hashable, Identifiable {
    var id: String
    var sourceID: UUID
    var sourceName: String
    var fileName: String
    var relativePath: String
    var absolutePath: String
    var fileExtension: String
    var sizeBytes: Int64
    var modifiedAt: Date
    var ownerNodeName: String
    var ownerBaseURL: String?
}

struct MediaLibraryPayload: Codable, Hashable {
    var nodeName: String
    var configFilePath: String
    var sources: [MediaLibrarySource]
    var items: [MediaLibraryItem]
    var generatedAt: Date
}

struct MediaExportStatus: Codable, Hashable {
    var installed: Bool
    var version: String?
    var path: String?
}

struct MediaExportJob: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case clip
        case multiview
    }

    enum Status: String, Codable {
        case queued
        case running
        case finished
        case failed
    }

    var id: String
    var kind: Kind
    var status: Status
    var createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var message: String?
    var outputFileName: String?
    var outputPath: String?
    var nodeName: String
}

struct MediaExportClipRequest: Codable, Hashable {
    var token: String
    var startSeconds: Double
    var endSeconds: Double
    var name: String?
    var thumbnailAtSeconds: Double?
}

struct MediaExportMultiViewRequest: Codable, Hashable {
    var primaryToken: String
    var secondaryToken: String
    var layout: String
    var audioSource: String
    var startSeconds: Double?
    var endSeconds: Double?
    var name: String?
}

struct MeshMediaClipRequest: Codable, Hashable {
    var itemID: String
    var startSeconds: Double
    var endSeconds: Double
    var name: String?
}

struct MeshMediaMultiViewRequest: Codable, Hashable {
    var primaryID: String
    var secondaryID: String
    var layout: String
    var audioSource: String
    var startSeconds: Double?
    var endSeconds: Double?
    var name: String?
}

struct MediaExportJobsPayload: Codable, Hashable {
    var jobs: [MediaExportJob]
}

struct MediaExportJobResponse: Codable, Hashable {
    var job: MediaExportJob?
    var error: String?
}
