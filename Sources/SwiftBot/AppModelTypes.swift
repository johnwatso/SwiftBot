import Foundation

struct ConnectionDiagnostics {
    static let gatewayHeartbeatWarningThresholdMs = 750
    static let gatewayHeartbeatCriticalThresholdMs = 1_500
    private static let heartbeatSampleLimit = 7

    enum RESTHealth {
        case unknown
        case ok
        case error(Int, String)
    }

    var heartbeatLatencyMs: Int?
    var heartbeatLatencySamplesMs: [Int] = []
    var restHealth: RESTHealth = .unknown
    var rateLimitRemaining: Int?
    var lastTestAt: Date?
    var lastTestMessage: String = ""
    /// Last non-normal WebSocket close code from Discord (e.g. 4004, 4014). Nil = no abnormal close.
    var lastGatewayCloseCode: Int?

    mutating func recordHeartbeatLatency(_ latencyMs: Int) {
        heartbeatLatencySamplesMs.append(latencyMs)
        if heartbeatLatencySamplesMs.count > Self.heartbeatSampleLimit {
            heartbeatLatencySamplesMs.removeFirst(heartbeatLatencySamplesMs.count - Self.heartbeatSampleLimit)
        }
        heartbeatLatencyMs = Self.median(of: heartbeatLatencySamplesMs)
    }

    static func isGatewayHeartbeatWarning(_ latencyMs: Int?) -> Bool {
        latencyMs.map { $0 >= gatewayHeartbeatWarningThresholdMs } == true
    }

    static func isGatewayHeartbeatCritical(_ latencyMs: Int?) -> Bool {
        latencyMs.map { $0 >= gatewayHeartbeatCriticalThresholdMs } == true
    }

    private static func median(of samples: [Int]) -> Int? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return Int((Double(sorted[middle - 1]) + Double(sorted[middle])) / 2.0)
        }
        return sorted[middle]
    }
}

struct BinaryHTTPResponse: Sendable {
    var status: String
    var contentType: String
    var headers: [String: String]
    var body: Data
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
