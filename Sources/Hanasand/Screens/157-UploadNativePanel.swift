import AppKit
import ApplicationServices
import Combine
import CryptoKit
import Darwin
import Foundation
import Network
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct UploadNativePanel: View {
    @EnvironmentObject var model: DesktopAgentModel
    @Environment(\.desktopTheme) var theme
    @State var isDropTargeted = false
    @State private var remoteMediaURL = ""
    @State private var isImportingRemoteMedia = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 126), alignment: .leading)], alignment: .leading, spacing: 8) {
                ActionButton(title: "Choose file", icon: "doc.badge.plus") {
                    model.chooseUploadFile()
                }
                ActionButton(title: "Check path", icon: "checkmark.seal") {
                    Task { await model.checkUploadPath() }
                }
                .disabled(model.uploadPath.isEmpty || model.isCheckingUploadPath)
                ActionButton(title: model.isUploadingFile ? "Uploading" : "Upload", icon: "arrow.up.doc") {
                    Task { await model.uploadSelectedFile() }
                }
                .disabled(model.uploadFileURL == nil || model.isUploadingFile)
                ActionButton(title: "Reset", icon: "arrow.counterclockwise") {
                    model.resetUploadDraft()
                }
                if model.isUploadingFile || model.isCheckingUploadPath {
                    ProgressView()
                        .scaleEffect(0.75)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], alignment: .leading, spacing: 10) {
                FeatureCard(title: "File", value: model.uploadFileURL?.lastPathComponent ?? "None", icon: "doc")
                FeatureCard(title: "Type", value: model.uploadType, icon: "tag")
                FeatureCard(title: "Path", value: uploadPathStatus, icon: "point.topleft.down.curvedto.point.bottomright.up")
            }

            NativeGroupPanel(title: isDropTargeted ? "Drop file to review" : "Review public media", subtitle: "Files are published to a public CDN") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Only publish media that can be shared outside your organization. Images and videos must be 20 MiB or smaller.")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        TextField("Paste a direct image or video URL", text: $remoteMediaURL)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .background(theme.field)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        ActionButton(title: isImportingRemoteMedia ? "Importing" : "Import", icon: "arrow.down.doc") {
                            Task { await importRemoteMedia() }
                        }
                        .disabled(remoteMediaURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImportingRemoteMedia)
                    }
                    if isImportingRemoteMedia { ProgressView("Fetching through Hanasand media proxy…") }
                    if let fileURL = model.uploadFileURL {
                        Text("Review: \(fileURL.lastPathComponent) · \(fileSizeDescription(fileURL))")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.textTertiary)
                            .textSelection(.enabled)
                    }
                    field("Name", text: $model.uploadName, placeholder: "Filename shown on the CDN")
                    field("Path", text: $model.uploadPath, placeholder: "optional-short-path")
                        .onChange(of: model.uploadPath) { _, _ in
                            model.uploadPathAvailable = nil
                        }
                    field("MIME type", text: $model.uploadType, placeholder: "image/png")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Description")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(theme.textTertiary)
                        TextEditor(text: $model.uploadDescription)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.text)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 74)
                            .padding(8)
                            .background(theme.field)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    Text(model.uploadStatus)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(statusColor)

                    if !model.uploadedFileURL.isEmpty {
                        HStack(spacing: 10) {
                            Text(model.uploadedFileURL)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(theme.textSecondary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                            Spacer()
                            ActionButton(title: "Preview in Desktop", icon: "macwindow") {
                                model.openUploadedFileInDesktop()
                            }
                            ActionButton(title: "Copy URL", icon: "doc.on.doc") {
                                model.copyUploadedFileURL()
                            }
                        }
                        .padding(10)
                        .background(Color.black.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
                model.selectUploadProviders(providers)
            }
        }
    }

    @MainActor
    private func importRemoteMedia() async {
        let value = remoteMediaURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        isImportingRemoteMedia = true
        defer { isImportingRemoteMedia = false }
        model.uploadStatus = "Fetching media through the authenticated Hanasand proxy…"
        do {
            let client = try NativePublicMediaImportClient(websiteBaseURL: model.settings.websiteBaseURL,
                                                           userID: model.userIDForRequests,
                                                           token: model.authTokenForRequests)
            let imported = try await client.fetch(value)
            let ext = URL(fileURLWithPath: imported.fileName).pathExtension
            let safeExtension = ext.isEmpty ? UTType(imported.mediaType)?.preferredFilenameExtension ?? "media" : ext
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("hanasand-public-media-\(UUID().uuidString).\(safeExtension)")
            try imported.data.write(to: destination, options: .atomic)
            model.selectUploadFile(destination)
            model.uploadName = imported.fileName
            model.uploadType = imported.mediaType
            model.uploadStatus = "Imported for review. Confirm the public-sharing notice before uploading."
        } catch {
            model.uploadStatus = error.localizedDescription
        }
    }

    private func fileSizeDescription(_ url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let bytes = values.fileSize else { return "size unavailable" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var uploadPathStatus: String {
        if model.uploadPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Generated"
        }
        if model.uploadPathAvailable == true {
            return "Available"
        }
        if model.uploadPathAvailable == false {
            return "Taken"
        }
        return "Unchecked"
    }

    var statusColor: Color {
        if model.uploadStatus.localizedCaseInsensitiveContains("failed") || model.uploadStatus.localizedCaseInsensitiveContains("taken") {
            return theme.danger
        }
        if model.uploadStatus.localizedCaseInsensitiveContains("uploaded") || model.uploadStatus.localizedCaseInsensitiveContains("available") {
            return theme.green
        }
        return theme.textSecondary
    }

    func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(theme.textTertiary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.text)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(theme.field)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}
