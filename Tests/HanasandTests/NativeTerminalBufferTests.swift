import XCTest
@testable import Hanasand

final class NativeTerminalBufferTests: XCTestCase {
    func testSGRColorsAndCursorPositionAreRendered() {
        var terminal = NativeTerminalBuffer(columns: 20, rows: 8)
        terminal.feed("\u{1b}[31mred\u{1b}[0m\u{1b}[2;3H!")

        let rows = terminal.visibleRows
        XCTAssertTrue(rows[0].runs.contains { $0.text.contains("red") && $0.foreground == 1 })
        XCTAssertTrue(rows[1].runs.first(where: { $0.text.contains("!") })?.text.hasPrefix("  !") == true)
    }

    func testEraseAndAlternateScreenRestoreMainScreen() {
        var terminal = NativeTerminalBuffer(columns: 20, rows: 8)
        terminal.feed("main\u{1b}[?1049hALT\u{1b}[?1049l")

        XCTAssertTrue(terminal.visibleRows[0].runs.contains { $0.text.contains("main") })
        XCTAssertFalse(terminal.visibleRows[0].runs.contains { $0.text.contains("ALT") })

        terminal.feed("\r\u{1b}[2Kclean")
        XCTAssertTrue(terminal.visibleRows[0].runs.contains { $0.text.contains("clean") })
        XCTAssertFalse(terminal.visibleRows[0].runs.contains { $0.text.contains("main") })
    }

    func testScrollbackAndDimensionsStayBounded() {
        var terminal = NativeTerminalBuffer(columns: 20, rows: 8)
        for index in 0..<600 { terminal.feed("line\(index)\n") }
        terminal.resize(columns: 900, rows: 400)

        XCTAssertLessThanOrEqual(terminal.columns, 120)
        XCTAssertLessThanOrEqual(terminal.rows, 48)
        XCTAssertLessThanOrEqual(terminal.scrollbackCount, NativeTerminalBuffer.maximumScrollbackRows)
        XCTAssertEqual(terminal.historyRows.count, terminal.scrollbackCount + terminal.rows)
    }

    func testEscapeSequenceCanArriveAcrossChunksAndEraseDisplay() {
        var terminal = NativeTerminalBuffer(columns: 20, rows: 8)
        terminal.feed("hello\u{1b}[")
        terminal.feed("2J")

        XCTAssertFalse(terminal.visibleRows[0].runs.contains { $0.text.contains("hello") })
    }

    func testTrueColorAndTextStylesArePreserved() {
        var terminal = NativeTerminalBuffer(columns: 20, rows: 8)
        terminal.feed("\u{1b}[38;2;1;2;3;48;2;4;5;6;1;2;3;4;5;7;9;53mX")

        let run = terminal.visibleRows[0].runs.first { $0.text.contains("X") }
        XCTAssertEqual(run?.foreground, 0x1000000 | 0x010203)
        XCTAssertEqual(run?.background, 0x1000000 | 0x040506)
        XCTAssertEqual([run?.bold, run?.italic, run?.dim, run?.underline, run?.strike, run?.overline, run?.blink, run?.inverse],
                       [true, true, true, true, true, true, true, true])
    }

    func testANSI256AndColonTrueColorSGRFormsAreRendered() {
        var terminal = NativeTerminalBuffer(columns: 30, rows: 8)
        terminal.feed("\u{1b}[38;5;196;48;5;33mindexed \u{1b}[38:2::12:34:56;48:2:0:78:90:123mcolon \u{1b}[38:5:201mindexed-colon")

        let row = terminal.visibleRows[0]
        let indexed = row.runs.first { $0.text.contains("indexed") }
        XCTAssertEqual(indexed?.foreground, 196)
        XCTAssertEqual(indexed?.background, 33)
        let colon = row.runs.first { $0.text.contains("colon") }
        XCTAssertEqual(colon?.foreground, 0x1000000 | 0x0c2238)
        XCTAssertEqual(colon?.background, 0x1000000 | 0x4e5a7b)
        XCTAssertEqual(row.runs.first { $0.text.contains("indexed-colon") }?.foreground, 201)
    }

    func testUnicodeCombiningMarkAtPendingWrapStaysWithFinalCell() {
        var terminal = NativeTerminalBuffer(columns: 20, rows: 8)
        terminal.feed(String(repeating: "a", count: 19) + "d")
        terminal.feed("\u{301}")

        XCTAssertTrue(terminal.visibleRows[0].runs.contains { $0.text.contains("d́") })
        terminal.feed("x")
        XCTAssertTrue(terminal.visibleRows[1].runs.first?.text.hasPrefix("x") == true)
    }

    func testWideUnicodeGraphemeWrapsBeforeSingleRemainingColumn() {
        var terminal = NativeTerminalBuffer(columns: 20, rows: 8)
        terminal.feed(String(repeating: "a", count: 19) + "\u{1b}[1;20H界")

        XCTAssertTrue(terminal.visibleRows[0].runs.first?.text.hasPrefix(String(repeating: "a", count: 19)) == true)
        XCTAssertTrue(terminal.visibleRows[1].runs.first?.text.hasPrefix("界") == true)
        XCTAssertEqual(terminal.cursorColumnPosition, 2)
    }

    func testEmojiJoinerAndVariationSelectorRemainSingleWideGraphemes() {
        var terminal = NativeTerminalBuffer(columns: 12, rows: 8)
        terminal.feed("👩‍💻✈️")

        XCTAssertEqual(terminal.cursorColumnPosition, 4)
        XCTAssertTrue(terminal.visibleRows[0].runs.first?.text.hasPrefix("👩‍💻✈️") == true)
    }

    func testScrollRegionKeepsRowsOutsideTheRegionAndCharacterEditingWorks() {
        var terminal = NativeTerminalBuffer(columns: 20, rows: 8)
        terminal.feed("\u{1b}[1;1Htop\u{1b}[2;1Hkeep\u{1b}[3;1Hone\u{1b}[4;1Htwo\u{1b}[5;1Hthree\u{1b}[6;1Hend")
        terminal.feed("\u{1b}[3;5r\u{1b}[5;1H\n")

        let text = terminal.visibleRows.map { $0.runs.map(\.text).joined() }
        XCTAssertTrue(text[0].contains("top"))
        XCTAssertTrue(text[1].contains("keep"))
        XCTAssertTrue(text[5].contains("end"))

        terminal.feed("\u{1b}[1;1Habcdef\u{1b}[1;3H\u{1b}[P")
        XCTAssertTrue(terminal.visibleRows[0].runs.first?.text.hasPrefix("abdef") == true)
    }

    func testUnicodeWideAndCombiningCharactersAndInteractiveModes() {
        var terminal = NativeTerminalBuffer(columns: 20, rows: 8)
        terminal.feed("A界e\u{301}\u{1b}[?1h\u{1b}[?2004h\u{1b}[?1000h\u{1b}[?1006h\u{1b}[?25l\u{1b}[5 q")

        XCTAssertEqual(terminal.cursorColumnPosition, 4)
        XCTAssertTrue(terminal.visibleRows[0].runs.contains { $0.text.contains("界é") })
        XCTAssertTrue(terminal.applicationCursorKeys)
        XCTAssertTrue(terminal.bracketedPaste)
        XCTAssertTrue(terminal.mouseTracking)
        XCTAssertEqual(terminal.mouseEncoding, "sgr")
        XCTAssertFalse(terminal.cursorVisible)
        XCTAssertTrue(terminal.cursorBlink)
        XCTAssertEqual(terminal.cursorStyle, 2)
    }

    func testDeviceStatusResponsesUseCurrentCursorAndIgnoreOSCClipboardRequests() {
        var terminal = NativeTerminalBuffer(columns: 20, rows: 8)
        let replies = terminal.feed("abc\u{1b}[6n\u{1b}[5n\u{1b}[c\u{1b}Z\u{1b}]52;c;c2VjcmV0\u{7}")

        XCTAssertEqual(replies, ["\u{1b}[1;4R", "\u{1b}[0n", "\u{1b}[?1;2c", "\u{1b}[?1;2c"])
    }

    func testMouseProtocolsClampCoordinatesAndRespectTrackingMode() {
        XCTAssertEqual(nativeTerminalMouseReport(column: 3, row: 4, columns: 20, rows: 8, action: .press, trackingMode: "normal", encoding: "sgr"), "\u{1b}[<0;4;5M")
        XCTAssertEqual(nativeTerminalMouseReport(column: 3, row: 4, columns: 20, rows: 8, action: .release, trackingMode: "normal", encoding: "sgr"), "\u{1b}[<3;4;5m")
        XCTAssertNil(nativeTerminalMouseReport(column: 3, row: 4, columns: 20, rows: 8, action: .release, trackingMode: "x10", encoding: "sgr"))
        XCTAssertEqual(nativeTerminalMouseReport(column: 999, row: 999, columns: 20, rows: 8, action: .wheelUp, trackingMode: "drag", encoding: "urxvt"), "\u{1b}[96;20;8M")
    }
}
