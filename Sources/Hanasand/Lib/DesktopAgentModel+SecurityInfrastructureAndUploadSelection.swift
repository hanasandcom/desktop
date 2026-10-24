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

@MainActor
final class NativeVMPowerActionGate: ObservableObject {
    enum Phase: Equatable {
        case submitting
        case needsReview
        case reviewed(currentStatus: String)
    }

    struct Intent: Equatable, Identifiable {
        let token: String
        let vmName: String
        let action: String
        var phase: Phase

        var id: String { token }
    }

    static let shared = NativeVMPowerActionGate()

    @Published private var intents: [String: Intent] = [:]
    private let maximumIntentCount = 64

    func intent(for scope: String) -> Intent? { intents[scope] }

    @discardableResult
    func begin(scope: String, vmName: String, action: String) -> Intent? {
        guard intents[scope] == nil,
              ["start", "stop", "restart"].contains(action),
              !scope.isEmpty, !vmName.isEmpty,
              intents.count < maximumIntentCount else { return nil }
        let intent = Intent(token: UUID().uuidString, vmName: vmName, action: action, phase: .submitting)
        intents[scope] = intent
        return intent
    }

    @discardableResult
    func finish(scope: String, token: String, uncertain: Bool) -> Bool {
        guard var intent = intents[scope], intent.token == token, intent.phase == .submitting else { return false }
        if uncertain {
            intent.phase = .needsReview
            intents[scope] = intent
        } else {
            intents.removeValue(forKey: scope)
        }
        return true
    }

    @discardableResult
    func markReviewed(
        scope: String,
        token: String,
        vmName: String,
        currentStatus: String,
        inventoryComplete: Bool,
        targetFound: Bool,
        managementReadSucceeded: Bool
    ) -> Bool {
        guard var intent = intents[scope], intent.token == token, intent.phase == .needsReview,
              intent.vmName.caseInsensitiveCompare(vmName) == .orderedSame,
              inventoryComplete, targetFound, managementReadSucceeded else { return false }
        let status = currentStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        intent.phase = .reviewed(currentStatus: status.isEmpty ? "Status not reported" : String(status.prefix(120)))
        intents[scope] = intent
        return true
    }

    func canAcknowledge(scope: String, token: String) -> Bool {
        guard let intent = intents[scope], intent.token == token else { return false }
        if case .reviewed = intent.phase { return true }
        return false
    }

    @discardableResult
    func acknowledge(scope: String, token: String) -> Bool {
        guard canAcknowledge(scope: scope, token: token) else { return false }
        intents.removeValue(forKey: scope)
        return true
    }
}

func nativeVMPowerActionScopeKey(apiBaseURL: URL, userID: String, organizationID: String, isImpersonating: Bool) -> String {
    [apiBaseURL.absoluteString, userID, organizationID == "personal" ? "" : organizationID, isImpersonating ? "impersonated" : "own"].joined(separator: "|")
}

func nativeVMPowerActionNeedsReviewAfterFailure(_ error: Error, requestWasDispatched: Bool) -> Bool {
    guard requestWasDispatched else { return false }
    if let requestError = error as? DashboardRequestError,
       case let .httpStatus(status) = requestError {
        return status == 408 || status >= 500
    }
    return true
}

extension DesktopAgentModel {

    func addProfileSshKey() async {
        profileSshKeyError = nil
        profileSshKeyNotice = nil
        guard hasHanasandAuth, !isProfileIdentityImpersonating else {
            profileSshKeyError = "Manage SSH keys from your own account."
            return
        }

        do {
            let payload = try ProfileSshKeyPayload(name: profileSshKeyName, publicKey: profileSshPublicKey)
            let body = try JSONEncoder().encode(payload)
            isLoadingNativeDashboard = true
            defer { isLoadingNativeDashboard = false }
            let _: ProfileSshKeyEnvelope = try await accountCredentialJSON(
                settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("user/self/ssh-keys"),
                method: "POST",
                body: body,
                authenticated: true
            )
            profileSshKeyName = ""
            profileSshPublicKey = ""
            profileSshKeyNotice = "SSH key added."
            append(meta: "SSH key added", body: payload.name, kind: .change)
            await loadProfileSecurityData()
        } catch {
            profileSshKeyError = error.localizedDescription
            append(meta: "SSH key add failed", body: error.localizedDescription, kind: .error)
        }
    }

    func deleteProfileSshKey(_ key: ProfileSshKey) async {
        profileSshKeyError = nil
        profileSshKeyNotice = nil
        guard hasHanasandAuth, !isProfileIdentityImpersonating else {
            profileSshKeyError = "Manage SSH keys from your own account."
            return
        }

        isLoadingNativeDashboard = true
        defer { isLoadingNativeDashboard = false }
        do {
            _ = try await accountCredentialText(
                settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("user/self/ssh-keys/\(key.id)"),
                method: "DELETE",
                authenticated: true
            )
            profileSshKeyNotice = "SSH key removed."
            append(meta: "SSH key removed", body: key.name, kind: .change)
            await loadProfileSecurityData()
        } catch {
            profileSshKeyError = error.localizedDescription
            append(meta: "SSH key removal failed", body: error.localizedDescription, kind: .error)
        }
    }

    func revokeProfileSession(_ session: DashboardAuthSession) async {
        guard hasHanasandAuth else {
            nativeDashboardStatus = "Hanasand session is not ready. Log in again if this persists."
            return
        }

        isLoadingNativeDashboard = true
        nativeDashboardStatus = "Revoking session"
        defer { isLoadingNativeDashboard = false }

        do {
            _ = try await accountCredentialText(
                settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("auth/sessions/\(session.tokenID)"),
                method: "DELETE",
                authenticated: true
            )
            nativeDashboardStatus = "Revoked session \(session.tokenID)"
            append(meta: "Session revoked", body: "\(session.deviceLabel) · \(session.ip ?? "unknown IP")", kind: .change)
            await loadProfileSecurityData()
        } catch {
            nativeDashboardStatus = error.localizedDescription
            append(meta: "Session revoke failed", body: error.localizedDescription, kind: .error)
        }
    }

    func revokeOtherProfileSessions() async {
        guard hasHanasandAuth else {
            nativeDashboardStatus = "Hanasand session is not ready. Log in again if this persists."
            return
        }

        isLoadingNativeDashboard = true
        nativeDashboardStatus = "Revoking other sessions"
        defer { isLoadingNativeDashboard = false }

        do {
            let body = (try? JSONEncoder().encode(["keep_current": true])) ?? Data("{}".utf8)
            let text = try await accountCredentialText(
                settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("auth/sessions/revoke"),
                method: "POST",
                body: body,
                authenticated: true
            )
            nativeDashboardStatus = "Revoked other sessions"
            append(meta: "Sessions revoked", body: String(text.prefix(240)), kind: .change)
            await loadProfileSecurityData()
        } catch {
            nativeDashboardStatus = error.localizedDescription
            append(meta: "Session revoke failed", body: error.localizedDescription, kind: .error)
        }
    }

    func deleteProfileCertificate(_ certificate: DashboardCertificate) async {
        guard hasHanasandAuth else {
            nativeDashboardStatus = "Hanasand session is not ready. Log in again if this persists."
            return
        }

        isLoadingNativeDashboard = true
        nativeDashboardStatus = "Deleting certificate"
        defer { isLoadingNativeDashboard = false }

        do {
            _ = try await accountCredentialText(
                settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("certificates/\(certificate.id)"),
                method: "DELETE",
                authenticated: true
            )
            nativeDashboardStatus = "Deleted certificate \(certificate.name)"
            append(meta: "Certificate deleted", body: certificate.name, kind: .change)
            await loadProfileSecurityData()
        } catch {
            nativeDashboardStatus = error.localizedDescription
            append(meta: "Certificate delete failed", body: error.localizedDescription, kind: .error)
        }
    }

    func restartDockerContainer(_ container: DashboardDockerContainer) async {
        guard hasHanasandAuth else {
            nativeDashboardStatus = "Hanasand session is not ready. Log in again if this persists."
            return
        }

        isLoadingNativeDashboard = true
        nativeDashboardStatus = "Restarting \(container.displayName)"
        defer { isLoadingNativeDashboard = false }

        do {
            let text = try await requestPrettyText(
                settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("restart/\(container.id)"),
                authenticated: true
            )
            nativeDashboardStatus = "Restart requested for \(container.displayName)"
            append(meta: "Docker restart", body: text.isEmpty ? container.id : String(text.prefix(240)), kind: .change)
            await loadNativeDashboardData()
        } catch {
            nativeDashboardStatus = error.localizedDescription
            append(meta: "Docker restart failed", body: error.localizedDescription, kind: .error)
        }
    }

    func runVirtualMachineAction(_ vm: DashboardVM, action: String) async {
        guard let actionPath = nativeVMActionPath(
            vmName: vm.name,
            action: action,
            isImpersonating: isProfileIdentityImpersonating
        ) else {
            nativeDashboardStatus = "Use your own account and choose a supported VM power action."
            append(meta: "VM action blocked", body: nativeDashboardStatus, kind: .error)
            return
        }
        guard hasHanasandAuth else {
            nativeDashboardStatus = "Hanasand session is not ready. Log in again if this persists."
            append(meta: "VM action failed", body: nativeDashboardStatus, kind: .error)
            return
        }

        let actionScope = nativeVMPowerActionScopeKey(
            apiBaseURL: settings.apiBaseURL.normalizedBaseURL,
            userID: userIDForRequests,
            organizationID: selectedOrganizationID,
            isImpersonating: isProfileIdentityImpersonating
        )
        guard let intent = NativeVMPowerActionGate.shared.begin(scope: actionScope, vmName: vm.name, action: action) else {
            nativeDashboardStatus = "Refresh and review the earlier VM action before submitting another power action."
            append(meta: "VM action blocked", body: nativeDashboardStatus, kind: .error)
            return
        }

        isLoadingNativeDashboard = true
        nativeDashboardStatus = "\(action.capitalized) \(vm.name)"
        defer { isLoadingNativeDashboard = false }

        var requestWasDispatched = false
        do {
            let accessClient = try NativeVMWorkspaceClient(
                apiBaseURL: settings.apiBaseURL,
                userID: userIDForRequests,
                token: authTokenForRequests,
                organizationID: selectedOrganizationID.isEmpty ? nil : selectedOrganizationID
            )
            let currentAccess = try await accessClient.loadManagement(for: vm.name)
            guard currentAccess.canManage, !isProfileIdentityImpersonating else {
                throw NativeVMWorkspaceClientError.permissionDenied
            }
            guard actionScope == nativeVMPowerActionScopeKey(
                apiBaseURL: settings.apiBaseURL.normalizedBaseURL,
                userID: userIDForRequests,
                organizationID: selectedOrganizationID,
                isImpersonating: isProfileIdentityImpersonating
            ) else {
                throw NativeVMWorkspaceClientError.permissionDenied
            }
            requestWasDispatched = true
            let text = try await requestPrettyText(
                settings.apiBaseURL.normalizedBaseURL.appendingAPIPath(actionPath),
                method: "POST",
                authenticated: true
            )
            _ = NativeVMPowerActionGate.shared.finish(scope: actionScope, token: intent.token, uncertain: false)
            nativeDashboardStatus = "\(action.capitalized) requested for \(vm.name)"
            append(meta: "VM \(action)", body: text.isEmpty ? vm.name : String(text.prefix(240)), kind: .change)
            await loadNativeDashboardData()
        } catch {
            let uncertain = nativeVMPowerActionNeedsReviewAfterFailure(error, requestWasDispatched: requestWasDispatched)
            _ = NativeVMPowerActionGate.shared.finish(scope: actionScope, token: intent.token, uncertain: uncertain)
            nativeDashboardStatus = uncertain
                ? "The \(action) request may still be processing for \(vm.name). Refresh and review its current state before acknowledging or trying again."
                : error.localizedDescription
            append(meta: "VM \(action) failed", body: error.localizedDescription, kind: .error)
        }
    }

    func chooseUploadFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image, .movie, .pdf, .plainText, .json, .data]

        guard panel.runModal() == .OK, let url = panel.url else {
            uploadStatus = "File selection cancelled."
            return
        }

        selectUploadFile(url)
    }

    func selectUploadFile(_ url: URL) {
        uploadFileURL = url
        uploadName = url.lastPathComponent
        uploadType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        if uploadPath.isEmpty {
            uploadPath = url.deletingPathExtension().lastPathComponent.slugifiedPath
        }
        uploadPathAvailable = nil
        uploadedFileURL = ""
        uploadedFileID = ""
        uploadStatus = "Ready to upload \(url.lastPathComponent)."
    }

    func resetUploadDraft() {
        uploadFileURL = nil
        uploadName = ""
        uploadDescription = ""
        uploadPath = ""
        uploadType = "application/octet-stream"
        uploadPathAvailable = nil
        uploadedFileURL = ""
        uploadedFileID = ""
        uploadStatus = "Choose a file to upload to the CDN."
    }
}
