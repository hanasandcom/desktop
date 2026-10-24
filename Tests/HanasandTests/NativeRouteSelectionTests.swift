import XCTest
@testable import Hanasand

final class NativeRouteSelectionTests: XCTestCase {
    func testResolvesOnlyAnAvailableTrimmedIdentifier() {
        XCTAssertEqual(NativeRouteSelection.resolve("  article-42  ", among: ["article-42", "article-43"]), "article-42")
        XCTAssertNil(NativeRouteSelection.resolve("article-44", among: ["article-42", "article-43"]))
        XCTAssertNil(NativeRouteSelection.resolve("  ", among: ["article-42"]))
    }

    func testRejectsPathTraversalAndControlCharacters() {
        let available = ["../settings", "folder/article", "folder\\article", "bad\nidentifier"]
        for identifier in available {
            XCTAssertNil(NativeRouteSelection.resolve(identifier, among: available), identifier)
        }
    }
}
