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

struct ThesisActivity: Codable, Equatable, Identifiable {
    var id: String
    var date: String
    var hours: Double
    var category: String
    var description: String
}

struct ThesisActivityLog: Codable, Equatable {
    var startYear: Int
    var activities: [ThesisActivity]

    static let initialStartYear = 2026
    static let empty = ThesisActivityLog(startYear: initialStartYear, activities: [])

    var isValid: Bool {
        guard (1900...2198).contains(startYear), activities.count <= 10_000 else { return false }
        var ids = Set<String>()
        return activities.allSatisfy { activity in
            guard !activity.id.isEmpty, activity.id.utf16.count <= 100, ids.insert(activity.id).inserted,
                  Self.isValidDate(activity.date), activity.hours.isFinite,
                  activity.hours > 0, activity.hours <= 24,
                  abs(activity.hours * 100 - (activity.hours * 100).rounded()) <= 1e-8,
                  !activity.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  activity.category.utf16.count <= 100, activity.description.utf16.count <= 4_000 else { return false }
            return true
        }
    }

    static func validationError(for activity: ThesisActivity, in log: ThesisActivityLog) -> String? {
        guard !activity.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Describe the activity so its hours can be reviewed."
        }
        let prior = log.activities.filter { $0.id != activity.id }
        guard prior.count < 10_000 else { return "The activity log is full." }
        let candidate = ThesisActivityLog(startYear: log.startYear, activities: prior + [activity])
        guard candidate.isValid else {
            return "Enter a valid date, 0.01–24 hours (up to two decimal places), a category and a description of at most 4,000 characters."
        }
        let dailyTotal = candidate.activities.filter { $0.date == activity.date }.reduce(0.0) { $0 + $1.hours }
        guard dailyTotal <= 24 else { return "The activities for one date cannot exceed 24 hours." }
        return nil
    }

    private static func isValidDate(_ value: String) -> Bool {
        guard value.range(of: "^(19|20|21)[0-9]{2}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil,
              let year = Int(value.prefix(4)), let month = Int(value.dropFirst(5).prefix(2)),
              let day = Int(value.suffix(2)) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var parts = DateComponents()
        parts.year = year; parts.month = month; parts.day = day
        guard let date = calendar.date(from: parts) else { return false }
        let result = calendar.dateComponents([.year, .month, .day], from: date)
        return result.year == year && result.month == month && result.day == day
    }
}

struct ThesisTimetableWeek: Identifiable, Equatable {
    var key: String
    var year: Int
    var week: Int
    var start: String
    var end: String
    var values: [String]
    var activities: [ThesisActivity]
    var legacy: Bool
    var expectedHours: Double
    var exclusions: [String]
    var id: String { key }
}

struct ThesisTimetableSummary: Equatable {
    var categories: [String]
    var weeks: [ThesisTimetableWeek]
    var totals: [String]
    var plannedWeeks: Int
    var expectedHours: Double
    var notes: [String]
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

    static func removingSheet(id: String, from sheets: [ThesisSheet]) -> [ThesisSheet]? {
        guard sheets.count > 1 else { return nil }
        let matches = sheets.indices.filter { sheets[$0].id == id }
        guard matches.count == 1, let index = matches.first else { return nil }
        var remaining = sheets
        remaining.remove(at: index)
        return remaining
    }

    static func activityLog(for sheet: ThesisSheet) -> ThesisActivityLog? {
        guard let raw = sheet.metadata["activityLog"] else { return .empty }
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let log = try? JSONDecoder().decode(ThesisActivityLog.self, from: data), log.isValid else { return nil }
        return log
    }

    static func settingActivityLog(_ log: ThesisActivityLog, on sheet: ThesisSheet) -> ThesisSheet? {
        guard log.isValid, let data = try? JSONEncoder().encode(log),
              let encoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let activities = encoded["activities"] as? [[String: Any]] else { return nil }
        var value = sheet.metadata["activityLog"] as? [String: Any] ?? [:]
        let previousActivities = value["activities"] as? [[String: Any]] ?? []
        let previousByID = Dictionary(previousActivities.compactMap { activity -> (String, [String: Any])? in
            guard let id = activity["id"] as? String else { return nil }
            return (id, activity)
        }, uniquingKeysWith: { current, _ in current })
        value["startYear"] = encoded["startYear"]
        value["activities"] = activities.map { activity -> [String: Any] in
            guard let id = activity["id"] as? String, var existing = previousByID[id] else { return activity }
            for (key, value) in activity { existing[key] = value }
            return existing
        }
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        var updated = sheet
        updated.metadata["activityLog"] = value
        return updated
    }

    static func timetableSummary(for table: ThesisTable, log: ThesisActivityLog) -> ThesisTimetableSummary? {
        guard table.kind == .timetable, log.isValid, let header = table.cells.first, header.count >= 3 else { return nil }
        let originalCategories = Array(header.dropFirst().dropLast())
        var categories: [String] = []
        for category in originalCategories where !categories.contains(category) { categories.append(category) }
        for activity in log.activities where !categories.contains(activity.category) { categories.append(activity.category) }

        var weeks: [String: ThesisTimetableWeek] = [:]
        var plannedKeys = Set<String>()
        var loggedHoursByWeek: [String: [String: Double]] = [:]
        var notes: [String] = []
        var year = log.startYear
        var previousWeek = 0

        for rowIndex in table.cells.indices.dropFirst() {
            let row = table.cells[rowIndex]
            let label = (row.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if label.range(of: "^(total(?:\\s|$)|[0-9]+\\s+weeks$)", options: [.regularExpression, .caseInsensitive]) != nil { continue }
            let explicit = label.range(of: "^[0-9]{4}-W[0-9]{1,2}$", options: .regularExpression) != nil
            let parts = label.split(separator: "-", omittingEmptySubsequences: false)
            let parsedWeek: Int?
            if explicit, parts.count == 2 {
                year = Int(parts[0]) ?? year
                parsedWeek = Int(parts[1].dropFirst())
            } else {
                parsedWeek = Int(label)
            }
            guard let weekNumber = parsedWeek, (1...53).contains(weekNumber) else {
                if row.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    notes.append("Original row \(rowIndex + 1): \(row.joined(separator: " | "))")
                }
                continue
            }
            if !explicit, previousWeek >= 40, weekNumber <= 10 { year += 1 }
            previousWeek = weekNumber
            let key = Self.weekKey(year: year, week: weekNumber)
            let values = categories.map { category -> String in
                guard let sourceColumn = originalCategories.firstIndex(of: category),
                      row.indices.contains(sourceColumn + 1) else { return "" }
                return Self.cellValue(table.cells, row: rowIndex, column: sourceColumn + 1)
            }
            let originalTotal = row.indices.contains(header.count - 1) ? Self.cellValue(table.cells, row: rowIndex, column: header.count - 1) : "#REF!"
            let legacy = (values + [originalTotal]).contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.trimmingCharacters(in: .whitespacesAndNewlines) != "0" }
            guard weeks[key] == nil else {
                notes.append("Duplicate \(key): \((values + [originalTotal]).joined(separator: " | "))")
                continue
            }
            let dates = Self.weekDates(year: year, week: weekNumber)
            let (expected, exclusions) = Self.expectedHours(start: dates.start, week: weekNumber, firstYear: log.startYear, scheduled: true)
            weeks[key] = ThesisTimetableWeek(key: key, year: year, week: weekNumber, start: dates.start, end: dates.end,
                                             values: values + [originalTotal], activities: [], legacy: legacy,
                                             expectedHours: expected, exclusions: exclusions)
            plannedKeys.insert(key)
        }

        for activity in log.activities {
            guard let date = Self.parseDate(activity.date), let dateParts = Self.isoWeekParts(date) else { continue }
            let key = Self.weekKey(year: dateParts.year, week: dateParts.week)
            if weeks[key] == nil {
                let dates = Self.weekDates(year: dateParts.year, week: dateParts.week)
                let (expected, exclusions) = Self.expectedHours(start: dates.start, week: dateParts.week, firstYear: log.startYear, scheduled: false)
                weeks[key] = ThesisTimetableWeek(key: key, year: dateParts.year, week: dateParts.week, start: dates.start, end: dates.end,
                                                 values: Array(repeating: "", count: categories.count + 1), activities: [], legacy: false,
                                                 expectedHours: expected, exclusions: exclusions)
            }
            weeks[key]?.activities.append(activity)
            loggedHoursByWeek[key, default: [:]][activity.category, default: 0] += activity.hours
        }

        let rows = weeks.values.map { source -> ThesisTimetableWeek in
            var week = source
            week.activities.sort { ($0.date, $0.category, $0.id) < ($1.date, $1.category, $1.id) }
            let sourceCategories = Array(week.values.dropLast())
            let categoryValues = categories.enumerated().map { index, category -> String in
                let logged = loggedHoursByWeek[week.key]?[category] ?? 0
                let old = sourceCategories.indices.contains(index) ? sourceCategories[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                if old.isEmpty || Double(old) != nil {
                    let base = Double(old) ?? 0
                    return base + logged == 0 ? "" : Self.hoursText(base + logged)
                }
                return logged == 0 ? old : "\(old) + \(Self.hoursText(logged))"
            }
            let imported = sourceCategories.reduce(0.0) { $0 + (Double($1) ?? 0) }
            let originalTotal = week.values.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let baseTotal = originalTotal.isEmpty ? imported : (Double(originalTotal) ?? imported)
            let loggedTotal = week.activities.reduce(0.0) { $0 + $1.hours }
            let total = baseTotal + loggedTotal
            week.values = categoryValues + [total == 0 ? "" : Self.hoursText(total)]
            return week
        }.sorted { $0.start < $1.start }

        let totals = (0...categories.count).map { column in
            let sum = rows.reduce(0.0) { partial, week in
                guard week.values.indices.contains(column), let value = Double(week.values[column]) else { return partial }
                return partial + value
            }
            return Self.hoursText(sum)
        }
        return ThesisTimetableSummary(categories: categories, weeks: rows, totals: totals,
                                      plannedWeeks: plannedKeys.count, expectedHours: rows.reduce(0) { $0 + $1.expectedHours }, notes: notes)
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

    private static var utcISOCalendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func parseDate(_ value: String) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]; components.month = parts[1]; components.day = parts[2]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: components) else { return nil }
        let verified = calendar.dateComponents([.year, .month, .day], from: date)
        guard verified.year == parts[0], verified.month == parts[1], verified.day == parts[2] else { return nil }
        return date
    }

    private static func dateText(_ date: Date, calendar: Calendar = utcISOCalendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func isoWeekParts(_ date: Date) -> (year: Int, week: Int)? {
        let parts = utcISOCalendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        guard let year = parts.yearForWeekOfYear, let week = parts.weekOfYear else { return nil }
        return (year, week)
    }

    private static func weekDates(year: Int, week: Int) -> (start: String, end: String) {
        var components = DateComponents()
        components.yearForWeekOfYear = year; components.weekOfYear = week; components.weekday = 2
        guard let monday = utcISOCalendar.date(from: components),
              let sunday = utcISOCalendar.date(byAdding: .day, value: 6, to: monday) else {
            return ("", "")
        }
        return (dateText(monday), dateText(sunday))
    }

    private static func weekKey(year: Int, week: Int) -> String {
        String(format: "%04d-W%02d", year, week)
    }

    private static func hoursText(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if let integer = Int(exactly: rounded) { return String(integer) }
        return String(rounded)
    }

    private static func cellValue(_ cells: [[String]], row: Int, column: Int) -> String {
        var visiting = Set<String>()
        var budget = 100_000
        return cellValue(cells, row: row, column: column, visiting: &visiting, budget: &budget)
    }

    private static func cellValue(_ cells: [[String]], row: Int, column: Int,
                                  visiting: inout Set<String>, budget: inout Int) -> String {
        budget -= 1
        guard budget >= 0 else { return "#LIMIT!" }
        guard cells.indices.contains(row), cells[row].indices.contains(column) else { return "#REF!" }
        let raw = cells[row][column].trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.range(of: "^=SUMMARIZE\\b", options: [.regularExpression, .caseInsensitive]) != nil else { return cells[row][column] }
        guard let match = raw.range(of: "^=SUMMARIZE\\(\\s*([A-Z]+)([1-9][0-9]*)\\s*:\\s*([A-Z]+)([1-9][0-9]*)\\s*\\)$", options: [.regularExpression, .caseInsensitive]) else {
            return raw.contains("#REF!") ? "#REF!" : "#FORMULA!"
        }
        let formula = String(raw[match])
        guard let captures = Self.formulaCaptures(formula) else { return "#FORMULA!" }
        let key = "\(row):\(column)"
        guard !visiting.contains(key), visiting.count <= 200 else { return "#CYCLE!" }
        let firstColumn = Self.columnIndex(captures.firstColumn), lastColumn = Self.columnIndex(captures.lastColumn)
        let firstRow = captures.firstRow - 1, lastRow = captures.lastRow - 1
        guard min(firstRow, lastRow) >= 0, max(firstRow, lastRow) < cells.count,
              min(firstColumn, lastColumn) >= 0,
              cells.allSatisfy({ max(firstColumn, lastColumn) < $0.count }) else { return "#REF!" }
        visiting.insert(key)
        defer { visiting.remove(key) }
        var total = 0.0
        for targetRow in min(firstRow, lastRow)...max(firstRow, lastRow) {
            for targetColumn in min(firstColumn, lastColumn)...max(firstColumn, lastColumn) {
                let value = cellValue(cells, row: targetRow, column: targetColumn, visiting: &visiting, budget: &budget)
                if value == "#LIMIT!" || (value.hasPrefix("#") && cells[targetRow][targetColumn].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("=")) { return value }
                if let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)), number.isFinite { total += number }
            }
        }
        return total.isFinite ? hoursText(total) : "#NUMBER!"
    }

    private static func formulaCaptures(_ value: String) -> (firstColumn: String, firstRow: Int, lastColumn: String, lastRow: Int)? {
        guard let regex = try? NSRegularExpression(pattern: "^=SUMMARIZE\\(\\s*([A-Z]+)([1-9][0-9]*)\\s*:\\s*([A-Z]+)([1-9][0-9]*)\\s*\\)$", options: [.caseInsensitive]),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let firstColumnRange = Range(match.range(at: 1), in: value), let firstRowRange = Range(match.range(at: 2), in: value),
              let lastColumnRange = Range(match.range(at: 3), in: value), let lastRowRange = Range(match.range(at: 4), in: value),
              let firstRow = Int(value[firstRowRange]), let lastRow = Int(value[lastRowRange]) else { return nil }
        return (String(value[firstColumnRange]).uppercased(), firstRow, String(value[lastColumnRange]).uppercased(), lastRow)
    }

    private static func columnIndex(_ letters: String) -> Int {
        letters.reduce(0) { $0 * 26 + Int($1.asciiValue ?? 64) - 64 } - 1
    }

    private static func expectedHours(start: String, week: Int, firstYear: Int, scheduled: Bool) -> (Double, [String]) {
        guard scheduled else { return (0, ["Outside the planned rows"]) }
        guard week < 51 else { return (0, ["Christmas break (weeks 51–53)"]) }
        guard let monday = parseDate(start) else { return (0, []) }
        var hoursHundredths = 0
        var exclusions: [String] = []
        for offset in 0..<5 {
            guard let date = utcISOCalendar.date(byAdding: .day, value: offset, to: monday) else { continue }
            let text = dateText(date)
            let year = utcISOCalendar.component(.year, from: date)
            if let holiday = norwegianHolidayName(on: date, year: year) {
                exclusions.append("\(text): \(holiday)")
            } else {
                hoursHundredths += year <= firstYear ? 240 : 750
            }
        }
        return (Double(hoursHundredths) / 100, exclusions)
    }

    private static func norwegianHolidayName(on date: Date, year: Int) -> String? {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        let text = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let fixed: [String: String] = [
            String(format: "%04d-01-01", year): "New Year's Day",
            String(format: "%04d-05-01", year): "Labour Day",
            String(format: "%04d-05-17", year): "Constitution Day",
            String(format: "%04d-12-25", year): "Christmas Day",
            String(format: "%04d-12-26", year): "Boxing Day",
        ]
        var holidays = fixed
        let a = year % 19, b = year / 100, c = year % 100
        let d = b / 4, e = b % 4, f = (b + 8) / 25, g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30, i = c / 4, k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7, m = (a + 11 * h + 22 * l) / 451
        let easterMonth = (h + l - 7 * m + 114) / 31
        let easterDay = (h + l - 7 * m + 114) % 31 + 1
        var easterParts = DateComponents()
        easterParts.year = year; easterParts.month = easterMonth; easterParts.day = easterDay
        guard let easter = gregorian.date(from: easterParts) else { return fixed[text] }
        let movable = [(-3, "Maundy Thursday"), (-2, "Good Friday"), (0, "Easter Sunday"),
                       (1, "Easter Monday"), (39, "Ascension Day"), (49, "Whit Sunday"), (50, "Whit Monday")]
        for (offset, name) in movable {
            guard let holiday = gregorian.date(byAdding: .day, value: offset, to: easter) else { continue }
            let holidayText = dateText(holiday, calendar: gregorian)
            holidays[holidayText] = [holidays[holidayText], name].compactMap { $0 }.joined(separator: " / ")
        }
        return holidays[text]
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
