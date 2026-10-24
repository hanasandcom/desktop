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

    func saveNoteDraft() async {
        let title = noteDraftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = noteDraftContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !content.isEmpty else {
            nativeDashboardStatus = "Write something first."
            return
        }

        let payload = ["title": title, "content": content, "source": "desktop"]
        let body = (try? JSONEncoder().encode(payload)) ?? Data("{}".utf8)
        let isUpdate = !selectedNoteID.isEmpty
        let path = isUpdate ? "notes/\(selectedNoteID)" : "notes"
        let method = isUpdate ? "PUT" : "POST"
        let draftID = isUpdate ? selectedNoteID : DashboardNoteDraftStore.newNoteID

        do {
            if isUpdate {
                let store = DashboardNoteDraftStore()
                let draft = store.draft(noteID: selectedNoteID, for: userIDForRequests)
                let baseUpdatedAt = draft?.baseUpdatedAt ?? notes.first(where: { $0.id == selectedNoteID })?.updatedAt
                let latestNotes: [DashboardNote] = try await requestJSON(
                    settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("notes"),
                    authenticated: true
                )
                notes = latestNotes
                let latest = latestNotes.first(where: { $0.id == selectedNoteID })
                guard let baseUpdatedAt, let latest, latest.updatedAt == baseUpdatedAt else {
                    noteSaveConflict = true
                    noteConflictServerNote = latest
                    nativeDashboardStatus = latest == nil
                        ? "This note was deleted on the website. Your local draft is preserved; review the conflict before saving."
                        : "This note changed on the website. Your local draft is preserved; review both versions before saving."
                    return
                }
            }
            _ = try await requestPrettyText(
                settings.apiBaseURL.normalizedBaseURL.appendingAPIPath(path),
                method: method,
                body: body,
                authenticated: true
            )
            DashboardNoteDraftStore().remove(noteID: draftID, for: userIDForRequests)
            noteSaveConflict = false
            noteConflictServerNote = nil
            nativeDashboardStatus = "Saved note."
            await loadNativeDashboardData()
        } catch {
            nativeDashboardStatus = error.localizedDescription
        }
    }

    func useWebsiteNoteVersion() {
        guard let noteConflictServerNote else { return }
        DashboardNoteDraftStore().remove(noteID: noteConflictServerNote.id, for: userIDForRequests)
        selectedNoteID = noteConflictServerNote.id
        noteDraftTitle = noteConflictServerNote.title
        noteDraftContent = noteConflictServerNote.content
        noteSaveConflict = false
        self.noteConflictServerNote = nil
        nativeDashboardStatus = "Loaded the website version."
    }

    func saveNoteConflictAsNewNote() async {
        guard noteSaveConflict else { return }
        let conflictedID = selectedNoteID
        let title = noteDraftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = noteDraftContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !content.isEmpty else {
            nativeDashboardStatus = "Write something first."
            return
        }
        let payload = ["title": title, "content": content, "source": "desktop"]
        guard let body = try? JSONEncoder().encode(payload) else {
            nativeDashboardStatus = "Unable to encode note."
            return
        }
        do {
            _ = try await requestPrettyText(
                settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("notes"),
                method: "POST",
                body: body,
                authenticated: true
            )
            DashboardNoteDraftStore().remove(noteID: conflictedID, for: userIDForRequests)
            DashboardNoteDraftStore().remove(noteID: DashboardNoteDraftStore.newNoteID, for: userIDForRequests)
            noteSaveConflict = false
            noteConflictServerNote = nil
            selectedNoteID = ""
            noteDraftTitle = ""
            noteDraftContent = ""
            nativeDashboardStatus = "Saved your draft as a new note."
            await loadNativeDashboardData()
        } catch {
            nativeDashboardStatus = "The new note could not be confirmed. Your local draft is preserved. Review notes before retrying."
        }
    }

    func deleteSelectedNote() async {
        guard !selectedNoteID.isEmpty else { return }
        do {
            _ = try await requestPrettyText(
                settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("notes/\(selectedNoteID)"),
                method: "DELETE",
                authenticated: true
            )
            DashboardNoteDraftStore().remove(noteID: selectedNoteID, for: userIDForRequests)
            noteSaveConflict = false
            noteConflictServerNote = nil
            nativeDashboardStatus = "Deleted note."
            selectedNoteID = ""
            noteDraftTitle = ""
            noteDraftContent = ""
            await loadNativeDashboardData()
        } catch {
            nativeDashboardStatus = error.localizedDescription
        }
    }

    func loadSelectedNoteIntoDraft() {
        let draftStore = DashboardNoteDraftStore()
        let draftID = selectedNoteID.isEmpty ? DashboardNoteDraftStore.newNoteID : selectedNoteID
        if let draft = draftStore.draft(noteID: draftID, for: userIDForRequests) {
            noteDraftTitle = draft.title
            noteDraftContent = draft.content
            return
        }
        guard let selected = notes.first(where: { $0.id == selectedNoteID }) else {
            noteDraftTitle = ""
            noteDraftContent = ""
            return
        }
        noteDraftTitle = selected.title
        noteDraftContent = selected.content
    }

    func createNativeShare() async {
        guard hasHanasandAuth else {
            nativeDashboardStatus = "Hanasand session is not ready. Log in again if this persists."
            return
        }

        let name = shareDraftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = shareDraftContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            nativeDashboardStatus = "Add share content first."
            return
        }

        let id = "desktop-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased())"
        let normalizedName = name.isEmpty ? "desktop-share-\(id.suffix(6))" : name
        let payload = CreateSharePayload(
            id: id,
            includeTree: true,
            name: normalizedName,
            path: normalizedName.slugifiedPath,
            content: content,
            parent: nil,
            type: "share"
        )
        let body = (try? JSONEncoder().encode(payload)) ?? Data("{}".utf8)

        isLoadingNativeDashboard = true
        nativeDashboardStatus = "Creating share"
        defer { isLoadingNativeDashboard = false }

        do {
            let text = try await requestPrettyText(
                settings.cdnBaseURL.normalizedBaseURL.appendingAPIPath("share"),
                method: "POST",
                body: body,
                authenticated: true
            )
            nativeDashboardStatus = "Created \(normalizedName)"
            nativeDashboardPayload = text
            shareDraftName = ""
            shareDraftContent = ""
            append(meta: "Share created", body: normalizedName, kind: .change)
            await loadNativeDashboardData()
        } catch {
            nativeDashboardStatus = error.localizedDescription
            append(meta: "Share failed", body: error.localizedDescription, kind: .error)
        }
    }

    func openShare(_ share: DashboardShare) {
        guard let destination = NativeShareManagerNavigation.destination(
            shareID: share.id, availableShareIDs: shares.map(\.id)
        ) else { return }
        loadShareIntoEditor(share)
        openNativeDashboard(path: destination.path, label: share.displayName, detailID: destination.detailID)
    }

    func loadShareIntoEditor(_ share: DashboardShare) {
        selectedShareID = share.id
        shareEditName = share.name ?? ""
        shareEditPath = share.path ?? ""
        shareEditContent = share.content ?? ""
        nativeDashboardStatus = "Editing \(share.displayName)"
    }

    func updateSelectedShare() async {
        guard !selectedShareID.isEmpty else {
            nativeDashboardStatus = "Select a share first."
            return
        }
        let body = (try? JSONEncoder().encode([
            "name": shareEditName.trimmingCharacters(in: .whitespacesAndNewlines),
            "path": shareEditPath.trimmingCharacters(in: .whitespacesAndNewlines),
            "content": shareEditContent,
        ])) ?? Data("{}".utf8)

        isLoadingNativeDashboard = true
        nativeDashboardStatus = "Updating share"
        defer { isLoadingNativeDashboard = false }

        do {
            _ = try await requestPrettyText(
                settings.cdnBaseURL.normalizedBaseURL.appendingAPIPath("share/\(selectedShareID)"),
                method: "PUT",
                body: body,
                authenticated: true
            )
            nativeDashboardStatus = "Updated share."
            append(meta: "Share updated", body: selectedShareID, kind: .change)
            await loadNativeDashboardData()
        } catch {
            nativeDashboardStatus = error.localizedDescription
        }
    }

    func toggleNativeShareLock(_ share: DashboardShare) async {
        isLoadingNativeDashboard = true
        nativeDashboardStatus = share.locked == true ? "Unlocking share" : "Locking share"
        defer { isLoadingNativeDashboard = false }

        do {
            let locked = share.locked != true
            _ = try await requestPrettyText(
                settings.cdnBaseURL.normalizedBaseURL.appendingAPIPath("share/lock/\(share.id)"),
                method: "PUT",
                body: try JSONSerialization.data(withJSONObject: ["locked": locked]),
                authenticated: true
            )
            nativeDashboardStatus = locked ? "Locked share." : "Unlocked share."
            append(meta: locked ? "Share locked" : "Share unlocked", body: share.id, kind: .change)
            await loadNativeDashboardData()
        } catch {
            nativeDashboardStatus = error.localizedDescription
        }
    }
}

enum NativeShareManagerNavigation {
    static func destination(shareID: String, availableShareIDs: [String]) -> (path: String, detailID: String)? {
        guard NativeRouteSelection.resolve(shareID, among: availableShareIDs) != nil else { return nil }
        return ("/s", shareID)
    }
}
