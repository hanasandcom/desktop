import AppKit
import SwiftUI

struct NativePublicAlbumPanel: View {
    let token: String

    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var items: [NativePublicAlbumItem] = []
    @State private var timeline: [NativePublicAlbumMonth] = []
    @State private var albumID = ""
    @State private var selectedItem: NativePublicAlbumItem?
    @State private var selectedMedia: NativeCDNFilePreview?
    @State private var search = ""
    @State private var selectedMonth = ""
    @State private var nextOffset: Int?
    @State private var total = 0
    @State private var error = ""
    @State private var isLoading = false
    @State private var isLoadingMore = false

    var body: some View {
        NativeGroupPanel(title: "Shared album", subtitle: token) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 9) {
                    searchField
                    monthPicker.frame(maxWidth: 190)
                    searchButton
                    refreshButton
                }
                .frame(minWidth: 700)
                VStack(alignment: .leading, spacing: 8) {
                    searchField
                    HStack(spacing: 9) {
                        monthPicker.frame(maxWidth: 240)
                        Spacer(minLength: 0)
                        searchButton
                        refreshButton
                    }
                }
            }
            if !error.isEmpty { NativeNotice(message: error) }
            if isLoading && items.isEmpty {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading shared album…") }
                    .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
            } else if items.isEmpty {
                NativeEmptyState(title: "No shared photos", message: total == 0 ? "This album has no matching media." : "No media matches these filters.")
            } else {
                HStack {
                    Text("\(items.count) of \(total) items")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
                    Spacer()
                    if let selectedItem { Text(selectedItem.name).lineLimit(1).foregroundStyle(theme.textTertiary) }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
                    ForEach(items) { item in
                        NativePublicAlbumTile(item: item, client: try? makeClient()) {
                            Task { await open(item) }
                        }
                    }
                }
                if let selectedItem {
                    selectedMediaPanel(for: selectedItem)
                }
                if nextOffset != nil {
                    HStack { Spacer()
                        ActionButton(title: isLoadingMore ? "Loading…" : "Load more", icon: "arrow.down") { Task { await loadMore() } }
                            .disabled(isLoading || isLoadingMore)
                        Spacer()
                    }
                }
            }
        }
        .task(id: token) { await refresh() }
    }

    private var searchField: some View {
        TextField("Search photos", text: $search).textFieldStyle(.roundedBorder)
            .onSubmit { Task { await refresh() } }
    }

    private var monthPicker: some View {
        Picker("Month", selection: $selectedMonth) {
            Text("All months").tag("")
            ForEach(timeline) { month in
                Text("\(month.monthKey) · \(month.photoCount)").tag(month.monthKey)
            }
        }
        .labelsHidden()
    }

    private var searchButton: some View {
        ActionButton(title: "Search", icon: "magnifyingglass") { Task { await refresh() } }
            .disabled(isLoading || isLoadingMore)
    }

    private var refreshButton: some View {
        ActionButton(title: isLoading ? "Loading…" : "Refresh", icon: "arrow.clockwise") { Task { await refresh() } }
            .disabled(isLoading || isLoadingMore)
    }

    private func selectedMediaPanel(for item: NativePublicAlbumItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                Spacer()
                Button("Close") { selectedItem = nil; selectedMedia = nil }
                    .buttonStyle(.plain).foregroundStyle(theme.accent)
            }
            if let selectedMedia, selectedMedia.isImage, let image = NSImage(data: selectedMedia.data) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 620)
            } else if let selectedMedia, selectedMedia.isVideo {
                NativeVideoPreview(id: selectedMedia.id, data: selectedMedia.data,
                                   fileExtension: URL(fileURLWithPath: selectedMedia.fileName).pathExtension)
                    .frame(maxWidth: .infinity, minHeight: 260, maxHeight: 620)
            } else if item.type.hasPrefix("video/"), selectedMedia == nil {
                NativeEmptyState(title: error.isEmpty ? "Loading video" : "Video unavailable",
                                 message: error.isEmpty ? "Fetching this shared video for native playback." : error)
            } else if selectedMedia == nil {
                NativeEmptyState(title: "Image unavailable", message: "This image could not be decoded by the native image viewer.")
            }
            HStack(spacing: 12) {
                metadata("Type", item.type)
                metadata("Captured", item.photoTakenAt ?? item.uploadedAt ?? "Unknown")
                metadata("Size", item.sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unknown")
            }
        }
        .padding(12)
        .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func metadata(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.system(size: 9, weight: .semibold)).foregroundStyle(theme.textTertiary)
            Text(value).font(.system(size: 10)).foregroundStyle(theme.textSecondary).lineLimit(2).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await makeClient().loadPage(token: token, search: search, month: selectedMonth)
            items = page.items
            albumID = page.id
            timeline = page.timeline
            total = page.total
            nextOffset = page.nextOffset
            selectedItem = nil
            selectedMedia = nil
            error = ""
        } catch {
            items = []
            selectedItem = nil
            selectedMedia = nil
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor private func loadMore() async {
        guard !isLoading, !isLoadingMore, let offset = nextOffset else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await makeClient().loadPage(token: token, offset: offset, search: search, month: selectedMonth)
            guard page.id == albumID else { throw NativePublicAlbumError.invalidResponse }
            let existing = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !existing.contains($0.id) })
            timeline = page.timeline
            total = page.total
            nextOffset = page.nextOffset
            error = ""
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor private func open(_ item: NativePublicAlbumItem) async {
        selectedItem = item
        selectedMedia = nil
        guard item.type.hasPrefix("image/") || item.type.hasPrefix("video/") else { return }
        do {
            selectedMedia = try await makeClient().media(for: item)
            error = ""
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func makeClient() throws -> NativePublicAlbumClient {
        try NativePublicAlbumClient(apiBaseURL: model.settings.cdnBaseURL.normalizedBaseURL)
    }
}

private struct NativePublicAlbumTile: View {
    let item: NativePublicAlbumItem
    let client: NativePublicAlbumClient?
    let action: () -> Void
    @Environment(\.desktopTheme) private var theme
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    theme.cardRaised
                    if let image { Image(nsImage: image).resizable().scaledToFill() }
                    else {
                        Image(systemName: item.type.hasPrefix("video/") ? "video" : "photo")
                            .font(.system(size: 24)).foregroundStyle(theme.textTertiary)
                    }
                    if failed { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.danger).padding(5).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing) }
                }
                .frame(height: 128).clipped().clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(item.name).font(.system(size: 10, weight: .medium)).foregroundStyle(theme.text)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(6)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .task(id: item.id) {
            guard item.type.hasPrefix("image/"), let client else { return }
            do {
                let preview = try await client.thumbnail(for: item)
                guard !Task.isCancelled else { return }
                image = NSImage(data: preview.data)
                failed = image == nil
            } catch { failed = true }
        }
    }
}
