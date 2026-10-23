import SwiftUI

struct ThesisNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var access: ThesisAccess?
    @State private var document: ThesisDocument?
    @State private var title = ""
    @State private var bodyText = ""
    @State private var history: [ThesisHistoryEntry] = []
    @State private var preview: ThesisDocument?
    @State private var remoteConflict: ThesisDocument?
    @State private var error = ""
    @State private var notice = ""
    @State private var busy = false
    @State private var loadingHistory = false
    @State private var revision = 0
    @State private var loadedScope = ""

    private var impersonating: Bool { !model.settings.impersonationToken.isEmpty || !model.settings.impersonatingUserID.isEmpty }
    private var canEdit: Bool { access?.member == true && access?.canEdit == true && !impersonating }
    private var dirty: Bool { document.map { $0.title != title || $0.body != bodyText } ?? false }
    private var scope: String { "\(model.settings.apiBaseURL)|\(model.userIDForRequests)|\(model.authTokenForRequests)|\(impersonating)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NativeGroupPanel(title: "Thesis", subtitle: "Shared Hanasand workspace", fillsAvailableWidth: true) {
                HStack(spacing: 8) {
                    ActionButton(title: busy ? "Refreshing…" : "Refresh", icon: "arrow.clockwise") { revision += 1 }
                        .disabled(busy)
                    ActionButton(title: busy ? "Saving…" : "Save changes", icon: "checkmark") { Task { await save() } }
                        .disabled(!canEdit || !dirty || busy || remoteConflict != nil)
                }
                if let document {
                    Text("Revision \(document.revision) · \(remoteConflict != nil ? "Resolve shared changes" : dirty ? "Unsaved draft" : "Saved") · \(canEdit ? "Editing enabled" : "Read only")")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
                }
                if !error.isEmpty { Text(error).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.danger).textSelection(.enabled) }
                if !notice.isEmpty { NativeNotice(message: notice) }
                if impersonating { NativeNotice(message: "Thesis is read-only while impersonating. Return to your own account to edit.") }
            }

            if document != nil {
                ThesisWorkspaceEditor(documentTitle: $title, bodyText: $bodyText, enabled: canEdit, busy: busy, conflicted: remoteConflict != nil)
                if !canEdit { Text("This account can view the shared workspace but cannot edit it. Hanasand organization owners and editors can make changes.").font(.system(size: 11)).foregroundStyle(theme.textSecondary) }
                Text("Markdown source · \(bodyText.utf16.count) of \(ThesisDocument.bodyLimit) characters")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary)

                if let remoteConflict {
                    NativeGroupPanel(title: "Newer shared version", subtitle: "Revision \(remoteConflict.revision) was saved by another editor.") {
                        Text(remoteConflict.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                        Text(String(remoteConflict.body.prefix(1200)) + (remoteConflict.body.count > 1200 ? "…" : ""))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                        HStack(spacing: 8) {
                            ActionButton(title: "Use shared version", icon: "arrow.uturn.backward") {
                                self.document = remoteConflict; title = remoteConflict.title; bodyText = remoteConflict.body
                                self.remoteConflict = nil; notice = "Loaded the newer shared version."
                            }
                            ActionButton(title: "Keep my draft", icon: "pencil") {
                                self.document = remoteConflict; self.remoteConflict = nil
                                notice = "Your draft is kept. Save again to apply it to the newer revision."
                            }.disabled(!canEdit)
                        }
                    }
                }

                historyPanel
                if let preview { versionPreview(preview) }
            } else if busy {
                NativeEmptyState(title: "Loading Thesis", message: "Checking organization access and loading the shared document.")
            } else {
                NativeEmptyState(title: model.hasHanasandAuth ? "Thesis unavailable" : "Sign in required", message: error.isEmpty ? "Refresh to load the shared workspace." : error)
            }
        }
        .task(id: "\(scope):\(revision)") { await refresh() }
        .onDisappear { preview = nil }
    }

    private var historyPanel: some View {
        NativeGroupPanel(title: "Version history", subtitle: "The immediate previous version and periodic checkpoints are retained.") {
            ActionButton(title: loadingHistory ? "Loading history…" : "Load version history", icon: "clock.arrow.circlepath") { Task { await loadHistory() } }
                .disabled(loadingHistory || busy || !canEdit)
            if history.isEmpty && !loadingHistory { Text("Load history to review saved versions.").font(.system(size: 12)).foregroundStyle(theme.textSecondary) }
            ForEach(history) { item in
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(item.title) · revision \(item.revision)").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                    Text("\(item.savedAt)\(item.immediate ? " · immediate previous version" : "")").font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                    ActionButton(title: "Preview", icon: "eye") { Task { await show(item) } }.disabled(busy || loadingHistory)
                }.padding(.vertical, 4)
                if item.id != history.last?.id { Divider() }
            }
        }
    }

    @ViewBuilder private func versionPreview(_ value: ThesisDocument) -> some View {
        NativeGroupPanel(title: "Revision \(value.revision)", subtitle: "Preview of a saved version") {
            Text(value.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
            ScrollView { Text(value.body.isEmpty ? "This version has no body content." : value.body)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                .frame(maxHeight: 240)
            HStack(spacing: 8) {
                ActionButton(title: "Prepare restore", icon: "arrow.uturn.backward") {
                    guard canEdit, let document else { return }
                    title = value.title; bodyText = value.body; preview = nil
                    notice = "Revision \(value.revision) is now a draft. Save changes to restore it."
                    self.document = document
                }.disabled(!canEdit || busy || remoteConflict != nil)
                ActionButton(title: "Close preview", icon: "xmark") { preview = nil }
            }
        }
    }

    @MainActor private func refresh() async {
        if loadedScope != scope {
            loadedScope = scope; access = nil; document = nil; title = ""; bodyText = ""
            history = []; preview = nil; remoteConflict = nil
        }
        if impersonating { access = nil; document = nil; error = "Return to your own account to open Thesis."; return }
        guard model.hasHanasandAuth else { access = nil; document = nil; error = "Sign in to open Thesis."; return }
        busy = true; error = ""; notice = ""; defer { busy = false }
        do {
            let client = try makeClient()
            async let loadedAccess = client.loadAccess()
            async let loadedDocument = client.load()
            let (rights, value) = try await (loadedAccess, loadedDocument)
            access = rights
            if dirty, let current = document {
                if value.revision != current.revision || value.title != current.title || value.body != current.body {
                    remoteConflict = value
                    notice = "A newer shared version is available. Your draft is kept for review."
                } else {
                    document = value
                }
            } else {
                document = value; title = value.title; bodyText = value.body; remoteConflict = nil
            }
        } catch {
            access = nil
            self.error = error.localizedDescription
        }
    }

    @MainActor private func save() async {
        guard let document, let access, canEdit, dirty, remoteConflict == nil else { return }
        busy = true; error = ""; notice = ""; defer { busy = false }
        do {
            let saved = try await makeClient().save(ThesisDocument(title: title, body: bodyText, revision: document.revision), access: access)
            self.document = saved; title = saved.title; bodyText = saved.body; notice = "Thesis saved as revision \(saved.revision)."
        } catch ThesisClientError.conflict(let current) {
            remoteConflict = current
            error = "A newer version exists. Choose whether to use it or keep your draft."
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func loadHistory() async {
        guard canEdit else { return }
        loadingHistory = true; error = ""; defer { loadingHistory = false }
        do { history = try await makeClient().history() }
        catch let cause { error = cause.localizedDescription }
    }

    @MainActor private func show(_ item: ThesisHistoryEntry) async {
        busy = true; error = ""; defer { busy = false }
        do { preview = try await makeClient().version(item.revision) }
        catch let cause { error = cause.localizedDescription }
    }

    private func makeClient() throws -> ThesisClient {
        var settings = model.settings
        settings.userID = model.userIDForRequests
        settings.authToken = model.authTokenForRequests
        return try ThesisClient(settings: settings)
    }
}
