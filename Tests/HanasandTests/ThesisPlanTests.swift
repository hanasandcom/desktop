import XCTest
@testable import Hanasand

final class ThesisPlanTests: XCTestCase {
    func testPlanAliasesSummaryFilteringAndStatusLanes() throws {
        let model = ThesisPlanModel(table: table([
            ["Milestone", "Effort", "State", "Iteration", "% Complete", "Description", "Updates", "Checklist", "Custom field"],
            ["Write proposal", "4", "Completed", "Sprint 1", "100", "Notes", "Details", "- [x] Draft", "kept"],
            ["Review", "2.5", "", "Sprint 2", "0", "", "", "", "also kept"],
            ["Summary", "99", "Completed", "", "", "", "", "", "not a task"]
        ]))

        XCTAssertEqual(model.fields.task, 0)
        XCTAssertEqual(model.fields.hours, 1)
        XCTAssertEqual(model.fields.status, 2)
        XCTAssertEqual(model.fields.sprint, 3)
        XCTAssertEqual(model.fields.progress, 4)
        XCTAssertEqual(model.fields.notes, 5)
        XCTAssertEqual(model.fields.details, 6)
        XCTAssertEqual(model.fields.subgoals, 7)
        XCTAssertEqual(model.tasks.count, 2)
        XCTAssertEqual(model.estimatedHours, 6.5)
        XCTAssertEqual(model.completedCount, 1)
        XCTAssertEqual(model.completedHours, 4)
        XCTAssertEqual(model.inProgressCount, 0)
        XCTAssertEqual(model.sprints, ["Sprint 1", "Sprint 2"])
        XCTAssertEqual(model.tasks(filteredToSprint: "Sprint 2").map(\.rowIndex), [2])
        XCTAssertEqual(model.tasks(inStatus: "Planned").map(\.rowIndex), [2])
        XCTAssertEqual(model.tasks(inStatus: "Completed").map(\.rowIndex), [1])
    }

    func testSubgoalChangesPreserveOtherCellsAndUpdateProgress() throws {
        let original = table([
            ["Task", "Progress", "Sub-goals", "Unknown"],
            ["Build", "0", "- [ ] First\n- [x] Second", "do not lose"]
        ])
        let model = ThesisPlanModel(table: original)
        let toggled = ThesisPlanModel(table: replacing(original, cells: model.togglingSubgoal(at: 0, row: 1)))
        XCTAssertEqual(toggled.cells[1][1], "100")
        XCTAssertEqual(toggled.cells[1][3], "do not lose")
        XCTAssertEqual(ThesisPlanModel.subgoals(in: toggled.cells[1][2]).map(\.done), [true, true])

        let addedCells = toggled.addingSubgoal(" Third ", row: 1)
        let added = ThesisPlanModel(table: replacing(original, cells: addedCells))
        XCTAssertEqual(added.cells[1][1], "67")
        XCTAssertEqual(ThesisPlanModel.subgoals(in: added.cells[1][2]).map(\.text), ["First", "Second", "Third"])

        let removed = ThesisPlanModel(table: replacing(original, cells: added.removingSubgoal(at: 0, row: 1)))
        XCTAssertEqual(removed.cells[1][1], "50")
        XCTAssertEqual(removed.cells[1][3], "do not lose")
    }

    func testUnknownHeadersAndRaggedRowsRemainIntactOnEdit() throws {
        let source = table([["Task", "Custom"], ["One", "preserve", "extra"]])
        let model = ThesisPlanModel(table: source)
        let updated = model.updating(row: 1, column: 0, value: "Changed")
        XCTAssertEqual(updated[1], ["Changed", "preserve", "extra"])
        XCTAssertEqual(ThesisPlanModel.displayStatus("legacy value"), "Planned")
        XCTAssertEqual(ThesisPlanModel.displayStatus("Waiting"), "Waiting")
    }

    func testPlanEditPreservesSurroundingMarkdownAndUnknownWorkspaceMetadata() throws {
        let sourceBody = "Before the plan.\n\n| Task | Status | Extra |\n| --- | --- | --- |\n| Draft | Planned | retain |\n\nAfter the plan."
        let source = ThesisWorkspaceCodec.write([
            ThesisSheet(body: sourceBody, metadata: ["id": "plan", "name": "Plan", "title": "# Plan", "custom": ["keep": true]])
        ])
        var sheets = ThesisWorkspaceCodec.sheets(title: "Thesis", body: source)
        let table = try XCTUnwrap(ThesisWorkspaceCodec.tables(in: sheets[0].body).first)
        let model = ThesisPlanModel(table: table)
        sheets[0].body = ThesisWorkspaceCodec.replacing(table, in: sheets[0].body, with: model.updating(row: 1, column: 0, value: "Revised"))

        let decoded = ThesisWorkspaceCodec.sheets(title: "Thesis", body: ThesisWorkspaceCodec.write(sheets))
        XCTAssertEqual(decoded[0].metadata["custom"] as? [String: Bool], ["keep": true])
        XCTAssertTrue(decoded[0].body.contains("Before the plan."))
        XCTAssertTrue(decoded[0].body.contains("After the plan."))
        XCTAssertTrue(decoded[0].body.contains("| Revised | Planned | retain |"))
    }

    private func table(_ cells: [[String]]) -> ThesisTable {
        ThesisTable(start: 0, end: 0, cells: cells, widths: [], heights: [])
    }

    private func replacing(_ table: ThesisTable, cells: [[String]]) -> ThesisTable {
        ThesisTable(start: table.start, end: table.end, cells: cells, widths: table.widths, heights: table.heights)
    }
}
