import AppKit
import SwiftUI
import WebKit

struct SandboxLiveWorkspaceNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @StateObject private var session = SandboxLiveSession()
    @State private var target = ""
    @State private var profiles = SandboxBrowserProfile.defaults
    @State private var selectedProfileID = SandboxBrowserProfile.defaults[0].id
    @State private var profileSyncMessage = ""
    @State private var isLoadingProfiles = false
    @State private var selectedFingerprintID = SandboxBrowserFingerprint.presets[0].id
    @State private var viewportWidth = String(SandboxBrowserFingerprint.presets[0].width)
    @State private var viewportHeight = String(SandboxBrowserFingerprint.presets[0].height)
    @State private var userAgent = SandboxBrowserFingerprint.presets[0].userAgent
    @State private var locale = SandboxBrowserFingerprint.presets[0].locale
    @State private var timezoneId = SandboxBrowserFingerprint.presets[0].timezoneId
    @State private var platform = SandboxBrowserFingerprint.presets[0].platform
    @State private var isMobile = SandboxBrowserFingerprint.presets[0].isMobile
    @State private var hasTouch = SandboxBrowserFingerprint.presets[0].hasTouch
    @State private var streamFailure = ""

    private var selectedProfile: SandboxBrowserProfile {
        profiles.first(where: { $0.id == selectedProfileID }) ?? SandboxBrowserProfile.defaults[0]
    }

    private var profileCredentialKey: String {
        var hasher = Hasher()
        hasher.combine(model.userIDForRequests)
        hasher.combine(model.authTokenForRequests)
        hasher.combine(model.settings.impersonationToken)
        hasher.combine(model.settings.impersonatingUserID)
        return String(hasher.finalize())
    }

    private var isImpersonating: Bool {
        !model.settings.impersonationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !model.settings.impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canStart: Bool {
        model.hasHanasandAuth && !isImpersonating && !session.isActive
            && !isLoadingProfiles
            && !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NativeGroupPanel(title: "Live browser", subtitle: "Native controls · Isolated Sandbox session") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Click, type, and scroll in the live browser. If live video is unavailable, Desktop keeps the latest frame available.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Text("Analysis profile")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                        Picker("Analysis profile", selection: $selectedProfileID) {
                            ForEach(profiles) { profile in
                                Text("\(profile.name) · \(profile.tools.count) providers").tag(profile.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(session.isActive || isLoadingProfiles)
                        if isLoadingProfiles { ProgressView().controlSize(.small) }
                    }
                    if !profileSyncMessage.isEmpty {
                        Text(profileSyncMessage)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("sandbox-profile-status")
                    }

                    DisclosureGroup("Browser fingerprint and viewport") {
                        VStack(alignment: .leading, spacing: 9) {
                            Picker("Preset", selection: $selectedFingerprintID) {
                                ForEach(SandboxBrowserFingerprint.presets) { preset in
                                    Text(preset.name).tag(preset.id)
                                }
                            }
                            .onChange(of: selectedFingerprintID) { _, id in applyFingerprint(id) }

                            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                                GridRow {
                                    metadataField("Width", value: $viewportWidth, accessibility: "Sandbox viewport width")
                                    metadataField("Height", value: $viewportHeight, accessibility: "Sandbox viewport height")
                                }
                                GridRow {
                                    metadataField("Locale", value: $locale, accessibility: "Sandbox locale")
                                    metadataField("Timezone", value: $timezoneId, accessibility: "Sandbox timezone")
                                }
                            }
                            metadataField("Platform", value: $platform, accessibility: "Sandbox platform")
                            VStack(alignment: .leading, spacing: 4) {
                                Text("User agent").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.textSecondary)
                                TextField("User agent", text: $userAgent, axis: .vertical)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(2...4)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("Sandbox user agent")
                            }
                            Toggle("Mobile emulation", isOn: $isMobile)
                                .font(.system(size: 11, weight: .medium))
                                .accessibilityIdentifier("sandbox-mobile-emulation")
                            Toggle("Touch input", isOn: $hasTouch)
                                .font(.system(size: 11, weight: .medium))
                                .accessibilityIdentifier("sandbox-touch-input")
                            let dimensions = SandboxBrowserFingerprint.streamViewport(
                                width: Int(viewportWidth) ?? 1_280,
                                height: Int(viewportHeight) ?? 720
                            )
                            Text("Stream size is limited to 921,600 pixels. This session will use \(dimensions.width) × \(dimensions.height) pixels.")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 7)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .disabled(session.isActive)
                    .accessibilityIdentifier("sandbox-fingerprint-controls")

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

            if let streamURL = session.streamURL, streamFailure.isEmpty {
                NativeGroupPanel(title: session.pageTitle.isEmpty ? "Browser viewport" : session.pageTitle,
                                 subtitle: "Live WebRTC browser stream") {
                    NativeSandboxWebRTCStreamView(url: streamURL, failureMessage: $streamFailure)
                        .aspectRatio(CGFloat(max(session.streamWidth, 1)) / CGFloat(max(session.streamHeight, 1)), contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: 720)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.divider, lineWidth: 1))
                        .accessibilityLabel("Live interactive Sandbox browser viewport")
                }
            } else if let frameData = session.frameData, let image = NSImage(data: frameData) {
                NativeGroupPanel(title: session.pageTitle.isEmpty ? "Browser viewport" : session.pageTitle,
                                 subtitle: session.pageURL.isEmpty ? "Isolated remote browser" : session.pageURL) {
                    if !streamFailure.isEmpty {
                        NativeNotice(message: streamFailure, tone: .error)
                    }
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
                    if !streamFailure.isEmpty {
                        NativeNotice(message: streamFailure, tone: .error)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Starting the isolated browser…")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                }
            }
        }
        .task(id: profileCredentialKey) { await loadProfiles() }
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
        streamFailure = ""
        let configuration = SandboxLiveConfiguration(
            userID: model.userIDForRequests,
            token: model.authTokenForRequests,
            target: target,
            isImpersonating: isImpersonating
        )
        var selectedConfiguration = configuration
        selectedConfiguration.profileTools = selectedProfile.tools
        let viewport = SandboxBrowserFingerprint.streamViewport(
            width: Int(viewportWidth) ?? 1_280,
            height: Int(viewportHeight) ?? 720
        )
        selectedConfiguration.width = viewport.width
        selectedConfiguration.height = viewport.height
        selectedConfiguration.userAgent = userAgent
        selectedConfiguration.locale = locale
        selectedConfiguration.timezoneId = timezoneId
        selectedConfiguration.platform = platform
        selectedConfiguration.isMobile = isMobile
        selectedConfiguration.hasTouch = hasTouch
        Task { await session.start(selectedConfiguration) }
    }

    private func metadataField(_ title: String, value: Binding<String>, accessibility: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.textSecondary)
            TextField(title, text: value)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(accessibility)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func applyFingerprint(_ id: String) {
        guard let preset = SandboxBrowserFingerprint.presets.first(where: { $0.id == id }) else { return }
        userAgent = preset.userAgent
        viewportWidth = String(preset.width)
        viewportHeight = String(preset.height)
        locale = preset.locale
        timezoneId = preset.timezoneId
        platform = preset.platform
        isMobile = preset.isMobile
        hasTouch = preset.hasTouch
    }

    @MainActor
    private func loadProfiles() async {
        let requestKey = profileCredentialKey
        guard model.hasHanasandAuth, !isImpersonating else {
            profiles = SandboxBrowserProfile.defaults
            selectedProfileID = SandboxBrowserProfile.defaults[0].id
            profileSyncMessage = "Sign in to load account-saved analysis profiles."
            return
        }
        isLoadingProfiles = true
        defer { isLoadingProfiles = false }
        do {
            let client = try SandboxBrowserProfileClient(
                userID: model.userIDForRequests,
                token: model.authTokenForRequests,
                impersonationToken: model.settings.impersonationToken,
                impersonatingUserID: model.settings.impersonatingUserID
            )
            let loaded = try await client.load()
            guard !Task.isCancelled, requestKey == profileCredentialKey else { return }
            profiles = loaded
            if !loaded.contains(where: { $0.id == selectedProfileID }) {
                selectedProfileID = SandboxBrowserProfile.defaults[0].id
            }
            profileSyncMessage = "Account profiles loaded. Selected providers run with the isolated browser."
        } catch {
            guard !Task.isCancelled, requestKey == profileCredentialKey else { return }
            profiles = SandboxBrowserProfile.defaults
            selectedProfileID = SandboxBrowserProfile.defaults[0].id
            profileSyncMessage = "Saved profiles unavailable; using built-in SOC triage profile. \(error.localizedDescription)"
        }
    }

    private func stopIfCredentialsChanged() {
        guard session.isActive else { return }
        Task { await session.stop() }
    }
}

private struct NativeSandboxWebRTCStreamView: NSViewRepresentable {
    let url: URL
    @Binding var failureMessage: String

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url, failureMessage: $failureMessage)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.failureMessage = $failureMessage
        if webView.url != url {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            webView.load(request)
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let allowedHost: String
        let allowedPort: Int
        var failureMessage: Binding<String>

        init(url: URL, failureMessage: Binding<String>) {
            allowedHost = url.host?.lowercased() ?? ""
            allowedPort = url.port ?? 443
            self.failureMessage = failureMessage
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.targetFrame != nil,
                  let destination = navigationAction.request.url,
                  destination.scheme?.lowercased() == "https",
                  destination.host?.lowercased() == allowedHost,
                  destination.user == nil, destination.password == nil,
                  (destination.port ?? 443) == allowedPort else {
                failureMessage.wrappedValue = "Live video left the trusted Browser service. Showing frame updates instead."
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            failureMessage.wrappedValue = ""
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            failureMessage.wrappedValue = "Live video could not connect. Showing frame updates instead."
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            failureMessage.wrappedValue = "Live video was interrupted. Showing frame updates instead."
        }
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
    private var viewportTrackingArea: NSTrackingArea?
    private var lastPointerMoveTime: TimeInterval = 0

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
        guard let image else { return }
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    override func updateTrackingAreas() {
        if let viewportTrackingArea { removeTrackingArea(viewportTrackingArea) }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        viewportTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        sendPointer(event, eventName: "pointermove", button: -1, buttons: 0, throttleMove: true)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendPointer(event, eventName: "pointerdown", button: 0, buttons: 1)
    }

    override func mouseUp(with event: NSEvent) {
        sendPointer(event, eventName: "pointerup", button: 0, buttons: 0)
    }

    override func mouseDragged(with event: NSEvent) {
        sendPointer(event, eventName: "pointermove", button: 0, buttons: 1, throttleMove: true)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendPointer(event, eventName: "pointerdown", button: 2, buttons: 2)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendPointer(event, eventName: "pointerup", button: 2, buttons: 0)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendPointer(event, eventName: "pointermove", button: 2, buttons: 2, throttleMove: true)
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendPointer(event, eventName: "pointerdown", button: 1, buttons: 4)
    }

    override func otherMouseUp(with event: NSEvent) {
        sendPointer(event, eventName: "pointerup", button: 1, buttons: 0)
    }

    override func otherMouseDragged(with event: NSEvent) {
        sendPointer(event, eventName: "pointermove", button: 1, buttons: 4, throttleMove: true)
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

    private func sendPointer(
        _ event: NSEvent,
        eventName: String,
        button: Int,
        buttons: Int,
        throttleMove: Bool = false
    ) {
        if throttleMove {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastPointerMoveTime >= 1.0 / 30.0 else { return }
            lastPointerMoveTime = now
        }
        guard let point = browserPoint(for: event),
              let message = SandboxLiveProtocol.pointerMessage(
                event: eventName, x: point.x, y: point.y, button: button, buttons: buttons
              ) else { return }
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
