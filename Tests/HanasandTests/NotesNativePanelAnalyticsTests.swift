import XCTest
@testable import Hanasand

final class NotesNativePanelAnalyticsTests: XCTestCase {
    func testWordCountMatchesWebsiteWhitespaceSplitBehavior() {
        XCTAssertEqual(NotesAnalyticsPresentation.wordCount(""), 0)
        XCTAssertEqual(NotesAnalyticsPresentation.wordCount(" \t\n\u{FEFF} "), 0)
        XCTAssertEqual(NotesAnalyticsPresentation.wordCount("one  two\nthree\u{00A0}four"), 4)
        XCTAssertEqual(NotesAnalyticsPresentation.wordCount("can't stop—now"), 2)
    }

    func testRecentNotesAreNewestFirstFilteredBySearchAndLimited() throws {
        let notes = try [
            note(id: "old", title: "Old security note", content: "one", updatedAt: "2026-01-01T12:00:00Z"),
            note(id: "new", title: "New security note", content: "two", updatedAt: "2026-03-01T12:00:00Z"),
            note(id: "middle", title: "Security checklist", content: "three", updatedAt: "2026-02-01T12:00:00Z"),
            note(id: "unrelated", title: "Travel", content: "four", updatedAt: "2026-04-01T12:00:00Z"),
        ]

        let recent = NotesAnalyticsPresentation.recentNotes(notes, query: "security", limit: 2)

        XCTAssertEqual(recent.map(\.id), ["new", "middle"])
    }

    func testRecentNotesCanBeLimitedToWebsiteDefaultOfFour() throws {
        let notes = try (1...6).map { index in
            try note(
                id: "note-\(index)",
                title: "Note \(index)",
                content: "content",
                updatedAt: "2026-01-0\(index)T12:00:00Z"
            )
        }

        XCTAssertEqual(NotesAnalyticsPresentation.recentNotes(notes, query: "").map(\.id), ["note-6", "note-5", "note-4", "note-3"])
    }

    func testAnalyticsColumnBreakpointLeavesEditorRoomAndStacksAnalyticsBelowIt() {
        let width = NotesNativePanelLayout.analyticsColumnBreakpoint
        let sidebar = NotesNativePanelLayout.sidebarWidth(contentWidth: width)
        let editor = width - sidebar - NotesNativePanelLayout.analyticsSidebarWidth - 32

        XCTAssertGreaterThanOrEqual(editor, 500)
        XCTAssertTrue(NotesNativePanelLayout.usesStackedLayout(contentWidth: 639))
        XCTAssertFalse(NotesNativePanelLayout.usesStackedLayout(contentWidth: 760))
    }

    func testUpdatedLabelUsesNewNoteForEmptySelection() {
        XCTAssertEqual(NotesAnalyticsPresentation.updatedLabel(for: nil), "New note")
    }

    private func note(id: String, title: String, content: String, updatedAt: String) throws -> DashboardNote {
        let payload = """
        {"id":"\(id)","title":"\(title)","content":"\(content)","source":"website","updated_at":"\(updatedAt)"}
        """
        return try JSONDecoder().decode(DashboardNote.self, from: Data(payload.utf8))
    }
}
