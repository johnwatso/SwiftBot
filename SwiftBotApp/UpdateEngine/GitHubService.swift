import Foundation

public enum GitHubWatchMode: Sendable, Hashable {
    case releases
    case commits(branch: String)
}

public struct GitHubUpdateInfo: Sendable {
    public let releaseIdentifier: String
    public let displayVersion: String
    public let title: String
    public let author: String
    public let date: String
    public let url: String
    public let summary: String
    public let embedJSON: String
    public let rawDebug: String
    public let mode: GitHubWatchMode

    public init(
        releaseIdentifier: String,
        displayVersion: String,
        title: String,
        author: String,
        date: String,
        url: String,
        summary: String,
        embedJSON: String,
        rawDebug: String,
        mode: GitHubWatchMode
    ) {
        self.releaseIdentifier = releaseIdentifier
        self.displayVersion = displayVersion
        self.title = title
        self.author = author
        self.date = date
        self.url = url
        self.summary = summary
        self.embedJSON = embedJSON
        self.rawDebug = rawDebug
        self.mode = mode
    }
}

public struct GitHubService: Sendable {
    private let session: URLSession
    private let formatter: EmbedFormatter

    public init(session: URLSession = .shared, formatter: EmbedFormatter = EmbedFormatter()) {
        self.session = session
        self.formatter = formatter
    }

    public func fetchLatest(owner: String, repo: String, mode: GitHubWatchMode) async throws -> GitHubUpdateInfo {
        let trimmedOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRepo = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOwner.isEmpty, !trimmedRepo.isEmpty else {
            throw GitHubServiceError.invalidRepo("\(owner)/\(repo)")
        }

        switch mode {
        case .releases:
            return try await fetchLatestRelease(owner: trimmedOwner, repo: trimmedRepo)
        case .commits(let branch):
            return try await fetchLatestCommit(owner: trimmedOwner, repo: trimmedRepo, branch: branch)
        }
    }

    private func fetchLatestRelease(owner: String, repo: String) async throws -> GitHubUpdateInfo {
        let urlString = "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"
        guard let url = URL(string: urlString) else { throw GitHubServiceError.invalidURL }

        let (data, response) = try await session.data(for: makeRequest(url: url))
        try validateHTTP(response)

        let rawJSON = String(data: data, encoding: .utf8) ?? ""
        let decoded = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)

        let tag = decoded.tagName
        let title = decoded.name?.isEmpty == false ? decoded.name! : tag
        let body = (decoded.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let date = formatISODate(decoded.publishedAt ?? decoded.createdAt ?? "")
        let author = decoded.author?.login ?? "\(owner)/\(repo)"

        let notes = ReleaseNotes(
            title: title,
            author: "\(owner)/\(repo)",
            url: decoded.htmlURL ?? "https://github.com/\(owner)/\(repo)/releases",
            version: tag,
            date: date,
            sections: makeReleaseSections(body: body),
            thumbnailURL: "https://github.com/\(owner).png",
            color: 0x24292E
        )

        let embed = formatter.format(releaseNotes: notes)

        return GitHubUpdateInfo(
            releaseIdentifier: "release:\(tag)",
            displayVersion: tag,
            title: title,
            author: author,
            date: date,
            url: notes.url,
            summary: body,
            embedJSON: embed,
            rawDebug: "GitHub releases/latest:\n\(rawJSON)",
            mode: .releases
        )
    }

    private func fetchLatestCommit(owner: String, repo: String, branch: String) async throws -> GitHubUpdateInfo {
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents(string: "https://api.github.com/repos/\(owner)/\(repo)/commits")
        var items: [URLQueryItem] = [URLQueryItem(name: "per_page", value: "1")]
        if !trimmedBranch.isEmpty {
            items.append(URLQueryItem(name: "sha", value: trimmedBranch))
        }
        components?.queryItems = items
        guard let url = components?.url else { throw GitHubServiceError.invalidURL }

        let (data, response) = try await session.data(for: makeRequest(url: url))
        try validateHTTP(response)

        let rawJSON = String(data: data, encoding: .utf8) ?? ""
        let decoded = try JSONDecoder().decode([GitHubCommitResponse].self, from: data)
        guard let commit = decoded.first else {
            throw GitHubServiceError.noCommits
        }

        let sha = commit.sha
        let shortSha = String(sha.prefix(7))
        let message = commit.commit.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? message
        let rest = message.dropFirst(firstLine.count).trimmingCharacters(in: .whitespacesAndNewlines)
        let author = commit.commit.author?.name ?? commit.author?.login ?? "Unknown"
        let date = formatISODate(commit.commit.author?.date ?? "")
        let branchLabel = trimmedBranch.isEmpty ? "default" : trimmedBranch

        let notes = ReleaseNotes(
            title: firstLine,
            author: "\(owner)/\(repo) (\(branchLabel))",
            url: commit.htmlURL,
            version: shortSha,
            date: date,
            sections: makeCommitSections(body: rest, author: author),
            thumbnailURL: "https://github.com/\(owner).png",
            color: 0x24292E
        )

        let embed = formatter.format(releaseNotes: notes)

        return GitHubUpdateInfo(
            releaseIdentifier: "commit:\(sha)",
            displayVersion: shortSha,
            title: firstLine,
            author: author,
            date: date,
            url: commit.htmlURL,
            summary: rest,
            embedJSON: embed,
            rawDebug: "GitHub commits[0]:\n\(rawJSON)",
            mode: .commits(branch: trimmedBranch)
        )
    }

    private func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("SwiftBot-Patchy", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw GitHubServiceError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw GitHubServiceError.httpError(statusCode: http.statusCode)
        }
    }

    private func makeReleaseSections(body: String) -> [ReleaseSection] {
        guard !body.isEmpty else {
            return [ReleaseSection(title: "Release Notes", bullets: [Bullet(text: "No description provided.")])]
        }
        let bullets = bulletize(body: body)
        return [ReleaseSection(title: "Release Notes", bullets: bullets)]
    }

    private func makeCommitSections(body: String, author: String) -> [ReleaseSection] {
        var sections: [ReleaseSection] = [
            ReleaseSection(title: "Author", bullets: [Bullet(text: author)])
        ]
        if !body.isEmpty {
            sections.append(ReleaseSection(title: "Details", bullets: bulletize(body: body)))
        }
        return sections
    }

    private func bulletize(body: String) -> [Bullet] {
        let lines = body
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            return [Bullet(text: "No details available.")]
        }
        return lines.prefix(10).map { line in
            let stripped = line.hasPrefix("- ") ? String(line.dropFirst(2)) : (line.hasPrefix("* ") ? String(line.dropFirst(2)) : line)
            let truncated = stripped.count > 200 ? String(stripped.prefix(197)) + "..." : stripped
            return Bullet(text: truncated)
        }
    }

    private func formatISODate(_ iso: String) -> String {
        guard !iso.isEmpty else { return "-" }
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: iso) {
            let out = DateFormatter()
            out.locale = Locale(identifier: "en_US_POSIX")
            out.dateFormat = "MMMM dd, yyyy"
            return out.string(from: date)
        }
        return iso
    }
}

public enum GitHubServiceError: LocalizedError, Sendable {
    case invalidRepo(String)
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case noCommits

    public var errorDescription: String? {
        switch self {
        case .invalidRepo(let value):
            return "Invalid GitHub repo identifier: '\(value)'. Use 'owner/repo'."
        case .invalidURL:
            return "Failed to build GitHub API URL."
        case .invalidResponse:
            return "GitHub API returned an invalid response object."
        case .httpError(let code):
            switch code {
            case 403: return "GitHub API rate limit reached. Try again later."
            case 404: return "GitHub repository or resource not found."
            default:  return "GitHub API request failed with HTTP \(code)."
            }
        case .noCommits:
            return "GitHub repository has no commits on the selected branch."
        }
    }
}

private struct GitHubReleaseResponse: Codable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: String?
    let publishedAt: String?
    let createdAt: String?
    let author: Author?

    struct Author: Codable {
        let login: String
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case createdAt = "created_at"
        case author
    }
}

private struct GitHubCommitResponse: Codable {
    let sha: String
    let htmlURL: String
    let commit: Commit
    let author: Author?

    struct Commit: Codable {
        let message: String
        let author: CommitAuthor?
    }

    struct CommitAuthor: Codable {
        let name: String?
        let email: String?
        let date: String?
    }

    struct Author: Codable {
        let login: String
    }

    enum CodingKeys: String, CodingKey {
        case sha
        case htmlURL = "html_url"
        case commit
        case author
    }
}
