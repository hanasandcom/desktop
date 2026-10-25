import Foundation

struct NativeShareWorkspaceSearchFile: Equatable, Identifiable {
    let id: String
    let name: String
    let path: String
    let content: String

    var isSearchable: Bool { Self.isSearchablePath(path) }

    func validate() throws {
        guard NativeShareWorkspaceSearchSafety.isIdentifier(id),
              !name.isEmpty, name.utf8.count <= NativeShareWorkspaceSearchLimits.fieldBytes,
              NativeShareWorkspaceSearchSafety.isSafeRelativePath(path),
              content.utf8.count <= NativeShareWorkspaceSearchLimits.maximumPerFileContentBytes else {
            throw NativeShareWorkspaceSearchError.invalidFile
        }
    }

    static func isSearchablePath(_ path: String) -> Bool {
        let component = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = component.lastIndex(of: ".") else { return true }
        let ext = String(component[component.index(after: dot)...]).lowercased()
        return NativeShareWorkspaceSearchLimits.searchableExtensions.contains(ext)
    }
}

struct NativeShareWorkspaceSearchOptions: Equatable {
    var caseSensitive = false
    var wholeWord = false
    var regex = false
    var include = ""
    var exclude = "node_modules,.next,dist,build"
}

struct NativeShareWorkspaceSearchMatch: Equatable, Identifiable {
    let id: String
    let fileID: String
    let fileName: String
    let path: String
    let line: Int
    let column: Int
    let endColumn: Int
    let preview: String
}

struct NativeShareWorkspaceSearchFileMatches: Equatable, Identifiable {
    let file: NativeShareWorkspaceSearchFile
    let matches: [NativeShareWorkspaceSearchMatch]

    var id: String { file.id }
}

struct NativeShareWorkspaceSearchResponse: Equatable {
    let filesScanned: Int
    let totalMatches: Int
    let groups: [NativeShareWorkspaceSearchFileMatches]
    let isTruncated: Bool
}

struct NativeShareWorkspaceReplacementPlan: Equatable, Identifiable {
    let fileID: String
    let path: String
    let originalContent: String
    let replacementContent: String
    let matchCount: Int

    var id: String { fileID }
}

enum NativeShareWorkspaceSearchError: LocalizedError, Equatable {
    case invalidFile
    case invalidQuery
    case invalidPattern
    case invalidReplacement
    case tooManyMatches
    case workspaceTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidFile: "The workspace contains a file path or content that cannot be searched safely."
        case .invalidQuery: "Enter a search query."
        case .invalidPattern: "The search expression is not valid."
        case .invalidReplacement: "The replacement plan could not be created safely."
        case .tooManyMatches: "The search has more matches than the supported limit. Narrow the query before replacing files."
        case .workspaceTooLarge: "This workspace exceeds the supported search size."
        }
    }
}

enum NativeShareWorkspaceSearchLimits {
    static let maximumFiles = 3_000
    static let maximumTotalContentBytes = 64 * 1024 * 1024
    static let maximumMatches = 10_000
    static let maximumPerFileContentBytes = 2 * 1024 * 1024
    static let fieldBytes = 4_096
    static let pathBytes = 1_024
    static let identifierBytes = 200
    static let previewCharacters = 500

    static let searchableExtensions: Set<String> = [
        "c", "cc", "cpp", "cs", "css", "go", "html", "java", "js", "json", "jsx", "kt", "md", "mjs",
        "py", "rb", "rs", "scss", "sh", "sql", "swift", "toml", "ts", "tsx", "txt", "xml", "yaml", "yml",
    ]
}

enum NativeShareWorkspaceSearchSafety {
    static func isIdentifier(_ value: String) -> Bool {
        value.utf8.count <= NativeShareWorkspaceSearchLimits.identifierBytes
            && value.range(of: "^[A-Za-z0-9._~-]{1,200}$", options: .regularExpression) != nil
    }

    static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= NativeShareWorkspaceSearchLimits.pathBytes,
              !value.hasPrefix("/"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        return !value.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }
}

enum NativeShareWorkspaceSearch {
    static func shouldSearch(_ file: NativeShareWorkspaceSearchFile,
                             options: NativeShareWorkspaceSearchOptions) -> Bool {
        file.isSearchable && matchesPathFilters(file.path, include: options.include, exclude: options.exclude)
    }

    static func search(files: [NativeShareWorkspaceSearchFile], query: String,
                       options: NativeShareWorkspaceSearchOptions = .init(),
                       maximumMatches: Int = NativeShareWorkspaceSearchLimits.maximumMatches) throws -> NativeShareWorkspaceSearchResponse {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty else { throw NativeShareWorkspaceSearchError.invalidQuery }
        guard maximumMatches > 0, files.count <= NativeShareWorkspaceSearchLimits.maximumFiles else {
            throw NativeShareWorkspaceSearchError.workspaceTooLarge
        }
        try validateWorkspace(files)
        let expression = try makeExpression(query: cleanQuery, options: options)
        let selected = files.filter { shouldSearch($0, options: options) }
        var totalBytes = 0
        for file in selected {
            totalBytes += file.content.utf8.count
            guard totalBytes <= NativeShareWorkspaceSearchLimits.maximumTotalContentBytes else {
                throw NativeShareWorkspaceSearchError.workspaceTooLarge
            }
        }

        var groups: [NativeShareWorkspaceSearchFileMatches] = []
        var totalMatches = 0
        var truncated = false
        for file in selected {
            let remainingIncludingProbe = maximumMatches - totalMatches + 1
            let found = try matches(in: file, expression: expression, maximumRemaining: remainingIncludingProbe)
            let remaining = maximumMatches - totalMatches
            if found.count > remaining {
                if remaining > 0 { groups.append(.init(file: file, matches: Array(found.prefix(remaining)))) }
                totalMatches = maximumMatches
                truncated = true
                break
            }
            if !found.isEmpty { groups.append(.init(file: file, matches: found)) }
            totalMatches += found.count
        }
        return NativeShareWorkspaceSearchResponse(filesScanned: selected.count, totalMatches: totalMatches,
                                                  groups: groups, isTruncated: truncated)
    }

    static func replacementPlans(files: [NativeShareWorkspaceSearchFile], query: String, replacement: String,
                                 options: NativeShareWorkspaceSearchOptions = .init(),
                                 maximumMatches: Int = NativeShareWorkspaceSearchLimits.maximumMatches) throws -> [NativeShareWorkspaceReplacementPlan] {
        guard replacement.utf8.count <= NativeShareWorkspaceSearchLimits.maximumPerFileContentBytes else {
            throw NativeShareWorkspaceSearchError.invalidReplacement
        }
        let response = try search(files: files, query: query, options: options, maximumMatches: maximumMatches)
        guard !response.isTruncated else { throw NativeShareWorkspaceSearchError.tooManyMatches }
        let expression = try makeExpression(query: query.trimmingCharacters(in: .whitespacesAndNewlines), options: options)
        return try response.groups.compactMap { group in
            guard let file = files.first(where: { $0.id == group.file.id }) else {
                throw NativeShareWorkspaceSearchError.invalidReplacement
            }
            let changed = replace(file.content, expression: expression, template: replacement)
            guard changed.content.utf8.count <= NativeShareWorkspaceSearchLimits.maximumPerFileContentBytes else {
                throw NativeShareWorkspaceSearchError.invalidReplacement
            }
            guard changed.content != file.content else { return nil }
            return NativeShareWorkspaceReplacementPlan(fileID: file.id, path: file.path,
                originalContent: file.content, replacementContent: changed.content, matchCount: changed.matchCount)
        }
    }

    private static func validateWorkspace(_ files: [NativeShareWorkspaceSearchFile]) throws {
        var seenIDs = Set<String>()
        var seenPaths = Set<String>()
        var totalBytes = 0
        for file in files {
            try file.validate()
            guard seenIDs.insert(file.id).inserted, seenPaths.insert(file.path).inserted else {
                throw NativeShareWorkspaceSearchError.invalidFile
            }
            totalBytes += file.content.utf8.count
            guard totalBytes <= NativeShareWorkspaceSearchLimits.maximumTotalContentBytes else {
                throw NativeShareWorkspaceSearchError.workspaceTooLarge
            }
        }
    }

    private static func makeExpression(query: String, options: NativeShareWorkspaceSearchOptions) throws -> NSRegularExpression {
        guard !query.isEmpty else { throw NativeShareWorkspaceSearchError.invalidQuery }
        let source = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
        let bounded = options.wholeWord ? "\\b\(source)\\b" : source
        let flags: NSRegularExpression.Options = options.caseSensitive ? [] : [.caseInsensitive]
        do { return try NSRegularExpression(pattern: bounded, options: flags) }
        catch { throw NativeShareWorkspaceSearchError.invalidPattern }
    }

    private static func matches(in file: NativeShareWorkspaceSearchFile, expression: NSRegularExpression,
                                maximumRemaining: Int) throws -> [NativeShareWorkspaceSearchMatch] {
        guard maximumRemaining > 0 else { return [] }
        var results: [NativeShareWorkspaceSearchMatch] = []
        let lines = file.content.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
        }
        for (index, line) in lines.enumerated() {
            let nsLine = line as NSString
            let lineRange = NSRange(location: 0, length: nsLine.length)
            let matches = expression.matches(in: line, range: lineRange)
            for match in matches {
                guard results.count < maximumRemaining else { return results }
                let column = match.range.location + 1
                let endColumn = max(column, match.range.location + match.range.length)
                results.append(NativeShareWorkspaceSearchMatch(
                    id: "\(file.id):\(index + 1):\(column):\(results.count)", fileID: file.id,
                    fileName: file.name, path: file.path, line: index + 1, column: column,
                    endColumn: endColumn, preview: preview(line, matching: match.range)
                ))
            }
        }
        return results
    }

    private static func replace(_ content: String, expression: NSRegularExpression, template: String) -> (content: String, matchCount: Int) {
        let source = content as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        let matches = expression.matches(in: content, range: fullRange)
        guard !matches.isEmpty else { return (content, 0) }
        var result = ""
        var cursor = 0
        for match in matches {
            let matchRange = match.range
            guard matchRange.location >= cursor, NSMaxRange(matchRange) <= source.length else { continue }
            result += source.substring(with: NSRange(location: cursor, length: matchRange.location - cursor))
            result += expandReplacement(template, match: match, source: source, expression: expression)
            cursor = NSMaxRange(matchRange)
        }
        result += source.substring(from: cursor)
        return (result, matches.count)
    }

    private static func expandReplacement(_ template: String, match: NSTextCheckingResult,
                                          source: NSString, expression: NSRegularExpression) -> String {
        var output = ""
        var index = template.startIndex
        while index < template.endIndex {
            let character = template[index]
            guard character == "$" else { output.append(character); index = template.index(after: index); continue }
            let next = template.index(after: index)
            guard next < template.endIndex else { output.append("$"); break }
            let marker = template[next]
            switch marker {
            case "$": output.append("$"); index = template.index(after: next)
            case "&": output += substring(match.range, from: source); index = template.index(after: next)
            case "`": output += source.substring(to: match.range.location); index = template.index(after: next)
            case "'": output += source.substring(from: NSMaxRange(match.range)); index = template.index(after: next)
            case "<":
                if let close = template[next...].firstIndex(of: ">"), close > next {
                    let name = String(template[template.index(after: next)..<close])
                    let range = match.range(withName: name)
                    if range.location != NSNotFound { output += substring(range, from: source) }
                    index = template.index(after: close)
                } else { output.append("$"); index = next }
            default:
                guard marker.isNumber, let first = marker.wholeNumberValue else {
                    output.append("$"); index = next; continue
                }
                var digits = String(first)
                var end = template.index(after: next)
                if end < template.endIndex, template[end].isNumber, let second = template[end].wholeNumberValue {
                    let twoDigit = first * 10 + second
                    if twoDigit > 0 && twoDigit <= match.numberOfRanges - 1 {
                        digits = String(twoDigit)
                        end = template.index(after: end)
                    }
                }
                let group = Int(digits) ?? 0
                if group < match.numberOfRanges { output += substring(match.range(at: group), from: source) }
                else { output += "$\(digits)" }
                index = end
            }
        }
        return output
    }

    private static func substring(_ range: NSRange, from source: NSString) -> String {
        guard range.location != NSNotFound, range.location >= 0, NSMaxRange(range) <= source.length else { return "" }
        return source.substring(with: range)
    }

    private static func preview(_ line: String, matching matchRange: NSRange) -> String {
        let limit = NativeShareWorkspaceSearchLimits.previewCharacters
        guard line.count > limit else { return line.trimmingCharacters(in: .whitespacesAndNewlines) }

        let source = line as NSString
        let boundedLocation = min(max(matchRange.location, 0), source.length)
        let boundedLength = min(max(matchRange.length, 0), source.length - boundedLocation)
        let composedMatch = source.rangeOfComposedCharacterSequences(
            for: NSRange(location: boundedLocation, length: boundedLength)
        )
        let utf16 = line.utf16
        let startUTF16 = utf16.index(utf16.startIndex, offsetBy: composedMatch.location)
        let endUTF16 = utf16.index(startUTF16, offsetBy: composedMatch.length)
        guard let matchStart = String.Index(startUTF16, within: line),
              let matchEnd = String.Index(endUTF16, within: line) else {
            return String(line.prefix(limit)) + "…"
        }

        let matchStartOffset = line.distance(from: line.startIndex, to: matchStart)
        let matchEndOffset = line.distance(from: line.startIndex, to: matchEnd)
        let matchLength = matchEndOffset - matchStartOffset
        let windowStartOffset: Int
        let windowEndOffset: Int
        if matchLength >= limit {
            windowStartOffset = matchStartOffset
            windowEndOffset = min(line.count, matchStartOffset + limit)
        } else {
            let availableContext = limit - matchLength
            let beforeCount = min(matchStartOffset, availableContext / 2)
            let afterCount = min(line.count - matchEndOffset, availableContext - beforeCount)
            let adjustedBeforeCount = min(matchStartOffset, availableContext - afterCount)
            windowStartOffset = matchStartOffset - adjustedBeforeCount
            windowEndOffset = matchEndOffset + afterCount
        }

        let windowStart = line.index(line.startIndex, offsetBy: windowStartOffset)
        let windowEnd = line.index(line.startIndex, offsetBy: windowEndOffset)
        let snippet = String(line[windowStart..<windowEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixMarker = windowStartOffset > 0 ? "…" : ""
        let suffixMarker = windowEndOffset < line.count ? "…" : ""
        return prefixMarker + snippet + suffixMarker
    }

    private static func matchesPathFilters(_ path: String, include: String, exclude: String) -> Bool {
        let includes = splitFilters(include)
        let excludes = splitFilters(exclude)
        let included = includes.isEmpty || includes.contains { globLikeMatch(path, filter: $0) }
        return included && !excludes.contains { globLikeMatch(path, filter: $0) }
    }

    private static func splitFilters(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func globLikeMatch(_ path: String, filter: String) -> Bool {
        guard filter.utf8.count <= NativeShareWorkspaceSearchLimits.pathBytes else { return false }
        guard filter.contains("*") else {
            return path.range(of: filter, options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) != nil
        }
        let escaped = filter.split(separator: "*", omittingEmptySubsequences: false)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: ".*")
        return (try? NSRegularExpression(pattern: "^\(escaped)$", options: [.caseInsensitive]))?
            .firstMatch(in: path, range: NSRange(location: 0, length: (path as NSString).length)) != nil
    }
}
