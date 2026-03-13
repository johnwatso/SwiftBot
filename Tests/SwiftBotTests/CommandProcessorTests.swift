import XCTest
@testable import SwiftBot

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
        let embeds = await recorder.sentEmbeds()
        XCTAssertEqual(embeds.count, 1)
        XCTAssertEqual(embeds.first?.channelId, "channel-1")
        XCTAssertEqual(embeds.first?.embed["title"] as? String, "SwiftBot Commands")
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
        let embeds = await recorder.sentEmbeds()
        XCTAssertEqual(embeds.count, 1)
        XCTAssertEqual(embeds.first?.embed["title"] as? String, "SwiftBot Commands")
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

    func testSlashWikiFallsBackToDefaultEnabledCommand() async {
        let recorder = CommandRecorder()
        let processor = makeProcessor(
            recorder: recorder,
            resolveWikiCommand: { _ in nil },
            defaultWikiCommand: {
                (
                    source: WikiSource(
                        name: "THE FINALS",
                        commands: [WikiCommand(trigger: "/wiki", description: "Lookup")]
                    ),
                    command: WikiCommand(trigger: "/wiki", description: "Lookup")
                )
            }
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

        XCTAssertEqual(response.embeds?.first?["title"] as? String, "WikiBridge Lookup")
        let lookups = await recorder.wikiLookups()
        XCTAssertEqual(lookups.count, 1)
        XCTAssertEqual(lookups.first?.query, "AKM")
        XCTAssertEqual(lookups.first?.channelId, "channel-1")
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
            if name == "wiki" {
                let command = WikiCommand(trigger: "/wiki", description: "Lookup")
                let source = WikiSource(name: "Primary Wiki", commands: [command])
                return (source: source, command: command)
            }
            return nil
        },
        defaultWikiCommand: @escaping () -> CommandProcessor.ResolvedWikiCommand? = { nil }
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
                    await recorder.recordEmbed(channelId: channelId, embed: embed)
                    return true
                },
                generateHelpReply: { _, _ in nil },
                rollDice: { notation in notation == "1d6" ? "rolled" : nil },
                generateImageCommand: { _, _, _, _ in true },
                authorId: { _ in "user-1" },
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
                bugReportText: { _ in "Bug summary" },
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
                handleLogABugSlash: { _, _, _, _ in (true, "Logged") },
                handleFeatureRequestSlash: { _, _, _, _, _ in (true, "Requested") },
                lookupFinalsWiki: { _ in nil }
            )
        )
    }
}

private actor CommandRecorder {
    private var messages: [(channelId: String, content: String)] = []
    private var embeds: [(channelId: String, embed: [String: Any])] = []
    private var lookups: [(command: String, source: String, query: String, channelId: String)] = []

    func recordMessage(channelId: String, content: String) {
        messages.append((channelId, content))
    }

    func recordEmbed(channelId: String, embed: [String: Any]) {
        embeds.append((channelId, embed))
    }

    func recordWikiLookup(command: String, source: String, query: String, channelId: String) {
        lookups.append((command, source, query, channelId))
    }

    func sentMessages() -> [(channelId: String, content: String)] {
        messages
    }

    func sentEmbeds() -> [(channelId: String, embed: [String: Any])] {
        embeds
    }

    func wikiLookups() -> [(command: String, source: String, query: String, channelId: String)] {
        lookups
    }
}
