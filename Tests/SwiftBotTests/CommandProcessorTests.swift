import XCTest
@testable import SwiftBot

@MainActor
final class CommandProcessorTests: XCTestCase {
    func testPrefixHelpRendersEmbedOverview() async {
        let recorder = CommandRecorder()
        let processor = makeProcessor(recorder: recorder)

        let ok = await processor.executePrefixCommand(
            .init(
                commandText: "help",
                username: "Taylor",
                channelId: "channel-1",
                raw: [:],
                bypassSystemToggles: false
            )
        )

        XCTAssertTrue(ok)
        let count = await recorder.embedsCount
        let channelId = await recorder.firstEmbedChannelId
        let title = await recorder.firstEmbedTitle
        XCTAssertEqual(count, 1)
        XCTAssertEqual(channelId, "channel-1")
        XCTAssertEqual(title, "SwiftBot Commands")
    }

    func testSlashHelpDelegatesToPrefixHelpEvenWhenPrefixCommandsDisabled() async {
        let recorder = CommandRecorder()
        let processor = makeProcessor(
            recorder: recorder,
            configuration: .init(
                commandsEnabled: true,
                prefixCommandsEnabled: false,
                slashCommandsEnabled: true,
                wikiEnabled: true,
                prefix: "/",
                helpSettings: HelpSettings()
            )
        )

        let response = await processor.executeSlashCommand(
            command: "help",
            data: [:],
            context: .init(channelId: "channel-1", username: "Taylor", rawLikeMessage: [:])
        )

        XCTAssertEqual(response.embeds?.first?["title"] as? String, "Help")
        let count = await recorder.embedsCount
        let title = await recorder.firstEmbedTitle
        XCTAssertEqual(count, 1)
        XCTAssertEqual(title, "SwiftBot Commands")
    }

    func testDisabledPrefixCommandReturnsDisabledMessage() async {
        let recorder = CommandRecorder()
        let processor = makeProcessor(
            recorder: recorder,
            isCommandEnabled: { name, surface in
                !(name == "ping" && surface == "prefix")
            }
        )

        let ok = await processor.executePrefixCommand(
            .init(
                commandText: "ping",
                username: "Taylor",
                channelId: "channel-1",
                raw: [:],
                bypassSystemToggles: false
            )
        )

        XCTAssertTrue(ok)
        let messages = await recorder.sentMessages()
        XCTAssertEqual(messages.first?.content, "⛔ `/ping` is disabled in command settings.")
    }

    func testSlashWikiIsNotBuiltInLookupCommand() async {
        let recorder = CommandRecorder()
        let processor = makeProcessor(
            recorder: recorder,
            resolveWikiCommand: { _ in nil }
        )

        let response = await processor.executeSlashCommand(
            command: "wiki",
            data: [
                "options": .array([
                    .object([
                        "name": .string("query"),
                        "value": .string("AKM")
                    ])
                ])
            ],
            context: .init(channelId: "channel-1", username: "Taylor", rawLikeMessage: [:])
        )

        XCTAssertEqual(response.embeds?.first?["title"] as? String, "Slash Command")
        let lookups = await recorder.wikiLookups()
        XCTAssertEqual(lookups.count, 0)
    }

    func testDynamicWikiSlashCommandRoutesConfiguredCommand() async {
        let recorder = CommandRecorder()
        let processor = makeProcessor(
            recorder: recorder,
            resolveWikiCommand: { name in
                guard name == "thefinals" else { return nil }
                let command = WikiCommand(trigger: "/thefinals", description: "Search THE FINALS")
                let source = WikiSource(name: "THE FINALS Wiki", commands: [command])
                return (source: source, command: command)
            }
        )

        let response = await processor.executeSlashCommand(
            command: "thefinals",
            data: [
                "options": .array([
                    .object([
                        "name": .string("query"),
                        "value": .string("AKM")
                    ])
                ])
            ],
            context: .init(channelId: "channel-1", username: "Taylor", rawLikeMessage: [:])
        )

        XCTAssertEqual(response.embeds?.first?["title"] as? String, "Lookup")
        let lookups = await recorder.wikiLookups()
        XCTAssertEqual(lookups.count, 1)
        XCTAssertEqual(lookups.first?.command, "/thefinals")
        XCTAssertEqual(lookups.first?.source, "THE FINALS Wiki")
        XCTAssertEqual(lookups.first?.query, "AKM")
    }

    func testPrefixMusicRoutesQueryLookup() async {
        let recorder = CommandRecorder()
        let processor = makeProcessor(recorder: recorder)

        let ok = await processor.executePrefixCommand(
            .init(
                commandText: "music title:Strobe artist:deadmau5",
                username: "Taylor",
                channelId: "channel-1",
                raw: ["author": .object(["id": .string("user-9")])],
                bypassSystemToggles: false
            )
        )

        XCTAssertTrue(ok)
        let lookups = await recorder.musicLookups()
        XCTAssertEqual(lookups.count, 1)
        XCTAssertEqual(lookups.first?.title, "Strobe")
        XCTAssertEqual(lookups.first?.artist, "deadmau5")
        XCTAssertEqual(lookups.first?.userId, "user-9")
    }

    func testSlashMusicPickRoutesSelection() async {
        let recorder = CommandRecorder()
        let processor = makeProcessor(recorder: recorder)

        let response = await processor.executeSlashCommand(
            command: "music",
            data: [
                "options": .array([
                    .object([
                        "name": .string("pick"),
                        "value": .int(2)
                    ])
                ])
            ],
            context: .init(
                channelId: "channel-1",
                username: "Taylor",
                rawLikeMessage: ["author": .object(["id": .string("user-9")])]
            )
        )

        XCTAssertEqual(response.embeds?.first?["title"] as? String, "Music Lookup")
        let picks = await recorder.musicPicks()
        XCTAssertEqual(picks.count, 1)
        XCTAssertEqual(picks.first?.selection, 2)
        XCTAssertEqual(picks.first?.userId, "user-9")
    }

    func testSlashAnnounceJoinRoutesAnnouncerCommand() async {
        let recorder = CommandRecorder()
        let processor = makeProcessor(
            recorder: recorder,
            announceCommand: { _, raw in
                await recorder.recordAnnounce(raw: raw)
                return (true, "Joining configured announcer.")
            }
        )

        let response = await processor.executeSlashCommand(
            command: "announce",
            data: [
                "options": .array([
                    .object([
                        "name": .string("action"),
                        "value": .string("join")
                    ])
                ])
            ],
            context: .init(
                channelId: "channel-1",
                username: "Taylor",
                rawLikeMessage: ["author": .object(["id": .string("user-9")])]
            )
        )

        XCTAssertEqual(response.embeds?.first?["title"] as? String, "Announcer")
        XCTAssertEqual(response.embeds?.first?["description"] as? String, "Joining configured announcer.")
        let announces = await recorder.announces()
        XCTAssertEqual(announces.count, 1)
    }

    func testSlashAnnounceRejectsUnknownAction() async {
        let recorder = CommandRecorder()
        let processor = makeProcessor(
            recorder: recorder,
            announceCommand: { _, _ in
                XCTFail("Announce dependency should not be called for unsupported actions")
                return (true, "")
            }
        )

        let response = await processor.executeSlashCommand(
            command: "announce",
            data: [
                "options": .array([
                    .object([
                        "name": .string("action"),
                        "value": .string("leave")
                    ])
                ])
            ],
            context: .init(channelId: "channel-1", username: "Taylor", rawLikeMessage: [:])
        )

        XCTAssertEqual(response.embeds?.first?["title"] as? String, "Announcer")
        XCTAssertEqual(response.embeds?.first?["description"] as? String, "Usage: `/announce join` or `/announce rejoin`.")
    }

    func testPrefixRandomTeamsParsesTeamCountAndMaxSize() async {
        let recorder = CommandRecorder()
        let processor = makeProcessor(
            recorder: recorder,
            randomTeamsCommand: { teamCount, maxSize, raw in
                await recorder.recordRandomTeams(teamCount: teamCount, maxSize: maxSize, raw: raw)
                return (true, "Random teams result")
            }
        )

        let ok = await processor.executePrefixCommand(
            .init(
                commandText: "randomteams 2 max size 3",
                username: "Taylor",
                channelId: "channel-1",
                raw: ["author": .object(["id": .string("user-9")])],
                bypassSystemToggles: false
            )
        )

        XCTAssertTrue(ok)
        let calls = await recorder.randomTeams()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.teamCount, 2)
        XCTAssertEqual(calls.first?.maxSize, 3)
    }

    func testSlashRandomTeamsRoutesOptions() async {
        let recorder = CommandRecorder()
        let processor = makeProcessor(
            recorder: recorder,
            randomTeamsCommand: { teamCount, maxSize, raw in
                await recorder.recordRandomTeams(teamCount: teamCount, maxSize: maxSize, raw: raw)
                return (true, "Random teams result")
            }
        )

        let response = await processor.executeSlashCommand(
            command: "randomteams",
            data: [
                "options": .array([
                    .object([
                        "name": .string("teams"),
                        "value": .int(2)
                    ]),
                    .object([
                        "name": .string("max_size"),
                        "value": .int(3)
                    ])
                ])
            ],
            context: .init(
                channelId: "channel-1",
                username: "Taylor",
                rawLikeMessage: ["author": .object(["id": .string("user-9")])]
            )
        )

        XCTAssertEqual(response.embeds?.first?["title"] as? String, "Random Teams")
        XCTAssertEqual(response.embeds?.first?["description"] as? String, "Random teams result")
        let calls = await recorder.randomTeams()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.teamCount, 2)
        XCTAssertEqual(calls.first?.maxSize, 3)
    }

    func testSlashMinerPrioritiseRoutesGameToSwiftMiner() async {
        let recorder = CommandRecorder()
        let processor = makeProcessor(
            recorder: recorder,
            swiftMinerSlashCommand: { action, game, userId, _ in
                XCTAssertEqual(action, "prioritise")
                XCTAssertEqual(game, "Marvel Rivals")
                XCTAssertEqual(userId, "user-9")
                return (true, "Now prioritising Marvel Rivals.", [
                    "title": "Now prioritising Marvel Rivals",
                    "image": ["url": "https://example.com/marvel-rivals.jpg"]
                ])
            }
        )

        let response = await processor.executeSlashCommand(
            command: "miner",
            data: [
                "options": .array([
                    .object([
                        "name": .string("action"),
                        "value": .string("prioritise")
                    ]),
                    .object([
                        "name": .string("game"),
                        "value": .string("Marvel Rivals")
                    ])
                ])
            ],
            context: .init(
                channelId: "channel-1",
                username: "Taylor",
                rawLikeMessage: ["author": .object(["id": .string("user-9")])]
            )
        )

        XCTAssertEqual(response.embeds?.first?["title"] as? String, "Now prioritising Marvel Rivals")
        XCTAssertNotNil(response.embeds?.first?["image"])
    }

    func testAnnounceJoinRequiresConfiguredChannel() async {
        let app = AppModel()

        let result = await app.handleAnnounceJoinSlash(raw: announceRaw(userID: "user-9", guildID: "guild-1"))

        XCTAssertFalse(result.ok)
        XCTAssertEqual(
            result.message,
            "Announcer is not set up yet. Add an enabled voice channel configuration in SwiftBot first."
        )
    }

    func testAnnounceJoinRequiresUserInVoice() async {
        let app = AppModel()
        app.settings.voice.announcerConfigs = [
            AnnouncerVoiceChannelConfig(
                id: "config-1",
                name: "General",
                voiceChannelID: "voice-1",
                voiceChannelName: "General",
                textChannels: ["general"]
            )
        ]

        let result = await app.handleAnnounceJoinSlash(raw: announceRaw(userID: "user-9", guildID: "guild-1"))

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.message, "Join a configured voice channel first, then run `/announce join` again.")
    }

    func testRandomTeamsUsesCallersCurrentVoiceChannelAndMaxSize() async {
        let app = AppModel()
        await app.replaceVoicePresence([
            VoiceMemberPresence(id: "guild-1-user-1", userId: "user-1", username: "Alex", guildId: "guild-1", channelId: "voice-1", channelName: "General", joinedAt: Date()),
            VoiceMemberPresence(id: "guild-1-user-2", userId: "user-2", username: "Blair", guildId: "guild-1", channelId: "voice-1", channelName: "General", joinedAt: Date()),
            VoiceMemberPresence(id: "guild-1-user-3", userId: "user-3", username: "Casey", guildId: "guild-1", channelId: "voice-1", channelName: "General", joinedAt: Date()),
            VoiceMemberPresence(id: "guild-1-user-4", userId: "user-4", username: "Devon", guildId: "guild-1", channelId: "voice-1", channelName: "General", joinedAt: Date()),
            VoiceMemberPresence(id: "guild-1-user-5", userId: "user-5", username: "Elliot", guildId: "guild-1", channelId: "voice-2", channelName: "Other", joinedAt: Date())
        ])

        let result = await app.suggestRandomTeams(
            teamCount: 2,
            maxSize: 1,
            raw: announceRaw(userID: "user-1", guildID: "guild-1")
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.message, "General has 4 member(s), but 2 teams with max size 1 only fit 2.")
    }

    func testAnnouncerVoiceChannelConfigDecodesManualIntroDefault() throws {
        let json = """
        {
          "id": "config-1",
          "name": "General",
          "voiceChannelID": "voice-1",
          "voiceChannelName": "General",
          "autoJoin": true,
          "connectionMode": "fixed",
          "connectionMinutes": 20,
          "textChannels": ["general"],
          "enabled": true
        }
        """

        let config = try JSONDecoder().decode(AnnouncerVoiceChannelConfig.self, from: Data(json.utf8))

        XCTAssertFalse(config.introduceOnManualJoin)
        XCTAssertTrue(config.autoJoin)
    }

    func testAnnouncerVoiceChannelConfigDecodesManualIntroEnabled() throws {
        let json = """
        {
          "id": "config-1",
          "name": "General",
          "introduceOnManualJoin": true
        }
        """

        let config = try JSONDecoder().decode(AnnouncerVoiceChannelConfig.self, from: Data(json.utf8))

        XCTAssertTrue(config.introduceOnManualJoin)
    }

    func testFormattedWikiResponseIncludesDetectedFieldsWithoutSummary() {
        let app = AppModel()
        let source = WikiSource(
            name: "Call of Duty Wiki",
            baseURL: "https://callofduty.fandom.com",
            formatting: WikiFormatting(includeStatBlocks: true, useEmbeds: true, compactMode: false)
        )
        let result = FinalsWikiLookupResult(
            title: "MP5",
            extract: "",
            url: "https://callofduty.fandom.com/wiki/MP5",
            fields: [
                WikiResultField(name: "Weapon Class", value: "Submachine Gun"),
                WikiResultField(name: "Magazine Size", value: "30 rounds")
            ]
        )

        let response = app.formattedWikiResponse(source: source, result: result)

        XCTAssertTrue(response.contains("**Weapon Class:** Submachine Gun"))
        XCTAssertTrue(response.contains("**Magazine Size:** 30 rounds"))
        XCTAssertTrue(response.contains("https://callofduty.fandom.com/wiki/MP5"))
    }

    func testWikiEmbedHidesSourceConfiguredFields() {
        let app = AppModel()
        let source = WikiSource(
            name: "Call of Duty Wiki",
            baseURL: "https://callofduty.fandom.com",
            formatting: WikiFormatting(
                includeStatBlocks: true,
                useEmbeds: true,
                compactMode: false,
                hiddenEmbedFields: ["magazinesize"]
            )
        )
        let result = FinalsWikiLookupResult(
            title: "MP5",
            extract: "",
            url: "https://callofduty.fandom.com/wiki/MP5",
            fields: [
                WikiResultField(name: "Weapon Class", value: "Submachine Gun"),
                WikiResultField(name: "Magazine Size", value: "30 rounds")
            ]
        )

        let embed = app.wikiEmbed(source: source, result: result)
        let fields = embed["fields"] as? [[String: Any]]

        XCTAssertEqual(fields?.compactMap { $0["name"] as? String }, ["Weapon Class"])
    }

    private func makeProcessor(
        recorder: CommandRecorder,
        configuration: CommandProcessor.RuntimeConfiguration = .init(
            commandsEnabled: true,
            prefixCommandsEnabled: true,
            slashCommandsEnabled: true,
            wikiEnabled: true,
            prefix: "/",
            helpSettings: HelpSettings()
        ),
        isCommandEnabled: @escaping (String, String) -> Bool = { _, _ in true },
        resolveWikiCommand: @escaping (String) -> CommandProcessor.ResolvedWikiCommand? = { name in
            if name == "finals" {
                let command = WikiCommand(trigger: "/finals", description: "Lookup")
                let source = WikiSource(name: "THE FINALS Wiki", commands: [command])
                return (source: source, command: command)
            }
            return nil
        },
        defaultWikiCommand: @escaping () -> CommandProcessor.ResolvedWikiCommand? = { nil },
        announceCommand: @escaping (String, [String: DiscordJSON]) async -> (ok: Bool, message: String) = { _, _ in
            (ok: true, message: "Announcer result")
        },
        randomTeamsCommand: @escaping (Int, Int?, [String: DiscordJSON]) async -> (ok: Bool, message: String) = { _, _, _ in
            (ok: true, message: "Random teams result")
        },
        swiftMinerSlashCommand: @escaping (String, String?, String, String) async -> (ok: Bool, message: String, embed: [String: Any]?) = { _, _, _, _ in
            (true, "SwiftMiner result", nil)
        }
    ) -> CommandProcessor {
        let catalog = CommandCatalog(
            entries: [
                CommandEntry(
                    name: "help",
                    aliases: [],
                    usage: "/help",
                    description: "Show help",
                    examples: ["/help"],
                    category: .general,
                    isAdminOnly: false
                )
            ]
        )

        return CommandProcessor(
            dependencies: .init(
                configuration: { configuration },
                canonicalPrefixCommandName: { $0.lowercased() },
                isCommandEnabled: isCommandEnabled,
                buildHelpCatalog: { _ in catalog },
                send: { channelId, message in
                    await recorder.recordMessage(channelId: channelId, content: message)
                    return true
                },
                sendEmbed: { channelId, embed in
                    nonisolated(unsafe) let safeEmbed = embed
                    await recorder.recordEmbed(channelId: channelId, embed: safeEmbed)
                    return true
                },
                generateHelpReply: { _, _ in nil },
                rollDice: { notation in notation == "1d6" ? "rolled" : nil },
                authorId: { raw in
                    guard let author = raw["author"] else { return "user-1" }
                    if case let .object(map) = author,
                       let idVal = map["id"],
                       case let .string(id) = idVal {
                        return id
                    }
                    return "user-1"
                },
                clusterCommand: { _, _ in true },
                setNotificationChannel: { _, _ in true },
                updateIgnoredChannels: { _, _, _ in true },
                notifyStatus: { _, _ in true },
                canRunDebugCommand: { _ in true },
                refreshDebugSnapshot: {},
                debugSummaryEmbed: {
                    [
                        "title": "Debug",
                        "description": "Snapshot"
                    ]
                },
                weeklySummary: { "Weekly summary" },
                fetchFinalsMeta: { "Meta summary" },
                resolveWikiCommand: resolveWikiCommand,
                defaultWikiCommand: defaultWikiCommand,
                performWikiLookup: { command, source, query, channelId in
                    await recorder.recordWikiLookup(
                        command: command.trigger,
                        source: source.name,
                        query: query,
                        channelId: channelId
                    )
                    return true
                },
                lookupFinalsWiki: { _ in nil },
                runMusicLookup: { query, title, artist, userID, channelID in
                    await recorder.recordMusicLookup(
                        query: query,
                        title: title,
                        artist: artist,
                        userId: userID,
                        channelId: channelID
                    )
                    return (true, "Music lookup result")
                },
                pickMusicLookup: { selection, userID, channelID in
                    await recorder.recordMusicPick(selection: selection, userId: userID, channelId: channelID)
                    return (true, "Music selection result")
                },
                swiftMinerCommand: { _, _, _ in
                    (true, "SwiftMiner result")
                },
                swiftMinerSlashCommand: { action, game, userId, channelId in
                    await swiftMinerSlashCommand(action, game, userId, channelId)
                },
                fetchSteamAppInfo: { _ in
                    (ok: true, embed: ["title": "Steam Game"])
                },
                sweepCommand: { _ in
                    (ok: true, message: "Sweep result")
                },
                announceCommand: announceCommand,
                randomTeamsCommand: randomTeamsCommand,
                lookupUserTimeZone: { _ in nil }
            )
        )
    }

    private func announceRaw(userID: String, guildID: String) -> [String: DiscordJSON] {
        [
            "guild_id": .string(guildID),
            "author": .object(["id": .string(userID), "username": .string("Taylor")])
        ]
    }
}

private actor CommandRecorder {
    private var messages: [(channelId: String, content: String)] = []
    private var embeds: [(channelId: String, embed: [String: Any])] = []
    private var lookups: [(command: String, source: String, query: String, channelId: String)] = []
    private var musicLookupRecords: [(query: String?, title: String?, artist: String?, userId: String, channelId: String)] = []
    private var musicPickRecords: [(selection: Int, userId: String, channelId: String)] = []
    private var announceRecords: [[String: DiscordJSON]] = []
    private var randomTeamRecords: [(teamCount: Int, maxSize: Int?, raw: [String: DiscordJSON])] = []

    func recordMessage(channelId: String, content: String) {
        messages.append((channelId, content))
    }

    func recordEmbed(channelId: String, embed: [String: Any]) {
        embeds.append((channelId, embed))
    }

    func recordWikiLookup(command: String, source: String, query: String, channelId: String) {
        lookups.append((command, source, query, channelId))
    }

    func recordMusicLookup(query: String?, title: String?, artist: String?, userId: String, channelId: String) {
        musicLookupRecords.append((query, title, artist, userId, channelId))
    }

    func recordMusicPick(selection: Int, userId: String, channelId: String) {
        musicPickRecords.append((selection, userId, channelId))
    }

    func recordAnnounce(raw: [String: DiscordJSON]) {
        announceRecords.append(raw)
    }

    func recordRandomTeams(teamCount: Int, maxSize: Int?, raw: [String: DiscordJSON]) {
        randomTeamRecords.append((teamCount, maxSize, raw))
    }

    func sentMessages() -> [(channelId: String, content: String)] {
        messages
    }

    func sentEmbeds() -> [(channelId: String, embed: [String: Any])] {
        embeds
    }

    // Sendable-friendly accessors for tests under Swift 6 strict concurrency.
    var embedsCount: Int { embeds.count }
    var firstEmbedChannelId: String? { embeds.first?.channelId }
    var firstEmbedTitle: String? { embeds.first?.embed["title"] as? String }

    func wikiLookups() -> [(command: String, source: String, query: String, channelId: String)] {
        lookups
    }

    func musicLookups() -> [(query: String?, title: String?, artist: String?, userId: String, channelId: String)] {
        musicLookupRecords
    }

    func musicPicks() -> [(selection: Int, userId: String, channelId: String)] {
        musicPickRecords
    }

    func announces() -> [[String: DiscordJSON]] {
        announceRecords
    }

    func randomTeams() -> [(teamCount: Int, maxSize: Int?, raw: [String: DiscordJSON])] {
        randomTeamRecords
    }
}
