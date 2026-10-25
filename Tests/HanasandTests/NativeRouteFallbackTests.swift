import XCTest
@testable import Hanasand

final class NativeRouteFallbackTests: XCTestCase {
    func testUnsupportedRouteIsNamedInNativeMessage() {
        let path = "/automation/health/2ee166a"

        XCTAssertEqual(NativeRouteFallbackDetails.routeName(path), path)
        XCTAssertEqual(
            NativeRouteFallbackDetails.message(for: path),
            "Desktop does not have a native screen for /automation/health/2ee166a."
        )
    }

    func testMissingRouteUsesClearFallbackCopy() {
        XCTAssertEqual(NativeRouteFallbackDetails.routeName(nil), "(no route selected)")
        XCTAssertEqual(NativeRouteFallbackDetails.routeName("  \n"), "(no route selected)")
        XCTAssertEqual(
            NativeRouteFallbackDetails.message(for: nil),
            "Desktop does not have a native screen for this route."
        )
    }
}
