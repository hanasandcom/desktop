import AVFoundation
import AppKit
import PDFKit
import SwiftUI

struct DocumentScannerNativePanel: View {
    @Environment(\.desktopTheme) private var theme
    @StateObject private var camera = DocumentScannerCamera()
    @State private var scans = DocumentScanSession()
    @State private var showingClearConfirmation = false
    @State private var pagePendingDeletion: DocumentScanPage.ID?
    @State private var exportedPDFURL: URL?
    @State private var exportedPDFRevision: Int?
    @State private var exportError: String?

    var body: some View {
        FeatureWorkspace(title: "Document Scanner", subtitle: camera.status.message) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    startCameraButton
                    capturePageButton
                    cancelCameraButton
                    exportPDFButton
                    sharePDFButton
                    clearPagesButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { startCameraButton; capturePageButton }
                    HStack(spacing: 8) { cancelCameraButton; exportPDFButton }
                    HStack(spacing: 8) { sharePDFButton; clearPagesButton }
                }
            }

            HStack(spacing: 12) {
                FeatureCard(title: "Pages", value: "\(scans.pageCount)", icon: "doc.on.doc")
                FeatureCard(title: "Camera", value: camera.status.shortTitle, icon: "camera")
                FeatureCard(title: "PDF", value: currentPDFLabel, icon: "doc.richtext")
            }

            if camera.isRunning {
                DocumentScannerCameraPreview(session: camera.session)
                    .frame(maxWidth: .infinity)
                    .frame(height: 340)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        Text("Position a page in view, then choose Capture page.")
                            .font(.caption.weight(.semibold))
                            .padding(10)
                            .background(.black.opacity(0.62), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(12)
                    }
            } else {
                NativeEmptyState(
                    title: camera.status.emptyTitle,
                    message: camera.status.message
                )
            }

            if let exportError {
                CompactInfoCard(title: "PDF export", lines: [exportError])
            }

            if scans.isEmpty {
                NativeEmptyState(title: "No scanned pages", message: "Capture pages with the camera. Reorder or remove pages before exporting them as a PDF.")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(Array(scans.pages.enumerated()), id: \.element.id) { index, page in
                        VStack(alignment: .leading, spacing: 10) {
                            Image(nsImage: page.image)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 220)
                                .frame(maxWidth: .infinity)
                                .background(Color.black.opacity(0.18))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            HStack {
                                Text("Page \(index + 1)").font(.system(size: 12, weight: .black))
                                Spacer()
                                Text(page.capturedAt, style: .time)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(theme.textTertiary)
                            }
                            HStack(spacing: 8) {
                                Button("Up") { scans.move(page.id, by: -1) }
                                    .disabled(index == 0)
                                Button("Down") { scans.move(page.id, by: 1) }
                                    .disabled(index == scans.pages.count - 1)
                                Spacer()
                                Button("Delete", role: .destructive) { pagePendingDeletion = page.id }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .bold))
                        }
                        .padding(12)
                        .background(theme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
        }
        .onChange(of: camera.captureRevision) { _, _ in
            guard let image = camera.capturedImage else { return }
            scans.append(DocumentScanPage(image: image))
            exportError = nil
        }
        .onDisappear { camera.cancel() }
        .alert("Clear scanned pages?", isPresented: $showingClearConfirmation) {
            Button("Clear", role: .destructive) {
                scans.clear()
                exportedPDFURL = nil
                exportedPDFRevision = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all \(scans.pageCount) captured pages from this scan.")
        }
        .confirmationDialog("Delete page?", isPresented: Binding(
            get: { pagePendingDeletion != nil },
            set: { if !$0 { pagePendingDeletion = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let pagePendingDeletion { scans.remove(pagePendingDeletion) }
                pagePendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pagePendingDeletion = nil }
        } message: {
            let pageNumber = scans.pages.firstIndex { $0.id == pagePendingDeletion }.map { $0 + 1 }
            Text(pageNumber.map { "Page \($0) will be removed from this scan." } ?? "This page will be removed from this scan.")
        }
    }

    private var currentPDFLabel: String {
        guard let exportedPDFURL, exportedPDFRevision == scans.revision else {
            return exportedPDFURL == nil ? "Not exported" : "Changes need export"
        }
        return exportedPDFURL.lastPathComponent
    }

    private var startCameraButton: some View {
        ActionButton(title: "Start camera", icon: "camera") { camera.start() }
            .disabled(camera.isRunning || camera.isRequestingPermission)
    }

    private var capturePageButton: some View {
        ActionButton(title: camera.isCapturing ? "Capturing…" : "Capture page", icon: "viewfinder") { camera.capture() }
            .disabled(!camera.isRunning || camera.isCapturing)
    }

    private var cancelCameraButton: some View {
        ActionButton(title: "Cancel camera", icon: "xmark.circle") { camera.cancel() }
            .disabled(!camera.isRunning && !camera.isRequestingPermission)
    }

    private var exportPDFButton: some View {
        ActionButton(title: "Export PDF", icon: "doc.richtext") { exportPDF() }
            .disabled(scans.isEmpty)
    }

    @ViewBuilder private var sharePDFButton: some View {
        if let exportedPDFURL, exportedPDFRevision == scans.revision {
            ShareLink(item: exportedPDFURL, preview: SharePreview(exportedPDFURL.lastPathComponent)) {
                Label("Share PDF", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
        }
    }

    private var clearPagesButton: some View {
        ActionButton(title: "Clear pages", icon: "trash", tone: .danger) { showingClearConfirmation = true }
            .disabled(scans.isEmpty)
    }

    private func exportPDF() {
        guard let data = DocumentScannerPDF.data(for: scans.pages) else {
            exportError = "The scanned pages could not be assembled into a PDF."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "Hanasand-Scan.pdf"
        panel.title = "Export scanned pages"
        guard panel.runModal() == .OK, let url = panel.url else {
            exportError = "PDF export cancelled. Your scanned pages are still available here."
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            exportedPDFURL = url
            exportedPDFRevision = scans.revision
            exportError = nil
        } catch {
            exportError = "Could not save the PDF: \(error.localizedDescription)"
        }
    }
}

private struct DocumentScannerCameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> DocumentScannerPreviewView {
        let view = DocumentScannerPreviewView(frame: .zero)
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ view: DocumentScannerPreviewView, context: Context) {
        if view.previewLayer.session !== session { view.previewLayer.session = session }
    }
}

private final class DocumentScannerPreviewView: NSView {
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
        layer.videoGravity = .resizeAspect
        return layer
    }

    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override var wantsUpdateLayer: Bool { true }
}

@MainActor
private final class DocumentScannerCamera: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    enum Status {
        case idle, requestingPermission, ready, denied, unavailable, failed(String), cancelled

        var shortTitle: String {
            switch self {
            case .idle: "Idle"
            case .requestingPermission: "Requesting"
            case .ready: "Ready"
            case .denied: "Permission denied"
            case .unavailable: "Unavailable"
            case .failed: "Error"
            case .cancelled: "Cancelled"
            }
        }

        var emptyTitle: String {
            switch self {
            case .denied: "Camera access is off"
            case .unavailable: "No camera available"
            case .failed: "Camera could not start"
            case .cancelled: "Camera stopped"
            case .requestingPermission: "Waiting for camera access"
            default: "Camera is ready to start"
            }
        }

        var message: String {
            switch self {
            case .idle: "Start the camera to capture a multi-page document scan."
            case .requestingPermission: "Respond to the macOS camera permission prompt."
            case .ready: "Camera is ready. Capture each page, then arrange and export the PDF."
            case .denied: "Allow camera access in System Settings → Privacy & Security → Camera, then try again."
            case .unavailable: "This Mac has no available video capture device. You can still keep this screen open; use Documents to import existing image pages."
            case .failed(let reason): reason
            case .cancelled: "Camera use was cancelled. Captured pages remain in this scan."
            }
        }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var capturedImage: NSImage?
    @Published private(set) var captureRevision = 0
    @Published private(set) var isCapturing = false
    private let resources = DocumentScannerCaptureResources()
    private let queue = DispatchQueue(label: "com.hanasand.desktop.document-scanner-camera")
    private var configured = false
    private var permissionRequestID: UUID?

    var session: AVCaptureSession { resources.session }
    var isRunning: Bool { resources.session.isRunning }
    var isRequestingPermission: Bool {
        if case .requestingPermission = status { return true }
        return false
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configureAndStart()
        case .notDetermined:
            let requestID = UUID()
            permissionRequestID = requestID
            status = .requestingPermission
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard self.permissionRequestID == requestID else { return }
                    self.permissionRequestID = nil
                    if allowed { self.configureAndStart() } else { self.status = .denied }
                }
            }
        case .denied, .restricted: status = .denied
        @unknown default: status = .unavailable
        }
    }

    func cancel() {
        permissionRequestID = nil
        let resources = self.resources
        queue.async { resources.session.stopRunning() }
        status = .cancelled
    }

    func capture() {
        guard session.isRunning, !isCapturing else { return }
        isCapturing = true
        capturedImage = nil
        resources.output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    private func configureAndStart() {
        let resources = self.resources
        let wasConfigured = configured
        queue.async { [weak self] in
            do {
                let session = resources.session
                let output = resources.output
                if !wasConfigured {
                    session.beginConfiguration()
                    session.sessionPreset = .photo
                    guard let device = AVCaptureDevice.default(for: .video) else {
                        session.commitConfiguration()
                        DispatchQueue.main.async { [weak self] in self?.status = .unavailable }
                        return
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input), session.canAddOutput(output) else {
                        session.commitConfiguration()
                        DispatchQueue.main.async { [weak self] in self?.status = .unavailable }
                        return
                    }
                    session.addInput(input)
                    session.addOutput(output)
                    session.commitConfiguration()
                    DispatchQueue.main.async { [weak self] in self?.configured = true }
                }
                session.startRunning()
                let isRunning = session.isRunning
                DispatchQueue.main.async { [weak self] in self?.status = isRunning ? .ready : .unavailable }
            } catch {
                DispatchQueue.main.async { [weak self] in self?.status = .failed("Camera setup failed: \(error.localizedDescription)") }
            }
        }
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = error == nil ? photo.fileDataRepresentation().flatMap(NSImage.init(data:)) : nil
        DispatchQueue.main.async {
            self.isCapturing = false
            if let error {
                self.status = .failed("Capture failed: \(error.localizedDescription)")
            } else if let image {
                self.capturedImage = image
                self.captureRevision += 1
            } else {
                self.status = .failed("The camera returned an empty image.")
            }
        }
    }
}

private final class DocumentScannerCaptureResources: @unchecked Sendable {
    let session = AVCaptureSession()
    let output = AVCapturePhotoOutput()
}
