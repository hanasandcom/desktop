import AppKit
import Photos
import SwiftUI

struct DevicePhotoReviewProgress {
    enum Decision: Equatable {
        case keep
        case discard
    }

    private(set) var decisions: [String: Decision] = [:]
    private(set) var history: [String] = []
    private(set) var index = 0

    var discardedIDs: Set<String> {
        Set(decisions.compactMap { $0.value == .discard ? $0.key : nil })
    }

    mutating func record(_ decision: Decision, for id: String, photoIDs: [String]) {
        guard photoIDs.indices.contains(index), photoIDs[index] == id else { return }
        decisions[id] = decision
        history.append(id)
        index += 1
    }

    mutating func undo(photoIDs: [String]) -> String? {
        guard let id = history.popLast() else { return nil }
        decisions[id] = nil
        index = photoIDs.firstIndex(of: id) ?? min(index, photoIDs.count)
        return id
    }

    mutating func resetAfterSuccessfulDeletion() {
        self = Self()
    }
}

struct DevicePhotoReviewNativePanel: View {
    @Environment(\.desktopTheme) private var theme
    @StateObject private var library = DevicePhotoLibrary()
    @State private var progress = DevicePhotoReviewProgress()
    @State private var showingDeleteConfirmation = false
    @State private var preview: NSImage?
    @State private var previewError = ""
    @State private var previewRequestID: PHImageRequestID?
    @State private var previewedPhotoID = ""
    @State private var deleteError = ""

    private var photoIDs: [String] { library.photos.map(\.localIdentifier) }
    private var currentPhoto: PHAsset? {
        guard photoIDs.indices.contains(progress.index) else { return nil }
        return library.photos[progress.index]
    }

    var body: some View {
        FeatureWorkspace(title: "Review device photos", subtitle: library.status) {
            if library.authorization == .authorized || library.authorization == .limited {
                reviewContent
            } else {
                accessContent
            }
        }
        .task { _ = await library.loadInitialPage() }
        .onChange(of: currentPhoto?.localIdentifier) { _, _ in requestPreview() }
        .onDisappear { cancelPreview() }
        .alert("Delete marked photos?", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) { Task { await deleteMarkedPhotos() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete \(progress.discardedIDs.count) marked photo\(progress.discardedIDs.count == 1 ? "" : "s") from this Mac’s Photos library? This cannot be undone.")
        }
    }

    private var accessContent: some View {
        NativeGroupPanel(title: "Photos library access", subtitle: "Review photos stored in the Photos library on this Mac") {
            if library.authorization == .notDetermined {
                NativeEmptyState(title: "Photo access needed", message: "Allow Hanasand to read your Photos library before reviewing images.")
                ActionButton(title: library.isRequestingAuthorization ? "Waiting for permission…" : "Allow photo access", icon: "photo", tone: .normal) {
                    Task { await library.requestAuthorization() }
                }
                .disabled(library.isRequestingAuthorization)
            } else {
                NativeEmptyState(
                    title: library.authorization == .restricted ? "Photo access is restricted" : "Photo access is turned off",
                    message: "Allow Hanasand in System Settings → Privacy & Security → Photos, then refresh this view."
                )
                ActionButton(title: "Check photo access again", icon: "arrow.clockwise") {
                    Task { await library.refreshAuthorizationAndLoad() }
                }
            }
            if !library.error.isEmpty { errorNotice(library.error, retry: nil) }
        }
    }

    private var reviewContent: some View {
        NativeGroupPanel(title: "Review photos", subtitle: "Keep or mark photos for deletion. Marked photos stay in your library until you confirm deletion.", fillsAvailableWidth: true) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { reviewActions }
                VStack(alignment: .leading, spacing: 8) { reviewActions }
            }

            if !library.error.isEmpty {
                errorNotice(library.error, retry: { Task { await library.loadNextPage(reset: library.photos.isEmpty) } })
            }
            if !deleteError.isEmpty {
                NativeNotice(message: deleteError, title: "Delete failed")
            }

            if library.isLoading && library.photos.isEmpty {
                NativeEmptyState(title: "Loading photos", message: "Reading the next page from your Photos library.")
            } else if let currentPhoto {
                photoCard(currentPhoto)
            } else if library.hasMore {
                NativeEmptyState(title: "Batch reviewed", message: "You’ve reviewed the loaded photos. Load another page to continue.")
                ActionButton(title: library.isLoading ? "Loading photos…" : "Load more photos", icon: "chevron.down") {
                    Task { await library.loadNextPage() }
                }
                .disabled(library.isLoading || library.isDeleting)
            } else if library.photos.isEmpty {
                NativeEmptyState(title: "No photos found", message: "This Photos library does not contain any images.")
                ActionButton(title: library.isLoading ? "Refreshing…" : "Refresh library", icon: "arrow.clockwise") {
                    Task { await library.loadInitialPage() }
                }
                .disabled(library.isLoading || library.isDeleting)
            } else {
                NativeEmptyState(title: "Batch sorted", message: "You’ve reviewed all photos in the library.")
                ActionButton(title: library.isLoading ? "Refreshing…" : "Start over", icon: "arrow.clockwise") {
                    Task { if await library.loadInitialPage() { progress = DevicePhotoReviewProgress() } }
                }
                .disabled(library.isLoading || library.isDeleting)
            }
        }
    }

    @ViewBuilder private var reviewActions: some View {
        ActionButton(title: library.isLoading ? "Refreshing…" : "Refresh", icon: "arrow.clockwise") {
            Task { if await library.loadInitialPage() { progress = DevicePhotoReviewProgress() } }
        }
        .disabled(library.isLoading || library.isDeleting)
        ActionButton(title: "Undo last", icon: "arrow.uturn.backward") {
            _ = progress.undo(photoIDs: photoIDs)
        }
        .disabled(progress.history.isEmpty || library.isDeleting)
        ActionButton(title: library.isDeleting ? "Deleting…" : "Delete marked (\(progress.discardedIDs.count))", icon: "trash", tone: .danger) {
            showingDeleteConfirmation = true
        }
        .disabled(progress.discardedIDs.isEmpty || library.isDeleting)
    }

    private func photoCard(_ asset: PHAsset) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                theme.cardRaised
                if let preview, previewedPhotoID == asset.localIdentifier {
                    Image(nsImage: preview).resizable().scaledToFit()
                } else if !previewError.isEmpty, previewedPhotoID == asset.localIdentifier {
                    NativeEmptyState(title: "Preview unavailable", message: previewError)
                } else {
                    ProgressView().controlSize(.small).accessibilityLabel("Loading photo preview")
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 400)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(alignment: .firstTextBaseline) {
                Text(photoName(asset)).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text).lineLimit(2)
                Spacer(minLength: 8)
                Text("\(asset.pixelWidth) × \(asset.pixelHeight)").font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.textTertiary)
            }
            if let creationDate = asset.creationDate {
                Text(creationDate, format: .dateTime.year().month().day())
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
            }
            Text("Photo \(progress.index + 1) of \(library.photos.count) loaded")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
            HStack(spacing: 8) {
                ActionButton(title: "Keep", icon: "checkmark", tone: .normal) { record(.keep, asset: asset) }
                    .disabled(library.isDeleting)
                ActionButton(title: "Discard later", icon: "xmark", tone: .danger) { record(.discard, asset: asset) }
                    .disabled(library.isDeleting)
            }
        }
        .padding(12)
        .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(theme.divider, lineWidth: 1))
    }

    private func record(_ decision: DevicePhotoReviewProgress.Decision, asset: PHAsset) {
        progress.record(decision, for: asset.localIdentifier, photoIDs: photoIDs)
    }

    private func photoName(_ asset: PHAsset) -> String {
        PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "Unnamed image"
    }

    private func requestPreview() {
        cancelPreview()
        guard let asset = currentPhoto else { return }
        let photoID = asset.localIdentifier
        previewedPhotoID = photoID
        previewError = ""
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        previewRequestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 1400, height: 1400),
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            if info?[PHImageResultIsDegradedKey] as? Bool == true { return }
            Task { @MainActor in
                guard previewedPhotoID == photoID else { return }
                preview = image
                if image == nil {
                    previewError = "The photo preview could not be loaded. Check that the original is available, then refresh the library."
                }
            }
        }
    }

    private func cancelPreview() {
        if let previewRequestID { PHImageManager.default().cancelImageRequest(previewRequestID) }
        previewRequestID = nil
        preview = nil
    }

    @MainActor private func deleteMarkedPhotos() async {
        let ids = progress.discardedIDs
        guard !ids.isEmpty else { return }
        deleteError = ""
        do {
            try await library.deletePhotos(ids: ids)
            library.removePhotos(ids: ids)
            progress.resetAfterSuccessfulDeletion()
            previewError = ""
        } catch {
            deleteError = error.localizedDescription
        }
    }

    @ViewBuilder private func errorNotice(_ message: String, retry: (() -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            NativeNotice(message: message, title: "Photo library needs attention")
            if let retry {
                ActionButton(title: "Retry", icon: "arrow.clockwise", action: retry)
                    .disabled(library.isLoading || library.isDeleting)
            }
        }
    }
}

@MainActor
private final class DevicePhotoLibrary: ObservableObject {
    @Published private(set) var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var photos: [PHAsset] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isDeleting = false
    @Published private(set) var isRequestingAuthorization = false
    @Published private(set) var hasMore = false
    @Published var error = ""
    @Published private(set) var status = "Review photos in your Mac’s Photos library"

    private let pageSize = 40
    private var offset = 0

    func requestAuthorization() async {
        guard !isRequestingAuthorization else { return }
        isRequestingAuthorization = true
        defer { isRequestingAuthorization = false }
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if isAuthorized { _ = await loadInitialPage() }
    }

    func refreshAuthorizationAndLoad() async {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if isAuthorized { _ = await loadInitialPage() }
    }

    func loadInitialPage() async -> Bool {
        guard !isLoading, !isDeleting else { return false }
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard isAuthorized else {
            status = "Photo library permission required"
            return false
        }
        photos = []
        offset = 0
        hasMore = false
        error = ""
        await loadNextPage()
        return error.isEmpty
    }

    func loadNextPage(reset: Bool = false) async {
        guard !isLoading, !isDeleting else { return }
        if reset { _ = await loadInitialPage(); return }
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard isAuthorized else {
            status = "Photo library permission required"
            return
        }

        isLoading = true
        error = ""
        defer { isLoading = false }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        let end = min(offset + pageSize, result.count)
        let page = offset < end ? (offset..<end).map { result.object(at: $0) } : []
        photos.append(contentsOf: page.filter { asset in !photos.contains { $0.localIdentifier == asset.localIdentifier } })
        offset = end
        hasMore = end < result.count
        status = page.isEmpty && photos.isEmpty ? "No photos found" : "Loaded \(photos.count) photos"
    }

    func deletePhotos(ids: Set<String>) async throws {
        guard isAuthorized else { throw DevicePhotoLibraryError.accessRevoked }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil)
        guard result.count == ids.count else { throw DevicePhotoLibraryError.photosChanged }
        isDeleting = true
        defer { isDeleting = false }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(result)
            } completionHandler: { success, error in
                if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: error ?? DevicePhotoLibraryError.deletionFailed)
                }
            }
        }
        status = "Deleted \(ids.count) photo\(ids.count == 1 ? "" : "s")"
    }

    func removePhotos(ids: Set<String>) {
        photos.removeAll { ids.contains($0.localIdentifier) }
        offset = photos.count
    }

    private var isAuthorized: Bool {
        authorization == .authorized || authorization == .limited
    }
}

private enum DevicePhotoLibraryError: LocalizedError {
    case accessRevoked
    case photosChanged
    case deletionFailed

    var errorDescription: String? {
        switch self {
        case .accessRevoked: "Photo library access is no longer available. Allow access in System Settings and try again."
        case .photosChanged: "Some marked photos are no longer available. Refresh the library and review the remaining photos again."
        case .deletionFailed: "Photos could not be deleted. Your marked photos are still available to review."
        }
    }
}
