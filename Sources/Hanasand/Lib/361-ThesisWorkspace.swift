import Foundation

/// The website/mobile Thesis workbook is serialized inside the existing Markdown
/// document. Keep this representation deliberately small so unknown sheet metadata
/// and all non-table Markdown remain untouched during native edits.
struct ThesisSheet: Identifiable {
    var id: String { metadata["id"] as? String ?? metadata["name"] as? String ?? "Overview" }
    var name: String { metadata["name"] as? String ?? id }
    var title: String { metadata["title"] as? String ?? "# \(name)" }
    var body: String
    var metadata: [String: Any]
}

struct ThesisTable: Identifiable {
    let start: Int
    let end: Int
    var cells: [[String]]
    var widths: [Double]
    var heights: [Double]
    var id: Int { start }

    var kind: Kind {
        let headers = cells.first?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? []
        if headers.count >= 3, headers.first == "week", headers.last == "total" { return .timetable }
        if headers.contains(where: { ["task", "goal", "item", "milestone"].contains($0) }) { return .plan }
        return .table
    }

    enum Kind: Equatable { case table, timetable, plan }
}

enum ThesisWorkspaceCodec {
    private static let defaults = ["Overview", "Timetable", "Plan", "Research"]
    private static let header = try! NSRegularExpression(pattern: "^<!-- thesis-workspace:2 (.*?) -->\\n")

    static func sheets(title: String, body: String) -> [ThesisSheet] {
        let ns = body as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let match = header.firstMatch(in: body, range: range),
           let encodedRange = Range(match.range(at: 1), in: body),
           let json = String(body[encodedRange]).removingPercentEncoding,
           let bytes = json.data(using: .utf8),
           let records = (try? JSONSerialization.jsonObject(with: bytes)) as? [[String: Any]], !records.isEmpty {
            var offset = match.range.length
            var parsed: [ThesisSheet] = []
            for record in records {
                guard let length = record["length"] as? Int, length >= 0, length <= ns.length - offset else { return fallback(title: title, body: body) }
                let content = ns.substring(with: NSRange(location: offset, length: length))
                var metadata = record
                metadata.removeValue(forKey: "length")
                parsed.append(ThesisSheet(body: content, metadata: metadata))
                offset += length + 2
            }
            if offset - 2 == ns.length { return parsed }
        }
        if let legacy = legacySheets(title: title, body: body) { return legacy }
        return fallback(title: title, body: body)
    }

    static func write(_ sheets: [ThesisSheet]) -> String {
        let records: [[String: Any]] = sheets.map { sheet in
            var value = sheet.metadata
            value["id"] = sheet.id
            value["name"] = sheet.name
            value["title"] = sheet.title
            value["length"] = (sheet.body as NSString).length
            return value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: records, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return sheets.map(\.body).joined(separator: "\n\n") }
        let escaped = json.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()")))?.replacingOccurrences(of: "-", with: "%2D") ?? ""
        return "<!-- thesis-workspace:2 \(escaped) -->\n" + sheets.map(\.body).joined(separator: "\n\n")
    }

    static func tables(in body: String) -> [ThesisTable] {
        let lines = body.components(separatedBy: "\n")
        var output: [ThesisTable] = []
        var offset = 0
        var fence: Character?
        var index = 0
        while index + 1 < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let mark = trimmed.first!
                fence = fence == nil ? mark : (fence == mark ? nil : fence)
                offset += (line as NSString).length + 1
                index += 1
                continue
            }
            if fence == nil, isPipeRow(line), isDelimiter(lines[index + 1]) {
                let start = offset
                var rows: [[String]] = [splitRow(line)]
                index += 2
                offset += (lines[index - 2] as NSString).length + 1 + (lines[index - 1] as NSString).length + 1
                while index < lines.count, isPipeRow(lines[index]) {
                    rows.append(splitRow(lines[index]))
                    offset += (lines[index] as NSString).length + 1
                    index += 1
                }
                var widths: [Double] = [], heights: [Double] = []
                if index < lines.count, lines[index].hasPrefix("<!-- thesis-table:"), lines[index].hasSuffix(" -->") {
                    let raw = String(lines[index].dropFirst("<!-- thesis-table:".count).dropLast(" -->".count))
                    if let data = raw.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                        widths = object["widths"] as? [Double] ?? []
                        heights = object["heights"] as? [Double] ?? []
                    }
                    offset += (lines[index] as NSString).length
                    if index + 1 < lines.count { offset += 1 }
                    index += 1
                }
                let cols = max(1, rows.map(\.count).max() ?? 1)
                rows = rows.map { row in row + Array(repeating: "", count: max(0, cols - row.count)) }
                output.append(ThesisTable(start: start, end: offset, cells: rows, widths: widths, heights: heights))
                continue
            }
            offset += (line as NSString).length + (index + 1 < lines.count ? 1 : 0)
            index += 1
        }
        return output
    }

    static func replacing(_ table: ThesisTable, in body: String, with cells: [[String]]) -> String {
        let normalized = cells.map { row in row + Array(repeating: "", count: max(0, (cells.first?.count ?? 1) - row.count)) }
        let markdown = normalized.enumerated().map { row, cells in
            "| " + cells.map(escape).joined(separator: " | ") + " |" + (row == 0 ? "\n| " + cells.map { _ in "---" }.joined(separator: " | ") + " |" : "")
        }.joined(separator: "\n")
        let metadata = "\n<!-- thesis-table:\(jsonSizes(widths: table.widths, heights: table.heights)) -->\n"
        let ns = body as NSString
        guard table.start >= 0, table.end >= table.start, table.end <= ns.length else { return body }
        return ns.replacingCharacters(in: NSRange(location: table.start, length: table.end - table.start), with: markdown + metadata)
    }

    static func appendingTable(to body: String, headers: [String], rowCount: Int = 2) -> String {
        let rows = [headers] + (1..<max(1, rowCount)).map { _ in Array(repeating: "", count: headers.count) }
        let rendered = rows.enumerated().map { index, row in
            "| " + row.map(escape).joined(separator: " | ") + " |" + (index == 0 ? "\n| " + row.map { _ in "---" }.joined(separator: " | ") + " |" : "")
        }.joined(separator: "\n")
        return body + (body.isEmpty ? "" : "\n\n") + rendered + "\n<!-- thesis-table:{\"widths\":[],\"heights\":[]} -->\n"
    }

    private static func fallback(title: String, body: String) -> [ThesisSheet] {
        defaults.enumerated().map { index, name in
            ThesisSheet(body: index == 0 ? body : "", metadata: ["id": name, "name": name, "title": index == 0 ? title : "# \(name)"])
        }
    }
    private static func legacySheets(title: String, body: String) -> [ThesisSheet]? {
        let pattern = try! NSRegularExpression(pattern: "^<!-- thesis-sheet:(Overview|Timetable|Plan|Research) title:(.*?) -->\\n", options: [.anchorsMatchLines])
        let ns = body as NSString
        let matches = pattern.matches(in: body, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        var markers: [(name: String, title: String, start: Int, end: Int)] = []
        var fence: Character?
        var lineStart = 0
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = trimmed.first!
                fence = fence == nil ? marker : (fence == marker ? nil : fence)
            } else if fence == nil, let match = matches.first(where: { $0.range.location == lineStart }),
                      let nameRange = Range(match.range(at: 1), in: body), let titleRange = Range(match.range(at: 2), in: body),
                      let decodedTitle = String(body[titleRange]).removingPercentEncoding {
                markers.append((String(body[nameRange]), decodedTitle, match.range.location, NSMaxRange(match.range)))
            }
            lineStart += (line as NSString).length + 1
        }
        guard let first = markers.first else { return nil }
        var result = defaults.map { name in ThesisSheet(body: "", metadata: ["id": name, "name": name, "title": "# \(name)"]) }
        result[0].body = ns.substring(to: first.start).replacingOccurrences(of: "\\n\\n$", with: "", options: .regularExpression)
        for index in markers.indices {
            let marker = markers[index]
            let end = index + 1 < markers.count ? markers[index + 1].start : ns.length
            var content = ns.substring(with: NSRange(location: marker.end, length: max(0, end - marker.end)))
            if index + 1 < markers.count { content = content.replacingOccurrences(of: "\\n\\n$", with: "", options: .regularExpression) }
            guard let slot = defaults.firstIndex(of: marker.name) else { continue }
            result[slot] = ThesisSheet(body: content, metadata: ["id": marker.name, "name": marker.name, "title": marker.title])
        }
        return result
    }
    private static func isPipeRow(_ line: String) -> Bool { line.contains("|") }
    private static func isDelimiter(_ line: String) -> Bool {
        let cells = splitRow(line)
        return !cells.isEmpty && cells.allSatisfy { $0.trimmingCharacters(in: .whitespaces).range(of: "^:?-{3,}:?$", options: .regularExpression) != nil }
    }
    private static func splitRow(_ line: String) -> [String] {
        var cells: [String] = [], current = "", escaped = false
        for character in line {
            if character == "|", !escaped { cells.append(decode(current.trimmingCharacters(in: .whitespaces))); current = "" }
            else { current.append(character) }
            if character == "\\" { escaped.toggle() } else { escaped = false }
        }
        if !current.isEmpty { cells.append(decode(current.trimmingCharacters(in: .whitespaces))) }
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("|"), cells.first == "" { cells.removeFirst() }
        if line.trimmingCharacters(in: .whitespaces).hasSuffix("|"), cells.last == "" { cells.removeLast() }
        return cells
    }
    private static func decode(_ value: String) -> String {
        value.replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "\\|", with: "|").replacingOccurrences(of: "&#124;", with: "|")
            .replacingOccurrences(of: "&#60;", with: "<").replacingOccurrences(of: "&#62;", with: ">")
            .replacingOccurrences(of: "&#92;", with: "\\").replacingOccurrences(of: "&amp;", with: "&")
    }
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\\", with: "&#92;")
            .replacingOccurrences(of: "|", with: "&#124;").replacingOccurrences(of: "<", with: "&#60;")
            .replacingOccurrences(of: ">", with: "&#62;").replacingOccurrences(of: "\n", with: "<br>")
    }
    private static func jsonSizes(widths: [Double], heights: [Double]) -> String {
        let object: [String: Any] = ["widths": widths, "heights": heights]
        guard let bytes = try? JSONSerialization.data(withJSONObject: object), let value = String(data: bytes, encoding: .utf8) else { return "{}" }
        return value
    }
}
