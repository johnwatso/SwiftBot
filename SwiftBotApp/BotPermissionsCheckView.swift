import SwiftUI
import Foundation
import AppKit

// MARK: - Permission model

/// A Discord permission bit Sweep / SwiftBot cares about, plus how essential
/// it is for the bot to function. The `bit` field is the index into the
/// permissions bitfield (i.e. 1 << bit).
struct DiscordPermissionFlag: Identifiable, Hashable {
    enum Severity { case essential, recommended, optional }

    let id: String
    let bit: UInt64
    let name: String
    let detail: String
    let severity: Severity

    var mask: UInt64 { 1 << bit }
}

enum DiscordPermissionCatalog {
    static let all: [DiscordPermissionFlag] = [
        .init(id: "view", bit: 10, name: "View Channels",
              detail: "See channel structure and read channel listings.",
              severity: .essential),
        .init(id: "history", bit: 16, name: "Read Message History",
              detail: "Required for Sweep to scan past messages and propose suggestions.",
              severity: .essential),
        .init(id: "send", bit: 11, name: "Send Messages",
              detail: "Post responses to commands and notifications.",
              severity: .essential),
        .init(id: "manageguild", bit: 5, name: "Manage Server",
              detail: "Read server invite use counts for Welcome Flow invite-specific rules.",
              severity: .recommended),
        .init(id: "manageroles", bit: 28, name: "Manage Roles",
              detail: "Grant or remove roles for Welcome Flow next steps and automation actions.",
              severity: .recommended),
        .init(id: "managechannels", bit: 4, name: "Manage Channels",
              detail: "Create channels from automation actions and manage channel-based workflows.",
              severity: .recommended),
        .init(id: "manage", bit: 13, name: "Manage Messages",
              detail: "Delete other users' messages and pin/unpin. Required for destructive Sweep actions.",
              severity: .recommended),
        .init(id: "embed", bit: 14, name: "Embed Links",
              detail: "Send rich embeds for Patchy notifications and command results.",
              severity: .recommended),
        .init(id: "reactions", bit: 6, name: "Add Reactions",
              detail: "React to messages — used by some commands.",
              severity: .recommended),
        .init(id: "attach", bit: 15, name: "Attach Files",
              detail: "Send file attachments alongside messages.",
              severity: .recommended),
        .init(id: "sendthreads", bit: 38, name: "Send Messages in Threads",
              detail: "Reply inside threads — without this, the bot can read threads but not respond.",
              severity: .recommended),
        .init(id: "threads", bit: 34, name: "Manage Threads",
              detail: "Required to archive stale support threads via Sweep.",
              severity: .optional),
        .init(id: "appcmds", bit: 31, name: "Use Application Commands",
              detail: "Lets the bot respond to slash commands.",
              severity: .recommended),
        .init(id: "moderate", bit: 40, name: "Moderate Members",
              detail: "Apply Discord timeouts. Used by Moderation actions short of kick/ban.",
              severity: .recommended),
        .init(id: "movemembers", bit: 24, name: "Move Members",
              detail: "Move members between voice channels from automation actions.",
              severity: .recommended),
        .init(id: "mutemembers", bit: 22, name: "Mute Members",
              detail: "Mute members in voice channels when moderation workflows need it.",
              severity: .optional),
        .init(id: "deafenmembers", bit: 23, name: "Deafen Members",
              detail: "Deafen members in voice channels when moderation workflows need it.",
              severity: .optional),
        .init(id: "managenicknames", bit: 27, name: "Manage Nicknames",
              detail: "Change other members' nicknames for moderation workflows.",
              severity: .optional),
        .init(id: "kick", bit: 1, name: "Kick Members",
              detail: "Remove members from the server. Used by Moderation kick actions.",
              severity: .optional),
        .init(id: "ban", bit: 2, name: "Ban Members",
              detail: "Ban members from the server. Used by Moderation ban actions.",
              severity: .optional),
        .init(id: "connect", bit: 20, name: "Connect (Voice)",
              detail: "Join voice channels — required for voice features.",
              severity: .optional),
        .init(id: "speak", bit: 21, name: "Speak (Voice)",
              detail: "Transmit audio in voice channels.",
              severity: .optional),
        .init(id: "voiceactivity", bit: 25, name: "Use Voice Activity",
              detail: "Transmit voice continuously without push-to-talk.",
              severity: .optional)
    ]

    static let administrator: UInt64 = 1 << 3

    /// Combined bitfield used for re-invite URLs. Includes every catalogued
    /// permission (essential, recommended, and optional) so a single Authorize
    /// click sets the bot up for every feature SwiftBot supports. The Bot
    /// Permissions sheet still classifies severities separately for the UI.
    static let desiredBitfield: UInt64 = {
        all.reduce(UInt64(0)) { $0 | $1.mask }
    }()
}

struct DiscordGuildPermissions: Identifiable, Hashable {
    let id: String
    let name: String
    let permissionsRaw: UInt64
    let isOwner: Bool

    var hasAdministrator: Bool { permissionsRaw & DiscordPermissionCatalog.administrator != 0 }

    func has(_ flag: DiscordPermissionFlag) -> Bool {
        if hasAdministrator || isOwner { return true }
        return permissionsRaw & flag.mask != 0
    }

    var missingEssential: [DiscordPermissionFlag] {
        DiscordPermissionCatalog.all.filter { $0.severity == .essential && !has($0) }
    }

    var missingRecommended: [DiscordPermissionFlag] {
        DiscordPermissionCatalog.all.filter { $0.severity == .recommended && !has($0) }
    }
}

// MARK: - View

struct BotPermissionsCheckView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AppModel
    let token: String

    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var botUsername: String?
    @State private var botID: String?
    @State private var guilds: [DiscordGuildPermissions] = []
    @State private var expandedGuildID: String?
    @State private var confirmingForceRejoin: DiscordGuildPermissions?
    @State private var isForceRejoining: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if isLoading {
                        loadingPanel
                    } else if let errorMessage {
                        errorPanel(message: errorMessage)
                    } else if guilds.isEmpty {
                        emptyPanel
                    } else {
                        summaryBanner
                        ForEach(guilds) { guild in
                            guildCard(guild)
                        }
                    }
                }
                .padding(20)
            }

            footer
        }
        .background(.regularMaterial)
        .frame(minWidth: 620, idealWidth: 720, minHeight: 520, idealHeight: 640)
        .task { await runCheck() }
        .confirmationDialog(
            "Force rejoin server?",
            isPresented: Binding(
                get: { confirmingForceRejoin != nil },
                set: { if !$0 { confirmingForceRejoin = nil } }
            ),
            presenting: confirmingForceRejoin
        ) { guild in
            Button("Kick & re-invite", role: .destructive) {
                Task { await performForceRejoin(for: guild) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { guild in
            Text("SwiftBot will leave \(guild.name), then Discord will open so you can re-authorise it with the correct permissions. The bot's existing role will be removed.")
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 26, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Bot Permissions")
                    .font(.title3.weight(.semibold))
                if let botUsername {
                    Text(botUsername + (botID.map { " · \($0)" } ?? ""))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Inspecting what the bot can do in each connected server.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.45)
            HStack {
                Button {
                    Task { await runCheck() }
                } label: {
                    Label("Re-check", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .disabled(isLoading)

                Spacer()

                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(.thinMaterial)
    }

    // MARK: Banners

    private var loadingPanel: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Checking permissions across connected servers…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.thinMaterial))
    }

    private func errorPanel(message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text("Check failed").font(.subheadline.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.thinMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.red.opacity(0.4), lineWidth: 1)
        )
    }

    private var emptyPanel: some View {
        Text("Bot isn't in any servers yet — invite it from the Discord settings tab to check per-server permissions.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.thinMaterial))
    }

    private var summaryBanner: some View {
        let totalEssentialIssues = guilds.flatMap(\.missingEssential).count
        let totalRecommendedIssues = guilds.flatMap(\.missingRecommended).count
        let tone: Color = totalEssentialIssues > 0 ? .red
            : totalRecommendedIssues > 0 ? .orange : .green
        let symbol: String = totalEssentialIssues > 0 ? "exclamationmark.triangle.fill"
            : totalRecommendedIssues > 0 ? "exclamationmark.circle.fill" : "checkmark.seal.fill"
        let message: String
        if totalEssentialIssues > 0 {
            message = "\(totalEssentialIssues) essential permission\(totalEssentialIssues == 1 ? "" : "s") missing across \(guilds.count) server\(guilds.count == 1 ? "" : "s"). Sweep and other features may fail."
        } else if totalRecommendedIssues > 0 {
            message = "All essentials look good. \(totalRecommendedIssues) recommended permission\(totalRecommendedIssues == 1 ? "" : "s") missing — some features may be limited."
        } else {
            message = "The bot has all essential and recommended permissions across \(guilds.count) server\(guilds.count == 1 ? "" : "s")."
        }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tone)
            Text(message)
                .font(.subheadline)
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.thinMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tone.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: Guild card

    @ViewBuilder
    private func guildCard(_ guild: DiscordGuildPermissions) -> some View {
        let essential = guild.missingEssential
        let recommended = guild.missingRecommended
        let tone: Color = !essential.isEmpty ? .red
            : !recommended.isEmpty ? .orange : .green

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: guild.hasAdministrator ? "crown.fill" : "server.rack")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(guild.name)
                    .font(.subheadline.weight(.semibold))
                if guild.hasAdministrator {
                    Text("ADMIN")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.purple.opacity(0.15)))
                }
                Spacer()
                statusChip(essential: essential.count, recommended: recommended.count, tone: tone)
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        expandedGuildID = expandedGuildID == guild.id ? nil : guild.id
                    }
                } label: {
                    Image(systemName: expandedGuildID == guild.id ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if !essential.isEmpty {
                permissionList(title: "Missing essentials", flags: essential, tone: .red)
            }
            if !recommended.isEmpty {
                permissionList(title: "Missing recommended", flags: recommended, tone: .orange)
            }

            if !essential.isEmpty || !recommended.isEmpty {
                HStack(spacing: 8) {
                    Spacer()
                    Button {
                        openReinviteURL(for: guild)
                    } label: {
                        Label("Re-invite", systemImage: "arrow.up.forward.square")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .buttonBorderShape(.capsule)
                    .help("Opens Discord to re-authorise SwiftBot in \(guild.name). Discord may keep the existing role permissions — use Force rejoin if so.")
                    .disabled(isForceRejoining)

                    Button {
                        confirmingForceRejoin = guild
                    } label: {
                        Label("Force rejoin", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .buttonBorderShape(.capsule)
                    .help("Kicks SwiftBot from \(guild.name), then opens Discord to re-add it with the correct permissions.")
                    .disabled(isForceRejoining)
                }
            }

            if expandedGuildID == guild.id {
                Divider().opacity(0.3)
                Text("All permissions")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(DiscordPermissionCatalog.all) { flag in
                        HStack(spacing: 8) {
                            Image(systemName: guild.has(flag) ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(guild.has(flag) ? .green : .secondary)
                            Text(flag.name).font(.caption)
                            Spacer()
                            Text(flag.severity == .essential ? "essential"
                                 : flag.severity == .recommended ? "recommended" : "optional")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.thinMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tone.opacity(0.25), lineWidth: 1)
        )
    }

    private func statusChip(essential: Int, recommended: Int, tone: Color) -> some View {
        let label: String = {
            if essential > 0 { return "\(essential) essential missing" }
            if recommended > 0 { return "\(recommended) recommended missing" }
            return "All good"
        }()
        return Text(label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(tone)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tone.opacity(0.14)))
    }

    @ViewBuilder
    private func permissionList(title: String, flags: [DiscordPermissionFlag], tone: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tone)
            ForEach(flags) { flag in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tone)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(flag.name).font(.caption.weight(.medium))
                        Text(flag.detail).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Re-invite

    @MainActor
    private func performForceRejoin(for guild: DiscordGuildPermissions) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "No bot token configured."
            return
        }
        isForceRejoining = true
        defer { isForceRejoining = false }

        do {
            try await leaveGuild(token: trimmed, guildID: guild.id)
            // Drop the guild from the local list so the UI reflects reality
            // while the user completes the OAuth flow in the browser.
            guilds.removeAll { $0.id == guild.id }
            if expandedGuildID == guild.id { expandedGuildID = nil }
            openReinviteURL(for: guild)
        } catch {
            errorMessage = "Couldn't remove SwiftBot from \(guild.name): \(error.localizedDescription)"
        }
    }

    private func leaveGuild(token: String, guildID: String) async throws {
        guard let url = URL(string: "https://discord.com/api/v10/users/@me/guilds/\(guildID)") else {
            throw NSError(domain: "BotPermissionsCheck", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid guild ID."
            ])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "BotPermissionsCheck", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "No response from Discord."
            ])
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "BotPermissionsCheck", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Discord returned \(http.statusCode) for leave-guild. \(body)"
            ])
        }
    }

    private func openReinviteURL(for guild: DiscordGuildPermissions) {
        guard let botID, !botID.isEmpty else { return }
        var components = URLComponents(string: "https://discord.com/oauth2/authorize")

        // Plain bot-install URL — single screen, user closes the tab when done.
        // We deliberately skip response_type=code / redirect_uri: mixing them
        // with the bot-install flow makes Discord show a second "Add a bot to
        // a server" picker (sometimes losing the guild_id pre-selection), and
        // the redirect ties the install to a working WebUI which isn't always
        // configured. The install itself doesn't need a callback — feedback
        // comes from the Re-check button in this dialog.
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: botID),
            URLQueryItem(name: "scope", value: "bot applications.commands"),
            URLQueryItem(name: "permissions", value: String(DiscordPermissionCatalog.desiredBitfield)),
            URLQueryItem(name: "guild_id", value: guild.id),
            URLQueryItem(name: "disable_guild_select", value: "true")
        ]
        guard let url = components?.url else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Network

    @MainActor
    private func runCheck() async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "No bot token configured."
            return
        }

        isLoading = true
        errorMessage = nil
        botUsername = nil
        botID = nil
        guilds = []

        do {
            // Identity
            if let (id, username) = try await fetchIdentity(token: trimmed) {
                botID = id
                botUsername = username
            }
            // Guilds
            let fetched = try await fetchGuilds(token: trimmed)
            self.guilds = fetched.sorted { lhs, rhs in
                let lhsScore = lhs.missingEssential.count * 100 + lhs.missingRecommended.count
                let rhsScore = rhs.missingEssential.count * 100 + rhs.missingRecommended.count
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        } catch let nsError as NSError {
            switch nsError.code {
            case 401: errorMessage = "Token rejected by Discord (401). Re-check the bot token."
            case 429: errorMessage = "Rate-limited by Discord (429). Try again in a few seconds."
            default: errorMessage = nsError.localizedDescription
            }
        }
        isLoading = false
    }

    private func fetchIdentity(token: String) async throws -> (id: String, username: String)? {
        var req = URLRequest(url: URL(string: "https://discord.com/api/v10/users/@me")!)
        req.httpMethod = "GET"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "BotPermissionsCheck", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Discord returned \(http.statusCode) for /users/@me."
            ])
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let username = json["username"] as? String ?? "Unknown"
        let id = json["id"] as? String ?? ""
        return (id, username)
    }

    private func fetchGuilds(token: String) async throws -> [DiscordGuildPermissions] {
        var req = URLRequest(url: URL(string: "https://discord.com/api/v10/users/@me/guilds")!)
        req.httpMethod = "GET"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { return [] }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "BotPermissionsCheck", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Discord returned \(http.statusCode) for /users/@me/guilds."
            ])
        }
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { dict -> DiscordGuildPermissions? in
            guard let id = dict["id"] as? String,
                  let name = dict["name"] as? String else { return nil }
            let permString = dict["permissions"] as? String ?? "0"
            let perms = UInt64(permString) ?? 0
            let isOwner = dict["owner"] as? Bool ?? false
            return DiscordGuildPermissions(id: id, name: name, permissionsRaw: perms, isOwner: isOwner)
        }
    }
}
