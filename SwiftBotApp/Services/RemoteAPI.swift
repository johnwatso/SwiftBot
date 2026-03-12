import Foundation

struct RemoteAPI {
    enum Error: LocalizedError {
        case missingConfiguration
        case invalidBaseURL
        case invalidResponse
        case requestFailed(statusCode: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .missingConfiguration:
                return "Enter the primary node address and access token first."
            case .invalidBaseURL:
                return "The primary node address is invalid."
            case .invalidResponse:
                return "The primary node returned an invalid response."
            case .requestFailed(let statusCode, let message):
                if message.isEmpty {
                    return "Request failed with HTTP \(statusCode)."
                }
                return "Request failed with HTTP \(statusCode): \(message)"
            }
        }
    }

    private let baseURL: URL
    private let accessToken: String
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(configuration: RemoteModeSettings, session: URLSession = .shared) throws {
        let normalizedAddress = configuration.normalizedPrimaryNodeAddress
        let normalizedToken = configuration.normalizedAccessToken
        guard !normalizedAddress.isEmpty, !normalizedToken.isEmpty else {
            throw Error.missingConfiguration
        }
        guard let baseURL = URL(string: normalizedAddress) else {
            throw Error.invalidBaseURL
        }

        self.baseURL = baseURL
        self.accessToken = normalizedToken
        self.session = session
    }

    func get<Response: Decodable>(_ path: String, as type: Response.Type = Response.self) async throws -> Response {
        let request = try makeRequest(path: path, method: "GET")
        return try await send(request, decode: type)
    }

    func post<RequestBody: Encodable>(_ path: String, body: RequestBody) async throws {
        let request = try makeRequest(path: path, method: "POST", body: body)
        let _: RemoteOKResponse = try await send(request, decode: RemoteOKResponse.self)
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        try makeRequest(path: path, method: method, body: Optional<String>.none)
    }

    private func makeRequest<RequestBody: Encodable>(path: String, method: String, body: RequestBody?) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw Error.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest, decode type: Response.Type) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw Error.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = Self.errorMessage(from: data)
            throw Error.requestFailed(statusCode: httpResponse.statusCode, message: message)
        }

        guard !data.isEmpty else {
            throw Error.invalidResponse
        }

        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw Error.invalidResponse
        }
    }

    private static func errorMessage(from data: Data) -> String {
        if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = payload["error"] as? String {
            return error
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
