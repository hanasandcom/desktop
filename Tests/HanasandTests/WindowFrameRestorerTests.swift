import XCTest
@testable import Hanasand

final class WindowFrameRestorerTests: XCTestCase {
    private let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testPreservesSavedFrameWhenItFitsOnAConnectedDisplay() {
        let secondary = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let saved = CGRect(x: 1800, y: 240, width: 900, height: 600)

        XCTAssertEqual(
            WindowFrameRestorationLayout.restoredFrame(
                for: saved,
                on: [primary, secondary],
                fallbackScreen: primary
            ),
            saved
        )
    }

    func testMovesMostlyOffscreenFrameIntoTheDisplay() {
        let saved = CGRect(x: 1380, y: 850, width: 900, height: 600)

        let restored = WindowFrameRestorationLayout.restoredFrame(
            for: saved,
            on: [primary],
            fallbackScreen: nil
        )

        XCTAssertEqual(restored, CGRect(x: 540, y: 300, width: 900, height: 600))
    }

    func testMovesDisconnectedDisplayFrameToTheCurrentDisplay() {
        let disconnectedSaved = CGRect(x: 5000, y: 300, width: 800, height: 600)

        let restored = WindowFrameRestorationLayout.restoredFrame(
            for: disconnectedSaved,
            on: [primary],
            fallbackScreen: primary
        )

        XCTAssertEqual(restored, CGRect(x: 640, y: 300, width: 800, height: 600))
    }

    func testOversizedFrameKeepsItsSizeAndLeavesAnAccessibleStripOnscreen() {
        let oversized = CGRect(x: -4000, y: -3000, width: 2200, height: 1400)

        let restored = WindowFrameRestorationLayout.restoredFrame(
            for: oversized,
            on: [primary],
            fallbackScreen: primary
        )

        XCTAssertEqual(restored?.size, oversized.size)
        XCTAssertEqual(restored?.minX, -2120)
        XCTAssertEqual(restored?.maxX, 80)
        XCTAssertEqual(restored?.minY, -1356)
        XCTAssertEqual(restored?.maxY, 44)
    }

    func testRejectsInvalidSavedFrameAndMissingDisplay() {
        XCTAssertNil(WindowFrameRestorationLayout.restoredFrame(
            for: .zero,
            on: [primary],
            fallbackScreen: primary
        ))
        XCTAssertNil(WindowFrameRestorationLayout.restoredFrame(
            for: CGRect(x: 0, y: 0, width: 500, height: 400),
            on: [],
            fallbackScreen: nil
        ))
    }
}
