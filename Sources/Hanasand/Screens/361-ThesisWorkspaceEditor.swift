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
    @State private var confirmingPageDeletion = false
    @State private var pageDeletionConfirmation = ""
    @State private var activityStartYear = ""
    @State private var activityDate = ""
    @State private var activityHours = ""
    @State private var activityCategory = ""
    @State private var activityDescription = ""
    @State private var editingActivityID: String?
    @State private var pendingActivityRemovalID: String?
    @State private var expandedActivityWeek = ""
    @State private var showingActivityForm = false
    @State private var activityMessage = ""
    @State private var planBoardView = false
    @State private var planSprintFilter = ""
    @State private var expandedPlanRow: Int?
    @State private var newPlanSubgoal = ""
    @State private var planTaskLimit = 30

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
                    ActionButton(title: "Delete page", icon: "trash") {
                        confirmingPageDeletion = true
                        pageDeletionConfirmation = ""
                    }.disabled(!editable || sheets.count <= 1)
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
            if confirmingPageDeletion {
                NativeGroupPanel(title: "Delete \(active.name)?", subtitle: "The page and its content will be removed from the shared workspace. Earlier saved versions remain in Version history.") {
                    Text("Type \(active.name) to confirm.")
                        .font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                    TextField("Page name", text: $pageDeletionConfirmation)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!editable)
                    HStack(spacing: 8) {
                        ActionButton(title: "Cancel", icon: "xmark") {
                            confirmingPageDeletion = false
                            pageDeletionConfirmation = ""
                        }
                        ActionButton(title: "Delete page", icon: "trash") { deleteActivePage() }
                            .disabled(!editable || pageDeletionConfirmation != active.name || sheets.count <= 1)
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
                        if table.kind == .plan {
                            thesisPlanPanel(table, tableIndex: index)
                        } else {
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
                    }
                    if table.kind == .timetable { timetableActivityPanel(table) }
                    if index + 1 < tables.count { Divider() }
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
    private func deleteActivePage() {
        guard editable, pageDeletionConfirmation == active.name,
              let remaining = ThesisWorkspaceCodec.removingSheet(id: active.id, from: sheets) else { return }
        let previousIndex = max(0, activeIndex - 1)
        selectedID = remaining[min(previousIndex, remaining.count - 1)].id
        bodyText = ThesisWorkspaceCodec.write(remaining)
        sourceMode = false
        confirmingPageDeletion = false
        pageDeletionConfirmation = ""
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

    @ViewBuilder private func thesisPlanPanel(_ table: ThesisTable, tableIndex: Int) -> some View {
        let model = ThesisPlanModel(table: table)
        let tasks = model.tasks(filteredToSprint: planSprintFilter)
        NativeGroupPanel(title: "Project plan", subtitle: "Track tasks, estimates, status, and subgoals.") {
            HStack(spacing: 12) {
                if model.fields.task >= 0, model.fields.status >= 0 {
                    Text("\(model.completedCount)/\(model.tasks.count) completed")
                }
                if model.fields.hours >= 0 {
                    Text("\(Self.hoursText(model.completedHours))/\(Self.hoursText(model.estimatedHours)) estimated hours")
                }
                if model.fields.status >= 0 { Text("\(model.inProgressCount) in progress") }
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)

            HStack(spacing: 8) {
                ActionButton(title: "Table view", icon: "tablecells") { planBoardView = false }
                if model.fields.task >= 0, model.fields.status >= 0 {
                    ActionButton(title: "Board view", icon: "rectangle.split.3x1") { planBoardView = true }
                }
                if model.fields.sprint >= 0 {
                    Picker("Sprint", selection: $planSprintFilter) {
                        Text("All sprints").tag("")
                        ForEach(model.sprints, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
            }

            HStack(spacing: 8) {
                ActionButton(title: "Add row", icon: "plus") { reshape(tableIndex: tableIndex, addingRow: true) }
                    .disabled(!editable || table.cells.count >= 10_000)
                ActionButton(title: "Add column", icon: "plus") { reshape(tableIndex: tableIndex, addingRow: false) }
                    .disabled(!editable || (table.cells.first?.count ?? 0) >= 100)
                ActionButton(title: "Delete table", icon: "trash") { deleteTable(table) }.disabled(!editable)
            }

            if planBoardView && model.fields.task >= 0 && model.fields.status >= 0 {
                ForEach(ThesisPlanModel.statuses, id: \.self) { status in
                    NativeGroupPanel(title: "\(status) · \(model.tasks(inStatus: status, sprint: planSprintFilter).count)", subtitle: "Tasks in this status") {
                        ForEach(model.tasks(inStatus: status, sprint: planSprintFilter).prefix(planTaskLimit)) { task in
                            planTaskCard(task, model: model, tableIndex: tableIndex, board: true)
                        }
                    }
                }
            } else {
                ForEach(tasks.prefix(planTaskLimit)) { task in
                    planTaskCard(task, model: model, tableIndex: tableIndex, board: false)
                }
            }
            if tasks.count > planTaskLimit {
                ActionButton(title: "Show more tasks", icon: "chevron.down") { planTaskLimit += 30 }
            }
            if !editable {
                Text("This thesis is read only.").font(.system(size: 10)).foregroundStyle(theme.textTertiary)
            }
        }
        .onChange(of: active.id) { _, _ in
            planSprintFilter = ""
            expandedPlanRow = nil
            planTaskLimit = 30
        }
    }

    @ViewBuilder private func planTaskCard(_ task: ThesisPlanModel.Task, model: ThesisPlanModel, tableIndex: Int, board: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                if model.fields.task >= 0 {
                    TextField("Task", text: planCellBinding(tableIndex: tableIndex, row: task.rowIndex, column: model.fields.task))
                        .textFieldStyle(.roundedBorder).disabled(!editable)
                } else {
                    Text("Row \(task.rowIndex)").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                }
                if model.fields.status >= 0 {
                    Picker("Status", selection: Binding(get: {
                        ThesisPlanModel.displayStatus(task.cells.indices.contains(model.fields.status) ? task.cells[model.fields.status] : "")
                    }, set: { updatePlan(tableIndex: tableIndex, row: task.rowIndex, column: model.fields.status, value: $0) })) {
                        ForEach(ThesisPlanModel.statuses, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu).disabled(!editable)
                }
            }

            let primaryColumns = board
                ? [model.fields.hours, model.fields.sprint, model.fields.progress].filter { $0 >= 0 }
                : Array(task.cells.indices).filter { $0 != model.fields.task && $0 != model.fields.status && $0 != model.fields.notes && $0 != model.fields.details && $0 != model.fields.subgoals }
            ForEach(primaryColumns, id: \.self) { column in
                HStack(spacing: 7) {
                    Text(model.cells[0].indices.contains(column) ? model.cells[0][column] : "Column \(column + 1)")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textSecondary).frame(width: 90, alignment: .leading)
                    TextField("", text: planCellBinding(tableIndex: tableIndex, row: task.rowIndex, column: column))
                        .textFieldStyle(.roundedBorder).disabled(!editable)
                }
            }

            if model.fields.subgoals >= 0 || model.fields.notes >= 0 || model.fields.details >= 0 {
                ActionButton(title: expandedPlanRow == task.rowIndex ? "Hide details" : "Details and subgoals", icon: "chevron.down") {
                    expandedPlanRow = expandedPlanRow == task.rowIndex ? nil : task.rowIndex
                    newPlanSubgoal = ""
                }
                if expandedPlanRow == task.rowIndex {
                    ForEach([model.fields.notes, model.fields.details].filter { $0 >= 0 }, id: \.self) { column in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.cells[0][column]).font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textSecondary)
                            TextEditor(text: planCellBinding(tableIndex: tableIndex, row: task.rowIndex, column: column))
                                .font(.system(size: 11)).frame(minHeight: 48)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.divider, lineWidth: 1)).disabled(!editable)
                        }
                    }
                    if model.fields.subgoals >= 0 {
                        let source = task.cells.indices.contains(model.fields.subgoals) ? task.cells[model.fields.subgoals] : ""
                        let goals = ThesisPlanModel.subgoals(in: source)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Subgoals · \(goals.filter(\.done).count)/\(goals.count)").font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textSecondary)
                            ForEach(Array(goals.enumerated()), id: \.offset) { index, goal in
                                HStack(spacing: 7) {
                                    Toggle(goal.text, isOn: Binding(get: { goal.done }, set: { _ in updatePlanSubgoals(tableIndex: tableIndex, row: task.rowIndex, action: .toggle(index)) }))
                                        .toggleStyle(.checkbox).disabled(!editable)
                                    ActionButton(title: "Remove", icon: "minus") { updatePlanSubgoals(tableIndex: tableIndex, row: task.rowIndex, action: .remove(index)) }.disabled(!editable)
                                }
                            }
                            HStack {
                                TextField("New subgoal", text: $newPlanSubgoal).textFieldStyle(.roundedBorder).disabled(!editable)
                                ActionButton(title: "Add subgoal", icon: "plus") { updatePlanSubgoals(tableIndex: tableIndex, row: task.rowIndex, action: .add(newPlanSubgoal)); newPlanSubgoal = "" }
                                    .disabled(!editable || newPlanSubgoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(theme.cardRaised.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
    }

    private enum PlanSubgoalAction { case toggle(Int), remove(Int), add(String) }

    private func updatePlanSubgoals(tableIndex: Int, row: Int, action: PlanSubgoalAction) {
        let tables = ThesisWorkspaceCodec.tables(in: active.body)
        guard tables.indices.contains(tableIndex), editable else { return }
        let table = tables[tableIndex]
        let model = ThesisPlanModel(table: table)
        let cells: [[String]]
        switch action {
        case .toggle(let index): cells = model.togglingSubgoal(at: index, row: row)
        case .remove(let index): cells = model.removingSubgoal(at: index, row: row)
        case .add(let text): cells = model.addingSubgoal(text, row: row)
        }
        updateBody(ThesisWorkspaceCodec.replacing(table, in: active.body, with: cells))
    }

    private func updatePlan(tableIndex: Int, row: Int, column: Int, value: String) {
        guard editable else { return }
        let tables = ThesisWorkspaceCodec.tables(in: active.body)
        guard tables.indices.contains(tableIndex) else { return }
        let table = tables[tableIndex]
        let cells = ThesisPlanModel(table: table).updating(row: row, column: column, value: value)
        updateBody(ThesisWorkspaceCodec.replacing(table, in: active.body, with: cells))
    }

    private func planCellBinding(tableIndex: Int, row: Int, column: Int) -> Binding<String> {
        Binding(get: {
            let tables = ThesisWorkspaceCodec.tables(in: active.body)
            guard tables.indices.contains(tableIndex), tables[tableIndex].cells.indices.contains(row), tables[tableIndex].cells[row].indices.contains(column) else { return "" }
            return tables[tableIndex].cells[row][column]
        }, set: { updatePlan(tableIndex: tableIndex, row: row, column: column, value: $0) })
    }

    @ViewBuilder private func timetableActivityPanel(_ table: ThesisTable) -> some View {
        let log = ThesisWorkspaceCodec.activityLog(for: active)
        let activityLog = log ?? .empty
        let summary = log.flatMap { ThesisWorkspaceCodec.timetableSummary(for: table, log: $0) }
        NativeGroupPanel(title: "Timetable activity", subtitle: "Dated work is summarized by ISO week alongside the planned hours.") {
            if log == nil {
                NativeNotice(message: "This activity log has invalid data and is read only here. The rest of the timetable remains available.")
            } else if let summary {
                Text("\(summary.totals.last ?? "0") h spent · \(Self.hoursText(summary.expectedHours)) h expected · \(summary.plannedWeeks) planned weeks")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                if editable {
                    HStack(spacing: 8) {
                        TextField("Initial timetable year", text: $activityStartYear)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 150)
                            .onAppear { if activityStartYear.isEmpty { activityStartYear = String(activityLog.startYear) } }
                        ActionButton(title: "Apply year", icon: "calendar") { applyActivityStartYear(activityLog) }
                            .disabled(!validActivityYear)
                        ActionButton(title: showingActivityForm ? "Cancel activity" : "Log activity", icon: showingActivityForm ? "xmark" : "plus") {
                            showingActivityForm.toggle()
                            editingActivityID = nil
                            activityMessage = ""
                            if showingActivityForm { beginActivity(categories: summary.categories) }
                        }
                    }
                }
                if showingActivityForm && editable {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(editingActivityID == nil ? "Log activity" : "Edit activity")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                        TextField("Date (YYYY-MM-DD)", text: $activityDate).textFieldStyle(.roundedBorder)
                        TextField("Hours", text: $activityHours).textFieldStyle(.roundedBorder)
                        TextField("Category", text: $activityCategory).textFieldStyle(.roundedBorder)
                        TextEditor(text: $activityDescription)
                            .font(.system(size: 11))
                            .frame(minHeight: 64)
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.divider, lineWidth: 1))
                        if let validation = activityDraftValidationError(activityLog) {
                            Text(validation).font(.system(size: 10)).foregroundStyle(theme.danger)
                        }
                        HStack(spacing: 8) {
                            ActionButton(title: editingActivityID == nil ? "Add activity" : "Save activity", icon: "checkmark") { saveActivity(activityLog) }
                                .disabled(!editable)
                            ActionButton(title: "Cancel", icon: "xmark") { showingActivityForm = false; editingActivityID = nil }
                        }
                    }
                    .padding(10)
                    .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 8))
                }
                if !activityMessage.isEmpty {
                    Text(activityMessage).font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                }
                if summary.weeks.isEmpty {
                    Text("No weeks or dated activities yet.").font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                }
                ForEach(summary.weeks) { week in
                    VStack(alignment: .leading, spacing: 7) {
                        Button {
                            expandedActivityWeek = expandedActivityWeek == week.id ? "" : week.id
                        } label: {
                            HStack {
                                Text("\(week.key) · \(week.values.last?.isEmpty == false ? week.values.last! : "0") h")
                                Spacer(minLength: 8)
                                Text("\(Self.hoursText(week.expectedHours)) h expected")
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        Text("\(week.start) – \(week.end) · " + summary.categories.enumerated().map { index, name in "\(name): \(week.values.indices.contains(index) && !week.values[index].isEmpty ? week.values[index] : "0")" }.joined(separator: " · "))
                            .font(.system(size: 10)).foregroundStyle(theme.textSecondary)
                        if expandedActivityWeek == week.id {
                            ForEach(week.activities) { activity in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(activity.date) · \(Self.hoursText(activity.hours)) h · \(activity.category)")
                                        .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.text)
                                    Text(activity.description).font(.system(size: 10)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                                    if editable {
                                        HStack(spacing: 8) {
                                            ActionButton(title: "Edit", icon: "pencil") { editActivity(activity) }
                                            if pendingActivityRemovalID == activity.id {
                                                ActionButton(title: "Confirm remove", icon: "trash") { removeActivity(activity, from: activityLog) }
                                                ActionButton(title: "Cancel", icon: "xmark") { pendingActivityRemovalID = nil }
                                            } else {
                                                ActionButton(title: "Remove", icon: "trash") { pendingActivityRemovalID = activity.id }
                                            }
                                        }
                                    }
                                }.padding(.vertical, 4)
                            }
                            if week.activities.isEmpty {
                                Text("No dated activities for this week.").font(.system(size: 10)).foregroundStyle(theme.textSecondary)
                            }
                            if !week.exclusions.isEmpty {
                                Text(week.exclusions.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                            }
                        }
                    }
                    .padding(8)
                    .background(theme.cardRaised.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
                }
                ForEach(Array(summary.notes.enumerated()), id: \.offset) { _, note in
                    Text(note).font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                }
            }
        }
        .onChange(of: active.id) { _, _ in
            activityStartYear = ThesisWorkspaceCodec.activityLog(for: active).map { String($0.startYear) } ?? ""
            showingActivityForm = false
            editingActivityID = nil
            pendingActivityRemovalID = nil
        }
    }

    private var validActivityYear: Bool {
        guard let year = Int(activityStartYear) else { return false }
        return (1900...2198).contains(year)
    }

    private func beginActivity(categories: [String]) {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)!
        formatter.dateFormat = "yyyy-MM-dd"
        activityDate = formatter.string(from: Date())
        activityHours = ""
        activityCategory = categories.first ?? "Research"
        activityDescription = ""
    }

    private func activityDraftValidationError(_ log: ThesisActivityLog) -> String? {
        guard let hours = Double(activityHours) else {
            return "Enter a valid date, 0.01–24 hours (up to two decimal places), a category and a description of at most 4,000 characters."
        }
        let id = editingActivityID ?? UUID().uuidString.lowercased()
        let value = ThesisActivity(id: id, date: activityDate, hours: hours,
                                  category: activityCategory.trimmingCharacters(in: .whitespacesAndNewlines),
                                  description: activityDescription.trimmingCharacters(in: .whitespacesAndNewlines))
        return ThesisActivityLog.validationError(for: value, in: log)
    }

    private func saveActivity(_ log: ThesisActivityLog) {
        guard editable else { return }
        if let validation = activityDraftValidationError(log) { activityMessage = validation; return }
        guard let hours = Double(activityHours) else { return }
        let id = editingActivityID ?? UUID().uuidString.lowercased()
        let value = ThesisActivity(id: id, date: activityDate, hours: hours,
                                   category: activityCategory.trimmingCharacters(in: .whitespacesAndNewlines),
                                   description: activityDescription.trimmingCharacters(in: .whitespacesAndNewlines))
        var next = log
        next.activities.removeAll { $0.id == id }
        next.activities.append(value)
        guard updateActivityLog(next) else { return }
        activityMessage = "Activity added to the draft. Save the thesis to share it."
        showingActivityForm = false
        editingActivityID = nil
    }

    private func editActivity(_ value: ThesisActivity) {
        editingActivityID = value.id
        activityDate = value.date
        activityHours = Self.hoursText(value.hours)
        activityCategory = value.category
        activityDescription = value.description
        showingActivityForm = true
        activityMessage = ""
    }

    private func removeActivity(_ value: ThesisActivity, from log: ThesisActivityLog) {
        guard editable, pendingActivityRemovalID == value.id else { return }
        var next = log
        next.activities.removeAll { $0.id == value.id }
        guard updateActivityLog(next) else { return }
        pendingActivityRemovalID = nil
        activityMessage = "Activity removed from the draft. Save the thesis to share the change."
    }

    private func applyActivityStartYear(_ log: ThesisActivityLog) {
        guard editable, validActivityYear, let year = Int(activityStartYear) else { return }
        var next = log
        next.startYear = year
        guard updateActivityLog(next) else { return }
        activityMessage = "Initial timetable year updated in the draft. Save the thesis to share it."
    }

    private func updateActivityLog(_ log: ThesisActivityLog) -> Bool {
        guard editable, let updated = ThesisWorkspaceCodec.settingActivityLog(log, on: active) else { return false }
        var nextSheets = sheets
        nextSheets[activeIndex] = updated
        let body = ThesisWorkspaceCodec.write(nextSheets)
        guard body.utf16.count <= ThesisDocument.bodyLimit else {
            activityMessage = "The thesis workspace is full. Remove content before changing the activity log."
            return false
        }
        bodyText = body
        return true
    }

    private static func hoursText(_ value: Double) -> String {
        String((value * 100).rounded() / 100)
    }

}
