import Foundation

struct PublicArticle: Decodable, Identifiable, Equatable {
    struct Metadata: Decodable, Equatable {
        let image: String?
        let description: String?
        let estimatedMinutes: Int?
        let wordCount: Int?
    }

    let id: String
    let title: String
    let created: String
    let modified: String
    let content: String
    let metadata: Metadata

    var coverAsset: PublicArticleCoverAsset? { metadata.coverAsset }

    var publishedDate: Date? { Self.parseDate(created) }
    var updatedDate: Date? { Self.parseDate(modified) }

    var markdownBody: String {
        content.replacingOccurrences(
            of: #"^\s*# [^\r\n]*(?:\r?\n)+"#,
            with: "",
            options: .regularExpression
        )
    }

    var descriptionText: String? {
        guard let description = metadata.description?.trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty else { return nil }
        return description
    }

    private static func parseDate(_ value: String) -> Date? {
        fractionalDateFormatter.date(from: value) ?? dateFormatter.date(from: value)
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

enum PublicArticleCoverAsset: String, Equatable {
    case city = "/images/assets/city.jpg"
    case art = "/images/assets/art.png"
    case project = "/images/assets/project.jpg"
    case abstract = "/images/assets/abstract.jpg"

    var resourceName: String {
        switch self {
        case .city: "city"
        case .art: "art"
        case .project: "project"
        case .abstract: "abstract"
        }
    }

    var fileExtension: String {
        switch self {
        case .city, .project, .abstract: "jpg"
        case .art: "png"
        }
    }
}

private extension PublicArticle.Metadata {
    var coverAsset: PublicArticleCoverAsset? {
        guard let image = image?.trimmingCharacters(in: .whitespacesAndNewlines), !image.isEmpty else {
            return nil
        }
        return PublicArticleCoverAsset(rawValue: image)
    }
}

struct PublicArticleCatalog: Decodable {
    let publishedArticles: [PublicArticle]
    let fallbackArticles: [PublicArticle]

    static func load(from data: Data) throws -> PublicArticleCatalog {
        try JSONDecoder().decode(PublicArticleCatalog.self, from: data)
    }

    static func bundled() throws -> PublicArticleCatalog {
        guard let url = Bundle.module.url(forResource: "public-articles", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try load(from: Data(contentsOf: url))
    }

    var articles: [PublicArticle] {
        publishedArticles.compactMap { article(for: $0.id) }
    }

    func article(for rawID: String) -> PublicArticle? {
        let id = Self.normalizedID(rawID)
        guard !id.isEmpty, id != "featured", id != "main" else { return nil }

        guard let published = publishedArticles.first(where: { Self.normalizedID($0.id) == id }) else {
            return nil
        }
        guard let fallback = fallbackArticles.first(where: { Self.normalizedID($0.id) == id }) else {
            return published
        }

        let content = published.content
        let wordCount = published.metadata.wordCount ?? 0
        let fallbackWordCount = fallback.metadata.wordCount ?? 0
        let unfinished = content.range(of: #"coming soon|TODO|placeholder"#, options: [.regularExpression, .caseInsensitive]) != nil
            || (wordCount > 0 && wordCount <= 20 && fallbackWordCount > wordCount)
        return unfinished ? fallback : published
    }

    static func normalizedID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\.md$"#, with: "", options: .regularExpression)
    }
}

enum PublicArticleMarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)
    case quote(String)
    case code(String)
    case divider
}

enum PublicArticleMarkdown {
    static func blocks(from markdown: String) -> [PublicArticleMarkdownBlock] {
        var blocks: [PublicArticleMarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String] = []
        var inCodeFence = false

        func flushParagraph() {
            let text = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph.removeAll()
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                flushParagraph()
                if inCodeFence {
                    blocks.append(.code(code.joined(separator: "\n")))
                    code.removeAll()
                }
                inCodeFence.toggle()
                continue
            }
            if inCodeFence {
                code.append(rawLine)
                continue
            }
            if line.isEmpty {
                flushParagraph()
            } else if let heading = heading(line) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
            } else if line.hasPrefix(">") {
                flushParagraph()
                blocks.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else if let item = bullet(line) {
                flushParagraph()
                blocks.append(.bullet(item))
            } else if ["---", "***", "___"].contains(line) {
                flushParagraph()
                blocks.append(.divider)
            } else {
                paragraph.append(line)
            }
        }

        flushParagraph()
        if inCodeFence { blocks.append(.code(code.joined(separator: "\n"))) }
        return blocks
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let prefix = line.prefix(while: { $0 == "#" })
        guard !prefix.isEmpty, prefix.count <= 6,
              line.dropFirst(prefix.count).first == " " else { return nil }
        return (prefix.count, String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
    }

    private static func bullet(_ line: String) -> String? {
        guard let first = line.first, ["-", "*", "+"].contains(first),
              line.dropFirst().first == " " else { return nil }
        return String(line.dropFirst(2))
    }
}
