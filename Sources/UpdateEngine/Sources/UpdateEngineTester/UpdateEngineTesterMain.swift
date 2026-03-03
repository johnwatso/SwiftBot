import Foundation
import UpdateEngine

private enum TesterError: LocalizedError {
    case invalidArgument(String)
    case missingArgument(String)

    var errorDescription: String? {
        switch self {
        case .invalidArgument(let message):
            return message
        case .missingArgument(let argument):
            return "Missing required argument: \(argument)"
        }
    }
}

private enum SourceKind: String {
    case nvidia
    case amd
    case intel
    case steam
}

private struct Config {
    var source: SourceKind = .nvidia
    var steamAppID: String?
    var guildID: String?
    var save: Bool = true

    static func fromCommandLine() throws -> Config {
        var config = Config()
        var args = Array(CommandLine.arguments.dropFirst())

        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--source":
                guard let value = args.first else { throw TesterError.missingArgument("--source") }
                _ = args.removeFirst()
                guard let source = SourceKind(rawValue: value.lowercased()) else {
                    throw TesterError.invalidArgument("Invalid --source value '\(value)'. Use: nvidia | amd | intel | steam")
                }
                config.source = source

            case "--app-id":
                guard let value = args.first else { throw TesterError.missingArgument("--app-id") }
                _ = args.removeFirst()
                config.steamAppID = value

            case "--guild":
                guard let value = args.first else { throw TesterError.missingArgument("--guild") }
                _ = args.removeFirst()
                config.guildID = value

            case "--no-save":
                config.save = false

            case "--help", "-h":
                printHelp()
                exit(0)

            default:
                throw TesterError.invalidArgument("Unknown argument: \(arg)")
            }
        }

        if config.source == .steam, config.steamAppID == nil {
            throw TesterError.missingArgument("--app-id (required for --source steam)")
        }

        return config
    }
}

private func printHelp() {
    print(
        """
        UpdateEngineTester

        Usage:
          swift run UpdateEngineTester [options]

        Options:
          --source <nvidia|amd|intel|steam>  Update source to fetch (default: nvidia)
          --app-id <steamAppID>         Required when --source steam
          --guild <guildID>             Optional guild scope for cache key
          --no-save                     Do not persist fetched identifier
          --help                        Show this help

        Environment:
          UPDATE_ENGINE_STORE_PATH      Optional cache file path
        """
    )
}

private func defaultStoreURL() -> URL {
    if let raw = ProcessInfo.processInfo.environment["UPDATE_ENGINE_STORE_PATH"], !raw.isEmpty {
        return URL(fileURLWithPath: raw)
    }

    let cwd = FileManager.default.currentDirectoryPath
    return URL(fileURLWithPath: cwd)
        .appendingPathComponent(".updateengine-tester")
        .appendingPathComponent("identifiers.json")
}

private func makeSource(from config: Config) -> any UpdateSource {
    switch config.source {
    case .nvidia:
        return NVIDIAUpdateSource()
    case .amd:
        return AMDUpdateSource()
    case .intel:
        return IntelUpdateSource()
    case .steam:
        return SteamNewsUpdateSource(appID: config.steamAppID!)
    }
}

private func resultLabel(_ result: UpdateChangeResult) -> String {
    switch result {
    case .firstSeen(let id):
        return "firstSeen (identifier: \(id))"
    case .changed(let old, let new):
        return "changed (old: \(old), new: \(new))"
    case .unchanged(let id):
        return "unchanged (identifier: \(id))"
    }
}

@main
struct UpdateEngineTesterMain {
    static func main() async {
        do {
            let config = try Config.fromCommandLine()
            let source = makeSource(from: config)

            let storeURL = defaultStoreURL()
            let store = try JSONVersionStore(fileURL: storeURL)
            let checker = UpdateChecker(store: store)

            let item = try await source.fetchLatest()
            let cacheKey: String
            if let guildID = config.guildID {
                cacheKey = CacheKeyBuilder.buildGuildScoped(guildID: guildID, baseKey: item.sourceKey)
            } else {
                cacheKey = item.sourceKey
            }

            let checkResult = try await checker.check(item: item, for: cacheKey)

            print("Source key: \(item.sourceKey)")
            print("Cache key:  \(cacheKey)")
            print("Identifier: \(item.identifier)")
            print("Version:    \(item.version)")
            print("Result:     \(resultLabel(checkResult))")

            if config.save {
                try await checker.save(item: item, for: cacheKey)
                print("Saved:      yes (\(storeURL.path))")
            } else {
                print("Saved:      no (--no-save)")
            }

            print("\nTester run complete.")
        } catch {
            fputs("Error: \(error.localizedDescription)\n\n", stderr)
            printHelp()
            exit(1)
        }
    }
}
