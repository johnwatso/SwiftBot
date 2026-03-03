import Foundation

struct NVIDIAService {
    struct DriverInfo {
        let releaseNotes: ReleaseNotes
        let embedJSON: String
        let rawDebug: String
    }

    // NVIDIA's official driver search API endpoint
    private let apiEndpoint = URL(string: "https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php")!
    
    private let formatter = EmbedFormatter()
    
    func fetchLatestDriver() async throws -> DriverInfo {
        // Build POST request for GeForce Game Ready Driver on Windows 11 64-bit
        var request = URLRequest(url: apiEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        // Query parameters for Game Ready Driver
        // psid=120 (GeForce), pfid=916 (Desktop), osID=135 (Windows 11 64-bit)
        let params = [
            "func": "DriverManualLookup",
            "psid": "120",           // Product Series: GeForce
            "pfid": "916",           // Product: Desktop
            "osID": "135",           // OS: Windows 11 64-bit
            "languageCode": "1033", // English (US)
            "beta": "0",            // No beta drivers
            "isWHQL": "1",          // WHQL certified only
            "dltype": "-1",         // All download types
            "dch": "1",             // DCH drivers
            "sort1": "0",           // Sort by date (newest first)
            "numberOfResults": "1"  // Only get the latest
        ]
        
        let bodyString = params.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        request.httpBody = bodyString.data(using: .utf8)
        
        // Execute the request
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NVIDIAServiceError.networkError
        }
        
        let rawJSON = String(data: data, encoding: .utf8) ?? ""
        
        // Parse JSON using JSONSerialization
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NVIDIAServiceError.invalidJSONResponse
        }
        
        // Extract IDS array
        guard let idsArray = jsonObject["IDS"] as? [[String: Any]],
              let firstDriver = idsArray.first else {
            throw NVIDIAServiceError.noDriverFound
        }
        
        // Extract downloadInfo object
        guard let downloadInfo = firstDriver["downloadInfo"] as? [String: Any] else {
            throw NVIDIAServiceError.missingField("downloadInfo")
        }
        
        // Extract required fields
        guard let versionString = downloadInfo["Version"] as? String else {
            throw NVIDIAServiceError.missingField("Version")
        }
        
        guard let releaseDate = downloadInfo["ReleaseDateTime"] as? String else {
            throw NVIDIAServiceError.missingField("ReleaseDateTime")
        }
        
        guard let downloadURL = downloadInfo["DownloadURL"] as? String else {
            throw NVIDIAServiceError.missingField("DownloadURL")
        }
        
        // Extract version number using strict regex
        let version = try extractVersionStrict(from: versionString)
        
        // Build ReleaseNotes model
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
        
        // Format using unified formatter
        let embedJSON = formatter.format(releaseNotes: releaseNotes)
        
        return DriverInfo(
            releaseNotes: releaseNotes,
            embedJSON: embedJSON,
            rawDebug: "NVIDIA Driver API Response:\n\(rawJSON)"
        )
    }
    
    /// Strict version extraction using regex pattern \d{3}\.\d{2}
    private func extractVersionStrict(from text: String) throws -> String {
        let pattern = #"\b(\d{3}\.\d{2})\b"#
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            throw NVIDIAServiceError.versionExtractionFailed(text: text)
        }
        
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard
            let match = regex.firstMatch(in: text, options: [], range: range),
            match.numberOfRanges > 1,
            let captureRange = Range(match.range(at: 1), in: text)
        else {
            throw NVIDIAServiceError.versionExtractionFailed(text: text)
        }
        
        return String(text[captureRange])
    }
}

// MARK: - Error Types

private enum NVIDIAServiceError: LocalizedError {
    case networkError
    case invalidJSONResponse
    case noDriverFound
    case missingField(String)
    case versionExtractionFailed(text: String)

    var errorDescription: String? {
        switch self {
        case .networkError:
            return "Network request to NVIDIA driver API failed."
        case .invalidJSONResponse:
            return "Response from NVIDIA API is not valid JSON."
        case .noDriverFound:
            return "No driver information was returned from the NVIDIA driver search API."
        case .missingField(let fieldName):
            return "Required field '\(fieldName)' is missing from the NVIDIA API response."
        case .versionExtractionFailed(let text):
            return "Failed to extract driver version from text: '\(text)'. Expected format: XXX.XX (e.g., 551.23)"
        }
    }
}

