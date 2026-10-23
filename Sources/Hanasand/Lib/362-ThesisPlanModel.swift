import Foundation

struct ThesisPlanModel {
    struct Fields: Equatable {
        var task = -1
        var hours = -1
        var notes = -1
        var status = -1
        var sprint = -1
        var progress = -1
        var details = -1
        var subgoals = -1
    }

    struct Task: Identifiable, Equatable {
        var rowIndex: Int
        var cells: [String]
        var id: Int { rowIndex }
    }

    static let statuses = ["Planned", "In progress", "Waiting", "Completed"]
    private static let aliases: [(keyPath: WritableKeyPath<Fields, Int>, names: [String])] = [
        (\.task, ["task", "goal", "item", "milestone"]),
        (\.hours, ["hours", "estimate", "estimated hours", "effort"]),
        (\.notes, ["notes", "note", "description"]),
        (\.status, ["status", "state"]),
        (\.sprint, ["sprint", "iteration"]),
        (\.progress, ["progress", "% complete"]),
        (\.details, ["details", "detail", "updates"]),
        (\.subgoals, ["subgoals", "sub-goals", "checklist"])
    ]

    var cells: [[String]]
    var fields: Fields
    var tasks: [Task]
    var estimatedHours: Double
    var completedHours: Double
    var completedCount: Int
    var inProgressCount: Int
    var sprints: [String]

    init(table: ThesisTable) {
        cells = table.cells
        var found = Fields()
        let headers = table.cells.first ?? []
        for (keyPath, names) in Self.aliases {
            found[keyPath: keyPath] = headers.firstIndex { names.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) } ?? -1
        }
        fields = found
        let rows = table.cells.enumerated().dropFirst().compactMap { index, row -> Task? in
            if found.task >= 0, row.indices.contains(found.task), ["total", "summary"].contains(row[found.task].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) { return nil }
            return Task(rowIndex: index, cells: row)
        }
        tasks = rows
        estimatedHours = rows.reduce(0) { $0 + Self.number(at: found.hours, in: $1.cells) }
        let completed = rows.filter { Self.value(at: found.status, in: $0.cells) == "Completed" }
        completedCount = completed.count
        completedHours = completed.reduce(0) { $0 + Self.number(at: found.hours, in: $1.cells) }
        inProgressCount = rows.filter { Self.value(at: found.status, in: $0.cells) == "In progress" }.count
        sprints = Array(Set(rows.compactMap { task -> String? in
            let value = Self.value(at: found.sprint, in: task.cells).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        })).sorted()
    }

    func tasks(filteredToSprint sprint: String) -> [Task] {
        guard !sprint.isEmpty, fields.sprint >= 0 else { return tasks }
        return tasks.filter { Self.value(at: fields.sprint, in: $0.cells) == sprint }
    }

    func tasks(inStatus status: String, sprint: String = "") -> [Task] {
        tasks(filteredToSprint: sprint).filter { Self.displayStatus(Self.value(at: fields.status, in: $0.cells)) == status }
    }

    func updating(row: Int, column: Int, value: String) -> [[String]] {
        guard cells.indices.contains(row), cells[row].indices.contains(column) else { return cells }
        var updated = cells
        updated[row][column] = value
        if column == fields.subgoals, fields.progress >= 0 {
            let goals = Self.subgoals(in: value)
            if !goals.isEmpty, updated[row].indices.contains(fields.progress) {
                updated[row][fields.progress] = String(Int((Double(goals.filter(\.done).count) / Double(goals.count) * 100).rounded()))
            }
        }
        return updated
    }

    func togglingSubgoal(at goalIndex: Int, row: Int) -> [[String]] {
        guard fields.subgoals >= 0, cells.indices.contains(row), cells[row].indices.contains(fields.subgoals) else { return cells }
        var goals = Self.subgoals(in: cells[row][fields.subgoals])
        guard goals.indices.contains(goalIndex) else { return cells }
        goals[goalIndex].done.toggle()
        return updating(row: row, column: fields.subgoals, value: Self.writeSubgoals(goals))
    }

    func addingSubgoal(_ text: String, row: Int) -> [[String]] {
        guard fields.subgoals >= 0, cells.indices.contains(row), cells[row].indices.contains(fields.subgoals) else { return cells }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return cells }
        var goals = Self.subgoals(in: cells[row][fields.subgoals])
        goals.append((done: false, text: trimmed))
        return updating(row: row, column: fields.subgoals, value: Self.writeSubgoals(goals))
    }

    func removingSubgoal(at goalIndex: Int, row: Int) -> [[String]] {
        guard fields.subgoals >= 0, cells.indices.contains(row), cells[row].indices.contains(fields.subgoals) else { return cells }
        let goals = Self.subgoals(in: cells[row][fields.subgoals])
        guard goals.indices.contains(goalIndex) else { return cells }
        return updating(row: row, column: fields.subgoals, value: Self.writeSubgoals(goals.enumerated().filter { $0.offset != goalIndex }.map(\.element)))
    }

    static func displayStatus(_ value: String) -> String {
        statuses.contains(value) ? value : "Planned"
    }

    static func subgoals(in value: String) -> [(done: Bool, text: String)] {
        let pattern = try! NSRegularExpression(pattern: "^\\s*-\\s*\\[([ xX])\\]\\s*(.*)$")
        return value.components(separatedBy: "\n").compactMap { line in
            let ns = line as NSString
            guard let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  let stateRange = Range(match.range(at: 1), in: line),
                  let textRange = Range(match.range(at: 2), in: line) else { return nil }
            return (done: line[stateRange].lowercased() == "x", text: String(line[textRange]))
        }
    }

    static func writeSubgoals(_ goals: [(done: Bool, text: String)]) -> String {
        goals.map { "- [\($0.done ? "x" : " ")] \($0.text)" }.joined(separator: "\n")
    }

    private static func value(at index: Int, in row: [String]) -> String {
        index >= 0 && row.indices.contains(index) ? row[index] : ""
    }

    private static func number(at index: Int, in row: [String]) -> Double {
        guard let value = Double(value(at: index, in: row).trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else { return 0 }
        return value
    }
}
