import Foundation

public struct NVIDIAService: Sendable {
    public struct DriverInfo: Sendable {
        public let releaseNotes: ReleaseNotes
        public let embedJSON: String
        public let rawDebug: String
        public let releaseIdentifier: String

        public init(
            releaseNotes: ReleaseNotes,
            embedJSON: String,
            rawDebug: String,
            releaseIdentifier: String
        ) {
            self.releaseNotes = releaseNotes
            self.embedJSON = embedJSON
            self.rawDebug = rawDebug
            self.releaseIdentifier = releaseIdentifier
        }
    }

    private let session: URLSession
    private let apiEndpoint: URL
    private let formatter: EmbedFormatter

    public init(
        session: URLSession = .shared,
        apiEndpoint: URL = URL(string: "https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php")!,
        formatter: EmbedFormatter = EmbedFormatter()
    ) {
        self.session = session
        self.apiEndpoint = apiEndpoint
        self.formatter = formatter
    }

    public func fetchLatestDriver() async throws -> DriverInfo {
        var request = URLRequest(url: apiEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let params = [
            "func": "DriverManualLookup",
            "psid": "120",
            "pfid": "916",
            "osID": "135",
            "languageCode": "1033",
            "beta": "0",
            "isWHQL": "1",
            "dltype": "-1",
            "dch": "1",
            "sort1": "0",
            "numberOfResults": "1"
        ]

        request.httpBody = params
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response)

        let rawJSON = String(data: data, encoding: .utf8) ?? ""
        guard let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NVIDIAServiceError.invalidJSONResponse
        }

        guard let idsArray = jsonObject["IDS"] as? [[String: Any]],
              let firstDriver = idsArray.first else {
            throw NVIDIAServiceError.noDriverFound
        }

        guard let downloadInfo = firstDriver["downloadInfo"] as? [String: Any] else {
            throw NVIDIAServiceError.missingField("downloadInfo")
        }

        guard let versionString = downloadInfo["Version"] as? String else {
            throw NVIDIAServiceError.missingField("Version")
        }

        guard let releaseDate = downloadInfo["ReleaseDateTime"] as? String else {
            throw NVIDIAServiceError.missingField("ReleaseDateTime")
        }

        guard let downloadURL = downloadInfo["DownloadURL"] as? String else {
            throw NVIDIAServiceError.missingField("DownloadURL")
        }

        let version = try extractVersionStrict(from: versionString)
        let releaseIdentifier = downloadURL.isEmpty ? "nvidia:\(version)" : downloadURL

        let releaseNotes = ReleaseNotes(
            title: "GeForce Game Ready Driver v\(version)",
            author: "NVIDIA GeForce Driver",
            url: "https://www.nvidia.com/en-us/geforce/drivers/",
            version: version,
            date: releaseDate,
            sections: [
                ReleaseSection(
                    title: "Driver Information",
                    bullets: [
                        Bullet(text: "Latest Game Ready Driver for Windows 11 64-bit"),
                        Bullet(text: "Optimized for the latest games and applications")
                    ]
                )
            ],
            thumbnailURL: "https://cdn.patchbot.io/games/142/nvidia-geforce_1710977247_sm.jpg",
            color: 5763719
        )

        return DriverInfo(
            releaseNotes: releaseNotes,
            embedJSON: formatter.format(releaseNotes: releaseNotes),
            rawDebug: "NVIDIA Driver API Response:\n\(rawJSON)",
            releaseIdentifier: releaseIdentifier
        )
    }

    private func extractVersionStrict(from text: String) throws -> String {
        let pattern = #"\b(\d{3}\.\d{2})\b"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)

        guard
            let match = regex.firstMatch(in: text, range: range),
            match.numberOfRanges > 1,
            let captureRange = Range(match.range(at: 1), in: text)
        else {
            throw NVIDIAServiceError.versionExtractionFailed(text: text)
        }

        return String(text[captureRange])
    }

    private func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw NVIDIAServiceError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            throw NVIDIAServiceError.httpError(statusCode: http.statusCode)
        }
    }
}

public enum NVIDIAServiceError: LocalizedError, Sendable {
    case invalidResponse
    case httpError(statusCode: Int)
    case invalidJSONResponse
    case noDriverFound
    case missingField(String)
    case versionExtractionFailed(text: String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "NVIDIA API returned an invalid response object."
        case .httpError(let statusCode):
            return "NVIDIA API request failed with HTTP \(statusCode)."
        case .invalidJSONResponse:
            return "NVIDIA API returned invalid JSON."
        case .noDriverFound:
            return "No NVIDIA driver entries were returned."
        case .missingField(let name):
            return "NVIDIA response missing required field '\(name)'."
        case .versionExtractionFailed(let text):
            return "Failed to extract NVIDIA version from '\(text)'."
        }
    }
}
