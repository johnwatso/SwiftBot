import XCTest
@testable import SwiftBot

final class MusicLinkDetectorTests: XCTestCase {
    @MainActor
    func testMusicPostUsesEmbedAndLinkButtonsWithOriginalTrackURL() throws {
        let app = AppModel()
        let sourceURL = URL(string: "https://open.spotify.com/track/abc123")!
        let track = MusicSearchResult(
            title: "Strobe", artist: "deadmau5", album: "For Lack of a Better Name",
            artworkURL: URL(string: "https://example.com/cover.jpg"),
            appleMusicURL: URL(string: "https://music.apple.com/nz/song/strobe/987654321"),
            spotifyURL: nil, youtubeMusicURL: nil, youtubeURL: nil
        )
        let payload = app.musicTrackPayload(for: track, sourceURL: sourceURL)
        // Exercise the actual JSON shape sent to Discord, including optional
        // artwork and metadata alongside legacy-compatible link buttons.
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(decoded["content"], "The post should not duplicate the title or expose raw links")
        let embed = try XCTUnwrap((decoded["embeds"] as? [[String: Any]])?.first)
        XCTAssertEqual(embed["title"] as? String, "Strobe")
        XCTAssertEqual(embed["description"] as? String, "by **deadmau5**\nFor Lack of a Better Name")
        XCTAssertEqual(embed["url"] as? String, sourceURL.absoluteString)
        XCTAssertEqual(embed["color"] as? Int, 0x1DB954, "Coloured for the service it was shared from")
        XCTAssertEqual((embed["author"] as? [String: String])?["name"], "Shared from Spotify")
        XCTAssertEqual((embed["image"] as? [String: String])?["url"], track.artworkURL?.absoluteString)

        let rows = try XCTUnwrap(decoded["components"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        let buttons = try XCTUnwrap(rows.first?["components"] as? [[String: Any]])
        XCTAssertEqual(buttons.count, 4)
        XCTAssertEqual(buttons.first { $0["label"] as? String == "Spotify" }?["url"] as? String, sourceURL.absoluteString)
        for button in buttons {
            XCTAssertEqual(button["type"] as? Int, 2)
            XCTAssertEqual(button["style"] as? Int, 5)
            XCTAssertNil(button["custom_id"], "Link buttons must not require an interaction session")
            let url = try XCTUnwrap(button["url"] as? String)
            XCTAssertEqual(URL(string: url)?.scheme, "https")
        }
    }

    @MainActor
    func testMusicPostWorksWithoutArtworkOrExactPlatformMatches() throws {
        let app = AppModel()
        let track = MusicSearchResult(
            title: "A Song", artist: "An Artist", album: nil, artworkURL: nil,
            appleMusicURL: nil, spotifyURL: nil, youtubeMusicURL: nil, youtubeURL: nil
        )
        let payload = app.musicTrackPayload(for: track)
        let embed = try XCTUnwrap((payload["embeds"] as? [[String: Any]])?.first)
        XCTAssertNil(embed["image"])
        XCTAssertNil(embed["author"])
        XCTAssertNil(payload["message_reference"])
        let rows = try XCTUnwrap(payload["components"] as? [[String: Any]])
        let buttons = try XCTUnwrap(rows.first?["components"] as? [[String: Any]])
        let youtube = try XCTUnwrap(buttons.first { $0["label"] as? String == "YouTube" }?["url"] as? String)
        let query = URLComponents(string: youtube)?.queryItems?.first { $0.name == "search_query" }?.value
        XCTAssertEqual(query, "A Song An Artist")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: payload))
    }

    func testFindsSupportedSpotifyTrack() {
        let url = MusicLinkDetector.firstTrackURL(in: "Try https://open.spotify.com/track/abc123 right now")

        XCTAssertEqual(url?.host, "open.spotify.com")
    }

    func testIgnoresPlaylists() {
        XCTAssertNil(MusicLinkDetector.firstTrackURL(in: "https://open.spotify.com/playlist/abc123"))
        XCTAssertNil(MusicLinkDetector.firstTrackURL(in: "https://www.youtube.com/playlist?list=PL123"))
        XCTAssertNil(MusicLinkDetector.firstTrackURL(in: "https://www.youtube.com/watch?dv=abc"))
    }

    func testFindsYouTubeTrackShapes() {
        for link in [
            "https://music.youtube.com/watch?v=kPO_KrQrhu8&si=vmlF-rK19TEh3GoJ",
            "https://music.youtube.com/watch?v=kPO_KrQrhu8&list=RDAMVMkPO_KrQrhu8",
            "https://m.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://www.youtube.com/shorts/dQw4w9WgXcQ",
            "https://youtu.be/dQw4w9WgXcQ?si=abc"
        ] {
            XCTAssertNotNil(MusicLinkDetector.firstTrackURL(in: "listen <\(link)>"), link)
        }
    }

    func testTopicChannelKeepsTitleAndTakesArtistFromChannel() {
        let url = URL(string: "https://music.youtube.com/watch?v=kPO_KrQrhu8")!
        let metadata = MusicLinkDetector.cleanedMetadata(
            title: "crystallized (feat. Inéz) - Subtronics Remix", author: "John Summit - Topic",
            thumbnailURL: nil, sourceURL: url
        )
        XCTAssertEqual(metadata.title, "crystallized (feat. Inéz) - Subtronics Remix")
        XCTAssertEqual(metadata.artist, "John Summit")
    }

    func testArtistDashTitleUploadsAreSplitAndCleaned() {
        let url = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        let metadata = MusicLinkDetector.cleanedMetadata(
            title: "Rick Astley - Never Gonna Give You Up (Official Video) (4K Remaster)", author: "Rick Astley",
            thumbnailURL: nil, sourceURL: url
        )
        XCTAssertEqual(metadata.title, "Never Gonna Give You Up")
        XCTAssertEqual(metadata.artist, "Rick Astley")
        XCTAssertEqual(
            MusicLinkDetector.stripVideoNoise(from: "Disgruntled (feat. J Hus & IRAH) [Official Video]"),
            "Disgruntled (feat. J Hus & IRAH)"
        )
    }

    func testConfidentMatchRejectsSameTitleByAnotherArtist() {
        let metadata = MusicLinkMetadata(title: "Disgruntled (feat. J Hus & IRAH)", artist: "Chase & Status", thumbnailURL: nil)
        let wrong = MusicSearchResult(title: "Disgruntled", artist: "Rancid", album: nil, artworkURL: nil,
                                      appleMusicURL: nil, spotifyURL: nil, youtubeMusicURL: nil, youtubeURL: nil)
        let right = MusicSearchResult(title: "Disgruntled (feat. J Hus & IRAH)", artist: "Chase & Status", album: nil, artworkURL: nil,
                                      appleMusicURL: nil, spotifyURL: nil, youtubeMusicURL: nil, youtubeURL: nil)
        XCTAssertFalse(MusicLinkDetector.isConfidentMatch(wrong, for: metadata))
        XCTAssertTrue(MusicLinkDetector.isConfidentMatch(right, for: metadata))
    }

    @MainActor
    func testWatchedLinkRepliesToTheSharedMessageWithoutPinging() {
        let app = AppModel()
        let track = MusicSearchResult(title: "Song", artist: "*NSYNC", album: nil, artworkURL: nil,
                                      appleMusicURL: nil, spotifyURL: nil, youtubeMusicURL: nil, youtubeURL: nil,
                                      releaseYear: 2000, durationSeconds: 201)
        let payload = app.musicTrackPayload(for: track, replyTo: "123")
        XCTAssertEqual((payload["message_reference"] as? [String: Any])?["message_id"] as? String, "123")
        XCTAssertEqual((payload["allowed_mentions"] as? [String: Any])?["replied_user"] as? Bool, false)
        let embed = (payload["embeds"] as? [[String: Any]])?.first
        XCTAssertEqual(embed?["description"] as? String, "by **\\*NSYNC**\n2000 · 3:21")
    }

    func testBuildsAppleMusicSearchQueryFromSongSlug() {
        let url = URL(string: "https://music.apple.com/nz/album/strobe/123456789?i=987654321")!

        XCTAssertEqual(MusicLinkDetector.appleMusicSearchQuery(for: url), "strobe")
    }
}
