import XCTest
@testable import SwiftBot

final class TextChannelAnnouncerTests: XCTestCase {
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
