import Foundation
import XCTest

@testable import Hanasand

final class NotesLocalDraftStoreTests: XCTestCase {
    func testDraftsPersistPerAccountAndCanBeReplacedAndRemoved() throws {
        let suiteName = "NotesLocalDraftStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = DashboardNoteDraftStore(defaults: defaults)
        let first = DashboardNoteDraft(
            noteID: "note-1",
            title: "Offline draft",
            content: "Keep this work",
            baseUpdatedAt: "2026-10-23T10:00:00.000Z",
            savedAt: Date(timeIntervalSince1970: 100)
        )
        let replacement = DashboardNoteDraft(
            noteID: "note-1",
            title: "Recovered draft",
            content: "Latest text",
            baseUpdatedAt: first.baseUpdatedAt,
            savedAt: Date(timeIntervalSince1970: 200)
        )

        store.save(first, for: "account-a")
        store.save(replacement, for: "account-a")
        store.save(first, for: "account-b")

        XCTAssertEqual(store.drafts(for: "account-a"), [replacement])
        XCTAssertEqual(store.draft(noteID: "note-1", for: "account-b"), first)

        store.remove(noteID: "note-1", for: "account-a")
        XCTAssertTrue(store.drafts(for: "account-a").isEmpty)
        XCTAssertEqual(store.draft(noteID: "note-1", for: "account-b"), first)
    }

    func testNewNoteDraftUsesSeparateLocalKey() throws {
        let suiteName = "NotesLocalDraftStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = DashboardNoteDraftStore(defaults: defaults)
        let draft = DashboardNoteDraft(
            noteID: DashboardNoteDraftStore.newNoteID,
            title: "Offline note",
            content: "Created while disconnected",
            baseUpdatedAt: nil,
            savedAt: Date()
        )

        store.save(draft, for: "account-a")

        XCTAssertEqual(store.draft(noteID: DashboardNoteDraftStore.newNoteID, for: "account-a"), draft)
        XCTAssertNil(store.draft(noteID: DashboardNoteDraftStore.newNoteID, for: "account-b"))
    }
}
