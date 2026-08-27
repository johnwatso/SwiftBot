import Foundation

/// Resolves a `GameProviderID` to the client that talks to it.
///
/// This is the single dispatch point for provider selection — adding a provider
/// means registering it here and adding a `GameProviderCatalog` descriptor, with
/// no `switch` to extend at each call site.
actor GameProviderRegistry {
    private var providers: [GameProviderID: any GameRankProvider] = [:]

    init(session: URLSession = .shared) {
        // Every provider this build ships. Registration happens here so the rest
        // of the app never names a concrete client.
        let registered: [any GameRankProvider] = [
            FinalsIDAPIClient(session: session)
        ]
        providers = Dictionary(
            uniqueKeysWithValues: registered.map { ($0.descriptor.id, $0) }
        )
    }

    func provider(for id: GameProviderID) -> (any GameRankProvider)? {
        providers[id]
    }

    /// Providers that are registered in this build, regardless of whether the
    /// operator has configured a connection for them.
    func availableProviderIDs() -> [GameProviderID] {
        providers.keys.sorted { $0.rawValue < $1.rawValue }
    }

    func fetchRankSnapshot(
        for target: GameTrackedPlayer,
        connection: GameProviderConnection
    ) async throws -> GameRankSnapshot {
        guard let provider = providers[target.provider] else {
            throw GameProviderRegistryError.unsupportedProvider(target.provider)
        }
        guard provider.descriptor.capabilities.contains(.rankedScore) else {
            throw GameProviderRegistryError.capabilityUnavailable(target.provider, .rankedScore)
        }
        return try await provider.fetchRankSnapshot(for: target, connection: connection)
    }
}

enum GameProviderRegistryError: LocalizedError, Equatable {
    case unsupportedProvider(GameProviderID)
    case capabilityUnavailable(GameProviderID, GameTrackingCapability)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider(let id):
            return "\(id.displayName) is not a supported provider in this build."
        case .capabilityUnavailable(let id, let capability):
            return "\(id.displayName) does not provide \(capability.rawValue) data."
        }
    }
}
