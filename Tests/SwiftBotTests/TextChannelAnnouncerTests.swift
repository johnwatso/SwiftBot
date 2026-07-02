import AVFoundation
import XCTest
@testable import SwiftBot

final class TextChannelAnnouncerTests: XCTestCase {
    func testSpeechSanitizerCleansDiscordNoise() {
        let sanitized = AnnouncerSpeechSanitizer.sanitized(
            "**Look** at <@123> in <#456> <:party_parrot:789> https://example.com/a/b"
        )

        XCTAssertEqual(sanitized, "Look at user in channel party parrot link")
    }

    func testSpeechSanitizerReplacesCodeBlocksAndMarkdownLinks() {
        let sanitized = AnnouncerSpeechSanitizer.sanitized(
            "```swift\nprint(\"secret\")\n``` Read [the notes](https://example.com)."
        )

        XCTAssertEqual(sanitized, "code block Read the notes.")
    }

    func testAnnouncementQueueKeepsLatestMessagesWhilePaused() async throws {
        let playback = VoicePlaybackService()
        let announcer = try VoiceAnnouncementService(playback: playback)

        await announcer.setPaused(true)
        for index in 1...25 {
            await announcer.enqueue("Message \(index)")
        }

        let pending = await announcer.pending
        XCTAssertEqual(pending.count, 20)
        XCTAssertEqual(pending.first?.text, "Message 6")
        XCTAssertEqual(pending.last?.text, "Message 25")

        let health = await announcer.healthSnapshot
        XCTAssertEqual(health.phase, .paused)
        XCTAssertEqual(health.queueDepth, 20)
        XCTAssertTrue(health.isPaused)
    }

    func testAnnouncementQueueStoresSanitizedSpeech() async throws {
        let playback = VoicePlaybackService()
        let announcer = try VoiceAnnouncementService(playback: playback)

        await announcer.setPaused(true)
        await announcer.enqueue("**Launch** `status` https://example.com <@123>")

        let pending = await announcer.pending
        XCTAssertEqual(pending.map(\.text), ["Launch status link user"])
    }

    func testAudioGuardrailsRejectEmptyRenderedAudio() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: OpusFrameEncoder.sampleRate,
            channels: OpusFrameEncoder.channelCount,
            interleaved: true
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        buffer.frameLength = 0

        XCTAssertThrowsError(try AnnouncerAudioGuardrails.validateAndRepair(buffer))
    }

    func testAudioGuardrailsNormaliseClipping() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: OpusFrameEncoder.sampleRate,
            channels: OpusFrameEncoder.channelCount,
            interleaved: true
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        buffer.frameLength = 2
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        samples[0] = 2.0
        samples[1] = -2.0
        samples[2] = 1.5
        samples[3] = -1.5

        _ = try AnnouncerAudioGuardrails.validateAndRepair(buffer)

        let peak = max(abs(samples[0]), abs(samples[1]), abs(samples[2]), abs(samples[3]))
        XCTAssertLessThanOrEqual(peak, 0.921)
    }

    func testTextChannelAnnouncerHandlesMultipleChannels() async throws {
        let playback = VoicePlaybackService()
        let announcer = try VoiceAnnouncementService(playback: playback)
        
        let expectation = XCTestExpectation(description: "Announcement enqueued")
        expectation.expectedFulfillmentCount = 2
        
        let capture = TestCapture()
        
        await announcer.setOnQueueChange { queue in
            if let last = queue.last {
                let appended = await capture.appendIfNew(last.text)
                if appended {
                    expectation.fulfill()
                }
            }
        }
        
        let watcher = TextChannelAnnouncer(announcer: announcer)
        
        // Configure to watch channels "channel-1" and "channel-2"
        await watcher.setWatchedChannels(["channel-1", "channel-2"])
        
        // Event from channel-1
        let event1 = GatewayMessageCreateEvent(
            rawMap: [:],
            content: "Hello from channel 1",
            author: [:],
            username: "Alice",
            displayName: "Alice",
            channelID: "channel-1",
            userID: "user-1",
            memberRoleIDs: nil,
            guildID: "guild-1",
            messageID: "msg-1",
            isBot: false,
            avatarHash: nil
        )
        
        // Event from channel-2
        let event2 = GatewayMessageCreateEvent(
            rawMap: [:],
            content: "Hello from channel 2",
            author: [:],
            username: "Bob",
            displayName: "Bob",
            channelID: "channel-2",
            userID: "user-2",
            memberRoleIDs: nil,
            guildID: "guild-1",
            messageID: "msg-2",
            isBot: false,
            avatarHash: nil
        )
        
        // Event from an unwatched channel
        let event3 = GatewayMessageCreateEvent(
            rawMap: [:],
            content: "Hello from channel 3",
            author: [:],
            username: "Charlie",
            displayName: "Charlie",
            channelID: "channel-3",
            userID: "user-3",
            memberRoleIDs: nil,
            guildID: "guild-1",
            messageID: "msg-3",
            isBot: false,
            avatarHash: nil
        )
        
        await watcher.handle(event1)
        await watcher.handle(event2)
        await watcher.handle(event3)
        
        // Wait for expectations
        await fulfillment(of: [expectation], timeout: 2.0)
        
        let texts = await capture.receivedTexts
        XCTAssertEqual(texts.count, 2)
        XCTAssertTrue(texts.contains("Alice: Hello from channel 1"))
        XCTAssertTrue(texts.contains("Bob: Hello from channel 2"))
    }

    func testTextChannelAnnouncerUsesSmartShortenerWhenAvailable() async throws {
        let playback = VoicePlaybackService()
        let announcer = try VoiceAnnouncementService(playback: playback)
        await announcer.setPaused(true)

        let watcher = TextChannelAnnouncer(announcer: announcer)
        await watcher.setWatchedChannel("channel-1")

        let longMessage = Array(repeating: "the build passed after removing the old DAVE retry timer", count: 5)
            .joined(separator: " and ")
        let event = GatewayMessageCreateEvent(
            rawMap: [:],
            content: longMessage,
            author: [:],
            username: "Alice",
            displayName: "Alice",
            channelID: "channel-1",
            userID: "user-1",
            guildID: "guild-1",
            messageID: "msg-1",
            isBot: false,
            avatarHash: nil
        )

        await watcher.handle(
            event,
            options: AnnouncerReadOptions(
                keepShort: true,
                smartShortenWithAppleIntelligence: true,
                smartShortener: { _ in "The build passed after removing the old DAVE retry timer." }
            )
        )

        let pending = await announcer.pending
        XCTAssertEqual(pending.map(\.text), ["Alice: The build passed after removing the old DAVE retry timer."])
    }

    func testTextChannelAnnouncerFallsBackWhenSmartShortenerReturnsNil() async throws {
        let playback = VoicePlaybackService()
        let announcer = try VoiceAnnouncementService(playback: playback)
        await announcer.setPaused(true)

        let watcher = TextChannelAnnouncer(announcer: announcer)
        await watcher.setWatchedChannel("channel-1")

        let longMessage = Array(repeating: "this is a long noisy Discord message that should be kept short", count: 6)
            .joined(separator: " ")
        let event = GatewayMessageCreateEvent(
            rawMap: [:],
            content: longMessage,
            author: [:],
            username: "Alice",
            displayName: "Alice",
            channelID: "channel-1",
            userID: "user-1",
            guildID: "guild-1",
            messageID: "msg-1",
            isBot: false,
            avatarHash: nil
        )

        await watcher.handle(
            event,
            options: AnnouncerReadOptions(
                summariseLong: true,
                keepShort: true,
                smartShortenWithAppleIntelligence: true,
                smartShortener: { _ in nil }
            )
        )

        let pending = await announcer.pending
        let spoken = try XCTUnwrap(pending.first?.text)
        XCTAssertTrue(spoken.hasPrefix("Alice: "))
        XCTAssertTrue(spoken.hasSuffix("…"))
        XCTAssertLessThanOrEqual(spoken.count, 170)
    }

    func testTextChannelAnnouncerTimesOutSlowSmartShortener() async throws {
        let playback = VoicePlaybackService()
        let announcer = try VoiceAnnouncementService(playback: playback)
        await announcer.setPaused(true)

        let watcher = TextChannelAnnouncer(announcer: announcer)
        await watcher.setWatchedChannel("channel-1")

        let longMessage = Array(repeating: "this message should not wait for a slow smart shortener", count: 6)
            .joined(separator: " ")
        let event = GatewayMessageCreateEvent(
            rawMap: [:],
            content: longMessage,
            author: [:],
            username: "Alice",
            displayName: "Alice",
            channelID: "channel-1",
            userID: "user-1",
            guildID: "guild-1",
            messageID: "msg-1",
            isBot: false,
            avatarHash: nil
        )

        let start = Date()
        await watcher.handle(
            event,
            options: AnnouncerReadOptions(
                summariseLong: true,
                keepShort: true,
                smartShortenWithAppleIntelligence: true,
                smartShortener: { _ in
                    await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                            continuation.resume(returning: "This arrived too late to be spoken.")
                        }
                    }
                }
            )
        )

        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
        let pending = await announcer.pending
        let spoken = try XCTUnwrap(pending.first?.text)
        XCTAssertTrue(spoken.hasPrefix("Alice: "))
        XCTAssertTrue(spoken.hasSuffix("…"))
        XCTAssertLessThanOrEqual(spoken.count, 170)
    }

    @MainActor
    func testAppModelForwardsActiveVoiceChannelMessages() async throws {
        let app = AppModel()
        
        // Mock connection status as connected, and text channel source as enabled
        app.voiceConnectionStatus = .connected
        app.settings.voice.textChannelSourceEnabled = true
        app.settings.voice.watchedTextChannelID = "channel-1"
        app.settings.voice.voiceChannelID = "voice-channel-chat"
        
        // Initialize text channel announcer storage
        let watcher = app.textChannelAnnouncer
        XCTAssertNotNil(watcher)
        
        // Create an expectation on the announcer queue change
        let expectation = XCTestExpectation(description: "Message enqueued")
        expectation.expectedFulfillmentCount = 2
        
        let capture = TestCapture()
        
        if let announcer = app.voiceAnnouncementService {
            await announcer.setOnQueueChange { queue in
                if let last = queue.last {
                    let appended = await capture.appendIfNew(last.text)
                    if appended {
                        expectation.fulfill()
                    }
                }
            }
        }
        
        // Create event for the watched text channel
        let event1 = GatewayMessageCreateEvent(
            rawMap: [:],
            content: "Message in watched text channel",
            author: [:],
            username: "Alice",
            displayName: "Alice",
            channelID: "channel-1",
            userID: "user-1",
            guildID: "guild-1",
            messageID: "msg-1",
            isBot: false,
            avatarHash: nil
        )
        
        // Create event for the active voice channel chat
        let event2 = GatewayMessageCreateEvent(
            rawMap: [:],
            content: "Message in voice chat",
            author: [:],
            username: "Bob",
            displayName: "Bob",
            channelID: "voice-channel-chat",
            userID: "user-2",
            guildID: "guild-1",
            messageID: "msg-2",
            isBot: false,
            avatarHash: nil
        )
        
        // Create event for an unwatched channel
        let event3 = GatewayMessageCreateEvent(
            rawMap: [:],
            content: "Message in unwatched channel",
            author: [:],
            username: "Charlie",
            displayName: "Charlie",
            channelID: "channel-3",
            userID: "user-3",
            guildID: "guild-1",
            messageID: "msg-3",
            isBot: false,
            avatarHash: nil
        )
        
        await app.forwardMessageToVoiceAnnouncer(event1)
        await app.forwardMessageToVoiceAnnouncer(event2)
        await app.forwardMessageToVoiceAnnouncer(event3)
        
        await fulfillment(of: [expectation], timeout: 2.0)
        
        let texts = await capture.receivedTexts
        XCTAssertEqual(texts.count, 2)
        XCTAssertTrue(texts.contains("Alice: Message in watched text channel"))
        XCTAssertTrue(texts.contains("Bob: Message in voice chat"))
    }

    @MainActor
    func testUIReconnectPreparationArmsConfiguredAnnouncerFeed() async throws {
        let app = AppModel()

        app.settings.voice.guildID = ""
        app.settings.voice.voiceChannelID = ""
        app.settings.voice.watchedTextChannelID = ""
        app.settings.voice.textChannelSourceEnabled = false
        app.settings.voice.announcerConfigs = [
            AnnouncerVoiceChannelConfig(
                id: "config-1",
                name: "General",
                voiceChannelID: "voice-1",
                voiceChannelName: "General",
                readVoiceChannelChat: false,
                textChannels: ["text-1"]
            )
        ]
        app.availableVoiceChannelsByServer = [
            "guild-1": [GuildVoiceChannel(id: "voice-1", name: "General")]
        ]
        app.availableTextChannelsByServer = [
            "guild-1": [GuildTextChannel(id: "text-1", name: "announcements")]
        ]

        let target = await app.prepareAnnouncerConfigForUIReconnect(persist: false)

        XCTAssertEqual(target?.guildID, "guild-1")
        XCTAssertEqual(target?.channelID, "voice-1")
        XCTAssertEqual(app.settings.voice.guildID, "guild-1")
        XCTAssertEqual(app.settings.voice.voiceChannelID, "voice-1")
        XCTAssertEqual(app.settings.voice.watchedTextChannelID, "text-1")
        XCTAssertTrue(app.settings.voice.textChannelSourceEnabled)

        app.voiceConnectionStatus = .connected
        guard let announcer = app.voiceAnnouncementService else {
            XCTFail("Expected voice announcement service")
            return
        }
        await announcer.setPaused(true)

        let event = GatewayMessageCreateEvent(
            rawMap: [:],
            content: "Message from the configured feed",
            author: [:],
            username: "Alice",
            displayName: "Alice",
            channelID: "text-1",
            userID: "user-1",
            guildID: "guild-1",
            messageID: "msg-1",
            isBot: false,
            avatarHash: nil
        )

        await app.forwardMessageToVoiceAnnouncer(event)

        let pending = await announcer.pending
        XCTAssertEqual(pending.map(\.text), ["Alice: Message from the configured feed"])
    }

    @MainActor
    func testPreservedVoiceDisconnectKeepsAnnouncerFeedArmed() async throws {
        let app = AppModel()

        app.settings.voice.guildID = ""
        app.settings.voice.voiceChannelID = "voice-1"
        app.settings.voice.watchedTextChannelID = "text-1"
        app.settings.voice.textChannelSourceEnabled = true

        _ = app.voicePlaybackService

        await app.disconnectVoice(preserveAnnouncerSession: true)

        XCTAssertEqual(app.settings.voice.voiceChannelID, "voice-1")
        XCTAssertEqual(app.settings.voice.watchedTextChannelID, "text-1")
        XCTAssertTrue(app.settings.voice.textChannelSourceEnabled)
        XCTAssertEqual(app.voiceConnectionStatus, .recovering("Preparing a clean rejoin…"))
    }

    @MainActor
    func testAppModelQueuesMessagesWhileVoiceConnectionRecovers() async throws {
        let app = AppModel()

        app.voiceConnectionStatus = .recovering("Rejoining voice channel...")
        app.settings.voice.textChannelSourceEnabled = true
        app.settings.voice.watchedTextChannelID = "channel-1"
        app.settings.voice.voiceChannelID = "voice-channel-chat"

        let watcher = app.textChannelAnnouncer
        XCTAssertNotNil(watcher)
        guard let announcer = app.voiceAnnouncementService else {
            XCTFail("Expected voice announcement service")
            return
        }
        await announcer.setPaused(true)

        let event = GatewayMessageCreateEvent(
            rawMap: [:],
            content: "Message while reconnecting",
            author: [:],
            username: "Alice",
            displayName: "Alice",
            channelID: "channel-1",
            userID: "user-1",
            guildID: "guild-1",
            messageID: "msg-1",
            isBot: false,
            avatarHash: nil
        )

        await app.forwardMessageToVoiceAnnouncer(event)

        let pending = await announcer.pending
        XCTAssertEqual(pending.map(\.text), ["Alice: Message while reconnecting"])
    }
}

private actor TestCapture {
    private(set) var receivedTexts: [String] = []
    
    func appendIfNew(_ text: String) -> Bool {
        if !receivedTexts.contains(text) {
            receivedTexts.append(text)
            return true
        }
        return false
    }
}
