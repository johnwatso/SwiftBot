import Foundation

struct PendingMusicSelection {
    let query: String
    let channelID: String
    let createdAt: Date
    let results: [MusicSearchResult]
}

struct MusicInteractionSession {
    let id: String
    let query: String
    let userID: String
    let channelID: String
    let createdAt: Date
    let results: [MusicSearchResult]
}

struct PlaylistTrackCardState {
    let key: String
    let threadID: String
    var messageID: String
    let sourceTitle: String
    let sourceArtist: String?
    var candidates: [MusicSearchResult]
    var selectedIndex: Int
    var useSourceQueryForApple: Bool
    var useSourceQueryForSpotify: Bool
    var useSourceQueryForYouTubeMusic: Bool
}
