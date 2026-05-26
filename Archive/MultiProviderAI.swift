// MARK: - Archived Multi-Provider AI (Apple-only consolidation, 2026-05-27)
//
// Preserved here in case we ever want to bring back support for Ollama,
// OpenAI chat completions, OpenAI image generation, or provider racing.
//
// Original files touched:
// - SwiftBotApp/Services/DiscordAIService.swift   (engine structs + racing)
// - SwiftBotApp/Models/AIModels.swift             (AIProvider, AIProviderPreference)
// - SwiftBotApp/Models/BotSettings.swift          (Ollama/OpenAI fields)
// - SwiftBotApp/Models/ClusterModels.swift        (mesh-synced provider prefs)
// - SwiftBotApp/AIBotsView.swift                  (provider picker UI)
// - SwiftBotApp/AppModel+Commands.swift           (/image slash command)
// - SwiftBotApp/AppModel.swift                    (configureLocalAIDMReplies wiring)
// - SwiftBotApp/AppModel+AdminWeb.swift           (admin API surface)
// - SwiftBotApp/RemoteModeRootView.swift          (openAIImageGenerationEnabled)
// - Tests/SwiftBotTests/DiscordAIServiceTests.swift (engine racing tests)

import Foundation

// MARK: - Provider enums (originally in Models/AIModels.swift)
/*
enum AIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case appleIntelligence
    case ollama
    case openAI
    var id: String { rawValue }
}

enum AIProviderPreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case apple
    case ollama
    case openAI
    var id: String { rawValue }
}
*/

// MARK: - OllamaEngine (originally in Services/DiscordAIService.swift)
/*
struct OllamaEngine: AIEngine {
    let baseURL: String
    let preferredModel: String?
    let session: URLSession

    private struct PayloadMessage: Encodable {
        let role: String
        let content: String
    }

    private struct ChatPayload: Encodable {
        let model: String
        let stream: Bool
        let messages: [PayloadMessage]
    }

    func generate(messages: [Message]) async -> String? {
        guard let url = URL(string: "\(baseURL)/api/chat") else { return nil }
        guard let model = await Self.resolveModel(baseURL: baseURL, preferredModel: preferredModel, session: session) else { return nil }

        let payloadMessages = messages.toEngineMessages().map { message in
            PayloadMessage(role: message.role.rawValue, content: message.content)
        }

        guard payloadMessages.contains(where: { $0.role == EngineMessageRole.user.rawValue }) else { return nil }

        let payload = ChatPayload(model: model, stream: false, messages: payloadMessages)

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(payload)

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            guard
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let message = object["message"] as? [String: Any],
                let content = message["content"] as? String
            else { return nil }

            let cleaned = cleanOutput(content)
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            return nil
        }
    }

    static func resolveModel(baseURL: String, preferredModel: String?, session: URLSession) async -> String? {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            guard
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let models = object["models"] as? [[String: Any]],
                !models.isEmpty
            else { return nil }

            let names = models.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
            guard !names.isEmpty else { return nil }

            let preferred = preferredModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !preferred.isEmpty {
                if let exact = names.first(where: { $0 == preferred }) { return exact }
                if let starts = names.first(where: { $0.hasPrefix(preferred) }) { return starts }
            }
            return names.first
        } catch {
            return nil
        }
    }
}
*/

// MARK: - OpenAIEngine (originally in Services/DiscordAIService.swift)
/*
struct OpenAIEngine: AIEngine {
    let apiKey: String
    let model: String
    let baseURL: String
    let session: URLSession

    private struct ChatCompletionRequest: Encodable {
        struct ChatMessage: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [ChatMessage]
        let temperature: Double
    }

    private struct ChatCompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }
            let message: Message
        }
        let choices: [Choice]
    }

    func generate(messages: [Message]) async -> String? {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return nil }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return nil }
        guard let url = URL(string: "\(baseURL)/v1/chat/completions") else { return nil }

        let payloadMessages = messages.toEngineMessages().map { message in
            ChatCompletionRequest.ChatMessage(role: message.role.rawValue, content: message.content)
        }
        guard payloadMessages.contains(where: { $0.role == "user" }) else { return nil }

        let payload = ChatCompletionRequest(model: trimmedModel, messages: payloadMessages, temperature: 0.4)

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 25
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONEncoder().encode(payload)

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            let content = decoded.choices.first?.message.content ?? ""
            let cleaned = cleanOutput(content)
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            return nil
        }
    }

    static func isOnline(apiKey: String, baseURL: String, session: URLSession) async -> Bool {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, let url = URL(string: "\(baseURL)/v1/models") else { return false }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 10
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }
}
*/

// MARK: - OpenAIImageEngine (originally in Services/DiscordAIService.swift)
/*
struct OpenAIImageEngine {
    let apiKey: String
    let model: String
    let baseURL: String
    let session: URLSession

    private struct ImageGenerationRequest: Encodable {
        let model: String
        let prompt: String
        let size: String
    }

    private struct ImageGenerationResponse: Decodable {
        struct ImageData: Decodable {
            let b64_json: String?
        }
        let data: [ImageData]
    }

    func generateImage(prompt: String) async -> Data? {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return nil }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return nil }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return nil }
        guard let url = URL(string: "\(baseURL)/v1/images/generations") else { return nil }

        let payload = ImageGenerationRequest(
            model: trimmedModel,
            prompt: trimmedPrompt,
            size: "1024x1024"
        )

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 60
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONEncoder().encode(payload)

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }

            let decoded = try JSONDecoder().decode(ImageGenerationResponse.self, from: data)
            guard
                let b64 = decoded.data.first?.b64_json,
                let imageData = Data(base64Encoded: b64)
            else {
                return nil
            }
            return imageData
        } catch {
            return nil
        }
    }
}
*/

// MARK: - Engine racing (originally in DiscordAIService.generateReply)
/*
// All three engines raced in parallel; first non-nil result won.
// `orderedEngines(preferred:engines:)` defined start ordering but did NOT
// gate parallelism. Cancellation fired as soon as any engine returned text.

struct EngineSet: Sendable {
    let apple: any AIEngine
    let ollama: any AIEngine
    let openAI: any AIEngine
}

private func orderedEngines(preferred: AIProviderPreference, engines: EngineSet) -> [any AIEngine] {
    switch preferred {
    case .apple:  return [engines.apple, engines.openAI, engines.ollama]
    case .ollama: return [engines.ollama, engines.openAI, engines.apple]
    case .openAI: return [engines.openAI, engines.apple, engines.ollama]
    }
}

// Body of generateReply previously:
//   let engines = engineFactory(configuration, systemPrompt)
//   let ordered = orderedEngines(preferred: configuration.preferredProvider, engines: engines)
//   return await withTaskGroup(of: (Int, String?).self) { group in
//       for (index, engine) in ordered.enumerated() {
//           group.addTask { let reply = await engine.generate(messages: finalMessages); ... }
//       }
//       for await (index, result) in group {
//           if let result { group.cancelAll(); return result }
//       }
//       return nil
//   }

// Ollama URL normalizer (defaulted to http://localhost:11434):
//   nonisolated static func normalizedOllamaBaseURL(_ raw: String) -> String {
//       let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
//       if trimmed.isEmpty { return "http://localhost:11434" }
//       if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return trimmed }
//       return "http://\(trimmed)"
//   }
*/

// MARK: - BotSettings fields (originally in Models/BotSettings.swift)
/*
var localAIProvider: AIProvider = .appleIntelligence
var preferredAIProvider: AIProviderPreference = .apple
var localAIEndpoint: String = "http://localhost:11434"
var localAIModel: String = ""
var ollamaBaseURL: String = "http://localhost:11434"
var ollamaEnabled: Bool = false
var openAIEnabled: Bool = false
var openAIAPIKey: String = ""
var openAIModel: String = "gpt-4o-mini"
var openAIImageGenerationEnabled: Bool = false
var openAIImageModel: String = "gpt-image-1"
var openAIImageMonthlyLimitPerUser: Int = 10
var openAIImageMonthlyHardCap: Int = 200
var openAIImageUsageByUserMonth: [String: Int] = [:]   // "userId:YYYY-MM" -> count
*/

// MARK: - ClusterModels mesh-synced fields (Models/ClusterModels.swift)
/*
var preferredAIProvider: AIProviderPreference = .apple
var ollamaBaseURL: String = "http://localhost:11434"
var ollamaModel: String = ""
var ollamaEnabled: Bool = false
*/

// MARK: - /image slash command (AppModel+Commands.swift)
/*
// Required: settings.openAIEnabled, settings.openAIImageGenerationEnabled,
//           settings.openAIAPIKey, settings.openAIImageModel,
//           settings.openAIImageMonthlyLimitPerUser,
//           settings.openAIImageMonthlyHardCap,
//           settings.openAIImageUsageByUserMonth
//
// func handleImageCommand(prompt: String, userId: String, channelId: String) async {
//     guard settings.openAIImageGenerationEnabled else { return error("Image gen disabled") }
//     guard settings.openAIEnabled else { return error("OpenAI disabled") }
//     guard !settings.openAIAPIKey.isEmpty else { return error("No API key configured") }
//     // check usage caps via openAIImageUsageByUserMonth (keyed "userId:YYYY-MM")
//     let data = await aiService.generateOpenAIImage(
//         prompt: prompt,
//         apiKey: settings.openAIAPIKey,
//         model: settings.openAIImageModel
//     )
//     // upload data as Discord attachment, bump usage counter
// }
//
// Helpers: imageUsageKey(userId:date:), pruneOldImageUsageMonths(),
//          pushImageUsageToAllNodes() — all in AppModel+Commands.swift
*/

// MARK: - AIBotsView provider picker (UI)
/*
// Sections to restore:
// - Provider picker ("Primary AI Engine") — Picker bound to preferredAIProvider
// - Ollama toggle + Host field
// - OpenAI toggle + SecureField for API key
// - OpenAI Model TextField
// - OpenAI Image Model TextField
// - Image generation toggle
// - Monthly limit/cap Steppers
// - Status badges per provider
// All state vars: showAppleSettings, showOllamaSettings, showOpenAISettings
// Helpers: changeWatchersWithTracking(), normalizePreferredProviderIfNeeded(),
//          syncProviderSelectionFromPreference()
*/

// MARK: - currentAIStatus shape (DiscordAIService)
/*
func currentAIStatus(
    ollamaBaseURL: String,
    ollamaModelHint: String?,
    openAIAPIKey: String,
    skipOllama: Bool = false
) async -> (appleOnline: Bool, ollamaOnline: Bool, ollamaModel: String?, openAIOnline: Bool)
*/
