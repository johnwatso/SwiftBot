import XCTest
@testable import SwiftBot

final class MusicLinkDetectorTests: XCTestCase {
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
