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
}

struct MediaLibrarySource: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var name: String = "Gameplay"
    var rootPath: String = ""
    var isEnabled: Bool = true
    var allowedExtensions: [String] = ["mp4", "mov", "m4v"]

    var normalizedRootPath: String {
        rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
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
