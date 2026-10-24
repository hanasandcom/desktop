import AppKit
import SwiftUI

struct NativeCDNFilePreviewPanel: View {
    let fileID: String

    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var file: NativeCDNFilePreview?
    @State private var error = ""
    @State private var isLoading = false
    @State private var isSaving = false

    var body: some View {
        NativeGroupPanel(title: "File preview", subtitle: file?.fileName ?? fileID) {
            HStack(spacing: 10) {
                if isLoading { ProgressView().controlSize(.small) }
                Text(error.isEmpty ? (file.map { "\($0.mediaType) · \($0.data.count) bytes" } ?? "Load a CDN file without opening a website.") : error)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(error.isEmpty ? theme.textSecondary : theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                ActionButton(title: isLoading ? "Loading…" : "Refresh", icon: "arrow.clockwise") { Task { await load() } }
                    .disabled(isLoading)
                if file != nil {
                    ActionButton(title: isSaving ? "Saving…" : "Save copy", icon: "square.and.arrow.down") { saveCopy() }
                        .disabled(isSaving)
                }
            }
            if let file {
                if file.isImage, let image = NSImage(data: file.data) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 640)
                        .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else if let text = file.textPreview {
                    ScrollView([.horizontal, .vertical]) {
                        Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.textSecondary)
                            .textSelection(.enabled).frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
                    }
                    .frame(maxHeight: 520).padding(10)
                    .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else if file.isVideo {
                    NativeEmptyState(title: "Video file ready", message: "Save a local copy to play this video in a native media app.")
                } else if file.mediaType == "application/octet-stream" {
                    NativeEmptyState(title: "Downloadable file", message: "This CDN response is an attachment. Save a copy to open it with a native app.")
                } else {
                    NativeEmptyState(title: "Preview unavailable", message: "This file type cannot be rendered in the native preview.")
                }
                HStack(spacing: 12) {
                    metadata("File ID", file.id)
                    metadata("Type", file.mediaType)
                    metadata("Disposition", file.disposition.components(separatedBy: ";").first ?? "inline")
                }
            }
        }
        .task(id: fileID) { await load() }
    }

    private func metadata(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(theme.textTertiary)
            Text(value).font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.textSecondary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let settings = model.settings
            let canSendAccountCookie = settings.impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && settings.impersonationToken.isEmpty
            let client = try NativeCDNFilePreviewClient(baseURL: model.settings.cdnBaseURL.normalizedBaseURL,
                                                       userID: canSendAccountCookie ? settings.userID : "",
                                                       token: canSendAccountCookie ? settings.authToken : "")
            file = try await client.load(id: fileID)
            error = ""
        } catch {
            file = nil
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor private func saveCopy() {
        guard let file else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.fileName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isSaving = true
        defer { isSaving = false }
        do { try file.data.write(to: url, options: .atomic) }
        catch { self.error = "Could not save this file: \(error.localizedDescription)" }
    }
}
