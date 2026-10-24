import XCTest
@testable import Hanasand

final class NativeUploadDescriptionTests: XCTestCase {
    func testDescriptionLimitMatchesWebsiteUTF16Maximum() {
        let value = String(repeating: "a", count: 1_025)

        XCTAssertEqual(NativeUploadDescriptionInput.limited(value), String(repeating: "a", count: 1_024))
        XCTAssertEqual(NativeUploadDescriptionInput.limited(String(repeating: "a", count: 1_024)), String(value.dropLast()))
    }

    func testDescriptionLimitCountsEmojiAsTwoUTF16UnitsWithoutSplittingCharacters() {
        let prefix = String(repeating: "a", count: 1_022)
        let value = prefix + "😀" + "b"

        XCTAssertEqual(NativeUploadDescriptionInput.limited(value), prefix + "😀")
        XCTAssertEqual(NativeUploadDescriptionInput.limited(value).utf16.count, 1_024)
    }

    func testDescriptionLimitPreservesComposedCharactersAndShortValues() {
        let composed = "e\u{301}"
        let value = String(repeating: "x", count: 1_023) + composed

        XCTAssertEqual(NativeUploadDescriptionInput.limited(value), String(repeating: "x", count: 1_023))
        XCTAssertEqual(NativeUploadDescriptionInput.limited("short description"), "short description")
    }
}
