import AppKit
import SwiftUI

struct GalleryAlbumsNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var albums: [GalleryAlbum] = []
    @State private var album: GalleryAlbumDetail?
    @State private var library: [GalleryLibraryItem] = []
    @State private var selectedFiles: Set<String> = []
    @State private var showPicker = false
    @State private var nameDraft = ""
    @State private var memberDraft = ""
    @State private var memberRole = "viewer"
    @State private var offset = 0
    @State private var libraryOffset = 0
    @State private var busy = false
    @State private var status = "Ready"
    @State private var error = ""
    @State private var confirmDelete = false
    @State private var itemToRemove: GalleryAlbumItem?
    @State private var memberToRemove: GalleryAlbumMember?
    @State private var sessionRevision = 0

    private var canManage: Bool { album.map { GalleryAlbumAccess.canManage($0, currentUserId: model.userIDForRequests) } ?? false }
    private var canAddItems: Bool { album.map(GalleryAlbumAccess.canAddItems) ?? false }

    var body: some View {
        FeatureWorkspace(title: "Albums", subtitle: status) {
            if !model.hasHanasandAuth {
                NativeEmptyState(title: "Sign in to manage albums", message: "Albums use your CDN account to organize and share files already in your library.")
            } else {
                if !error.isEmpty {
                    NativeGroupPanel(title: "Album request failed", subtitle: "") {
                        Text(error).foregroundStyle(theme.danger).textSelection(.enabled)
                    }
                }
                if let album {
                    albumDetail(album)
                } else {
                    albumList
                }
            }
        }
        .task { await refreshAlbums() }
        .onChange(of: sessionFingerprint) { _, _ in
            sessionRevision += 1
            albums = []; album = nil; library = []; selectedFiles.removeAll()
            showPicker = false; error = ""; status = "Refreshing account…"
            Task { await refreshAlbums() }
        }
        .confirmationDialog("Delete album?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete album", role: .destructive) { Task { await deleteAlbum() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The album and its sharing access will be deleted. Original files stay in their owners’ libraries.")
        }
        .confirmationDialog("Remove this album item?", isPresented: Binding(
            get: { itemToRemove != nil }, set: { if !$0 { itemToRemove = nil } }
        ), titleVisibility: .visible) {
            Button("Remove from album", role: .destructive) {
                if let itemToRemove { Task { await remove(itemToRemove) } }
            }
            Button("Cancel", role: .cancel) { itemToRemove = nil }
        } message: {
            Text("The original file remains in its owner’s library.")
        }
        .confirmationDialog("Remove album access?", isPresented: Binding(
            get: { memberToRemove != nil }, set: { if !$0 { memberToRemove = nil } }
        ), titleVisibility: .visible) {
            Button("Remove access", role: .destructive) {
                if let memberToRemove { Task { await remove(memberToRemove) } }
            }
            Button("Cancel", role: .cancel) { memberToRemove = nil }
        } message: {
            Text("This account will lose its invitation to the album.")
        }
    }

    private var albumList: some View {
        NativeGroupPanel(title: "Your albums", subtitle: "Private by default · shared albums also appear here") {
            HStack(spacing: 8) {
                TextField("New album name", text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .disabled(busy)
                ActionButton(title: "Create album", icon: "plus", tone: .normal) {
                    Task { await createAlbum() }
                }
                .disabled(busy || nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                ActionButton(title: "Refresh", icon: "arrow.clockwise") { Task { await refreshAlbums() } }
                    .disabled(busy)
            }
            if albums.isEmpty && !busy {
                NativeEmptyState(title: "No albums yet", message: "Create an album, then add photos already uploaded to your library.")
            }
            ForEach(albums) { item in
                Button { Task { await open(item.id) } } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "photo.stack").foregroundStyle(theme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.system(size: 15, weight: .bold)).foregroundStyle(theme.text)
                            Text("\(item.photoCount ?? 0) items · \(item.memberRole ?? (item.owner == model.userIDForRequests ? "owner" : "shared")) · \(item.isPublic ? "Public link" : "Private")")
                                .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(theme.textTertiary)
                    }
                    .padding(12)
                    .background(theme.cardRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
        }
    }

    @ViewBuilder private func albumDetail(_ album: GalleryAlbumDetail) -> some View {
        NativeGroupPanel(title: album.name, subtitle: "\(album.total) items · \(album.role) · \(album.isPublic ? "Public link enabled" : "Private")") {
            HStack(spacing: 8) {
                ActionButton(title: "All albums", icon: "chevron.left") { self.album = nil; showPicker = false; error = "" }
                ActionButton(title: "Refresh", icon: "arrow.clockwise") { Task { await open(album.id, offset: offset) } }
                if canAddItems {
                    ActionButton(title: showPicker ? "Close picker" : "Add library photos", icon: "photo.badge.plus") {
                        showPicker.toggle(); selectedFiles.removeAll()
                        if showPicker { Task { await loadLibrary(offset: 0) } }
                    }
                    .disabled(busy)
                }
            }
            if canManage {
                HStack(spacing: 8) {
                    TextField("Album name", text: $nameDraft).textFieldStyle(.roundedBorder).disabled(busy)
                    ActionButton(title: "Save name", icon: "checkmark") { Task { await renameAlbum() } }
                        .disabled(busy || nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || nameDraft.trimmingCharacters(in: .whitespacesAndNewlines) == album.name)
                    ActionButton(title: "Delete", icon: "trash", tone: .danger) { confirmDelete = true }.disabled(busy)
                }
            } else if !canAddItems {
                Text("View only. Owners and contributors can add photos.")
                    .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
            }
        }

        if showPicker && canAddItems {
            NativeGroupPanel(title: "Choose library photos", subtitle: "Select existing files · \(selectedFiles.count) selected") {
                HStack {
                    ActionButton(title: "Add selected", icon: "plus", tone: .normal) { Task { await addSelected() } }
                        .disabled(busy || selectedFiles.isEmpty)
                    ActionButton(title: "Previous", icon: "chevron.left") { Task { await loadLibrary(offset: max(0, libraryOffset - 60)) } }
                        .disabled(busy || libraryOffset == 0)
                    ActionButton(title: "Next", icon: "chevron.right") { Task { await loadLibrary(offset: libraryOffset + 60) } }
                        .disabled(busy || library.count < 60 || libraryOffset >= 1_000_000)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 126), spacing: 10)], spacing: 10) {
                    ForEach(library) { file in
                        Button {
                            if selectedFiles.contains(file.id) { selectedFiles.remove(file.id) }
                            else if selectedFiles.count < 500 { selectedFiles.insert(file.id) }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                GalleryAlbumThumbnail(client: makeClient(), fileId: file.id, sessionRevision: sessionRevision)
                                    .frame(height: 96)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                Text("\(selectedFiles.contains(file.id) ? "✓ " : "")\(file.name ?? "Photo")")
                                    .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.text).lineLimit(2)
                            }
                            .padding(8)
                            .background(selectedFiles.contains(file.id) ? theme.accent.opacity(0.18) : theme.cardRaised)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(file.name ?? "Photo"), \(selectedFiles.contains(file.id) ? "selected" : "not selected")")
                    }
                }
            }
        }

        NativeGroupPanel(title: "Album contents", subtitle: "Items \(album.items.isEmpty ? 0 : album.offset + 1)–\(album.offset + album.items.count) of \(album.total)") {
            if album.items.isEmpty {
                NativeEmptyState(title: album.total == 0 ? "This album is empty" : "No items on this page", message: album.total == 0 ? "Add photos already in your library." : "Return to the previous page or refresh.")
            }
            ForEach(album.items) { item in
                HStack(spacing: 12) {
                    if item.type.hasPrefix("image/") {
                        GalleryAlbumThumbnail(client: makeClient(), fileId: item.id, sessionRevision: sessionRevision).frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name ?? "Untitled item").font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
                        Text(item.addedBy == nil ? item.type : "Added by \(item.addedBy!)").font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    if GalleryAlbumAccess.canRemove(item, album: album, currentUserId: model.userIDForRequests) {
                        ActionButton(title: "Remove", icon: "trash", tone: .danger) { itemToRemove = item }.disabled(busy)
                    }
                }
                .padding(.vertical, 6)
            }
            HStack {
                ActionButton(title: "Previous page", icon: "chevron.left") { Task { await open(album.id, offset: max(0, offset - 60)) } }.disabled(busy || offset == 0)
                ActionButton(title: "Next page", icon: "chevron.right") { Task { await open(album.id, offset: offset + 60) } }.disabled(busy || offset + album.items.count >= album.total || offset >= 1_000_000)
            }
        }

        if canManage {
            NativeGroupPanel(title: "Sharing & access", subtitle: "Owner controls") {
                Text(album.isPublic ? "Anyone with the public link can view this album." : "Only you and invited accounts can view this album.")
                    .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                HStack(spacing: 8) {
                    TextField("Hanasand account ID", text: $memberDraft).textFieldStyle(.roundedBorder).disabled(busy)
                    Picker("Access", selection: $memberRole) {
                        Text("View only").tag("viewer")
                        Text("Can add photos").tag("contributor")
                    }.frame(width: 170).disabled(busy)
                    ActionButton(title: "Grant access", icon: "person.badge.plus") { Task { await addMember() } }
                        .disabled(busy || memberDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ForEach(album.members ?? []) { member in
                    HStack {
                        Text("\(member.userId) · \(member.role)").font(.system(size: 13)).foregroundStyle(theme.text)
                        Spacer()
                        ActionButton(title: "Remove access", icon: "person.badge.minus", tone: .danger) { memberToRemove = member }.disabled(busy)
                    }
                }
            }
        }
    }

    private func makeClient() -> GalleryAlbumClient? { try? GalleryAlbumClient(settings: model.settings) }

    private var sessionFingerprint: String {
        let settings = model.settings
        return "\(settings.userID)|\(settings.authToken.hashValue)|\(settings.cdnBaseURL)|\(settings.impersonatingUserID)|\(settings.impersonationToken.hashValue)"
    }

    private func withClient<T>(_ action: (GalleryAlbumClient) async throws -> T, success: String) async -> T? {
        guard !busy else { return nil }
        let revision = sessionRevision
        busy = true; error = ""; status = "Working…"
        defer { busy = false }
        do {
            let value = try await action(try GalleryAlbumClient(settings: model.settings))
            guard revision == sessionRevision else { return nil }
            status = success
            return value
        } catch {
            guard revision == sessionRevision else { return nil }
            self.error = error.localizedDescription
            status = "Needs attention"
            return nil
        }
    }

    private func refreshAlbums() async {
        guard let result = await withClient({ try await $0.listAlbums() }, success: "Albums loaded") else { return }
        albums = result
    }

    private func open(_ id: String, offset: Int = 0) async {
        guard let result = await withClient({ try await $0.album(id: id, offset: offset) }, success: "Album loaded") else { return }
        album = result; self.offset = offset; nameDraft = result.name
    }

    private func createAlbum() async {
        guard let result = await withClient({ try await $0.createAlbum(name: nameDraft) }, success: "Album created privately") else { return }
        nameDraft = ""; await refreshAlbums(); await open(result.id)
    }

    private func renameAlbum() async {
        guard let album, let _ = await withClient({ try await $0.renameAlbum(id: album.id, name: nameDraft) }, success: "Album renamed") else { return }
        await open(album.id, offset: offset); await refreshAlbums()
    }

    private func deleteAlbum() async {
        guard let album, await withClient({ try await $0.deleteAlbum(album) }, success: "Album deleted") != nil else { return }
        self.album = nil; showPicker = false; await refreshAlbums()
    }

    private func loadLibrary(offset: Int) async {
        guard let items = await withClient({ try await $0.listLibrary(offset: offset) }, success: "Library loaded") else { return }
        library = items.filter { $0.type.hasPrefix("image/") }; libraryOffset = offset
    }

    private func addSelected() async {
        guard let album, let receipt = await withClient({ try await $0.addItems(Array(selectedFiles), to: album) }, success: "Photos added") else { return }
        status = "Added \(receipt.added) of \(receipt.requested) selected photos"
        selectedFiles.removeAll(); showPicker = false; await open(album.id, offset: offset); await refreshAlbums()
    }

    private func remove(_ item: GalleryAlbumItem) async {
        guard let album, await withClient({ try await $0.removeItem(item, from: album) }, success: "Item removed from album") != nil else { return }
        itemToRemove = nil; await open(album.id, offset: offset); await refreshAlbums()
    }

    private func addMember() async {
        guard let album, let _ = await withClient({ try await $0.setMember(memberDraft, role: memberRole, in: album) }, success: "Album access updated") else { return }
        memberDraft = ""; await open(album.id, offset: offset)
    }

    private func remove(_ member: GalleryAlbumMember) async {
        guard let album, await withClient({ try await $0.removeMember(member.userId, from: album) }, success: "Album access removed") != nil else { return }
        memberToRemove = nil; await open(album.id, offset: offset)
    }
}

private struct GalleryAlbumThumbnail: View {
    let client: GalleryAlbumClient?
    let fileId: String
    let sessionRevision: Int
    @Environment(\.desktopTheme) private var theme
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { ZStack { theme.cardRaised; Image(systemName: "photo").foregroundStyle(theme.textTertiary) } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: "\(fileId)-\(sessionRevision)") {
            image = nil
            guard let client else { return }
            do {
                let data = try await client.thumbnail(for: fileId)
                guard !Task.isCancelled else { return }
                image = NSImage(data: data)
            } catch { image = nil }
        }
        .accessibilityLabel("Private album thumbnail")
    }
}
