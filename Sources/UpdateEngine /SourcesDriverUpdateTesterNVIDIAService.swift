import Foundation

enum NVIDIAServiceError: Error {
    case invalidURL
    case networkError(Error)
    case decodingError(Error)
    case noDriverFound
}

actor NVIDIAService {
    
    // NVIDIA's public driver API endpoint (example - you may need to adjust)
    private let apiURL = "https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=DriverManualLookup&psid=120&pfid=916&osID=57&languageCode=1033&beta=0&isWHQL=1&dltype=-1&dch=1&upCRD=0&qnf=0&sort1=0&numberOfResults=1"
    
    func fetchLatestDriver() async throws -> DriverInfo {
        guard let url = URL(string: apiURL) else {
            throw NVIDIAServiceError.invalidURL
        }
        
        let (data, _) = try await URLSession.shared.data(from: url)
        
        do {
            let response = try JSONDecoder().decode(NVIDIAResponse.self, from: data)
            
            guard let driver = response.IDS.first?.downloadInfo else {
                throw NVIDIAServiceError.noDriverFound
            }
            
            // Extract highlights from release notes or description
            let highlights = extractHighlights(from: driver)
            
            return DriverInfo(
                version: driver.Version,
                releaseDate: driver.ReleaseDateTime,
                downloadURL: driver.DownloadURL,
                highlights: highlights
            )
        } catch let error as DecodingError {
            throw NVIDIAServiceError.decodingError(error)
        } catch {
            throw NVIDIAServiceError.networkError(error)
        }
    }
    
    private func extractHighlights(from driver: NVIDIADriverInfo) -> [String] {
        // Parse the description or notes to extract highlights
        // This is a simple implementation - you may want to enhance this
        var highlights: [String] = []
        
        if let description = driver.Description {
            // Split by common delimiters and take first few items
            let lines = description.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            
            highlights = Array(lines.prefix(3))
        }
        
        // Fallback highlights if none found
        if highlights.isEmpty {
            highlights = [
                "Game Ready Driver",
                "Optimized for latest games",
                "Performance improvements"
            ]
        }
        
        return highlights
    }
}

// MARK: - Response Models

struct NVIDIAResponse: Decodable {
    let IDS: [NVIDIADriver]
}

struct NVIDIADriver: Decodable {
    let downloadInfo: NVIDIADriverInfo
}

struct NVIDIADriverInfo: Decodable {
    let Version: String
    let ReleaseDateTime: String
    let DownloadURL: String
    let Description: String?
    
    enum CodingKeys: String, CodingKey {
        case Version
        case ReleaseDateTime
        case DownloadURL
        case Description = "ReleaseNotes"
    }
}
