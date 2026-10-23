import SwiftUI

struct ThesisWorkspaceEditor: View {
    @Environment(\.desktopTheme) private var theme
    @Binding var documentTitle: String
    @Binding var bodyText: String
    let enabled: Bool
    let busy: Bool
    let conflicted: Bool
    @State private var selectedID = "Overview"
    @State private var sourceMode = false
    @State private var newTableRows = "3"
    @State private var newTableColumns = "3"
    @State private var newPageName = ""

    private var sheets: [ThesisSheet] { ThesisWorkspaceCodec.sheets(title: documentTitle, body: bodyText) }
    private var activeIndex: Int { max(0, sheets.firstIndex(where: { $0.id == selectedID }) ?? 0) }
    private var active: ThesisSheet { sheets[activeIndex] }
    private var editable: Bool { enabled && !busy && !conflicted }
    private var validTableDimensions: Bool {
        guard let rows = Int(newTableRows), let columns = Int(newTableColumns) else { return false }
        return (1...100).contains(rows) && (1...20).contains(columns)
    }

    var body: some View {
        NativeGroupPanel(title: "Workspace", subtitle: "Structured pages and Markdown tables") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(sheets) { sheet in
                        Button {
                            selectedID = sheet.id
                            sourceMode = false
                        } label: {
                            Text((sheet.id == active.id ? "✓ " : "") + sheet.name)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(sheet.id == active.id ? theme.accent : theme.textSecondary)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(sheet.id == active.id ? theme.accentSoft : theme.cardRaised, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }
            }

            TextField("Sheet title", text: sheetTitleBinding)
                .textFieldStyle(.roundedBorder).disabled(!editable)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                ActionButton(title: sourceMode ? "Table view" : "Markdown source", icon: "text.alignleft") { sourceMode.toggle() }
                if !sourceMode {
                    TextField("New page name", text: $newPageName).textFieldStyle(.roundedBorder).frame(maxWidth: 180).disabled(!editable)
                    ActionButton(title: "Add page", icon: "plus") { addPage() }.disabled(!editable || newPageName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    TextField("Rows", text: $newTableRows).textFieldStyle(.roundedBorder).frame(maxWidth: 55).disabled(!editable)
                    TextField("Columns", text: $newTableColumns).textFieldStyle(.roundedBorder).frame(maxWidth: 65).disabled(!editable)
                    ActionButton(title: "Insert table", icon: "tablecells") { insertTable() }.disabled(!editable || !validTableDimensions)
                    if active.name.lowercased() == "plan" {
                        ActionButton(title: "Create plan table", icon: "checklist") {
                            appendTable(headers: ["Task", "Hours", "Status", "Sprint", "Progress", "Notes"])
                        }.disabled(!editable || !ThesisWorkspaceCodec.tables(in: active.body).isEmpty)
                    } else if active.name.lowercased() == "timetable" {
                        ActionButton(title: "Create timetable", icon: "calendar") {
                            appendTable(headers: ["Week", "Research", "Total"])
                        }.disabled(!editable || !ThesisWorkspaceCodec.tables(in: active.body).isEmpty)
                    }
                }
                }
            }
            if sourceMode {
                TextEditor(text: sheetBodyBinding)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 260)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.divider, lineWidth: 1))
                    .disabled(!editable)
            } else {
                let tables = ThesisWorkspaceCodec.tables(in: active.body)
                if tables.isEmpty {
                    Text("No tables on this page. Use Markdown source to edit the page text, or insert a table.")
                        .font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                }
                ForEach(Array(tables.enumerated()), id: \.offset) { index, table in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(table.kind == .plan ? "Project plan · Table \(index + 1)" : table.kind == .timetable ? "Timetable · Table \(index + 1)" : "Table \(index + 1)")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                        ScrollView(.horizontal, showsIndicators: true) {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(Array(table.cells.prefix(100).enumerated()), id: \.offset) { row, cells in
                                    HStack(spacing: 5) {
                                        ForEach(Array(cells.prefix(20).enumerated()), id: \.offset) { column, _ in
                                            TextField(row == 0 ? "Column \(column + 1)" : "", text: cellBinding(tableIndex: index, row: row, column: column))
                                                .textFieldStyle(.roundedBorder)
                                                .font(.system(size: 11, weight: row == 0 ? .semibold : .regular))
                                                .frame(minWidth: 130, idealWidth: 170)
                                                .accessibilityLabel("Row \(row + 1), column \(column + 1)")
                                                .disabled(!editable)
                                        }
                                    }
                                }
                            }
                        }
                        if table.cells.count > 100 || (table.cells.first?.count ?? 0) > 20 {
                            Text("Showing up to 100 rows and 20 columns in the grid. Use Markdown source to edit the rest.")
                                .font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                        }
                        HStack(spacing: 8) {
                            ActionButton(title: "Add row", icon: "plus") { reshape(tableIndex: index, addingRow: true) }.disabled(!editable)
                            ActionButton(title: "Add column", icon: "plus") { reshape(tableIndex: index, addingRow: false) }.disabled(!editable)
                            ActionButton(title: "Delete table", icon: "trash") { deleteTable(table) }.disabled(!editable)
                        }
                    }
                    if index + 1 < tables.count { Divider() }
                }
                if tables.contains(where: { $0.kind == .timetable }) {
                    NativeNotice(message: "Edit planned week rows here. For dated activity logs and calendar totals, open the Thesis timetable in the web workspace.")
                }
                if tables.contains(where: { $0.kind == .plan }) {
                    NativeNotice(message: "Edit plan task rows here. For status boards, subgoals, and sprint filters, open the Thesis plan in the web workspace.")
                }
            }
        }
    }

    private var sheetTitleBinding: Binding<String> {
        Binding(get: { active.title }, set: { value in
            guard editable else { return }
            var next = sheets
            next[activeIndex].metadata["title"] = value
            bodyText = ThesisWorkspaceCodec.write(next)
        })
    }
    private var sheetBodyBinding: Binding<String> {
        Binding(get: { active.body }, set: { value in updateBody(value) })
    }
    private func cellBinding(tableIndex: Int, row: Int, column: Int) -> Binding<String> {
        Binding(get: {
            let parsed = ThesisWorkspaceCodec.tables(in: active.body)
            guard parsed.indices.contains(tableIndex), parsed[tableIndex].cells.indices.contains(row), parsed[tableIndex].cells[row].indices.contains(column) else { return "" }
            return parsed[tableIndex].cells[row][column]
        }, set: { value in
            guard editable else { return }
            let parsed = ThesisWorkspaceCodec.tables(in: active.body)
            guard parsed.indices.contains(tableIndex) else { return }
            var cells = parsed[tableIndex].cells
            cells[row][column] = value
            updateBody(ThesisWorkspaceCodec.replacing(parsed[tableIndex], in: active.body, with: cells))
        })
    }
    private func updateBody(_ value: String) {
        guard editable else { return }
        var next = sheets
        next[activeIndex].body = value
        bodyText = ThesisWorkspaceCodec.write(next)
    }
    private func insertTable() {
        guard editable, let rows = Int(newTableRows), let columns = Int(newTableColumns), (1...100).contains(rows), (1...20).contains(columns) else { return }
        let headers = (0..<columns).map { "Column \($0 + 1)" }
        var next = sheets
        next[activeIndex].body = ThesisWorkspaceCodec.appendingTable(to: next[activeIndex].body, headers: headers, rowCount: rows)
        bodyText = ThesisWorkspaceCodec.write(next)
    }
    private func appendTable(headers: [String]) {
        guard editable else { return }
        var next = sheets
        next[activeIndex].body = ThesisWorkspaceCodec.appendingTable(to: next[activeIndex].body, headers: headers)
        bodyText = ThesisWorkspaceCodec.write(next)
    }
    private func addPage() {
        guard editable else { return }
        let name = newPageName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else { return }
        let id = UUID().uuidString.lowercased()
        var next = sheets
        next.append(ThesisSheet(body: "", metadata: ["id": id, "name": name, "title": "# \(name)"]))
        bodyText = ThesisWorkspaceCodec.write(next)
        selectedID = id
        newPageName = ""
    }
    private func reshape(tableIndex: Int, addingRow: Bool) {
        guard editable else { return }
        let tables = ThesisWorkspaceCodec.tables(in: active.body)
        guard tables.indices.contains(tableIndex) else { return }
        var cells = tables[tableIndex].cells
        if addingRow {
            guard cells.count < 10_000 else { return }
            cells.append(Array(repeating: "", count: cells[0].count))
        } else {
            guard cells[0].count < 100 else { return }
            for row in cells.indices { cells[row].append("") }
        }
        updateBody(ThesisWorkspaceCodec.replacing(tables[tableIndex], in: active.body, with: cells))
    }
    private func deleteTable(_ table: ThesisTable) {
        guard editable else { return }
        let ns = active.body as NSString
        guard table.start >= 0, table.end <= ns.length, table.end >= table.start else { return }
        updateBody(ns.replacingCharacters(in: NSRange(location: table.start, length: table.end - table.start), with: ""))
    }
}
