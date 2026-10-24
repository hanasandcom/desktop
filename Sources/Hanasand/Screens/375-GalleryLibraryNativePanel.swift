import AppKit
import SwiftUI

struct GalleryLibraryNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var search = ""
    @State private var favoritesOnly = false
    @State private var files: [GalleryLibraryItem] = []
    @State private var offset = 0
    @State private var hasMore = false
    @State private var loading = false
    @State private var loadingMore = false
    @State private var error = ""
    @State private var status = "Your private CDN file library"
    @State private var activeRequest = UUID()
    @State private var favoritePending: [String: UUID] = [:]
    @State private var favoriteErrors: [String: String] = [:]
    @State private var preview: GalleryLibraryItem?
    @State private var sessionRevision = 0

    private var impersonating: Bool {
        !model.settings.impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !model.settings.impersonationToken.isEmpty
    }
    private var sessionFingerprint: String {
        let value = model.settings
        return "\(value.cdnBaseURL)|\(value.userID)|\(value.authToken.hashValue)|\(value.impersonatingUserID)|\(value.impersonationToken.hashValue)"
    }
    private var queryKey: String { "\(search)|\(favoritesOnly)|\(sessionFingerprint)" }

    var body: some View {
        FeatureWorkspace(title: "Images", subtitle: status) {
            if !model.hasHanasandAuth {
                NativeEmptyState(title: "Sign in to view your files", message: "Your private file library uses the authenticated CDN session.")
            } else if impersonating {
                NativeEmptyState(title: "Return to your own account", message: "The private file library is unavailable while an impersonation token or target account is active.")
            } else {
                NativeGroupPanel(title: "Your file library", subtitle: "Private files from your authenticated CDN account", fillsAvailableWidth: true) {
                    HStack(spacing: 8) {
                        TextField("Search files", text: $search)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Search private files")
                        Toggle("Favorites", isOn: $favoritesOnly)
                            .toggleStyle(.checkbox)
                            .fixedSize()
                        ActionButton(title: "Upload media", icon: "arrow.up.to.line") {
                            model.openNativeDashboard(path: "/upload", label: "Upload media")
                        }
                        ActionButton(title: loading ? "Loading…" : "Refresh", icon: "arrow.clockwise") {
                            let request = UUID()
                            activeRequest = request
                            files = []; offset = 0; hasMore = false; error = ""
                            Task { await loadPage(offset: 0, reset: true, request: request) }
                        }.disabled(loading || loadingMore)
                    }
                    if !error.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Text(error).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.danger).textSelection(.enabled)
                            Spacer(minLength: 0)
                            ActionButton(title: "Retry", icon: "arrow.clockwise") { retry() }
                        }
                    }
                    if loading && files.isEmpty {
                        NativeEmptyState(title: "Loading files", message: "Searching the signed-in account’s private CDN library.")
                    } else if files.isEmpty && error.isEmpty {
                        NativeEmptyState(
                            title: search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !favoritesOnly ? "No files yet" : "No matching files",
                            message: search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !favoritesOnly
                                ? "Upload a file to start your private CDN library."
                                : "Try a different search or switch back to the full library."
                        )
                    } else if !files.isEmpty {
                        Text("\(files.count) file\(files.count == 1 ? "" : "s") loaded\(hasMore ? " · more available" : "")")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], alignment: .leading, spacing: 12) {
                            ForEach(files) { file in
                                libraryTile(file)
                            }
                        }
                        if hasMore {
                            ActionButton(title: loadingMore ? "Loading more…" : "Load more", icon: "chevron.down") { loadMore() }
                                .disabled(loading || loadingMore)
                        }
                    }
                }
            }
        }
        .task(id: queryKey) {
            sessionRevision += 1
            let request = UUID()
            activeRequest = request
            files = []; offset = 0; hasMore = false; error = ""
            favoriteErrors = [:]; favoritePending = [:]
            preview = nil
            status = "Loading your file library…"
            guard !impersonating, model.hasHanasandAuth else { status = "Your private CDN file library"; return }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await loadPage(offset: 0, reset: true, request: request)
        }
        .onDisappear { activeRequest = UUID(); preview = nil }
        .sheet(item: $preview) { item in
            GalleryLibraryPreview(settings: model.settings, file: item)
                .frame(minWidth: 560, minHeight: 420)
        }
    }

    private func libraryTile(_ file: GalleryLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                if file.type.hasPrefix("image/") { preview = file }
                else { openFile(file) }
            } label: {
                Group {
                    if file.type.hasPrefix("image/") {
                        GalleryLibraryThumbnail(settings: model.settings, file: file, sessionRevision: sessionRevision)
                    } else {
                        ZStack {
                            theme.card
                            Image(systemName: file.type.hasPrefix("video/") ? "video" : "doc")
                                .font(.system(size: 34)).foregroundStyle(theme.textTertiary)
                        }
                    }
                }
                .frame(height: 154)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(file.type.hasPrefix("image/") ? "Preview \(file.name ?? "image")" : "Open \(file.name ?? "file")")
            Text(file.name ?? "Untitled file")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                .lineLimit(1).help(file.name ?? "Untitled file")
            HStack(spacing: 5) {
                Text(file.uploadedAt.map { formatDateText($0, fallback: "Date unavailable") } ?? file.type)
                if let size = file.sizeBytes {
                    Text("·")
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                }
            }
            .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary).lineLimit(1)
            HStack(spacing: 6) {
                Button {
                    copyFileURL(file)
                } label: {
                    Label("Copy link", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                Button {
                    openFile(file)
                } label: {
                    Label("Open", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
                Button {
                    Task { await toggleFavorite(file) }
                } label: {
                    Label(file.isFavorite == true ? "Favorite" : "Add favorite", systemImage: file.isFavorite == true ? "heart.fill" : "heart")
                }
                .buttonStyle(.bordered)
                .disabled(favoritePending[file.id] != nil || loading || loadingMore || favoriteErrors[file.id] != nil)
                if favoritePending[file.id] != nil {
                    ProgressView().controlSize(.small).accessibilityLabel("Saving favorite")
                }
            }
            if let favoriteError = favoriteErrors[file.id] {
                Text(favoriteError).font(.system(size: 10, weight: .medium)).foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Refresh the library to confirm the saved state before trying again.")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textSecondary)
            }
        }
        .padding(10)
        .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(theme.divider, lineWidth: 1))
    }

    private func openFile(_ file: GalleryLibraryItem) {
        model.openNativeDashboard(path: "/cdn/files", label: file.name ?? "CDN file", detailID: file.id)
    }

    private func copyFileURL(_ file: GalleryLibraryItem) {
        guard var components = URLComponents(url: model.settings.cdnBaseURL.normalizedBaseURL, resolvingAgainstBaseURL: false),
              let encodedID = file.id.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) else { return }
        components.percentEncodedPath = "/files/\(encodedID)"
        guard let url = components.url, url.scheme == "https", url.host == model.settings.cdnBaseURL.normalizedBaseURL.host else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        status = "File link copied"
    }

    @MainActor private func loadPage(offset requestedOffset: Int, reset: Bool, request: UUID) async {
        guard request == activeRequest else { return }
        if reset { loading = true } else { loadingMore = true }
        defer {
            if request == activeRequest {
                loading = false
                loadingMore = false
            }
        }
        do {
            let client = try GalleryAlbumClient(settings: model.settings)
            let page = try await client.listLibraryPage(offset: requestedOffset, search: search, favorites: favoritesOnly)
            guard request == activeRequest else { return }
            if reset { files = page.items }
            else {
                let loaded = Set(files.map(\.id))
                files.append(contentsOf: page.items.filter { !loaded.contains($0.id) })
            }
            if reset { favoriteErrors = [:] }
            offset = page.nextOffset
            hasMore = page.hasMore
            error = ""
            status = "Loaded \(files.count) private images"
        } catch {
            guard request == activeRequest else { return }
            self.error = error.localizedDescription
            status = "File library needs attention"
        }
    }

    @MainActor private func loadMore() {
        guard hasMore, !loading, !loadingMore else { return }
        let request = activeRequest
        Task { await loadPage(offset: offset, reset: false, request: request) }
    }

    @MainActor private func retry() {
        let request = UUID()
        activeRequest = request
        Task { await loadPage(offset: 0, reset: true, request: request) }
    }

    @MainActor private func toggleFavorite(_ file: GalleryLibraryItem) async {
        guard favoritePending[file.id] == nil, !impersonating else { return }
        let mutation = UUID()
        favoritePending[file.id] = mutation
        favoriteErrors[file.id] = nil
        let expected = !(file.isFavorite ?? false)
        let currentSession = sessionFingerprint
        defer { if favoritePending[file.id] == mutation { favoritePending[file.id] = nil } }
        do {
            let client = try GalleryAlbumClient(settings: model.settings)
            _ = try await client.setFavorite(expected, for: file.id)
            guard currentSession == sessionFingerprint else { return }
            if favoritesOnly && !expected {
                files.removeAll { $0.id == file.id }
            } else if let index = files.firstIndex(where: { $0.id == file.id }) {
                files[index] = GalleryLibraryItem(id: file.id, name: file.name, type: file.type, isFavorite: expected)
            }
            status = "Favorite saved"
        } catch {
            guard currentSession == sessionFingerprint else { return }
            if case GalleryAlbumClientError.unconfirmedMutation = error {
                favoriteErrors[file.id] = "The favorite update was not confirmed. Refresh before retrying."
            } else {
                favoriteErrors[file.id] = error.localizedDescription
            }
        }
    }
}

private struct GalleryLibraryThumbnail: View {
    let settings: HanasandDesktopSettings
    let file: GalleryLibraryItem
    let sessionRevision: Int
    @Environment(\.desktopTheme) private var theme
    @State private var image: NSImage?
    @State private var error = ""
    @State private var attempt = 0

    var body: some View {
        ZStack {
            theme.card
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else if !error.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "photo.badge.exclamationmark").foregroundStyle(theme.danger)
                    Text("Preview unavailable").font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textSecondary)
                    Button("Retry") { attempt += 1 }.buttonStyle(.link).font(.system(size: 10))
                }.padding(6)
            } else {
                ProgressView().controlSize(.small).accessibilityLabel("Loading image preview")
            }
        }
        .clipped()
        .task(id: "\(file.id)|\(sessionRevision)|\(attempt)") {
            image = nil; error = ""
            do {
                let bytes = try await GalleryAlbumClient(settings: settings).thumbnail(for: file.id)
                guard !Task.isCancelled else { return }
                guard let decoded = NSImage(data: bytes) else { throw GalleryAlbumClientError.invalidImage }
                image = decoded
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
        .accessibilityLabel("Private thumbnail for \(file.name ?? "image")")
    }
}

private struct GalleryLibraryPreview: View {
    let settings: HanasandDesktopSettings
    let file: GalleryLibraryItem
    @Environment(\.desktopTheme) private var theme
    @State private var image: NSImage?
    @State private var error = ""
    @State private var loading = true
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(file.name ?? "Image preview").font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.escape)
            }
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else if loading {
                    NativeEmptyState(title: "Loading image", message: "Fetching the original through your authenticated CDN session.")
                } else {
                    VStack(spacing: 10) {
                        NativeEmptyState(title: "Preview unavailable", message: error.isEmpty ? "The CDN did not return a supported image." : error)
                        Button("Retry") { attempt += 1 }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(18)
        .background(theme.background)
        .task(id: "\(file.id)|\(settings.userID)|\(settings.authToken.hashValue)|\(attempt)") { await load() }
    }

    @Environment(\.dismiss) private var dismiss

    @MainActor private func load() async {
        loading = true; image = nil; error = ""
        defer { loading = false }
        do {
            let bytes = try await GalleryAlbumClient(settings: settings).originalImage(for: file.id)
            guard !Task.isCancelled else { return }
            guard let decoded = NSImage(data: bytes) else { throw GalleryAlbumClientError.invalidImage }
            image = decoded
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
