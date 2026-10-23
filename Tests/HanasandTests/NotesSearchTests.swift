import Foundation
import XCTest

@testable import Hanasand

final class NotesSearchTests: XCTestCase {
    private func note(id: String, title: String, content: String) throws -> DashboardNote {
        let object: [String: Any] = [
            "id": id,
            "title": title,
            "content": content,
            "source": "website",
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(DashboardNote.self, from: data)
    }

    func testSearchMatchesTitleOrContentCaseInsensitivelyAndKeepsOrder() throws {
        let notes = [
            try note(id: "1", title: "Security plan", content: "Rotate service keys"),
            try note(id: "2", title: "Travel", content: "Security conference in Oslo"),
            try note(id: "3", title: "Shopping", content: "Coffee"),
        ]

        XCTAssertEqual(NotesSearch.filter(notes, query: "  SECURITY ").map(\.id), ["1", "2"])
        XCTAssertEqual(NotesSearch.filter(notes, query: "rotate").map(\.id), ["1"])
    }

    func testEmptyOrWhitespaceQueryReturnsAllNotesAndNoMatchReturnsEmpty() throws {
        let notes = [try note(id: "1", title: "One", content: "First")]

        XCTAssertEqual(NotesSearch.filter(notes, query: "").map(\.id), ["1"])
        XCTAssertEqual(NotesSearch.filter(notes, query: " \n ").map(\.id), ["1"])
        XCTAssertTrue(NotesSearch.filter(notes, query: "missing").isEmpty)
    }
}
