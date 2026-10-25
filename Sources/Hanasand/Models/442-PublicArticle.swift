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
    case orderedList(start: Int, items: [PublicArticleMarkdownListItem])
    case task(checked: Bool, text: String)
    case table(headers: [String], alignments: [PublicArticleTableAlignment], rows: [[String]])
    case quote(String)
    case code(String)
    case divider
}

struct PublicArticleMarkdownListItem: Equatable {
    let text: String
    let checked: Bool?
}

enum PublicArticleTableAlignment: Equatable {
    case leading
    case center
    case trailing
}

enum PublicArticleMarkdown {
    static func blocks(from markdown: String) -> [PublicArticleMarkdownBlock] {
        var blocks: [PublicArticleMarkdownBlock] = []
        var paragraph: [String] = []
        var orderedItems: [PublicArticleMarkdownListItem] = []
        var orderedStart = 1
        var code: [String] = []
        var inCodeFence = false

        func flushParagraph() {
            let text = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph.removeAll()
        }

        func flushOrderedList() {
            guard !orderedItems.isEmpty else { return }
            blocks.append(.orderedList(start: orderedStart, items: orderedItems))
            orderedItems.removeAll()
            orderedStart = 1
        }

        let lines = markdown.components(separatedBy: .newlines)
        var index = 0
        while index < lines.count {
            let rawLine = lines[index]
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                flushParagraph()
                flushOrderedList()
                if inCodeFence {
                    blocks.append(.code(code.joined(separator: "\n")))
                    code.removeAll()
                }
                inCodeFence.toggle()
                index += 1
                continue
            }
            if inCodeFence {
                code.append(rawLine)
                index += 1
                continue
            }
            if line.isEmpty {
                flushParagraph()
                index += 1
            } else if index + 1 < lines.count,
                      let header = tableCells(line),
                      let alignments = tableAlignments(lines[index + 1], columnCount: header.count) {
                flushParagraph()
                flushOrderedList()
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let rowLine = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !rowLine.isEmpty, let cells = tableCells(rowLine) else { break }
                    rows.append(normalizedTableRow(cells, columnCount: header.count))
                    index += 1
                }
                blocks.append(.table(headers: header, alignments: alignments, rows: rows))
            } else if let item = orderedItem(line) {
                flushParagraph()
                if orderedItems.isEmpty { orderedStart = item.number }
                if let task = taskItem(item.text) {
                    orderedItems.append(PublicArticleMarkdownListItem(text: task.text, checked: task.checked))
                } else {
                    orderedItems.append(PublicArticleMarkdownListItem(text: item.text, checked: nil))
                }
                index += 1
            } else if let heading = heading(line) {
                flushParagraph()
                flushOrderedList()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
            } else if line.hasPrefix(">") {
                flushParagraph()
                flushOrderedList()
                blocks.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
                index += 1
            } else if let item = bullet(line) {
                flushParagraph()
                flushOrderedList()
                if let task = taskItem(item) {
                    blocks.append(.task(checked: task.checked, text: task.text))
                } else {
                    blocks.append(.bullet(item))
                }
                index += 1
            } else if ["---", "***", "___"].contains(line) {
                flushParagraph()
                flushOrderedList()
                blocks.append(.divider)
                index += 1
            } else {
                paragraph.append(line)
                flushOrderedList()
                index += 1
            }
        }

        flushParagraph()
        flushOrderedList()
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

    private static func orderedItem(_ line: String) -> (number: Int, text: String)? {
        let digits = line.prefix(while: { $0 >= "0" && $0 <= "9" })
        guard !digits.isEmpty,
              let number = Int(digits),
              let separator = line.dropFirst(digits.count).first,
              separator == "." || separator == ")",
              line.dropFirst(digits.count + 1).first?.isWhitespace == true else {
            return nil
        }
        return (number, String(line.dropFirst(digits.count + 2)))
    }

    private static func taskItem(_ item: String) -> (checked: Bool, text: String)? {
        guard item.count >= 3, item.first == "[",
              let closingBracket = item.firstIndex(of: "]"),
              item.index(after: item.startIndex) == item.index(before: closingBracket),
              let marker = item[item.index(after: item.startIndex)].lowercased().first,
              marker == " " || marker == "x",
              closingBracket == item.index(before: item.endIndex) || item[item.index(after: closingBracket)].isWhitespace else {
            return nil
        }
        let suffix = item.index(after: closingBracket)
        let text = suffix < item.endIndex ? String(item[suffix...]).trimmingCharacters(in: .whitespaces) : ""
        return (marker == "x", text)
    }

    private static func tableCells(_ line: String) -> [String]? {
        let characters = Array(line)
        var cells: [String] = []
        var cell = ""
        var escaped = false
        var hasSeparator = false
        var trailingSeparator = false
        var codeDelimiterLength = 0
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "`", codeDelimiterLength > 0 || !escaped {
                var runLength = 1
                while index + runLength < characters.count, characters[index + runLength] == "`" {
                    runLength += 1
                }
                if codeDelimiterLength == 0 {
                    if hasMatchingBacktickRun(in: characters, from: index + runLength, length: runLength) {
                        codeDelimiterLength = runLength
                    }
                } else if codeDelimiterLength == runLength {
                    codeDelimiterLength = 0
                }
                cell.append(contentsOf: repeatElement("`", count: runLength))
                escaped = false
                trailingSeparator = false
                index += runLength
                continue
            }
            if character == "|", !escaped, codeDelimiterLength == 0 {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
                hasSeparator = true
                trailingSeparator = index == characters.count - 1
                escaped = false
                index += 1
                continue
            }
            cell.append(character)
            if codeDelimiterLength == 0, character == "\\" {
                escaped.toggle()
            } else {
                escaped = false
            }
            trailingSeparator = false
            index += 1
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        guard hasSeparator else { return nil }
        if line.first == "|", !cells.isEmpty { cells.removeFirst() }
        if trailingSeparator, !cells.isEmpty { cells.removeLast() }
        return cells
    }

    private static func hasMatchingBacktickRun(in characters: [Character], from startIndex: Int, length: Int) -> Bool {
        var index = startIndex
        while index < characters.count {
            guard characters[index] == "`" else {
                index += 1
                continue
            }
            var runLength = 1
            while index + runLength < characters.count, characters[index + runLength] == "`" {
                runLength += 1
            }
            if runLength == length { return true }
            index += runLength
        }
        return false
    }

    private static func tableAlignments(_ line: String, columnCount: Int) -> [PublicArticleTableAlignment]? {
        guard let cells = tableCells(line), cells.count == columnCount, columnCount > 0 else { return nil }
        var alignments: [PublicArticleTableAlignment] = []
        for cell in cells {
            let value = cell.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return nil }
            let leadingColon = value.first == ":"
            let trailingColon = value.last == ":"
            var dashStart = value.startIndex
            var dashEnd = value.endIndex
            if leadingColon { dashStart = value.index(after: dashStart) }
            if trailingColon { dashEnd = value.index(before: dashEnd) }
            let dashRange = value[dashStart..<dashEnd]
            guard !dashRange.isEmpty, dashRange.allSatisfy({ $0 == "-" }),
                  value.filter({ $0 == ":" }).count == (leadingColon ? 1 : 0) + (trailingColon ? 1 : 0) else { return nil }
            if leadingColon && trailingColon { alignments.append(.center) }
            else if trailingColon { alignments.append(.trailing) }
            else { alignments.append(.leading) }
        }
        return alignments
    }

    private static func normalizedTableRow(_ cells: [String], columnCount: Int) -> [String] {
        Array(cells.prefix(columnCount)) + Array(repeating: "", count: max(0, columnCount - cells.count))
    }
}
