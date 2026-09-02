import XCTest
@testable import SwiftBot

final class AdminWebCopyTests: XCTestCase {
    func testSweepWebCreationAndEditingAreAvailable() throws {
        let adminHTML = try XCTUnwrap(
            Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "admin")
        )
        let html = try String(contentsOf: adminHTML, encoding: .utf8)

        XCTAssertTrue(html.contains("showModal('New Sweep Rule'"))
        XCTAssertTrue(html.contains("showModal('Edit Sweep Rule'"))
        XCTAssertFalse(html.contains("Web parity will follow"))
    }

    func testNativeSidebarViewsAreWiredIntoAdminWebUI() throws {
        let adminHTML = try XCTUnwrap(
            Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "admin")
        )
        let html = try String(contentsOf: adminHTML, encoding: .utf8)
        let webViewsBySidebarItem: [SidebarItem: String] = [
            .overview: "overview",
            .patchy: "patchy",
            .welcomeFlow: "welcome",
            .automations: "automations",
            .moderation: "moderation",
            .commands: "commands",
            .activity: "activity",
            .wikiBridge: "wikibridge",
            .appleIntelligence: "aibots",
            .voice: "announcer",
            .recordings: "recordings",
            .analytics: "analytics",
            .rewind: "rewind",
            .swiftMesh: "swiftmesh",
            .sweep: "sweep",
            .gameTracker: "gametracker"
        ]

        for item in SidebarItem.allCases {
            let webView = try XCTUnwrap(webViewsBySidebarItem[item], "Missing WebUI mapping for \(item.rawValue)")
            XCTAssertTrue(html.contains(#"data-view="\#(webView)""#), "\(item.rawValue) is missing from WebUI navigation")
            XCTAssertTrue(html.contains(#"id="\#(webView)View""#), "\(item.rawValue) is missing a WebUI view section")
            XCTAssertTrue(html.contains(#"view === '\#(webView)'"#), "\(item.rawValue) is missing a WebUI selection branch")
        }
    }

    func testAIBotsWebViewMirrorsNativeAppleIntelligenceSurface() throws {
        let adminHTML = try XCTUnwrap(
            Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "admin")
        )
        let html = try String(contentsOf: adminHTML, encoding: .utf8)

        XCTAssertTrue(html.contains("/api/aibots"), "AI Bots view must read the dedicated snapshot endpoint")
        XCTAssertTrue(html.contains("/api/aibots/memory/clear"), "Conversation memory must be clearable from the web")

        // Section parity with AppleIntelligenceView.
        for panel in ["Personality", "Reply Rules", "Conversation Memory", "Capabilities"] {
            XCTAssertTrue(html.contains("</i> \(panel)</div>"), "AI Bots view is missing the \(panel) panel")
        }

        // Reply rule copy is authored natively and must not drift on the web.
        for rule in ["Reply when mentioned", "Reply to DMs", "Allow DMs from anyone", "Ignore bot accounts"] {
            XCTAssertTrue(html.contains(rule), "AI Bots view is missing the '\(rule)' reply rule")
        }
        XCTAssertFalse(
            html.contains("Guild Mention Replies"),
            "Stale WebUI-only reply rule copy should match the native Reply Rules section"
        )
    }

    func testAnnouncerWebEditorMirrorsNativeAnnouncerSheet() throws {
        let adminHTML = try XCTUnwrap(
            Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "admin")
        )
        let html = try String(contentsOf: adminHTML, encoding: .utf8)

        // Section parity with AnnouncerConfigSheet.
        for section in ["Voice Channel", "Connection", "Reads From", "Behaviour"] {
            XCTAssertTrue(html.contains("', '\(section)'"),
                          "Announcer editor is missing the \(section) section")
        }

        // Toggle copy is authored natively and must not drift on the web.
        for label in [
            "Auto-join when someone enters",
            "Introduce on /announce join",
            "Auto-join when someone goes live",
            "Announce on stream join",
            "Read voice channel chat",
            "Only read server members",
            "Shorten long messages",
            "Ignore links",
            "Skip bot messages",
            "Ignore emoji spam",
            "Keep announcements short",
            "Skip repeated speaker names"
        ] {
            XCTAssertTrue(html.contains(label), "Announcer editor is missing the '\(label)' control")
        }

        // Every persisted field on AnnouncerVoiceChannelConfig must be reachable.
        for field in [
            "acEnabled", "acName", "acVoiceChannel", "acSymbol", "acTint", "acPreferredVoice",
            "acAutoJoin", "acIntroduceOnManualJoin", "acAutoJoinOnStream", "acIntroduceOnStreamJoin",
            "acReadVoiceChat", "acIgnoreWebhooks", "acSkipBots", "acIgnoreLinks",
            "acSummariseLong", "acKeepShort", "acSmartShorten", "acIgnoreEmojiSpam",
            "acSuppressRepeatedNames", "acConnectionMode", "acConnectionMinutes", "acEmptyGrace",
            "acChannelPicker"
        ] {
            XCTAssertTrue(html.contains(field), "Announcer editor cannot edit \(field)")
        }

        // A guild can have hundreds of text channels, so the picker filters as
        // you type instead of rendering every channel as a checkbox.
        XCTAssertTrue(html.contains("AC_CHANNEL_RESULT_LIMIT"), "Text-channel results must be capped")
        XCTAssertTrue(html.contains(#"id="acChannelSearch""#), "Text channels must be searchable")
        XCTAssertFalse(html.contains("ac-text-channel-cb"), "The unbounded text-channel checkbox list was replaced")

        // `symbol` is rendered natively with Image(systemName:), so the stored
        // value has to stay an SF Symbol name rather than a Lucide icon name.
        XCTAssertTrue(
            html.contains("speaker.wave.2.bubble.fill"),
            "Announcer icon options must store SF Symbol names shared with the native sheet"
        )
        XCTAssertTrue(
            html.contains("announcerSymbolLucide(config.symbol)"),
            "Announcer cards must map the stored SF Symbol to a Lucide icon for display"
        )
    }

    func testAnnouncerWebShowsLiveStateInsteadOfEditableSessionFields() throws {
        let adminHTML = try XCTUnwrap(
            Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "admin")
        )
        let html = try String(contentsOf: adminHTML, encoding: .utf8)

        // Row parity with the native "Current State" panel.
        for label in ["Listening", "Monitored feeds", "Next announcement", "Manual hold", "Recovery"] {
            XCTAssertTrue(html.contains("'\(label)'"), "Announcer live state is missing the \(label) row")
        }
        XCTAssertTrue(html.contains("announcerData.liveState"), "Announcer view must read the live state payload")
        XCTAssertTrue(html.contains(#"id="announcerLiveState""#), "Announcer view is missing the live state panel")

        // guildID / voiceChannelID / watchedTextChannelID / textChannelSourceEnabled are
        // rewritten by activateAnnouncerConfig on every connect, so the web must not
        // offer them as editable settings again.
        XCTAssertFalse(html.contains("openAnnouncerGlobalSettings"), "The Default Announcer editor edited session state and was removed")
        for staleField in [#"id="agGuild""#, #"id="agVoice""#, #"id="agText""#, #"id="agTextEnabled""#] {
            XCTAssertFalse(html.contains(staleField), "Announcer view must not edit live session state (\(staleField))")
        }

        XCTAssertFalse(
            html.contains(#"id="announcerAutoConnect""#),
            "The auto-connect card was removed from the Announcer view"
        )

        // Disconnecting must go through the endpoint that also arms the manual
        // hold, otherwise auto-join or recovery pulls the bot straight back in.
        XCTAssertTrue(html.contains("/api/announcer/disconnect"), "Announcer view must offer a disconnect action")
        XCTAssertTrue(html.contains(#"id="announcerDisconnect""#), "Announcer live state is missing the disconnect button")
        XCTAssertTrue(
            html.contains("state.isConnected ? '<button id=\"announcerDisconnect\""),
            "Disconnect must only be offered while the announcer is connected"
        )
    }

    func testAdminWebUIHasNoStaleLegacyViewReferences() throws {
        let adminHTML = try XCTUnwrap(
            Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "admin")
        )
        let html = try String(contentsOf: adminHTML, encoding: .utf8)

        XCTAssertFalse(html.contains("logs.classList"), "Use activityView/logsPanels instead of the removed logs view variable")
        XCTAssertFalse(html.contains("actions.classList"), "Use automationsView instead of the removed actions view variable")
    }

    func testAuthScreenExplainsMissingDiscordOAuthButton() throws {
        let adminHTML = try XCTUnwrap(
            Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "admin")
        )
        let html = try String(contentsOf: adminHTML, encoding: .utf8)

        XCTAssertTrue(html.contains(#"id="discordAuthButton""#))
        XCTAssertTrue(html.contains(#"id="authSetupHint""#))
        XCTAssertTrue(html.contains("Discord sign-in is not configured yet."))
        XCTAssertTrue(html.contains("setupHint.style.display = authOptions.discordEnabled ? 'none' : '';"))
    }
}
