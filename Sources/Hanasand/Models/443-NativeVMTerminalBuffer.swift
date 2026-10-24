import Foundation

struct NativeTerminalRun: Equatable, Identifiable {
    let id: Int
    let text: String
    let foreground: Int
    let background: Int
    let bold: Bool
    let italic: Bool
    let dim: Bool
    let underline: Bool
    let strike: Bool
    let overline: Bool
    let blink: Bool
    let inverse: Bool
    let invisible: Bool
}

struct NativeTerminalRow: Equatable, Identifiable {
    let id: Int
    let runs: [NativeTerminalRun]
}

enum NativeTerminalPointerAction: Equatable { case press, release, move, wheelUp, wheelDown }

func nativeTerminalMouseReport(
    column: Int, row: Int, columns: Int, rows: Int,
    action: NativeTerminalPointerAction, trackingMode: String, encoding: String
) -> String? {
    guard trackingMode != "none" else { return nil }
    if trackingMode == "x10", action != .press { return nil }
    if trackingMode == "normal", action == .move { return nil }
    let x = min(columns, max(1, column + 1))
    let y = min(rows, max(1, row + 1))
    let code: Int
    switch action {
    case .press: code = 0
    case .release: code = 3
    case .move: code = 32
    case .wheelUp: code = 64
    case .wheelDown: code = 65
    }
    switch encoding {
    case "sgr": return "\u{1b}[<\(code);\(x);\(y)\(action == .release ? "m" : "M")"
    case "urxvt": return "\u{1b}[\(code + 32);\(x);\(y)M"
    case "utf8", "legacy":
        guard encoding == "utf8" || (x <= 223 && y <= 223) else { return nil }
        guard let button = UnicodeScalar(code + 32), let cx = UnicodeScalar(x + 32), let cy = UnicodeScalar(y + 32) else { return nil }
        return "\u{1b}[M\(String(button))\(String(cx))\(String(cy))"
    default: return nil
    }
}

/// A deliberately bounded VT subset for server consoles. It is not a full xterm emulator.
struct NativeTerminalBuffer {
    private struct Cell: Equatable {
        var character = " "
        var continuation = false
        var foreground = 7
        var background = -1
        var bold = false
        var italic = false
        var dim = false
        var underline = false
        var strike = false
        var overline = false
        var blink = false
        var inverse = false
        var invisible = false
    }

    static let maximumColumns = 120
    static let maximumRows = 48
    static let maximumScrollbackRows = 1_000

    private(set) var columns = 80
    private(set) var rows = 24
    private var screen: [[Cell]] = []
    private var scrollback: [[Cell]] = []
    private var cursorRow = 0
    private var cursorColumn = 0
    private var savedCursor = (row: 0, column: 0)
    private var alternateScreen: [[Cell]]?
    private var parserState: ParserState = .ground
    private var csiBuffer = ""
    private var currentForeground = 7
    private var currentBackground = -1
    private var currentBold = false
    private var currentItalic = false
    private var currentDim = false
    private var currentUnderline = false
    private var currentStrike = false
    private var currentOverline = false
    private var currentBlink = false
    private var currentInverse = false
    private var currentInvisible = false
    private(set) var applicationCursorKeys = false
    private(set) var bracketedPaste = false
    private(set) var mouseTrackingMode = "none"
    var mouseTracking: Bool { mouseTrackingMode != "none" }
    var isAlternateScreen: Bool { alternateScreen != nil }
    private(set) var mouseEncoding = "legacy"
    private(set) var cursorVisible = true
    private(set) var cursorBlink = false
    private(set) var cursorStyle = 0
    private var scrollTop = 0
    private var scrollBottom = 23
    private var pendingReplies: [String] = []

    private enum ParserState { case ground, escape, csi, osc, oscEscape, ignoredControlString, ignoredControlStringEscape }

    init(columns: Int = 80, rows: Int = 24) {
        resize(columns: columns, rows: rows)
    }

    var visibleRows: [NativeTerminalRow] {
        let visible = screen
        return visible.enumerated().map { rowIndex, row in
            var runs: [NativeTerminalRun] = []
            var text = ""
            var style: Cell?
            for cell in row {
                if cell.continuation { continue }
                if let style, !sameStyle(style, cell) {
                    runs.append(makeRun(runs.count, text, style))
                    text = ""
                }
                style = cell
                text.append(cell.character)
            }
            if let style, !text.isEmpty {
                runs.append(makeRun(runs.count, text, style))
            }
            return NativeTerminalRow(id: rowIndex, runs: runs)
        }
    }

    var historyRows: [NativeTerminalRow] {
        let allRows = scrollback + screen
        return allRows.enumerated().map { rowIndex, row in
            var runs: [NativeTerminalRun] = []
            var text = ""
            var style: Cell?
            for cell in row {
                if cell.continuation { continue }
                if let style, !sameStyle(style, cell) {
                    runs.append(makeRun(runs.count, text, style))
                    text = ""
                }
                style = cell
                text.append(cell.character)
            }
            if let style, !text.isEmpty {
                runs.append(makeRun(runs.count, text, style))
            }
            return NativeTerminalRow(id: rowIndex, runs: runs)
        }
    }

    var scrollbackCount: Int { scrollback.count }
    var cursorHistoryRow: Int { scrollback.count + cursorRow }
    var cursorColumnPosition: Int { cursorColumn }

    private func sameStyle(_ lhs: Cell, _ rhs: Cell) -> Bool {
        lhs.foreground == rhs.foreground && lhs.background == rhs.background && lhs.bold == rhs.bold
            && lhs.italic == rhs.italic && lhs.dim == rhs.dim && lhs.underline == rhs.underline
            && lhs.strike == rhs.strike && lhs.overline == rhs.overline && lhs.blink == rhs.blink
            && lhs.inverse == rhs.inverse && lhs.invisible == rhs.invisible
    }

    private func makeRun(_ id: Int, _ text: String, _ cell: Cell) -> NativeTerminalRun {
        NativeTerminalRun(id: id, text: text, foreground: cell.foreground, background: cell.background,
            bold: cell.bold, italic: cell.italic, dim: cell.dim, underline: cell.underline,
            strike: cell.strike, overline: cell.overline, blink: cell.blink, inverse: cell.inverse,
            invisible: cell.invisible)
    }

    mutating func resize(columns requestedColumns: Int, rows requestedRows: Int) {
        let newColumns = min(Self.maximumColumns, max(20, requestedColumns))
        let newRows = min(Self.maximumRows, max(8, requestedRows))
        guard newColumns != columns || newRows != rows || screen.isEmpty else { return }
        columns = newColumns
        rows = newRows
        if screen.isEmpty {
            screen = Array(repeating: Array(repeating: Cell(), count: columns), count: rows)
        } else {
            screen = screen.prefix(rows).map { Array($0.prefix(columns)) + Array(repeating: Cell(), count: max(0, columns - $0.count)) }
            if screen.count < rows { screen += Array(repeating: Array(repeating: Cell(), count: columns), count: rows - screen.count) }
        }
        scrollback = scrollback.map { Array($0.prefix(columns)) + Array(repeating: Cell(), count: max(0, columns - $0.count)) }
        if let alternateScreen {
            var resizedAlternate = alternateScreen.prefix(rows).map { Array($0.prefix(columns)) + Array(repeating: Cell(), count: max(0, columns - $0.count)) }
            if resizedAlternate.count < rows { resizedAlternate += Array(repeating: Array(repeating: Cell(), count: columns), count: rows - resizedAlternate.count) }
            self.alternateScreen = resizedAlternate
        }
        cursorRow = min(cursorRow, rows - 1)
        cursorColumn = min(cursorColumn, columns - 1)
        scrollTop = 0
        scrollBottom = rows - 1
    }

    mutating func clear() {
        screen = Array(repeating: Array(repeating: Cell(), count: columns), count: rows)
        scrollback.removeAll(keepingCapacity: true)
        cursorRow = 0
        cursorColumn = 0
    }

    mutating func reset() { resetTerminal() }

    @discardableResult
    mutating func feed(_ text: String) -> [String] {
        pendingReplies.removeAll(keepingCapacity: true)
        for character in text {
            switch parserState {
            case .ground:
                consumeGround(character)
            case .escape:
                parserState = .ground
                switch character {
                case "[": parserState = .csi; csiBuffer = ""
                case "]": parserState = .osc
                case "P", "^", "_": parserState = .ignoredControlString
                case "Z": pendingReplies.append("\u{1b}[?1;2c")
                case "7": savedCursor = (cursorRow, cursorColumn)
                case "8": cursorRow = savedCursor.row; cursorColumn = savedCursor.column
                case "c": resetTerminal()
                default: break
                }
            case .csi:
                if character.isASCII, (character.asciiValue ?? 0) >= 0x40, (character.asciiValue ?? 0) <= 0x7e {
                    handleCSI(final: character)
                    parserState = .ground
                } else if csiBuffer.count < 64 {
                    csiBuffer.append(character)
                } else {
                    parserState = .ground
                }
            case .osc:
                if character == "\u{7}" { parserState = .ground }
                else if character == "\u{1b}" { parserState = .oscEscape }
            case .oscEscape:
                parserState = character == "\\" ? .ground : .osc
            case .ignoredControlString:
                if character == "\u{1b}" { parserState = .ignoredControlStringEscape }
            case .ignoredControlStringEscape:
                parserState = character == "\\" ? .ground : .ignoredControlString
            }
        }
        return pendingReplies
    }

    private mutating func consumeGround(_ character: Character) {
        switch character {
        case "\u{1b}": parserState = .escape
        case "\r": cursorColumn = 0
        case "\n": lineFeed()
        case "\u{08}": cursorColumn = max(0, cursorColumn - 1)
        case "\t": cursorColumn = min(columns - 1, ((cursorColumn / 8) + 1) * 8)
        default:
            guard character.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else { return }
            if isCombining(character), cursorColumn > 0 {
                var previous = cursorColumn - 1
                if screen[cursorRow][previous].continuation, previous > 0 { previous -= 1 }
                screen[cursorRow][previous].character.append(String(character))
                return
            }
            let width = isWide(character) ? 2 : 1
            screen[cursorRow][cursorColumn] = currentCell(character: String(character))
            if width == 2, cursorColumn + 1 < columns {
                var continuation = currentCell(character: " ")
                continuation.continuation = true
                screen[cursorRow][cursorColumn + 1] = continuation
            }
            cursorColumn += width
            if cursorColumn >= columns { cursorColumn = 0; lineFeed() }
        }
    }

    private func currentCell(character: String) -> Cell {
        Cell(character: character, foreground: currentForeground, background: currentBackground,
            bold: currentBold, italic: currentItalic, dim: currentDim, underline: currentUnderline,
            strike: currentStrike, overline: currentOverline, blink: currentBlink,
            inverse: currentInverse, invisible: currentInvisible)
    }

    private func isCombining(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    private func isWide(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        let value = scalar.value
        return (0x1100...0x115f).contains(value) || (0x2e80...0xa4cf).contains(value)
            || (0xac00...0xd7a3).contains(value) || (0xf900...0xfaff).contains(value)
            || (0xfe10...0xfe6f).contains(value) || (0xff01...0xff60).contains(value)
            || (0x1f300...0x1faff).contains(value) || (0x20000...0x3fffd).contains(value)
    }

    private mutating func lineFeed() {
        if cursorRow == scrollBottom {
            if scrollTop == 0 && scrollBottom == rows - 1 {
                if alternateScreen == nil {
                    scrollback.append(screen.removeFirst())
                    if scrollback.count > Self.maximumScrollbackRows { scrollback.removeFirst(scrollback.count - Self.maximumScrollbackRows) }
                } else { screen.removeFirst() }
                screen.append(Array(repeating: Cell(), count: columns))
            } else {
                screen.remove(at: scrollTop)
                screen.insert(Array(repeating: Cell(), count: columns), at: scrollBottom)
            }
        } else {
            cursorRow = min(rows - 1, cursorRow + 1)
        }
    }

    private mutating func handleCSI(final: Character) {
        let privateMode = csiBuffer.hasPrefix("?")
        let values = csiBuffer.drop(while: { $0 == "?" }).split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
        let first = values.first ?? 0
        switch final {
        case "A": cursorRow = max(0, cursorRow - max(1, first))
        case "B": cursorRow = min(rows - 1, cursorRow + max(1, first))
        case "C": cursorColumn = min(columns - 1, cursorColumn + max(1, first))
        case "D": cursorColumn = max(0, cursorColumn - max(1, first))
        case "H", "f":
            cursorRow = min(rows - 1, max(0, (values.first ?? 1) - 1))
            cursorColumn = min(columns - 1, max(0, (values.dropFirst().first ?? 1) - 1))
        case "J": eraseDisplay(mode: first)
        case "K": eraseLine(mode: first)
        case "m": setGraphics(values.isEmpty ? [0] : values)
        case "r":
            scrollTop = min(rows - 1, max(0, (values.first ?? 1) - 1))
            scrollBottom = min(rows - 1, max(scrollTop, (values.dropFirst().first ?? rows) - 1))
            cursorRow = scrollTop; cursorColumn = 0
        case "S": scrollUp(max(1, first))
        case "T": scrollDown(max(1, first))
        case "L": insertLines(max(1, first))
        case "M": deleteLines(max(1, first))
        case "@": insertCharacters(max(1, first))
        case "P": deleteCharacters(max(1, first))
        case "X": eraseCharacters(max(1, first))
        case "s": savedCursor = (cursorRow, cursorColumn)
        case "u": cursorRow = savedCursor.row; cursorColumn = savedCursor.column
        case "h", "l":
            for mode in values {
                if privateMode && mode == 1 { applicationCursorKeys = final == "h" }
                if privateMode && mode == 12 { cursorBlink = final == "h" }
                if privateMode && mode == 25 { cursorVisible = final == "h" }
                if privateMode && mode == 2004 { bracketedPaste = final == "h" }
                if privateMode && [9, 1000, 1002, 1003].contains(mode) { mouseTrackingMode = final == "h" ? (mode == 9 ? "x10" : mode == 1000 ? "normal" : mode == 1002 ? "drag" : "any") : "none" }
                if privateMode && mode == 1006 { mouseEncoding = final == "h" ? "sgr" : "legacy" }
                if privateMode && mode == 1005 { mouseEncoding = final == "h" ? "utf8" : "legacy" }
                if privateMode && mode == 1015 { mouseEncoding = final == "h" ? "urxvt" : "legacy" }
                if privateMode && mode == 1049 {
                    if final == "h", alternateScreen == nil {
                        alternateScreen = screen
                        screen = Array(repeating: Array(repeating: Cell(), count: columns), count: rows)
                        cursorRow = 0; cursorColumn = 0
                    } else if final == "l", let previous = alternateScreen {
                        screen = previous
                        alternateScreen = nil
                        cursorRow = 0; cursorColumn = 0
                    }
                }
            }
        case "n":
            if first == 5 { pendingReplies.append("\u{1b}[0n") }
            if first == 6 { pendingReplies.append("\u{1b}[\(cursorRow + 1);\(cursorColumn + 1)R") }
        case "c": pendingReplies.append("\u{1b}[?1;2c")
        case "q" where csiBuffer.contains(" "):
            let value = first
            cursorBlink = value == 0 || value == 1 || value == 3 || value == 5
            cursorStyle = value == 3 || value == 4 ? 1 : value == 5 || value == 6 ? 2 : 0
        default: break
        }
    }

    private mutating func resetTerminal() {
        clear()
        currentForeground = 7; currentBackground = -1; currentBold = false
        currentItalic = false; currentDim = false; currentUnderline = false; currentStrike = false
        currentOverline = false; currentBlink = false; currentInverse = false; currentInvisible = false
        applicationCursorKeys = false; bracketedPaste = false; mouseTrackingMode = "none"; mouseEncoding = "legacy"
        cursorVisible = true; cursorBlink = false; cursorStyle = 0
        scrollTop = 0; scrollBottom = rows - 1
        alternateScreen = nil
        parserState = .ground
        csiBuffer = ""
    }

    private mutating func eraseDisplay(mode: Int) {
        switch mode {
        case 2, 3:
            screen = Array(repeating: Array(repeating: Cell(), count: columns), count: rows)
            if mode == 3 { scrollback.removeAll() }
        case 0:
            eraseLine(mode: 0)
            if cursorRow + 1 < rows { for row in (cursorRow + 1)..<rows { screen[row] = Array(repeating: Cell(), count: columns) } }
        case 1:
            if cursorRow > 0 { for row in 0..<cursorRow { screen[row] = Array(repeating: Cell(), count: columns) } }
            eraseLine(mode: 1)
        default: break
        }
    }

    private mutating func eraseLine(mode: Int) {
        let range: ClosedRange<Int>
        switch mode {
        case 1: range = 0...cursorColumn
        case 2: range = 0...(columns - 1)
        default: range = cursorColumn...(columns - 1)
        }
        for column in range { screen[cursorRow][column] = Cell() }
    }

    private mutating func scrollUp(_ count: Int) {
        for _ in 0..<min(count, rows) {
            let removed = screen.remove(at: scrollTop)
            if scrollTop == 0 && scrollBottom == rows - 1 && alternateScreen == nil {
                scrollback.append(removed)
                if scrollback.count > Self.maximumScrollbackRows { scrollback.removeFirst(scrollback.count - Self.maximumScrollbackRows) }
            }
            screen.insert(Array(repeating: Cell(), count: columns), at: scrollBottom)
        }
    }

    private mutating func scrollDown(_ count: Int) {
        for _ in 0..<min(count, rows) {
            screen.remove(at: scrollBottom)
            screen.insert(Array(repeating: Cell(), count: columns), at: scrollTop)
        }
    }

    private mutating func insertLines(_ count: Int) {
        guard (scrollTop...scrollBottom).contains(cursorRow) else { return }
        for _ in 0..<min(count, scrollBottom - cursorRow + 1) {
            screen.remove(at: scrollBottom)
            screen.insert(Array(repeating: Cell(), count: columns), at: cursorRow)
        }
    }

    private mutating func deleteLines(_ count: Int) {
        guard (scrollTop...scrollBottom).contains(cursorRow) else { return }
        for _ in 0..<min(count, scrollBottom - cursorRow + 1) {
            screen.remove(at: cursorRow)
            screen.insert(Array(repeating: Cell(), count: columns), at: scrollBottom)
        }
    }

    private mutating func insertCharacters(_ count: Int) {
        guard cursorColumn < columns else { return }
        let amount = min(count, columns - cursorColumn)
        screen[cursorRow].insert(contentsOf: Array(repeating: Cell(), count: amount), at: cursorColumn)
        screen[cursorRow] = Array(screen[cursorRow].prefix(columns))
    }

    private mutating func deleteCharacters(_ count: Int) {
        guard cursorColumn < columns else { return }
        let amount = min(count, columns - cursorColumn)
        screen[cursorRow].removeSubrange(cursorColumn..<(cursorColumn + amount))
        screen[cursorRow] += Array(repeating: Cell(), count: amount)
    }

    private mutating func eraseCharacters(_ count: Int) {
        guard cursorColumn < columns else { return }
        for column in cursorColumn..<min(columns, cursorColumn + count) { screen[cursorRow][column] = Cell() }
    }

    private mutating func setGraphics(_ values: [Int]) {
        var index = 0
        while index < values.count {
            let value = values[index]
            switch value {
            case 0:
                currentForeground = 7; currentBackground = -1; currentBold = false
                currentItalic = false; currentDim = false; currentUnderline = false; currentStrike = false
                currentOverline = false; currentBlink = false; currentInverse = false; currentInvisible = false
            case 1: currentBold = true
            case 2: currentDim = true
            case 3: currentItalic = true
            case 4: currentUnderline = true
            case 5, 6: currentBlink = true
            case 7: currentInverse = true
            case 8: currentInvisible = true
            case 9: currentStrike = true
            case 21: currentUnderline = true
            case 22: currentBold = false; currentDim = false
            case 23: currentItalic = false
            case 24: currentUnderline = false
            case 25: currentBlink = false
            case 27: currentInverse = false
            case 28: currentInvisible = false
            case 29: currentStrike = false
            case 53: currentOverline = true
            case 55: currentOverline = false
            case 30...37: currentForeground = value - 30
            case 39: currentForeground = 7
            case 40...47: currentBackground = value - 40
            case 49: currentBackground = -1
            case 90...97: currentForeground = value - 90 + 8
            case 100...107: currentBackground = value - 100 + 8
            case 38, 48:
                guard index + 1 < values.count else { break }
                let isForeground = value == 38
                if values[index + 1] == 5, index + 2 < values.count {
                    let color = min(255, max(0, values[index + 2]))
                    if isForeground { currentForeground = color } else { currentBackground = color }
                    index += 2
                } else if values[index + 1] == 2, index + 4 < values.count {
                    let red = min(255, max(0, values[index + 2]))
                    let green = min(255, max(0, values[index + 3]))
                    let blue = min(255, max(0, values[index + 4]))
                    let color = 0x1000000 | (red << 16) | (green << 8) | blue
                    if isForeground { currentForeground = color } else { currentBackground = color }
                    index += 4
                }
            default: break
            }
            index += 1
        }
    }
}
