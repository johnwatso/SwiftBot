import Foundation

enum FinalsIDAPIError: LocalizedError, Equatable {
    case invalidBaseURL
    case endpointContractMissing
    case invalidEndpoint
    case unauthorized
    case httpStatus(Int)
    case missingRankedScore
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "The finals.id API base URL is invalid."
        case .endpointContractMissing:
            return "The finals.id rank endpoint contract has not been configured."
        case .invalidEndpoint:
            return "The finals.id endpoint could not be constructed."
        case .unauthorized:
            return "finals.id rejected the API token."
        case .httpStatus(let status):
            return "finals.id returned HTTP \(status)."
        case .missingRankedScore:
            return "The finals.id response did not contain an explicit SR/RS value."
        case .invalidResponse:
            return "The finals.id response could not be decoded."
        }
    }
}

actor FinalsIDAPIClient: GameRankProvider {
    nonisolated let descriptor = GameProviderCatalog.descriptors[.finalsID]
        ?? GameProviderDescriptor(
            id: .finalsID,
            supportedGames: [.theFinals],
            capabilities: [],
            auth: .bearer,
            defaultBaseURL: "https://api.finals.id"
        )
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchRankSnapshot(
        for target: GameTrackedPlayer,
        connection: GameProviderConnection
    ) async throws -> GameRankSnapshot {
        let url = try endpointURL(for: target.playerID, connection: connection)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SwiftBot-finals.id/1", forHTTPHeaderField: "User-Agent")
        if !connection.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            connection.authorize(&request)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FinalsIDAPIError.invalidResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw FinalsIDAPIError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            throw FinalsIDAPIError.httpStatus(http.statusCode)
        }
        return try FinalsIDRankResponseDecoder.decode(
            data: data,
            game: target.game,
            provider: target.provider,
            fallbackPlayerID: target.playerID,
            fallbackDisplayName: target.resolvedDisplayName
        )
    }

    func fetchLatestRound(
        endpointPath: String,
        connection: GameProviderConnection
    ) async throws -> FinalsIDLatestRoundResponse {
        guard let baseURL = normalizedBaseURL(connection.baseURL) else {
            throw FinalsIDAPIError.invalidBaseURL
        }
        guard let url = URL(string: endpointPath, relativeTo: baseURL)?.absoluteURL else {
            throw FinalsIDAPIError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SwiftBot-finals.id/1", forHTTPHeaderField: "User-Agent")
        if !connection.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            connection.authorize(&request)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FinalsIDAPIError.invalidResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw FinalsIDAPIError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            throw FinalsIDAPIError.httpStatus(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(FinalsIDLatestRoundResponse.self, from: data)
        } catch {
            throw FinalsIDAPIError.invalidResponse
        }
    }

    private func endpointURL(for playerID: String, connection: GameProviderConnection) throws -> URL {
        guard let baseURL = normalizedBaseURL(connection.baseURL) else {
            throw FinalsIDAPIError.invalidBaseURL
        }
        let template = connection.rankEndpointTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard template.contains("{playerID}") else {
            throw FinalsIDAPIError.endpointContractMissing
        }
        var allowedPlayerIDCharacters = CharacterSet.urlPathAllowed
        allowedPlayerIDCharacters.remove(charactersIn: "/")
        guard let encodedPlayerID = playerID.addingPercentEncoding(
            withAllowedCharacters: allowedPlayerIDCharacters
        ) else {
            throw FinalsIDAPIError.invalidEndpoint
        }
        let path = template.replacingOccurrences(of: "{playerID}", with: encodedPlayerID)
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw FinalsIDAPIError.invalidEndpoint
        }
        return url
    }

    private func normalizedBaseURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            return nil
        }
        return url.absoluteString.hasSuffix("/") ? url : url.appendingPathComponent("")
    }
}

enum FinalsIDRankResponseDecoder {
    private static let scoreKeys = ["sr", "rs", "rankedScore", "rankScore", "ranked_score", "rank_score"]
    private static let containerKeys = ["data", "result", "profile", "ranked", "ranking", "rank"]

    static func decode(
        data: Data,
        game: GameID,
        provider: GameProviderID,
        fallbackPlayerID: String,
        fallbackDisplayName: String
    ) throws -> GameRankSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw FinalsIDAPIError.invalidResponse
        }
        guard let scoreNode = findScoreNode(in: root),
              let score = integer(from: value(forAnyKey: scoreKeys, in: scoreNode)) else {
            // Deliberately do not accept a generic `score`: the proposed round
            // response contains combat score, which must never be announced as SR.
            throw FinalsIDAPIError.missingRankedScore
        }

        let playerID = string(from: value(forAnyKey: ["playerId", "playerID", "id"], in: scoreNode))
            ?? stringFromTree(root, keys: ["playerId", "playerID"])
            ?? fallbackPlayerID
        let displayName = string(from: value(forAnyKey: ["displayName", "playerName", "username", "name"], in: scoreNode))
            ?? stringFromTree(root, keys: ["displayName", "playerName", "username"])
            ?? fallbackDisplayName
        let season = string(from: value(forAnyKey: ["season", "seasonId", "seasonID"], in: scoreNode))
            ?? stringFromTree(root, keys: ["season", "seasonId", "seasonID"])
            ?? ""
        let rankName = string(from: value(forAnyKey: ["rankName", "tier", "league", "rankLabel"], in: scoreNode))
            ?? stringFromTree(root, keys: ["rankName", "tier", "league", "rankLabel"])
        let updatedAtText = string(from: value(forAnyKey: ["updatedAt", "lastUpdated", "recordedAt"], in: scoreNode))
            ?? stringFromTree(root, keys: ["updatedAt", "lastUpdated", "recordedAt"])

        return GameRankSnapshot(
            game: game,
            provider: provider,
            playerID: playerID,
            displayName: displayName,
            season: season,
            rankName: rankName,
            score: score,
            updatedAt: updatedAtText.flatMap(parseDate)
        )
    }

    private static func findScoreNode(in candidate: Any) -> [String: Any]? {
        if let dictionary = candidate as? [String: Any] {
            if value(forAnyKey: scoreKeys, in: dictionary) != nil {
                return dictionary
            }
            for key in containerKeys {
                if let nested = dictionary[key], let found = findScoreNode(in: nested) {
                    return found
                }
            }
            for nested in dictionary.values {
                if let found = findScoreNode(in: nested) { return found }
            }
        } else if let array = candidate as? [Any] {
            for nested in array {
                if let found = findScoreNode(in: nested) { return found }
            }
        }
        return nil
    }

    private static func stringFromTree(_ candidate: Any, keys: [String]) -> String? {
        if let dictionary = candidate as? [String: Any] {
            if let result = string(from: value(forAnyKey: keys, in: dictionary)) { return result }
            for nested in dictionary.values {
                if let result = stringFromTree(nested, keys: keys) { return result }
            }
        } else if let array = candidate as? [Any] {
            for nested in array {
                if let result = stringFromTree(nested, keys: keys) { return result }
            }
        }
        return nil
    }

    private static func value(forAnyKey keys: [String], in dictionary: [String: Any]) -> Any? {
        for key in keys where dictionary[key] != nil { return dictionary[key] }
        return nil
    }

    private static func integer(from value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value.replacingOccurrences(of: ",", with: "")) }
        return nil
    }

    private static func string(from value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
