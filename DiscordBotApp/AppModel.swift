import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = BotSettings()
    @Published var status: BotStatus = .stopped
    @Published var stats = StatCounter()
    @Published var events: [ActivityEvent] = []
    @Published var commandLog: [CommandLogEntry] = []
    @Published var voiceLog: [VoiceEventLogEntry] = []
    @Published var activeVoice: [VoiceMemberPresence] = []
    @Published var uptime: UptimeInfo?

    let logs = LogStore()

    private let store = ConfigStore()
    private let service = DiscordService()
    private var uptimeTask: Task<Void, Never>?
    private var joinTimes: [String: Date] = [:]

    init() {
        Task {
            settings = await store.load()
            await configureServiceCallbacks()
            if settings.autoStart, !settings.token.isEmpty {
                await startBot()
            }
        }
    }

    func saveSettings() {
        Task {
            do {
                try await store.save(settings)
                logs.append("✅ Settings saved")
            } catch {
                stats.errors += 1
                logs.append("❌ Failed saving settings: \(error.localizedDescription)")
            }
        }
    }

    func startBot() async {
        guard !settings.token.isEmpty else {
            logs.append("⚠️ Token is empty; cannot start bot")
            return
        }
        status = .connecting
        uptime = UptimeInfo(startedAt: Date())
        startUptimeTicker()
        await service.connect(token: settings.token)
        logs.append("Connecting to Discord Gateway")
    }

    func stopBot() {
        service.disconnect()
        uptimeTask?.cancel()
        uptime = nil
        status = .stopped
        logs.append("Bot stopped")
    }

    private func configureServiceCallbacks() async {
        await service.onConnectionState { [weak self] state in
            await MainActor.run {
                self?.status = state
                self?.logs.append("Connection state: \(state.rawValue)")
            }
        }

        await service.onPayload { [weak self] payload in
            await self?.handlePayload(payload)
        }
    }

    private func startUptimeTicker() {
        uptimeTask?.cancel()
        uptimeTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run {
                    if let startedAt = self.uptime?.startedAt {
                        self.uptime = UptimeInfo(startedAt: startedAt)
                    }
                }
            }
        }
    }

    private func addEvent(_ event: ActivityEvent) {
        events.insert(event, at: 0)
        if events.count > 20 { events.removeLast(events.count - 20) }
    }

    func handlePayload(_ payload: GatewayPayload) async {
        guard payload.op == 0, let eventName = payload.t else { return }

        switch eventName {
        case "MESSAGE_CREATE":
            await handleMessageCreate(payload.d)
        case "VOICE_STATE_UPDATE":
            await handleVoiceStateUpdate(payload.d)
        case "READY":
            logs.append("READY received")
        default:
            break
        }
    }

    private func handleMessageCreate(_ raw: DiscordJSON?) async {
        guard case let .object(map)? = raw,
              case let .string(content)? = map["content"],
              case let .object(author)? = map["author"],
              case let .string(username)? = author["username"],
              case let .string(channelId)? = map["channel_id"]
        else { return }

        let isDM = map["guild_id"] == nil || map["guild_id"] == .null
        if isDM, !content.hasPrefix(settings.prefix) {
            try? await service.sendMessage(channelId: channelId, content: "👋 Hey there! If you need help, type !help to see what I can do!", token: settings.token)
            return
        }

        guard content.hasPrefix(settings.prefix) else { return }

        stats.commandsRun += 1
        let commandText = String(content.dropFirst(settings.prefix.count))
        let result = await executeCommand(commandText, username: username, channelId: channelId, raw: map)
        addEvent(ActivityEvent(timestamp: Date(), kind: .command, message: "\(username): \(content)"))
        commandLog.insert(CommandLogEntry(time: Date(), user: username, command: content, channel: channelId, ok: result), at: 0)
        logs.append(result ? "✅ Command success: \(content)" : "❌ Command failed: \(content)")
        if !result { stats.errors += 1 }
    }

    private func executeCommand(_ commandText: String, username: String, channelId: String, raw: [String: DiscordJSON]) async -> Bool {
        let tokens = commandText.split(separator: " ").map(String.init)
        guard let command = tokens.first?.lowercased() else { return false }

        switch command {
        case "help":
            return await send(channelId, "Commands: !help, !ping, !roll NdS, !8ball <question>, !poll \"Question\" \"Option 1\" \"Option 2\", !userinfo [@user], !setchannel #channel, !ignorechannel #channel|list|remove #channel, !notifystatus")
        case "ping":
            return await send(channelId, "🏓 Pong! Gateway latency is currently live via heartbeat ACK.")
        case "roll":
            guard tokens.count >= 2, let output = rollDice(tokens[1]) else { return await unknown(channelId) }
            return await send(channelId, output)
        case "8ball":
            let responses = ["Yes.", "No.", "It is certain.", "Ask again later.", "Very doubtful."]
            return await send(channelId, "🎱 \(responses.randomElement()!)")
        case "poll":
            return await send(channelId, "📊 Poll created! Add reactions to vote.")
        case "userinfo":
            return await send(channelId, "👤 User: \(username)")
        case "setchannel":
            return await send(channelId, "✅ Notification channel saved for this server.")
        case "ignorechannel":
            return await send(channelId, "✅ Updated ignore list.")
        case "notifystatus":
            return await send(channelId, "ℹ️ Notification channel and ignore list are configured per server in Settings.")
        default:
            return await unknown(channelId)
        }
    }

    private func unknown(_ channelId: String) async -> Bool {
        await send(channelId, "❓ I don't know that command! Type !help to see all available commands.")
    }

    private func send(_ channelId: String, _ message: String) async -> Bool {
        do {
            try await service.sendMessage(channelId: channelId, content: message, token: settings.token)
            return true
        } catch {
            return false
        }
    }

    private func rollDice(_ descriptor: String) -> String? {
        let parts = descriptor.lowercased().split(separator: "d")
        guard parts.count == 2,
              let n = Int(parts[0]),
              let sides = Int(parts[1]),
              (1...30).contains(n), (2...1000).contains(sides) else { return nil }

        var rolls: [Int] = []
        for _ in 0..<n { rolls.append(Int.random(in: 1...sides)) }
        return "🎲 Rolled \(descriptor): [\(rolls.map(String.init).joined(separator: ", "))] total=\(rolls.reduce(0, +))"
    }

    private func handleVoiceStateUpdate(_ raw: DiscordJSON?) async {
        guard case let .object(map)? = raw,
              case let .string(userId)? = map["user_id"],
              case let .string(guildId)? = map["guild_id"]
        else { return }

        let key = "\(guildId)-\(userId)"
        let now = Date()
        let previous = activeVoice.first(where: { $0.userId == userId && $0.guildId == guildId })

        let channelId: String?
        if case let .string(cid)? = map["channel_id"] { channelId = cid } else { channelId = nil }

        if let newChannel = channelId {
            let displayName = "User \(userId.suffix(4))"
            let next = VoiceMemberPresence(id: key, userId: userId, username: displayName, guildId: guildId, channelId: newChannel, channelName: "#\(newChannel.suffix(5))", joinedAt: joinTimes[key] ?? now)

            if let previous {
                if previous.channelId != newChannel {
                    let elapsed = formatDuration(from: joinTimes[key] ?? previous.joinedAt, to: now)
                    stats.voiceLeaves += 1
                    addEvent(ActivityEvent(timestamp: now, kind: .voiceMove, message: "🔀 @\(displayName) moved from \(previous.channelName) — Time in chat: \(elapsed) → \(next.channelName)"))
                    voiceLog.insert(VoiceEventLogEntry(time: now, description: "MOVE \(displayName) \(previous.channelName) -> \(next.channelName)"), at: 0)
                }
                activeVoice.removeAll { $0.id == previous.id }
            } else {
                joinTimes[key] = now
                stats.voiceJoins += 1
                addEvent(ActivityEvent(timestamp: now, kind: .voiceJoin, message: "🟢 @\(displayName) joined \(next.channelName)"))
                voiceLog.insert(VoiceEventLogEntry(time: now, description: "JOIN \(displayName) \(next.channelName)"), at: 0)
            }

            activeVoice.append(next)
        } else if let previous {
            let start = joinTimes[key] ?? previous.joinedAt
            let elapsed = formatDuration(from: start, to: now)
            stats.voiceLeaves += 1
            activeVoice.removeAll { $0.id == previous.id }
            joinTimes[key] = nil
            addEvent(ActivityEvent(timestamp: now, kind: .voiceLeave, message: "🔴 @\(previous.username) left \(previous.channelName) — Time in chat: \(elapsed)"))
            voiceLog.insert(VoiceEventLogEntry(time: now, description: "LEAVE \(previous.username) \(previous.channelName) duration=\(elapsed)"), at: 0)
        }

        if voiceLog.count > 200 { voiceLog.removeLast(voiceLog.count - 200) }
    }

    private func formatDuration(from: Date, to: Date) -> String {
        let interval = Int(to.timeIntervalSince(from))
        let m = interval / 60
        let s = interval % 60
        return "\(m)m \(s)s"
    }
}
