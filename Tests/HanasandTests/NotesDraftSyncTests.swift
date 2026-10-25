import Foundation
import XCTest

@testable import Hanasand

final class NotesDraftSyncTests: XCTestCase {
    private enum OfflineError: Error {
        case unavailable
    }

    func testOfflineDraftSurvivesFailureAndRetryClearsAfterServerConfirmation() async throws {
        let (store, suiteName) = try makeStore()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let draft = makeDraft()
        store.save(draft, for: "account-a")

        do {
            _ = try await DashboardNoteDraftSync.sync(
                draft,
                userID: "account-a",
                store: store,
                fetchNotes: { throw OfflineError.unavailable },
                createNote: { _, _ in XCTFail("Offline lookup must fail before writing"); throw OfflineError.unavailable },
                updateNote: { _, _, _ in XCTFail("Offline lookup must fail before writing"); throw OfflineError.unavailable }
            )
            XCTFail("Expected offline request to fail")
        } catch is OfflineError {
            XCTAssertEqual(store.draft(noteID: draft.noteID, for: "account-a"), draft)
        }

        let saved = try await DashboardNoteDraftSync.sync(
            draft,
            userID: "account-a",
            store: store,
            fetchNotes: { [] },
            createNote: { title, content in
                XCTAssertEqual(title, draft.title)
                XCTAssertEqual(content, draft.content)
                XCTAssertEqual(store.draft(noteID: draft.noteID, for: "account-a"), draft)
                return makeNote(id: "server-note", title: title, content: content, updatedAt: "2026-10-25T10:00:00Z")
            },
            updateNote: { _, _, _ in XCTFail("A new local note should use create"); throw OfflineError.unavailable }
        )

        guard case .saved(let confirmed) = saved else {
            return XCTFail("Expected the server-confirmed note to be saved")
        }
        XCTAssertEqual(confirmed.id, "server-note")
        XCTAssertNil(store.draft(noteID: draft.noteID, for: "account-a"))
    }

    func testConflictPreservesLocalDraftAndDoesNotWrite() async throws {
        let (store, suiteName) = try makeStore()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let draft = makeDraft(noteID: "note-1", baseUpdatedAt: "2026-10-20T10:00:00Z")
        let website = makeNote(id: "note-1", title: "Website edit", content: "New version", updatedAt: "2026-10-25T10:00:00Z")
        store.save(draft, for: "account-a")

        let result = try await DashboardNoteDraftSync.sync(
            draft,
            userID: "account-a",
            store: store,
            fetchNotes: { [website] },
            createNote: { _, _ in XCTFail("Conflicts must not create"); throw OfflineError.unavailable },
            updateNote: { _, _, _ in XCTFail("Conflicts must not overwrite"); throw OfflineError.unavailable }
        )

        guard case .conflict(let remote) = result else { return XCTFail("Expected a version conflict") }
        XCTAssertEqual(remote?.title, website.title)
        XCTAssertEqual(store.draft(noteID: draft.noteID, for: "account-a"), draft)
    }

    func testEditMadeDuringSyncRemainsPendingAgainstConfirmedVersion() async throws {
        let (store, suiteName) = try makeStore()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let draft = makeDraft(noteID: "note-1", baseUpdatedAt: "2026-10-20T10:00:00Z")
        let newer = DashboardNoteDraft(
            noteID: draft.noteID,
            title: "Latest local title",
            content: "Typed during request",
            baseUpdatedAt: draft.baseUpdatedAt,
            savedAt: Date(timeIntervalSince1970: 200)
        )
        store.save(draft, for: "account-a")

        let result = try await DashboardNoteDraftSync.sync(
            draft,
            userID: "account-a",
            store: store,
            fetchNotes: { [remote = makeNote(id: "note-1", title: draft.title, content: draft.content, updatedAt: draft.baseUpdatedAt)] in [remote] },
            createNote: { _, _ in XCTFail("Existing note should use update"); throw OfflineError.unavailable },
            updateNote: { _, title, content in
                store.save(newer, for: "account-a")
                return makeNote(id: "note-1", title: title, content: content, updatedAt: "2026-10-25T11:00:00Z")
            }
        )

        guard case .newerDraftPreserved = result else { return XCTFail("Expected the newer edit to remain pending") }
        let pending = try XCTUnwrap(store.draft(noteID: "note-1", for: "account-a"))
        XCTAssertEqual(pending.title, newer.title)
        XCTAssertEqual(pending.content, newer.content)
        XCTAssertEqual(pending.baseUpdatedAt, "2026-10-25T11:00:00Z")
    }

    private func makeStore() throws -> (DashboardNoteDraftStore, String) {
        let suiteName = "NotesDraftSyncTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return (DashboardNoteDraftStore(defaults: defaults), suiteName)
    }

    private func makeDraft(noteID: String = DashboardNoteDraftStore.newNoteID, baseUpdatedAt: String? = nil) -> DashboardNoteDraft {
        DashboardNoteDraft(
            noteID: noteID,
            title: "Offline draft",
            content: "Keep this work",
            baseUpdatedAt: baseUpdatedAt,
            savedAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func makeNote(id: String, title: String, content: String, updatedAt: String?) -> DashboardNote {
        DashboardNote(
            id: id,
            title: title,
            content: content,
            source: "desktop",
            ownerID: "account-a",
            createdAt: nil,
            updatedAt: updatedAt
        )
    }
}
