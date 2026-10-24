import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ImagesJourneyNativePanel: View {
    @State private var section: Section = .library

    init(initialSection: String? = nil) {
        let requested = Section(rawValue: initialSection ?? "") ?? .library
        _section = State(initialValue: requested)
    }

    var body: some View {
        VStack(spacing: 10) {
            Picker("Images", selection: $section) {
                ForEach(Section.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            switch section {
            case .library: GalleryLibraryNativePanel()
            case .albums: GalleryAlbumsNativePanel()
            case .upload: GalleryPhotoUploadNativePanel(onLibrary: { section = .library })
            case .deviceReview: DevicePhotoReviewNativePanel()
            }
        }
    }

    private enum Section: String, CaseIterable, Identifiable {
        case library, albums, upload, deviceReview
        var id: String { rawValue }
        var title: String {
            switch self {
            case .library: "Library"
            case .albums: "Albums"
            case .upload: "Upload photos"
            case .deviceReview: "Review device photos"
            }
        }
    }
}

private struct GalleryPhotoUploadNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var selection: [PhotosPickerItem] = []
    @State private var uploadPending = false
    @State private var stopRequested = false
    @State private var completed = 0
    @State private var progress = ""
    @State private var error = ""
    var onLibrary: () -> Void

    private var sessionFingerprint: String {
        let value = model.settings
        return "\(value.cdnBaseURL)|\(value.userID)|\(value.authToken.hashValue)|\(value.impersonatingUserID)|\(value.impersonationToken.hashValue)"
    }

    private var impersonating: Bool {
        !model.settings.impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !model.settings.impersonationToken.isEmpty
    }

    var body: some View {
        FeatureWorkspace(title: "Upload photos", subtitle: "Select photos from this Mac and add them to your private CDN library") {
            if !model.hasHanasandAuth {
                NativeEmptyState(title: "Sign in to upload photos", message: "Photos are added to the private image library for your signed-in account.")
            } else if impersonating {
                NativeEmptyState(title: "Return to your own account", message: "Photo uploads are unavailable while an impersonation token or target account is active.")
            } else {
                NativeGroupPanel(title: "Choose photos", subtitle: "The upload is checked against your CDN account before photo data is sent") {
                    PhotosPicker(selection: $selection, maxSelectionCount: 50, matching: .images) {
                        Label(selection.isEmpty ? "Choose photos" : "Change selection · \(selection.count) selected", systemImage: "photo.on.rectangle.angled")
                    }
                    .buttonStyle(.bordered)
                    .disabled(uploadPending)

                    if !selection.isEmpty {
                        Text("\(selection.count) selected · Up to 50 MB per photo")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                    }
                    HStack(spacing: 8) {
                        ActionButton(title: uploadPending ? "Uploading…" : "Upload selected", icon: "arrow.up.to.line", tone: .normal) {
                            Task { await uploadSelection() }
                        }
                        .disabled(uploadPending || selection.isEmpty)
                        if uploadPending {
                            ActionButton(title: stopRequested ? "Stopping…" : "Stop after current", icon: "stop.fill") {
                                stopRequested = true
                            }
                            .disabled(stopRequested)
                        } else {
                            ActionButton(title: "Clear selection", icon: "xmark") { selection = []; error = "" }
                                .disabled(selection.isEmpty)
                        }
                    }
                    if completed > 0 {
                        Text("\(completed) photo\(completed == 1 ? "" : "s") added to your library.")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                        ActionButton(title: "View library", icon: "photo.stack", tone: .normal, action: onLibrary)
                    }
                    if !progress.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(progress).font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(progress)
                    }
                    if !error.isEmpty {
                        Text(error).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.danger).textSelection(.enabled)
                        if !selection.isEmpty && !uploadPending {
                            ActionButton(title: "Retry remaining photos", icon: "arrow.clockwise", tone: .normal) {
                                Task { await uploadSelection() }
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: sessionFingerprint) { _, _ in
            if uploadPending { stopRequested = true }
        }
    }

    @MainActor private func uploadSelection() async {
        guard !uploadPending, !selection.isEmpty, !impersonating, model.hasHanasandAuth else { return }
        uploadPending = true
        stopRequested = false
        error = ""
        let selected = selection
        let snapshot = model.settings
        let client: GalleryPhotoUploadClient
        do { client = try GalleryPhotoUploadClient(settings: snapshot) }
        catch {
            self.error = error.localizedDescription
            uploadPending = false
            return
        }

        var uploadIndex = 0
        let result = await GalleryPhotoUploadQueue.run(selected, shouldStop: { stopRequested }) { item in
            let index = uploadIndex
            progress = "Preparing photo \(index + 1) of \(selected.count)…"
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw GalleryPhotoUploadError.invalidSize
            }
            let mime = item.supportedContentTypes.compactMap(\.preferredMIMEType).first?.lowercased() ?? ""
            guard let ext = Self.fileExtension(for: mime) else { throw GalleryPhotoUploadError.unsupportedType }
            let photo = GalleryPhotoUpload(name: "Photo-\(UUID().uuidString).\(ext)", type: mime, data: data)
            progress = "Uploading photo \(index + 1) of \(selected.count)…"
            _ = try await client.upload(photo)
            uploadIndex += 1
        }

        completed += result.completedCount
        selection = result.pending
        progress = ""
        uploadPending = false
        stopRequested = false
        if let issue = result.error { error = "\(issue) The remaining selection is ready to retry." }
        else if result.stopped { error = "Stopped after the current photo. The remaining selection is ready to upload." }
        else if result.completedCount > 0 { error = "" }
    }

    private static func fileExtension(for mime: String) -> String? {
        switch mime {
        case "image/jpeg": "jpg"
        case "image/png": "png"
        case "image/gif": "gif"
        case "image/webp": "webp"
        case "image/avif": "avif"
        case "image/heic": "heic"
        case "image/heif": "heif"
        default: nil
        }
    }
}
