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

// MARK: - View Mode


enum ViewMode: String, Codable, CaseIterable, Identifiable {
    case local
    case remote
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .local: return "Local Dashboard"
        case .remote: return "Remote Dashboard"
        }
    }
    
    var icon: String {
        switch self {
        case .local: return "desktopcomputer"
        case .remote: return "dot.radiowaves.left.and.right"
        }
    }
}

struct AdminWebCertificateRenewalConfiguration: Equatable {
    let enabled: Bool
    let domain: String
    let cloudflareToken: String
}


// MARK: - Admin Web Setup Events & Errors

enum AdminWebAutomaticHTTPSSetupEvent: Sendable, Equatable {
    case verifyingCloudflareAccess
    case cloudflareAccessVerified
    case detectingCloudflareZone(domain: String)
    case cloudflareZoneDetected(zone: String)
    case creatingDNSChallengeRecord(recordName: String)
    case dnsChallengeRecordCreated(recordName: String, reusedExistingRecord: Bool)
    case waitingForDNSPropagation(recordName: String)
    case dnsChallengeRecordPropagated(recordName: String)
    case dnsChallengeRecordVerified(recordName: String, reusedExistingRecord: Bool)
    case requestingTLSCertificate(domain: String)
    case tlsCertificateIssued(domain: String)
    case storingCertificate
    case certificateStored(path: String)
    case enablingHTTPSListener
    case httpsListenerEnabled(url: String)
}

enum AdminWebPublicAccessSetupEvent: Sendable, Equatable {
    case verifyingCloudflareAccess
    case cloudflareAccessVerified
    case detectingCloudflareZone(domain: String)
    case cloudflareZoneDetected(zone: String)
    case creatingTunnel(hostname: String)
    case tunnelCreated(name: String)
    case tunnelDetected(name: String)
    case creatingTunnelDNSRecord(hostname: String)
    case tunnelDNSRecordCreated(hostname: String)
    case storingTunnelCredentials
    case startingTunnelProcess
    case publicAccessEnabled(url: String)
}

enum InternetAccessSetupEvent: Sendable, Equatable {
    case verifyingCloudflareAccess
    case cloudflareAccessVerified
    case detectingCloudflareZone(domain: String)
    case cloudflareZoneDetected(zone: String)
    case creatingTunnel(hostname: String)
    case tunnelCreated(name: String)
    case tunnelDetected(name: String)
    case creatingTunnelDNSRecord(hostname: String)
    case tunnelDNSRecordCreated(hostname: String)
    case issuingHTTPSCertificate(hostname: String)
    case httpsCertificateIssued(hostname: String)
    case startingCloudflareTunnel
    case cloudflareTunnelStarted
    case internetAccessEnabled(url: String)
}

enum AdminWebHTTPSProvisioningError: LocalizedError {
    case tlsActivationFailed

    var errorDescription: String? {
        switch self {
        case .tlsActivationFailed:
            return "The certificate was issued, but SwiftBot could not start the Admin Web UI over HTTPS. Check the logs and TLS files, then try again."
        }
    }
}

enum AdminWebPublicAccessError: LocalizedError {
    case missingHostname
    case invalidOriginURL
    case tunnelStartupFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingHostname:
            return "Enter a public hostname before enabling Public Access."
        case .invalidOriginURL:
            return "SwiftBot could not determine the local Web UI address for Cloudflare Tunnel."
        case .tunnelStartupFailed(let detail):
            return detail
        }
    }
}

let genericAdminWebHTTPSSetupFailureMessage = "HTTPS setup couldn’t be completed. Verify Cloudflare access and DNS propagation, then try again."
let genericAdminWebPublicAccessFailureMessage = "Public Access couldn’t be completed. Verify the hostname, Cloudflare access, and tunnel configuration, then try again."

