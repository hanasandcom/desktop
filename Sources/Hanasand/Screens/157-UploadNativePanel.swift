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

enum NativeUploadDescriptionInput {
    static let maximumLength = 1_024

    static func limited(_ value: String) -> String {
        guard value.utf16.count > maximumLength else { return value }

        var result = ""
        var length = 0
        for character in value {
            let characterLength = String(character).utf16.count
            guard length + characterLength <= maximumLength else { break }
            result.append(character)
            length += characterLength
        }
        return result
    }
}

struct UploadNativePanel: View {
    @EnvironmentObject var model: DesktopAgentModel
    @Environment(\.desktopTheme) var theme
    @State var isDropTargeted = false
    @State private var remoteMediaURL = ""
    @State private var isImportingRemoteMedia = false
    @State private var localPreviewData: Data?
    @State private var isLoadingLocalPreview = false
    @State private var localPreviewError = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 126), alignment: .leading)], alignment: .leading, spacing: 8) {
                ActionButton(title: "Choose file", icon: "doc.badge.plus") {
                    model.chooseUploadFile()
                }
                ActionButton(title: "Check path", icon: "checkmark.seal") {
                    Task { await model.checkUploadPath() }
                }
                .disabled(!model.hasHanasandAuth || model.uploadPath.isEmpty || model.isCheckingUploadPath)
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
                        .disabled(!model.hasHanasandAuth || remoteMediaURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImportingRemoteMedia)
                    }
                    if !model.hasHanasandAuth {
                        Text("Remote media import and custom paths require sign-in. Guest uploads receive a generated public link.")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if isImportingRemoteMedia { ProgressView("Fetching through Hanasand media proxy…") }
                    if let fileURL = model.uploadFileURL {
                        Text("Review: \(fileURL.lastPathComponent) · \(fileSizeDescription(fileURL))")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.textTertiary)
                            .textSelection(.enabled)
                        localPreview(fileURL)
                    }
                    field("Name", text: $model.uploadName, placeholder: "Filename shown on the CDN")
                    if model.hasHanasandAuth {
                        field("Path", text: $model.uploadPath, placeholder: "optional-short-path")
                            .onChange(of: model.uploadPath) { _, _ in
                                model.uploadPathAvailable = nil
                            }
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
                            .onChange(of: model.uploadDescription) { _, value in
                                let limited = NativeUploadDescriptionInput.limited(value)
                                if limited != value { model.uploadDescription = limited }
                            }
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
        .task(id: model.uploadFileURL) {
            await loadLocalPreview(for: model.uploadFileURL)
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

    @ViewBuilder
    private func localPreview(_ fileURL: URL) -> some View {
        let kind = NativeUploadPreviewKind(fileExtension: fileURL.pathExtension)

        if kind == .other {
            NativeEmptyState(title: "Preview after upload", message: "This file type can still be uploaded, but Desktop does not render a local preview for it.")
                .frame(maxWidth: .infinity, minHeight: 170)
                .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else if let data = localPreviewData {
            if kind == .image, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 300)
                    .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel("Selected image preview")
            } else if kind == .video {
                NativeVideoPreview(id: fileURL.absoluteString, data: data, fileExtension: fileURL.pathExtension)
                    .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 320)
                    .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                NativeEmptyState(title: "Preview unavailable", message: "This image could not be decoded. You can still upload the selected file.")
                    .frame(maxWidth: .infinity, minHeight: 170)
                    .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        } else if isLoadingLocalPreview {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Preparing local preview…")
                    .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 170)
            .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityElement(children: .combine)
        } else {
            NativeEmptyState(title: "Preview unavailable", message: localPreviewError.isEmpty ? "This file could not be previewed. You can still upload it." : localPreviewError)
                .frame(maxWidth: .infinity, minHeight: 170)
                .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    @MainActor
    private func loadLocalPreview(for fileURL: URL?) async {
        localPreviewData = nil
        localPreviewError = ""
        guard let fileURL else {
            isLoadingLocalPreview = false
            return
        }

        let kind = NativeUploadPreviewKind(fileExtension: fileURL.pathExtension)
        guard kind != .other else {
            isLoadingLocalPreview = false
            return
        }

        isLoadingLocalPreview = true
        defer { isLoadingLocalPreview = false }
        do {
            let data = try await Self.readLocalPreviewData(from: fileURL)
            guard !Task.isCancelled, model.uploadFileURL == fileURL else { return }
            guard kind.canPreview(fileSize: data.count) else {
                localPreviewError = NativePublicMediaImportError.tooLarge.localizedDescription
                return
            }
            localPreviewData = data
        } catch {
            guard !Task.isCancelled, model.uploadFileURL == fileURL else { return }
            localPreviewError = error.localizedDescription
        }
    }

    private nonisolated static func readLocalPreviewData(from fileURL: URL) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let hasSecurityScope = fileURL.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope { fileURL.stopAccessingSecurityScopedResource() }
            }

            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = values.fileSize, fileSize > 0 else {
                throw NativeUploadPreviewReadError.emptyFile
            }
            guard fileSize <= NativePublicMediaImportLimits.maxBytes else {
                throw NativePublicMediaImportError.tooLarge
            }

            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            var data = Data()
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                guard chunk.count <= NativePublicMediaImportLimits.maxBytes - data.count else {
                    throw NativePublicMediaImportError.tooLarge
                }
                data.append(chunk)
            }
            guard !data.isEmpty else { throw NativeUploadPreviewReadError.emptyFile }
            return data
        }.value
    }

    private func fileSizeDescription(_ url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let bytes = values.fileSize else { return "size unavailable" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var uploadPathStatus: String {
        if !model.hasHanasandAuth {
            return "Generated public link"
        }
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

private enum NativeUploadPreviewReadError: LocalizedError {
    case emptyFile

    var errorDescription: String? {
        "This file is empty or could not be read for preview. You can still select another file."
    }
}
