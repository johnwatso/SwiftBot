import Foundation

struct PlaylistTrackSeed: Codable, Sendable, Hashable {
    let title: String
    let artist: String?
}

struct PlaylistImportResult: Codable, Sendable, Hashable {
    let playlistTitle: String?
    let tracks: [PlaylistTrackSeed]
}

actor PlaylistImportService {
    private let session: URLSession
    private let iTunesLookupURL: URL

    init(
        session: URLSession,
        iTunesLookupURL: URL = URL(string: "https://itunes.apple.com/lookup")!
    ) {
        self.session = session
        self.iTunesLookupURL = iTunesLookupURL
    }

    func importTracks(from playlistURL: URL, limit: Int) async -> [PlaylistTrackSeed] {
        let result = await importPlaylist(from: playlistURL, limit: limit)
        return result.tracks
    }

    func importPlaylist(from playlistURL: URL, limit: Int) async -> PlaylistImportResult {
        let clampedLimit = max(1, min(limit, 100))
        guard let html = await fetchHTML(url: playlistURL) else {
            return PlaylistImportResult(playlistTitle: nil, tracks: [])
        }

        let host = playlistURL.host?.lowercased() ?? ""
        let listID = URLComponents(url: playlistURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "list" })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var workingHTML = html
        var title = extractPlaylistTitle(from: html)
        let candidates: [PlaylistTrackSeed]
        if host.contains("youtube.com") || host.contains("youtu.be") {
            if host.contains("music.youtube.com"), !listID.isEmpty {
                // music.youtube.com often returns sparse HTML in non-browser contexts.
                // Fallback to equivalent www.youtube.com playlist page with the same list ID.
                let initial = parseYouTubePlaylistHTML(workingHTML)
                if initial.isEmpty, let fallbackURL = youtubePlaylistURL(from: listID),
                   let fallbackHTML = await fetchHTML(url: fallbackURL) {
                    workingHTML = fallbackHTML
                    if let fallbackTitle = extractPlaylistTitle(from: fallbackHTML), !fallbackTitle.isEmpty {
                        title = fallbackTitle
                    }
                }
            }

            let playlistCandidates = parseYouTubePlaylistHTML(workingHTML)
            if !playlistCandidates.isEmpty {
                candidates = playlistCandidates
            } else if !listID.isEmpty {
                // list= present but no structured rows found; fallback to watch metadata.
                candidates = parseYouTubeWatchHTML(workingHTML)
            } else {
                // watch URL with no list: treat as single-track import.
                candidates = parseYouTubeWatchHTML(workingHTML)
            }
        } else if host.contains("spotify.com") {
            candidates = await parseSpotifyPlaylistHTML(html, limit: clampedLimit)
        } else if host.contains("music.apple.com") {
            candidates = await parseAppleMusicPlaylistHTML(html, limit: clampedLimit)
        } else {
            candidates = parseGenericPlaylistHTML(html)
        }

        return PlaylistImportResult(
            playlistTitle: title,
            tracks: Array(deduplicate(candidates).prefix(clampedLimit))
        )
    }

    private func fetchHTML(url: URL) async -> String? {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("SwiftBot/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func parseYouTubePlaylistHTML(_ html: String) -> [PlaylistTrackSeed] {
        // Best-effort: parse playlist rows from ytInitialData payload.
        let pairPatterns = [
            #""playlistVideoRenderer":\{[\s\S]*?"title":\{"runs":\[\{"text":"([^"]+)"\}\][\s\S]*?"(?:short|long)BylineText":\{"runs":\[\{"text":"([^"]+)"\}"#,
            #""playlistVideoRenderer":\{[\s\S]*?"title":\{"simpleText":"([^"]+)"\}[\s\S]*?"(?:short|long)BylineText":\{"runs":\[\{"text":"([^"]+)"\}"#,
            #""playlistVideoRenderer":\{[\s\S]*?"title":\{"runs":\[\{"text":"([^"]+)"\}\][\s\S]*?"(?:short|long)BylineText":\{"simpleText":"([^"]+)"\}"#,
            #""playlistVideoRenderer":\{[\s\S]*?"title":\{"simpleText":"([^"]+)"\}[\s\S]*?"(?:short|long)BylineText":\{"simpleText":"([^"]+)"\}"#
        ]
        for pattern in pairPatterns {
            let pairs = regexPairCaptures(pattern: pattern, in: html)
            if !pairs.isEmpty {
                return pairs.compactMap { titleRaw, artistRaw in
                    let title = decodeJSONEscapes(titleRaw).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { return nil }
                    let lowered = title.lowercased()
                    if lowered == "private video" || lowered == "deleted video" {
                        return nil
                    }
                    let artist = decodeJSONEscapes(artistRaw).trimmingCharacters(in: .whitespacesAndNewlines)
                    return PlaylistTrackSeed(title: title, artist: artist.isEmpty ? nil : artist)
                }
            }
        }

        let titlePattern = #""(?:playlistVideoRenderer|videoRenderer)":\{[\s\S]*?"title":\{"runs":\[\{"text":"([^"]+)"\}\]"#
        let titles = regexCaptures(pattern: titlePattern, in: html)
        return titles.compactMap { rawTitle in
            let cleaned = decodeJSONEscapes(rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }
            if cleaned.lowercased() == "private video" || cleaned.lowercased() == "deleted video" {
                return nil
            }
            return PlaylistTrackSeed(title: cleaned, artist: nil)
        }
    }

    private func parseYouTubeWatchHTML(_ html: String) -> [PlaylistTrackSeed] {
        let title = regexCaptures(
            pattern: #"<meta\s+property=\"og:title\"\s+content=\"([^\"]+)\""#,
            in: html
        ).first.map(decodeHTMLEntities)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let artist = regexCaptures(
            pattern: #"<meta\s+property=\"og:description\"\s+content=\"([^\"]+)\""#,
            in: html
        ).first.map(decodeHTMLEntities)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !title.isEmpty else { return [] }
        return [
            PlaylistTrackSeed(
                title: title,
                artist: artist.isEmpty ? nil : artist
            )
        ]
    }

    private func parseSpotifyPlaylistHTML(_ html: String, limit: Int) async -> [PlaylistTrackSeed] {
        // Best-effort: track-like nodes embedded in JSON scripts.
        let names = regexCaptures(pattern: #""trackName":"([^"]+)""#, in: html)
        let artists = regexCaptures(pattern: #""artistName":"([^"]+)""#, in: html)
        if !names.isEmpty {
            return zipPad(names, artists).compactMap { pair in
                let title = decodeJSONEscapes(pair.0).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                let artist = decodeJSONEscapes(pair.1 ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return PlaylistTrackSeed(title: title, artist: artist.isEmpty ? nil : artist)
            }
        }

        // Newer Spotify payloads often embed track objects in minified JSON blobs.
        let graphPairs = regexPairCaptures(
            pattern: #""artists":\{"items":\[\{"profile":\{"name":"([^"]+)"\}[\s\S]*?"name":"([^"]+)"[\s\S]*?"uri":"spotify:track:[^"]+""#,
            in: html
        )
        if !graphPairs.isEmpty {
            return graphPairs.compactMap { artistRaw, titleRaw in
                let title = decodeJSONEscapes(titleRaw).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                let artist = decodeJSONEscapes(artistRaw).trimmingCharacters(in: .whitespacesAndNewlines)
                return PlaylistTrackSeed(title: title, artist: artist.isEmpty ? nil : artist)
            }
        }

        // Fallback patterns occasionally present in rendered script blobs.
        let altNames = regexCaptures(pattern: #""name":"([^"]+)","type":"track""#, in: html)
        if !altNames.isEmpty {
            return altNames.compactMap { item in
                let title = decodeJSONEscapes(item).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                return PlaylistTrackSeed(title: title, artist: nil)
            }
        }

        // Stable fallback: Spotify playlist pages expose track URLs via meta music:song tags.
        // Resolve each track page to extract og:title/og:description for title and artist.
        let trackURLs = extractSpotifyTrackURLs(from: html)

        var resolved: [PlaylistTrackSeed] = []
        for url in Array(trackURLs.prefix(max(1, min(limit, 50)))) {
            if let seed = await resolveSpotifyTrack(from: url) {
                resolved.append(seed)
            }
        }
        if !resolved.isEmpty {
            return resolved
        }

        return trackURLs.compactMap { url in
            let raw = url.lastPathComponent
            guard !raw.isEmpty else { return nil }
            let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return PlaylistTrackSeed(title: title, artist: nil)
        }
    }

    private func resolveSpotifyTrack(from url: URL) async -> PlaylistTrackSeed? {
        guard let html = await fetchHTML(url: url) else { return nil }

        let title = regexCaptures(
            pattern: #"<meta\s+property=\"og:title\"\s+content=\"([^\"]+)\""#,
            in: html
        ).first.map(decodeHTMLEntities)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return nil }

        let description = regexCaptures(
            pattern: #"<meta\s+property=\"og:description\"\s+content=\"([^\"]+)\""#,
            in: html
        ).first.map(decodeHTMLEntities)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let artist: String?
        if description.isEmpty {
            artist = nil
        } else {
            let segments = description
                .components(separatedBy: "·")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let first = segments.first
            if let first, first.caseInsensitiveCompare(title) != .orderedSame {
                artist = first
            } else {
                artist = nil
            }
        }

        return PlaylistTrackSeed(title: title, artist: artist)
    }

    private func extractSpotifyTrackURLs(from html: String) -> [URL] {
        var results: [URL] = []
        var seen: Set<String> = []

        let patterns = [
            #"<meta[^>]+name=\"music:song\"[^>]+content=\"([^\"]+)\""#,
            #"<meta[^>]+content=\"([^\"]+)\"[^>]+name=\"music:song\""#,
            #"<meta[^>]+name='music:song'[^>]+content='([^']+)'"#,
            #"<meta[^>]+content='([^']+)'[^>]+name='music:song'"#
        ]

        for pattern in patterns {
            for raw in regexCaptures(pattern: pattern, in: html) {
                let decoded = decodeHTMLEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let url = URL(string: decoded) else { continue }
                let key = url.absoluteString
                if seen.insert(key).inserted {
                    results.append(url)
                }
            }
        }

        // Last-resort extraction from script blobs / embedded payloads.
        let directPattern = #"(https:\/\/open\.spotify\.com\/track\/[A-Za-z0-9]+)"#
        for raw in regexCaptures(pattern: directPattern, in: html) {
            guard let url = URL(string: raw) else { continue }
            let key = url.absoluteString
            if seen.insert(key).inserted {
                results.append(url)
            }
        }

        return results
    }

    private func parseAppleMusicPlaylistHTML(_ html: String, limit: Int) async -> [PlaylistTrackSeed] {
        // Reliable signal from Apple playlist pages: repeated meta tags.
        let songURLs = regexCaptures(
            pattern: #"<meta\s+property=\"music:song\"\s+content=\"([^\"]+)\""#,
            in: html
        )
        let ids = songURLs.compactMap { urlString -> String? in
            guard let url = URL(string: decodeHTMLEntities(urlString)) else { return nil }
            return url.pathComponents.last?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }

        if !ids.isEmpty {
            var output: [PlaylistTrackSeed] = []
            for id in ids.prefix(limit) {
                if let seed = await lookupAppleSong(id: id) {
                    output.append(seed)
                }
            }
            if !output.isEmpty {
                return output
            }
        }

        // Fallback to JSON snippets if metadata lookup fails.
        let pairs = regexPairCaptures(pattern: #""name":"([^"]+)","artistName":"([^"]+)""#, in: html)
        return pairs.compactMap { titleRaw, artistRaw in
            let title = decodeJSONEscapes(decodeHTMLEntities(titleRaw)).trimmingCharacters(in: .whitespacesAndNewlines)
            let artist = decodeJSONEscapes(decodeHTMLEntities(artistRaw)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return PlaylistTrackSeed(title: title, artist: artist.isEmpty ? nil : artist)
        }
    }

    private func lookupAppleSong(id: String) async -> PlaylistTrackSeed? {
        var components = URLComponents(url: iTunesLookupURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: id)]
        guard let url = components?.url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("SwiftBot/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let track = results.first(where: { ($0["wrapperType"] as? String) == "track" }) ?? results.first,
                  let name = track["trackName"] as? String else {
                return nil
            }
            let artist = track["artistName"] as? String
            let cleanTitle = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanArtist = artist?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanTitle.isEmpty else { return nil }
            return PlaylistTrackSeed(title: cleanTitle, artist: cleanArtist?.isEmpty == false ? cleanArtist : nil)
        } catch {
            return nil
        }
    }

    private func parseGenericPlaylistHTML(_ html: String) -> [PlaylistTrackSeed] {
        let titles = regexCaptures(pattern: #""trackName":"([^"]+)""#, in: html)
        if !titles.isEmpty {
            return titles.map {
                PlaylistTrackSeed(
                    title: decodeJSONEscapes($0).trimmingCharacters(in: .whitespacesAndNewlines),
                    artist: nil
                )
            }.filter { !$0.title.isEmpty }
        }
        return []
    }

    private func deduplicate(_ seeds: [PlaylistTrackSeed]) -> [PlaylistTrackSeed] {
        var seen: Set<String> = []
        var output: [PlaylistTrackSeed] = []
        for seed in seeds {
            let key = "\(seed.title.lowercased())|\((seed.artist ?? "").lowercased())"
            if seen.insert(key).inserted {
                output.append(seed)
            }
        }
        return output
    }

    private func regexCaptures(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        let matches = regex.matches(in: text, options: [], range: range)
        return matches.compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            let capture = match.range(at: 1)
            guard capture.location != NSNotFound else { return nil }
            return (text as NSString).substring(with: capture)
        }
    }

    private func zipPad(_ left: [String], _ right: [String]) -> [(String, String?)] {
        let count = max(left.count, right.count)
        return (0..<count).map { index in
            let l = index < left.count ? left[index] : ""
            let r = index < right.count ? right[index] : nil
            return (l, r)
        }
    }

    private func regexPairCaptures(pattern: String, in text: String) -> [(String, String)] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        let matches = regex.matches(in: text, options: [], range: range)
        return matches.compactMap { match in
            guard match.numberOfRanges > 2 else { return nil }
            let first = match.range(at: 1)
            let second = match.range(at: 2)
            guard first.location != NSNotFound, second.location != NSNotFound else { return nil }
            return ((text as NSString).substring(with: first), (text as NSString).substring(with: second))
        }
    }

    private func decodeJSONEscapes(_ text: String) -> String {
        let quoted = "\"\(text)\""
        guard let data = quoted.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data) else {
            return text
        }
        return decoded
    }

    private func decodeHTMLEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    private func extractPlaylistTitle(from html: String) -> String? {
        let appleTitle = regexCaptures(
            pattern: #"<meta\s+name=\"apple:title\"\s+content=\"([^\"]+)\""#,
            in: html
        ).first
        if let appleTitle {
            let decoded = decodeHTMLEntities(appleTitle).trimmingCharacters(in: .whitespacesAndNewlines)
            if !decoded.isEmpty { return decoded }
        }

        let ogTitle = regexCaptures(
            pattern: #"<meta\s+property=\"og:title\"\s+content=\"([^\"]+)\""#,
            in: html
        ).first
        if let ogTitle {
            var decoded = decodeHTMLEntities(ogTitle).trimmingCharacters(in: .whitespacesAndNewlines)
            decoded = decoded.replacingOccurrences(of: " on Apple Music", with: "")
            if !decoded.isEmpty { return decoded }
        }

        let titleTag = regexCaptures(
            pattern: #"<title>([^<]+)</title>"#,
            in: html
        ).first
        if let titleTag {
            let decoded = decodeHTMLEntities(titleTag).trimmingCharacters(in: .whitespacesAndNewlines)
            if !decoded.isEmpty { return decoded }
        }
        return nil
    }

    private func youtubePlaylistURL(from listID: String) -> URL? {
        var components = URLComponents(string: "https://www.youtube.com/playlist")
        components?.queryItems = [URLQueryItem(name: "list", value: listID)]
        return components?.url
    }
}
