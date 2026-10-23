import XCTest
@testable import Hanasand

final class ThesisUndoHistoryTests: XCTestCase {
    func testTypingInOneFieldCoalescesAndKeepsCurrentRevisionWhenUndoing() {
        var history = ThesisUndoHistory()
        let base = ThesisDocument(title: "Research", body: "A", revision: 4)
        let firstEdit = ThesisDocument(title: "Research", body: "AB", revision: 4)
        let secondEdit = ThesisDocument(title: "Research", body: "ABC", revision: 4)

        history.remember(base, group: "source-overview", now: 1)
        history.remember(firstEdit, group: "source-overview", now: 1.4)

        XCTAssertEqual(history.undoCount, 1)
        XCTAssertEqual(history.redoCount, 0)
        let newerRevision = ThesisDocument(title: secondEdit.title, body: secondEdit.body, revision: 9)
        XCTAssertEqual(history.travel(current: newerRevision, redo: false), ThesisDocument(title: base.title, body: base.body, revision: 9))
        XCTAssertEqual(history.undoCount, 0)
        XCTAssertEqual(history.redoCount, 1)
        XCTAssertEqual(history.travel(current: ThesisDocument(title: base.title, body: base.body, revision: 9), redo: true), newerRevision)
    }

    func testDifferentEditsCreateEntriesAndNewEditClearsRedoBranch() {
        var history = ThesisUndoHistory()
        let base = ThesisDocument(title: "Research", body: "A", revision: 8)
        let afterTitle = ThesisDocument(title: "Updated", body: "A", revision: 8)
        let afterBody = ThesisDocument(title: "Updated", body: "B", revision: 8)
        let replacement = ThesisDocument(title: "Updated", body: "C", revision: 8)

        history.remember(base, group: "title", now: 1)
        history.remember(afterTitle, group: "source-overview", now: 1.1)
        XCTAssertEqual(history.undoCount, 2)

        XCTAssertEqual(history.travel(current: afterBody, redo: false), afterTitle)
        XCTAssertEqual(history.redoCount, 1)
        history.remember(ThesisDocument(title: "Updated", body: "B", revision: 8), group: nil, now: 2)
        XCTAssertEqual(history.redoCount, 0)
        XCTAssertNil(history.travel(current: replacement, redo: true))
    }

    func testDocumentTitleAndBodyUseOneUndoSequence() {
        var history = ThesisUndoHistory()
        let initial = ThesisDocument(title: "Thesis", body: "Overview", revision: 5)
        let renamed = ThesisDocument(title: "New thesis title", body: "Overview", revision: 5)
        let edited = ThesisDocument(title: "New thesis title", body: "Revised overview", revision: 5)

        history.remember(initial, group: "document-title", now: 1)
        history.remember(ThesisDocument(title: "New thesis", body: "Overview", revision: 5), group: "document-title", now: 1.3)
        history.remember(renamed, group: "document-title", now: 1.6)
        history.remember(renamed, now: 2)

        XCTAssertEqual(history.travel(current: edited, redo: false), renamed)
        XCTAssertEqual(history.travel(current: renamed, redo: false), initial)
        XCTAssertEqual(history.travel(current: initial, redo: true), renamed)
        XCTAssertEqual(history.travel(current: renamed, redo: true), edited)
    }

    func testHistoryIsBoundedAndCanBeClearedAfterConflictResolution() {
        var history = ThesisUndoHistory()
        for index in 0...55 {
            history.remember(ThesisDocument(title: "Research", body: "\(index)", revision: 2), now: TimeInterval(index))
        }
        XCTAssertEqual(history.undoCount, 50)

        history.clear()
        XCTAssertEqual(history.undoCount, 0)
        XCTAssertEqual(history.redoCount, 0)
        XCTAssertNil(history.travel(current: ThesisDocument(title: "Research", body: "latest", revision: 2), redo: false))
    }
}
