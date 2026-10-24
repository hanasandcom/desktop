import XCTest
@testable import Hanasand

final class ShortcutLinkValidationTests: XCTestCase {
    func testIdentifierMatchesWebsiteShortcutRules() {
        XCTAssertEqual(ShortcutLinkValidation.identifier(" /g/team_docs-2 "), "team_docs-2")
        XCTAssertEqual(ShortcutLinkValidation.identifier("g/Short"), "Short")
        XCTAssertNil(ShortcutLinkValidation.identifier(""))
        XCTAssertNil(ShortcutLinkValidation.identifier("two/segments"))
        XCTAssertNil(ShortcutLinkValidation.identifier(String(repeating: "a", count: 65)))
    }

    func testDestinationAddsHTTPSAndAllowsWebsiteProtocols() {
        XCTAssertEqual(ShortcutLinkValidation.destination("example.com/path"), "https://example.com/path")
        XCTAssertEqual(ShortcutLinkValidation.destination("mailto:hello@example.com"), "mailto:hello@example.com")
        XCTAssertEqual(ShortcutLinkValidation.destination("tel:+4799999999"), "tel:+4799999999")
        XCTAssertEqual(ShortcutLinkValidation.destination("https://example.com"), "https://example.com")
    }

    func testDestinationRejectsInvalidProtocolsAndMalformedURLs() {
        XCTAssertNil(ShortcutLinkValidation.destination("javascript:alert(1)"))
        XCTAssertNil(ShortcutLinkValidation.destination("https://"))
        XCTAssertNil(ShortcutLinkValidation.destination("http://localhost"))
        XCTAssertNil(ShortcutLinkValidation.destination("https://user:password@example.com"))
        XCTAssertNil(ShortcutLinkValidation.destination("example.com/path with spaces"))
        XCTAssertNil(ShortcutLinkValidation.destination("mailto:"))
    }
}
