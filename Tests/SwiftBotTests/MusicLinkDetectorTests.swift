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
        XCTAssertEqual(embed["description"] as? String, "deadmau5")
        XCTAssertEqual(embed["url"] as? String, sourceURL.absoluteString)
        XCTAssertEqual((embed["thumbnail"] as? [String: String])?["url"], track.artworkURL?.absoluteString)

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
        XCTAssertNil(embed["thumbnail"])
        XCTAssertNil(embed["footer"])
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
        XCTAssertNil(MusicLinkDetector.firstTrackURL(in: "https://www.youtube.com/watch?v=abc&list=playlist"))
    }

    func testBuildsAppleMusicSearchQueryFromSongSlug() {
        let url = URL(string: "https://music.apple.com/nz/album/strobe/123456789?i=987654321")!

        XCTAssertEqual(MusicLinkDetector.appleMusicSearchQuery(for: url), "strobe")
    }
}
