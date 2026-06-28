import Foundation

struct MusicSearchResult: Sendable, Hashable {
    let title: String
    let artist: String
    let album: String?
    let artworkURL: URL?
    let appleMusicURL: URL?
    let spotifyURL: URL?
    let youtubeMusicURL: URL?
    let youtubeURL: URL?
}

struct MusicPlatformLinks: Sendable, Hashable {
    let appleMusicURL: URL?
    let spotifyURL: URL?
    let youtubeMusicURL: URL?
    let youtubeURL: URL?
}

actor MusicLookupService {
    private let session: URLSession
    private let iTunesSearchURL: URL
    private let songLinkAPIURL: URL

    init(
        session: URLSession,
        iTunesSearchURL: URL = URL(string: "https://itunes.apple.com/search")!,
        songLinkAPIURL: URL = URL(string: "https://api.song.link/v1-alpha.1/links")!
    ) {
        self.session = session
        self.iTunesSearchURL = iTunesSearchURL
        self.songLinkAPIURL = songLinkAPIURL
    }

    func searchTracks(query: String, limit: Int = 5) async -> [MusicSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(url: iTunesSearchURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "term", value: trimmed),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 10))))
        ]

        guard let url = components?.url else { return [] }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("SwiftBot/1.0", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return []
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                return []
            }

            let baseResults = results.compactMap { item -> MusicSearchResult? in
                guard let title = (item["trackName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let artist = (item["artistName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty,
                      !artist.isEmpty else {
                    return nil
                }

                let album = (item["collectionName"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let appleURL = (item["trackViewUrl"] as? String).flatMap(URL.init(string:))
                let artworkURL = (item["artworkUrl100"] as? String).flatMap(URL.init(string:))

                return MusicSearchResult(
                    title: title,
                    artist: artist,
                    album: album?.isEmpty == false ? album : nil,
                    artworkURL: artworkURL,
                    appleMusicURL: appleURL,
                    spotifyURL: nil,
                    youtubeMusicURL: nil,
                    youtubeURL: nil
                )
            }

            var enriched: [MusicSearchResult] = []
            for item in baseResults {
                if let appleURL = item.appleMusicURL,
                   let links = await resolveCrossPlatformLinks(inputURL: appleURL) {
                    enriched.append(
                        MusicSearchResult(
                            title: item.title,
                            artist: item.artist,
                            album: item.album,
                            artworkURL: item.artworkURL,
                            appleMusicURL: links.appleMusicURL ?? item.appleMusicURL,
                            spotifyURL: links.spotifyURL,
                            youtubeMusicURL: links.youtubeMusicURL,
                            youtubeURL: links.youtubeURL
                        )
                    )
                } else {
                    enriched.append(item)
                }
            }

            return enriched
        } catch {
            return []
        }
    }

    func resolveCrossPlatformLinks(inputURL: URL) async -> MusicPlatformLinks? {
        var components = URLComponents(url: songLinkAPIURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "url", value: inputURL.absoluteString)]
        guard let url = components?.url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("SwiftBot/1.0", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let linksByPlatform = json["linksByPlatform"] as? [String: Any] else {
                return nil
            }

            func link(_ key: String) -> URL? {
                guard let container = linksByPlatform[key] as? [String: Any],
                      let value = container["url"] as? String else {
                    return nil
                }
                return URL(string: value)
            }

            return MusicPlatformLinks(
                appleMusicURL: link("appleMusic"),
                spotifyURL: link("spotify"),
                youtubeMusicURL: link("youtubeMusic"),
                youtubeURL: link("youtube")
            )
        } catch {
            return nil
        }
    }
}
