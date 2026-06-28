import Foundation

public struct ReleaseNotes: Sendable, Codable, Hashable {
    public let title: String
    public let author: String
    public let url: String
    public let version: String
    public let date: String
    public let sections: [ReleaseSection]
    public let thumbnailURL: String
    public let color: Int

    public init(
        title: String,
        author: String,
        url: String,
        version: String,
        date: String,
        sections: [ReleaseSection],
        thumbnailURL: String,
        color: Int
    ) {
        self.title = title
        self.author = author
        self.url = url
        self.version = version
        self.date = date
        self.sections = sections
        self.thumbnailURL = thumbnailURL
        self.color = color
    }
}

public struct ReleaseSection: Sendable, Codable, Hashable {
    public let title: String
    public let bullets: [Bullet]

    public init(title: String, bullets: [Bullet]) {
        self.title = title
        self.bullets = bullets
    }
}

public struct Bullet: Sendable, Codable, Hashable {
    public let text: String
    public let subBullets: [String]

    public init(text: String, subBullets: [String] = []) {
        self.text = text
        self.subBullets = subBullets
    }
}
