import Foundation

/// Protocol for models that require deep validation of their fields to prevent
/// logic injection or unsafe operations (e.g. hitting internal network via webhooks).
protocol Validatable {
    func validate() throws
}

enum ValidationError: Error, LocalizedError {
    case invalidValue(String)
    case unsafeURL(String)
    case outOfRange(String, min: Double, max: Double)

    var errorDescription: String? {
        switch self {
        case .invalidValue(let msg):
            return "Invalid value: \(msg)"
        case .unsafeURL(let url):
            return "Unsafe URL: \(url). Only HTTPS URLs are allowed, and loopback/internal addresses are forbidden."
        case .outOfRange(let field, let min, let max):
            return "Field '\(field)' is out of range. Must be between \(min) and \(max)."
        }
    }
}

extension Validatable {
    /// Validates that a URL is HTTPS and does not point to a loopback address.
    func validateSecureURL(_ urlString: String?) throws {
        guard let urlString = urlString?.trimmingCharacters(in: .whitespacesAndNewlines), !urlString.isEmpty else { return }
        guard let url = URL(string: urlString) else {
            throw ValidationError.invalidValue("Malformed URL: \(urlString)")
        }
        guard url.scheme?.lowercased() == "https" else {
            throw ValidationError.unsafeURL(urlString)
        }
        
        let host = url.host?.lowercased() ?? ""
        let forbidden = ["localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0"]
        if forbidden.contains(where: { host.contains($0) }) {
            throw ValidationError.unsafeURL(urlString)
        }
    }
}
