import AppKit
import SwiftUI

struct NativeVMTerminalView: View {
    @Environment(\.desktopTheme) private var theme
    let rows: [NativeTerminalRow]
    let isConnected: Bool
    let generation: Int
    let cursorRow: Int
    let cursorColumn: Int
    let cursorVisible: Bool
    let cursorBlink: Bool
    let cursorStyle: Int
    let applicationCursorKeys: Bool
    let bracketedPaste: Bool
    let mouseTracking: Bool
    let mouseTrackingMode: String
    let mouseEncoding: String
    let alternateScreen: Bool
    let columns: Int
    let screenRows: Int
    let onInput: (String, Int) -> Bool
    let onResize: (Int, Int, Int) -> Void
    @State private var lastSize = CGSize.zero
    @State private var draft = ""
    @State private var inputHidden = true

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
              ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        HStack(spacing: 0) {
                            ForEach(row.runs) { run in
                                Text(run.text)
                                    .foregroundStyle(run.invisible ? color(for: run, foreground: false) : color(for: run, foreground: true))
                                    .background(color(for: run, foreground: false))
                                    .font(.system(size: 12, weight: run.bold ? .bold : .regular, design: .monospaced))
                                    .italic(run.italic)
                                    .opacity(run.blink && !cursorBlinkOn ? 0 : run.dim ? 0.5 : 1)
                                    .underline(run.underline || run.overline)
                                    .strikethrough(run.strike)
                            }
                        }
                        .lineLimit(1)
                        .frame(height: 15, alignment: .leading)
                        .id(row.id)
                    }
                }
                .frame(minWidth: 600, minHeight: CGFloat(max(8, rows.count)) * 15, alignment: .topLeading)
                .padding(12)
                .contentShape(Rectangle())
                .focusable()
                .onKeyPress { press in handle(press) }
                .overlay(alignment: .topLeading) {
                    if isConnected && cursorVisible && cursorRow >= 0 && cursorRow < rows.count {
                        Rectangle()
                            .fill(Color.white.opacity(cursorBlink && !cursorBlinkOn ? 0 : 0.72))
                            .frame(width: cursorStyle == 2 ? 2 : 7.2, height: cursorStyle == 1 ? 2 : 15)
                            .offset(x: 12 + CGFloat(cursorColumn) * 7.2, y: 12 + CGFloat(cursorRow) * 15 + (cursorStyle == 1 ? 13 : 0))
                            .allowsHitTesting(false)
                    }
                }
                }
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    NativeTerminalPointerBridge(enabled: mouseTracking || alternateScreen, trackingMode: mouseTrackingMode) { column, row, action in
                        if mouseTracking {
                            if let report = nativeTerminalMouseReport(column: column, row: row, columns: columns, rows: screenRows,
                                action: action, trackingMode: mouseTrackingMode, encoding: mouseEncoding) {
                                _ = onInput(report, generation)
                            }
                        } else if alternateScreen && (action == .wheelUp || action == .wheelDown) {
                            let up = action == .wheelUp
                            let suffix = up ? "A" : "B"
                            _ = onInput("\u{1b}\(applicationCursorKeys ? "O" : "[")\(suffix)", generation)
                        }
                    }
                }
                .onChange(of: rows.count) { _, _ in
                    guard let last = rows.last else { return }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
                .onChange(of: viewport.size, initial: true) { _, size in
                    guard size != lastSize else { return }
                    lastSize = size
                    onResize(Int(size.width / 7.2), Int(size.height / 15), generation)
                }
            }
        }
        .task(id: isConnected) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                cursorBlinkOn.toggle()
            }
        }
        .onChange(of: generation) { _, _ in
            draft = ""
            inputHidden = true
            inputError = ""
        }
        .overlay(alignment: .topTrailing) {
            Button("Paste") {
                guard let paste = NSPasteboard.general.string(forType: .string), !paste.isEmpty else { return }
                let safe = paste.replacingOccurrences(of: "\u{1b}", with: "")
                guard safe.utf16.count <= 16_384 else { inputError = "Paste exceeds the 16,384 character input limit."; return }
                draft = safe
                inputError = ""
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(8)
            .disabled(!isConnected)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if inputHidden {
                        SecureField("Type terminal input", text: $draft)
                    } else {
                        TextField("Type terminal input", text: $draft)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit { sendDraft(asPaste: false) }
                .onChange(of: draft) { _, next in
                    if next.utf16.count > 16_384 { draft = limitedInput(next) }
                }
                HStack(spacing: 8) {
                    Button("Send + Enter") { sendDraft(asPaste: false) }.disabled(!isConnected || draft.isEmpty)
                    Button("Send Ctrl") { sendControlDraft() }.disabled(!isConnected || draft.count != 1)
                    Button("Paste text") { sendDraft(asPaste: true) }.disabled(!isConnected || draft.isEmpty)
                    Button(inputHidden ? "Show input" : "Hide input") { inputHidden.toggle() }
                    Button("Clear input") { draft = "" }.disabled(draft.isEmpty)
                }
            }
            .padding(10)
            .background(.ultraThinMaterial)
        }
        .overlay(alignment: .bottomLeading) {
            if !inputError.isEmpty {
                Text(inputError).font(.system(size: 11)).foregroundStyle(.red).padding(8)
            }
        }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard isConnected else { return .ignored }
        if press.modifiers.contains(.control) {
            if let scalar = press.characters.lowercased().unicodeScalars.first, (97...122).contains(scalar.value), let control = UnicodeScalar(scalar.value - 96) {
                inputError = onInput(String(control), generation) ? "" : "The complete input was not accepted by the console."
                return .handled
            }
        }
        let modifier = 1 + (press.modifiers.contains(.shift) ? 1 : 0)
            + (press.modifiers.contains(.option) ? 2 : 0)
            + (press.modifiers.contains(.control) ? 4 : 0)
            + (press.modifiers.contains(.command) ? 8 : 0)
        func cursorKey(_ suffix: String) -> String {
            if modifier != 1 { return "\u{1b}[1;\(modifier)\(suffix)" }
            return "\u{1b}\(applicationCursorKeys ? "O" : "[")\(suffix)"
        }
        switch press.key {
        case .upArrow: _ = onInput(cursorKey("A"), generation)
        case .downArrow: _ = onInput(cursorKey("B"), generation)
        case .rightArrow: _ = onInput(cursorKey("C"), generation)
        case .leftArrow: _ = onInput(cursorKey("D"), generation)
        case .home: _ = onInput(cursorKey("H"), generation)
        case .end: _ = onInput(cursorKey("F"), generation)
        case .pageUp: _ = onInput("\u{1b}[5~", generation)
        case .pageDown: _ = onInput("\u{1b}[6~", generation)
        case .delete: _ = onInput("\u{7f}", generation)
        case .tab: _ = onInput("\t", generation)
        case .return: _ = onInput("\r", generation)
        case .escape: _ = onInput("\u{1b}", generation)
        case .deleteForward: _ = onInput(modifier == 1 ? "\u{1b}[3~" : "\u{1b}[3;\(modifier)~", generation)
        default:
            guard !press.characters.isEmpty else { return .ignored }
            let value = String(press.characters.prefix(16_384))
            inputError = onInput(value, generation) ? "" : "The complete input was not accepted by the console."
        }
        return .handled
    }

    private func sendDraft(asPaste: Bool) {
        guard !draft.isEmpty else { return }
        let payload: String
        if asPaste {
            let safe = draft.replacingOccurrences(of: "\u{1b}", with: "")
            payload = bracketedPaste ? "\u{1b}[200~\(safe)\u{1b}[201~" : safe
        } else {
            payload = draft + "\r"
        }
        guard payload.utf16.count <= 16_384 else { inputError = "Input exceeds the 16,384 character limit."; return }
        guard onInput(payload, generation) else { inputError = "The complete input was not accepted by the console."; return }
        inputError = ""
        draft = ""
    }

    private func sendControlDraft() {
        guard draft.count == 1, let scalar = draft.uppercased().unicodeScalars.first,
              (64...95).contains(scalar.value), let control = UnicodeScalar(scalar.value - 64) else { return }
        guard onInput(String(control), generation) else { inputError = "The complete input was not accepted by the console."; return }
        inputError = ""
        draft = ""
    }

    private func limitedInput(_ value: String) -> String {
        var scalars = String.UnicodeScalarView()
        var units = 0
        for scalar in value.unicodeScalars {
            let nextUnits = scalar.value > 0xffff ? 2 : 1
            guard units + nextUnits <= 16_384 else { break }
            scalars.append(scalar)
            units += nextUnits
        }
        return String(scalars)
    }

    private func ansiColor(_ index: Int) -> Color {
        let palette: [Color] = [
            Color(hex: 0x000000), Color(hex: 0xcd0000), Color(hex: 0x00cd00), Color(hex: 0xcdcd00),
            Color(hex: 0x0000ee), Color(hex: 0xcd00cd), Color(hex: 0x00cdcd), Color(hex: 0xe5e5e5),
            Color(hex: 0x7f7f7f), Color(hex: 0xff0000), Color(hex: 0x00ff00), Color(hex: 0xffff00),
            Color(hex: 0x5c5cff), Color(hex: 0xff00ff), Color(hex: 0x00ffff), Color.white
        ]
        if index >= 0x1000000 {
            let rgb = index & 0xffffff
            return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
        }
        if index < 0 { return Color(hex: 0x101416) }
        if (0..<16).contains(index) { return palette[index] }
        if (16...231).contains(index) {
            let value = index - 16
            let component: (Int) -> Double = { $0 == 0 ? 0 : Double(55 + $0 * 40) / 255 }
            return Color(red: component(value / 36), green: component((value / 6) % 6), blue: component(value % 6))
        }
        if (232...255).contains(index) {
            let level = Double(8 + (index - 232) * 10) / 255
            return Color(red: level, green: level, blue: level)
        }
        return theme.text
    }

    private func color(for run: NativeTerminalRun, foreground: Bool) -> Color {
        var index = foreground ? run.foreground : run.background
        if foreground && run.bold && (0..<8).contains(index) { index += 8 }
        if foreground && run.inverse { index = run.background }
        if !foreground && run.inverse { index = run.foreground }
        return ansiColor(index)
    }

    @State private var cursorBlinkOn = true
    @State private var inputError = ""
}

private struct NativeTerminalPointerBridge: NSViewRepresentable {
    let enabled: Bool
    let trackingMode: String
    let onAction: (Int, Int, NativeTerminalPointerAction) -> Void

    func makeNSView(context: Context) -> NativeTerminalPointerNSView {
        let view = NativeTerminalPointerNSView()
        view.update(enabled: enabled, trackingMode: trackingMode, onAction: onAction)
        return view
    }

    func updateNSView(_ view: NativeTerminalPointerNSView, context: Context) {
        view.update(enabled: enabled, trackingMode: trackingMode, onAction: onAction)
    }

    static func dismantleNSView(_ view: NativeTerminalPointerNSView, coordinator: ()) { view.tearDown() }
}

private final class NativeTerminalPointerNSView: NSView {
    private var enabled = false
    private var trackingMode = "none"
    private var onAction: (Int, Int, NativeTerminalPointerAction) -> Void = { _, _, _ in }
    private var mouseDown = false
    private weak var configuredWindow: NSWindow?
    private var previousAcceptsMouseMovedEvents = false

    override var acceptsFirstResponder: Bool { false }

    func update(enabled: Bool, trackingMode: String, onAction: @escaping (Int, Int, NativeTerminalPointerAction) -> Void) {
        self.enabled = enabled
        self.trackingMode = trackingMode
        self.onAction = onAction
        if let window, configuredWindow !== window {
            restoreMouseMovedEvents()
            configuredWindow = window
            previousAcceptsMouseMovedEvents = window.acceptsMouseMovedEvents
        }
        if enabled { window?.acceptsMouseMovedEvents = true } else { restoreMouseMovedEvents() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window, enabled {
            configuredWindow = window
            previousAcceptsMouseMovedEvents = window.acceptsMouseMovedEvents
            window.acceptsMouseMovedEvents = true
        } else { restoreMouseMovedEvents() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        enabled ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) { mouseDown = true; report(event, .press) }
    override func mouseUp(with event: NSEvent) { report(event, .release); mouseDown = false }
    override func mouseDragged(with event: NSEvent) { if mouseDown && (trackingMode == "drag" || trackingMode == "any") { report(event, .move) } }
    override func mouseMoved(with event: NSEvent) { if trackingMode == "any" { report(event, .move) } }

    override func scrollWheel(with event: NSEvent) {
        let steps = min(8, max(1, Int(abs(event.scrollingDeltaY).rounded(.up))))
        let action: NativeTerminalPointerAction = event.scrollingDeltaY > 0 ? .wheelUp : .wheelDown
        for _ in 0..<steps { report(event, action) }
    }

    private func report(_ event: NSEvent, _ action: NativeTerminalPointerAction) {
        let point = convert(event.locationInWindow, from: nil)
        onAction(max(0, Int(point.x / 7.2)), max(0, Int((bounds.height - point.y) / 15)), action)
    }

    private func restoreMouseMovedEvents() {
        if let configuredWindow { configuredWindow.acceptsMouseMovedEvents = previousAcceptsMouseMovedEvents }
        configuredWindow = nil
    }

    func tearDown() { restoreMouseMovedEvents() }

    deinit { restoreMouseMovedEvents() }
}

private extension Color {
    init(hex: Int) {
        self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}
