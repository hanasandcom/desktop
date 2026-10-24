import AppKit
import SwiftUI

struct SandboxLiveWorkspaceNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @StateObject private var session = SandboxLiveSession()
    @State private var target = ""

    private var isImpersonating: Bool {
        !model.settings.impersonationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !model.settings.impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canStart: Bool {
        model.hasHanasandAuth && !isImpersonating && !session.isActive
            && !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NativeGroupPanel(title: "Live browser", subtitle: "Native controls · Isolated Sandbox session") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Click, type, scroll, and paste in the native viewport. Frames refresh after page actions rather than showing continuous video.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        TextField("https://example.com", text: $target)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Sandbox target address")
                            .disabled(session.isActive)
                            .onSubmit { startSession() }

                        ActionButton(title: session.state == .connecting || session.state == .starting ? "Starting…" : "Start browser", icon: "play.fill") {
                            startSession()
                        }
                        .disabled(!canStart)

                        if session.isActive {
                            ActionButton(title: "Stop", icon: "stop.fill") {
                                Task { await session.stop() }
                            }
                        }
                    }

                    if !session.serviceMessage.isEmpty {
                        Text(session.serviceMessage)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(session.state.isFailure ? theme.danger : theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("sandbox-live-status")
                    }

                    if !model.hasHanasandAuth {
                        Text("Sign in to start a Sandbox session.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                    } else if isImpersonating {
                        Text("Return to your own account to start a Sandbox session.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
            }

            if let frameData = session.frameData, let image = NSImage(data: frameData) {
                NativeGroupPanel(title: session.pageTitle.isEmpty ? "Browser viewport" : session.pageTitle,
                                 subtitle: session.pageURL.isEmpty ? "Isolated remote browser" : session.pageURL) {
                    NativeSandboxLiveViewport(
                        image: image,
                        imageWidth: session.frameWidth,
                        imageHeight: session.frameHeight,
                        onInput: session.sendInput
                    )
                    .aspectRatio(CGFloat(session.frameWidth) / CGFloat(max(session.frameHeight, 1)), contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 720)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.divider, lineWidth: 1))
                    .accessibilityLabel("Interactive native Sandbox browser viewport")
                }
            } else if session.isActive {
                NativeGroupPanel(title: "Browser viewport", subtitle: "Waiting for the first page frame") {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Starting the isolated browser…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
            }
        }
        .onChange(of: model.userIDForRequests) { _, _ in stopIfCredentialsChanged() }
        .onChange(of: model.authTokenForRequests) { _, _ in stopIfCredentialsChanged() }
        .onChange(of: model.settings.impersonationToken) { _, _ in stopIfCredentialsChanged() }
        .onChange(of: model.settings.impersonatingUserID) { _, _ in stopIfCredentialsChanged() }
        .onDisappear {
            guard session.isActive else { return }
            Task { await session.stop() }
        }
    }

    private func startSession() {
        let configuration = SandboxLiveConfiguration(
            userID: model.userIDForRequests,
            token: model.authTokenForRequests,
            target: target,
            isImpersonating: isImpersonating
        )
        Task { await session.start(configuration) }
    }

    private func stopIfCredentialsChanged() {
        guard session.isActive else { return }
        Task { await session.stop() }
    }
}

private extension SandboxLiveSessionState {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

private struct NativeSandboxLiveViewport: NSViewRepresentable {
    let image: NSImage
    let imageWidth: Int
    let imageHeight: Int
    let onInput: (String) -> Void

    func makeNSView(context: Context) -> NativeSandboxLiveInputView {
        let view = NativeSandboxLiveInputView()
        view.image = image
        view.imageWidth = imageWidth
        view.imageHeight = imageHeight
        view.onInput = onInput
        return view
    }

    func updateNSView(_ view: NativeSandboxLiveInputView, context: Context) {
        view.image = image
        view.imageWidth = imageWidth
        view.imageHeight = imageHeight
        view.onInput = onInput
        view.needsDisplay = true
    }
}

private final class NativeSandboxLiveInputView: NSView {
    var image: NSImage?
    var imageWidth = 0
    var imageHeight = 0
    var onInput: ((String) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
        guard let image else { return }
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendClick(event, button: 0)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendClick(event, button: 2)
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendClick(event, button: 1)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let point = browserPoint(for: event) else { return }
        guard let message = SandboxLiveProtocol.wheelMessage(
            x: point.x, y: point.y,
            deltaX: -Double(event.scrollingDeltaX),
            deltaY: -Double(event.scrollingDeltaY)
        ) else { return }
        onInput?(message)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags
        let command = modifiers.contains(.command)
        let control = modifiers.contains(.control)
        let option = modifiers.contains(.option)
        let shift = modifiers.contains(.shift)
        let key = keyName(event)

        if command, key.lowercased() == "v", let text = NSPasteboard.general.string(forType: .string),
           let paste = SandboxLiveProtocol.pasteMessage(text) {
            onInput?(paste)
        }
        if let message = SandboxLiveProtocol.keyMessage(key: key, command: command, control: control, option: option, shift: shift) {
            onInput?(message)
        }
    }

    private var imageRect: CGRect {
        guard imageWidth > 0, imageHeight > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / CGFloat(imageWidth), bounds.height / CGFloat(imageHeight))
        let size = CGSize(width: CGFloat(imageWidth) * scale, height: CGFloat(imageHeight) * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    private func browserPoint(for event: NSEvent) -> (x: Int, y: Int)? {
        let point = convert(event.locationInWindow, from: nil)
        let rect = imageRect
        guard rect.width > 0, rect.height > 0, rect.contains(point), imageWidth > 0, imageHeight > 0 else { return nil }
        let x = Int((point.x - rect.minX) * CGFloat(imageWidth) / rect.width)
        let y = Int((rect.maxY - point.y) * CGFloat(imageHeight) / rect.height)
        return (min(imageWidth - 1, max(0, x)), min(imageHeight - 1, max(0, y)))
    }

    private func sendClick(_ event: NSEvent, button: Int) {
        guard let point = browserPoint(for: event),
              let message = SandboxLiveProtocol.inputMessage(type: "click", x: point.x, y: point.y, button: button) else { return }
        onInput?(message)
    }

    private func keyName(_ event: NSEvent) -> String {
        switch event.keyCode {
        case 36: return "Enter"
        case 48: return "Tab"
        case 51: return "Backspace"
        case 53: return "Escape"
        case 76: return "Enter"
        case 115: return "Home"
        case 116: return "PageUp"
        case 117: return "Delete"
        case 119: return "End"
        case 121: return "PageDown"
        case 123: return "ArrowLeft"
        case 124: return "ArrowRight"
        case 125: return "ArrowDown"
        case 126: return "ArrowUp"
        default:
            let characters = event.characters ?? event.charactersIgnoringModifiers ?? ""
            return characters.isEmpty ? "Unidentified" : characters
        }
    }
}
