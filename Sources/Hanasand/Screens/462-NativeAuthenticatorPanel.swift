import AppKit
import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import Vision

struct NativeAuthenticatorPanel: View {
    private let vault: any NativeAuthenticatorVault
    @StateObject private var camera = NativeAuthenticatorQRCamera()
    @State private var entries: [NativeAuthenticatorEntry] = []
    @State private var label = ""
    @State private var secretOrURI = ""
    @State private var message: String?
    @State private var isImportingQR = false
    @State private var pendingDeletion: NativeAuthenticatorEntry?

    init(vault: any NativeAuthenticatorVault = KeychainNativeAuthenticatorVault()) {
        self.vault = vault
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Authenticator").font(.largeTitle.weight(.semibold))
                    Text("Store TOTP secrets in this Mac’s Keychain and copy codes here.")
                        .foregroundStyle(.secondary)
                }

                GroupBox("Add an account") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Account label", text: $label)
                            .textFieldStyle(.roundedBorder)
                        TextField("Base32 secret or otpauth:// URI", text: $secretOrURI, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...3)
                        HStack {
                            Button(camera.isRunning ? "Stop camera" : "Scan with camera") {
                                if camera.isRunning { camera.stop() } else { camera.start() }
                            }
                            .disabled(camera.isStarting)
                            Button("Choose QR image…") { isImportingQR = true }
                            Button("Add code", action: addEntry)
                                .keyboardShortcut(.defaultAction)
                                .disabled(secretOrURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        if let cameraStatus = camera.statusMessage {
                            Text(cameraStatus)
                                .font(.callout)
                                .foregroundStyle(camera.isError ? .red : .secondary)
                                .textSelection(.enabled)
                        }
                        if camera.isRunning {
                            NativeAuthenticatorCameraPreview(session: camera.session)
                                .frame(maxWidth: .infinity)
                                .frame(height: 240)
                                .background(Color.black)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(alignment: .bottomLeading) {
                                    Text("Hold a TOTP QR code in front of the camera.")
                                        .font(.caption.weight(.semibold))
                                        .padding(8)
                                        .background(.black.opacity(0.65), in: Capsule())
                                        .foregroundStyle(.white)
                                        .padding(10)
                                }
                        }
                    }
                    .padding(.top, 5)
                }

                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(message.hasPrefix("Added") || message.hasPrefix("Updated") ? .green : .red)
                        .textSelection(.enabled)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Saved codes").font(.title2.weight(.semibold))
                    if entries.isEmpty {
                        ContentUnavailableView("No authenticator codes", systemImage: "key.horizontal", description: Text("Add a Base32 secret or choose an image containing a TOTP QR code."))
                            .frame(maxWidth: .infinity, minHeight: 150)
                    } else {
                        ForEach(entries) { entry in
                            AuthenticatorCodeRow(entry: entry, onCopy: { copy(entry) }, onDelete: { pendingDeletion = entry })
                        }
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear(perform: reload)
        .onChange(of: camera.scannedPayload) { _, payload in
            guard let payload else { return }
            importScannedQR(payload)
        }
        .onDisappear { camera.stop() }
        .fileImporter(isPresented: $isImportingQR, allowedContentTypes: [.image], allowsMultipleSelection: false, onCompletion: importQR)
        .confirmationDialog("Delete authenticator code?", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let entry = pendingDeletion { delete(entry) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(pendingDeletion?.label ?? "")
        }
    }

    private func reload() {
        do { entries = try vault.read() }
        catch { message = error.localizedDescription }
    }

    private func addEntry() {
        let value = secretOrURI.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            var entry: NativeAuthenticatorEntry
            if value.lowercased().hasPrefix("otpauth://") {
                entry = try NativeAuthenticator.parse(value)
                if !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { entry.label = label.trimmingCharacters(in: .whitespacesAndNewlines) }
            } else {
                entry = NativeAuthenticatorEntry(label: label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Authenticator code" : label,
                                                 secret: value)
                try NativeAuthenticator.validate(entry)
            }
            let isUpdate = entries.contains { $0.secret == entry.secret }
            let next = NativeAuthenticator.upsert(entry, into: entries)
            try vault.save(next)
            entries = next
            label = ""
            secretOrURI = ""
            message = "\(isUpdate ? "Updated" : "Added") \(entry.label)."
        } catch { message = error.localizedDescription }
    }

    private func delete(_ entry: NativeAuthenticatorEntry) {
        do {
            let next = entries.filter { $0.id != entry.id }
            try vault.save(next)
            entries = next
            message = "Deleted \(entry.label)."
        } catch { message = error.localizedDescription }
    }

    private func copy(_ entry: NativeAuthenticatorEntry) {
        do {
            let code = try NativeAuthenticator.code(for: entry)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            message = "Copied a code for \(entry.label)."
        } catch { message = error.localizedDescription }
    }

    private func importQR(_ result: Result<[URL], Error>) {
        do {
            let url = try result.get().first.unwrap(or: NativeAuthenticatorError.imageHasNoQRCode)
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw NativeAuthenticatorError.imageHasNoQRCode
            }
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            try VNImageRequestHandler(cgImage: image).perform([request])
            guard let payload = request.results?.compactMap(\.payloadStringValue).first(where: { $0.lowercased().hasPrefix("otpauth://totp/") }) else {
                throw NativeAuthenticatorError.imageHasNoQRCode
            }
            secretOrURI = payload
            addEntry()
        } catch { message = error.localizedDescription }
    }

    private func importScannedQR(_ payload: String) {
        camera.stop()
        guard NativeAuthenticatorQRScan.isTOTPURI(payload) else {
            message = "This QR code is not a TOTP authenticator. Scan an otpauth://totp/ code."
            return
        }
        secretOrURI = payload
        addEntry()
    }
}

enum NativeAuthenticatorQRScan {
    static func isTOTPURI(_ payload: String) -> Bool {
        guard payload.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              let components = URLComponents(string: payload),
              components.scheme?.caseInsensitiveCompare("otpauth") == .orderedSame,
              components.host?.caseInsensitiveCompare("totp") == .orderedSame,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              let label = components.percentEncodedPath.removingPercentEncoding,
              label.hasPrefix("/"),
              label.count > 1 else {
            return false
        }
        return true
    }
}

@MainActor
private final class NativeAuthenticatorQRCamera: NSObject, ObservableObject, AVCaptureMetadataOutputObjectsDelegate {
    @Published private(set) var statusMessage: String?
    @Published private(set) var scannedPayload: String?
    @Published private(set) var isStarting = false
    @Published private(set) var isError = false

    private let resources = NativeAuthenticatorCameraResources()
    private let queue = DispatchQueue(label: "com.hanasand.desktop.authenticator-qr-camera")
    private var configured = false
    private var permissionRequestID: UUID?

    var session: AVCaptureSession { resources.session }
    var isRunning: Bool { resources.session.isRunning }

    func start() {
        scannedPayload = nil
        isError = false
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            let requestID = UUID()
            permissionRequestID = requestID
            isStarting = true
            statusMessage = "Waiting for camera permission…"
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async {
                    guard let self, self.permissionRequestID == requestID else { return }
                    self.permissionRequestID = nil
                    self.isStarting = false
                    if allowed {
                        self.configureAndStart()
                    } else {
                        self.fail("Camera access was denied. Allow Hanasand in System Settings → Privacy & Security → Camera.")
                    }
                }
            }
        case .denied, .restricted:
            fail("Camera access is off. Allow Hanasand in System Settings → Privacy & Security → Camera.")
        @unknown default:
            fail("Camera access is unavailable on this Mac.")
        }
    }

    func stop() {
        permissionRequestID = nil
        isStarting = false
        let resources = self.resources
        queue.async { resources.session.stopRunning() }
        statusMessage = "Camera scanning stopped."
    }

    private func configureAndStart() {
        guard !isStarting, !isRunning else { return }
        isStarting = true
        isError = false
        statusMessage = "Starting camera…"
        let resources = self.resources
        let wasConfigured = configured
        queue.async { [weak self] in
            do {
                let session = resources.session
                let output = resources.output
                if !wasConfigured {
                    session.beginConfiguration()
                    session.sessionPreset = .high
                    guard let device = AVCaptureDevice.default(for: .video) else {
                        session.commitConfiguration()
                        DispatchQueue.main.async { [weak self] in self?.fail("No camera is available on this Mac.") }
                        return
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input), session.canAddOutput(output) else {
                        session.commitConfiguration()
                        DispatchQueue.main.async { [weak self] in self?.fail("The camera cannot scan QR codes on this Mac.") }
                        return
                    }
                    session.addInput(input)
                    session.addOutput(output)
                    guard output.availableMetadataObjectTypes.contains(.qr) else {
                        session.commitConfiguration()
                        DispatchQueue.main.async { [weak self] in self?.fail("This camera cannot detect QR codes.") }
                        return
                    }
                    output.metadataObjectTypes = [.qr]
                    output.setMetadataObjectsDelegate(self, queue: .main)
                    session.commitConfiguration()
                    DispatchQueue.main.async { [weak self] in self?.configured = true }
                }
                session.startRunning()
                let running = session.isRunning
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isStarting = false
                    self.isError = !running
                    self.statusMessage = running ? "Camera is ready. Present a TOTP QR code to scan." : "The camera could not start. Check that it is available, then try again."
                }
            } catch {
                DispatchQueue.main.async { [weak self] in self?.fail("Camera setup failed: \(error.localizedDescription)") }
            }
        }
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let payload = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            self.scannedPayload = payload
            self.stop()
        }
    }

    private func fail(_ message: String) {
        isStarting = false
        isError = true
        statusMessage = message
    }
}

private struct NativeAuthenticatorCameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NativeAuthenticatorCameraPreviewView {
        let view = NativeAuthenticatorCameraPreviewView(frame: .zero)
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ view: NativeAuthenticatorCameraPreviewView, context: Context) {
        if view.previewLayer.session !== session { view.previewLayer.session = session }
    }
}

private final class NativeAuthenticatorCameraPreviewView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func makeBackingLayer() -> CALayer {
        let layer = AVCaptureVideoPreviewLayer()
        layer.videoGravity = .resizeAspectFill
        return layer
    }

    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override var wantsUpdateLayer: Bool { true }
}

private final class NativeAuthenticatorCameraResources: @unchecked Sendable {
    let session = AVCaptureSession()
    let output = AVCaptureMetadataOutput()
}

private struct AuthenticatorCodeRow: View {
    let entry: NativeAuthenticatorEntry
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.label).font(.headline)
                    if let account = entry.account, !account.isEmpty { Text(account).font(.caption).foregroundStyle(.secondary) }
                    if let code = try? NativeAuthenticator.code(for: entry, at: context.date) {
                        Text(code).font(.system(.title, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                    } else {
                        Text("Invalid secret").foregroundStyle(.red)
                    }
                    Text("Refreshes in \(NativeAuthenticator.remainingSeconds(for: entry, at: context.date))s")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Copy", action: onCopy)
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .help("Delete code")
            }
            .padding(14)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private extension Optional {
    func unwrap(or error: Error) throws -> Wrapped {
        guard let value = self else { throw error }
        return value
    }
}
