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

extension DesktopAgentModel {

    func copyUploadedFileURL() {
        guard !uploadedFileURL.isEmpty else {
            uploadStatus = "No uploaded URL to copy yet."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(uploadedFileURL, forType: .string)
        uploadStatus = "Copied uploaded file URL."
        append(meta: "Upload", body: "Copied \(uploadedFileURL)", kind: .command)
    }

    func openUploadedFileInDesktop() {
        guard !uploadedFileID.isEmpty else {
            uploadStatus = "The uploaded file preview is not available yet."
            return
        }
        openNativeDashboard(path: "/cdn/files", label: "Uploaded file", detailID: uploadedFileID)
        uploadStatus = "Opened the native file preview."
    }

    func selectUploadProviders(_ providers: [NSItemProvider]) -> Bool {
        importFileProviders(providers) { [weak self] urls in
            guard let first = urls.first else { return }
            self?.selectUploadFile(first)
        }
        return !providers.isEmpty
    }

    func checkUploadPath() async {
        guard hasHanasandAuth else {
            uploadPathAvailable = nil
            uploadStatus = "Sign in to choose or check a custom public path. Guest uploads get a generated link."
            return
        }
        let safePath = uploadPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safePath.isEmpty else {
            uploadPathAvailable = nil
            uploadStatus = "Custom path is optional. Leave it blank to use the generated file id."
            return
        }

        isCheckingUploadPath = true
        defer { isCheckingUploadPath = false }

        do {
            var components = URLComponents(url: settings.cdnBaseURL.normalizedBaseURL.appendingPathComponent("files/check"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "path", value: safeUploadPathWithExtension())]
            let text = try await requestPrettyText(components?.url ?? settings.cdnBaseURL.normalizedBaseURL.appendingPathComponent("files/check"))
            let exists = text.localizedCaseInsensitiveContains(#""exists": true"#) || text.localizedCaseInsensitiveContains(#""exists":true"#)
            uploadPathAvailable = !exists
            uploadStatus = exists ? "That path is already taken." : "Path is available."
        } catch {
            uploadPathAvailable = false
            uploadStatus = "Could not check path: \(error.localizedDescription)"
        }
    }

    func uploadSelectedFile() async {
        guard let fileURL = uploadFileURL else {
            uploadStatus = "Choose a file first."
            return
        }

        let userID = userIDForRequests.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = authTokenForRequests.trimmingCharacters(in: .whitespacesAndNewlines)
        let isGuestUpload = userID.isEmpty && token.isEmpty

        if uploadPathAvailable == false && !isGuestUpload {
            uploadStatus = "Choose an available path before uploading."
            return
        }

        guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
            uploadStatus = "Choose a readable, non-empty file before uploading."
            return
        }
        guard size <= NativePublicMediaImportLimits.maxBytes else {
            uploadStatus = NativePublicMediaImportError.tooLarge.localizedDescription
            return
        }
        if isGuestUpload && (!settings.impersonationToken.isEmpty || !settings.impersonatingUserID.isEmpty) {
            uploadStatus = NativePublicMediaImportError.signInRequired.localizedDescription
            return
        }

        isUploadingFile = true
        defer { isUploadingFile = false }

        do {
            let effectiveName = uploadName.isEmpty ? fileURL.lastPathComponent : uploadName
            let customPath = uploadPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : safeUploadPathWithExtension()
            let client = try NativeCDNUploadClient(
                cdnBaseURL: settings.cdnBaseURL.normalizedBaseURL,
                userID: isGuestUpload ? "" : userID,
                token: isGuestUpload ? "" : token
            )
            let uploaded = try await client.upload(
                fileURL: fileURL,
                name: effectiveName,
                description: uploadDescription,
                path: customPath,
                type: uploadType.isEmpty ? "application/octet-stream" : uploadType
            )
            guard let destination = NativeCDNUploadClient.publicURL(
                cdnBaseURL: settings.cdnBaseURL.normalizedBaseURL,
                uploaded: uploaded,
                preferCustomPath: !isGuestUpload && !uploadPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ) else { throw NativePublicMediaImportError.invalidResponse }
            uploadedFileURL = destination
            uploadedFileID = uploaded.id
            uploadStatus = "Uploaded \(effectiveName) successfully."
            append(meta: "Upload", body: destination, kind: .change)
        } catch {
            uploadStatus = error.localizedDescription
            append(meta: "Upload", body: error.localizedDescription, kind: .error)
        }
    }

    func safeUploadPathWithExtension() -> String {
        let safePath = uploadPath.slugifiedPath
        let ext = uploadFileURL?.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !ext.isEmpty, !safePath.lowercased().hasSuffix(".\(ext.lowercased())") else { return safePath }
        return "\(safePath).\(ext.lowercased())"
    }

    func runNativeDashboardMutation(_ mutation: NativeDashboardMutation) async {
        isLoadingNativeDashboard = true
        nativeDashboardStatus = "Running \(mutation.label)"
        defer { isLoadingNativeDashboard = false }

        do {
            let text = try await requestPrettyText(
                mutation.baseURL(settings: settings).appendingAPIPath(mutation.path),
                method: "POST",
                body: mutation.body,
                authenticated: true,
                userAgent: mutation.userAgent
            )
            nativeDashboardStatus = text.isEmpty ? "Completed \(mutation.label)" : String(text.prefix(240))
            append(meta: mutation.label, body: nativeDashboardStatus, kind: .change)
            await loadNativeDashboardData()
        } catch {
            nativeDashboardStatus = error.localizedDescription
            append(meta: mutation.label, body: error.localizedDescription, kind: .error)
        }
    }

    func append(meta: String, body: String, kind: AgentEvent.Kind = .note) {
        events.append(AgentEvent(meta: meta, body: body, kind: kind))
        if events.count > 80 {
            events.removeFirst(events.count - 80)
        }
    }
}
