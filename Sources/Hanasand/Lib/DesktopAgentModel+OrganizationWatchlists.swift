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

private struct OrganizationWatchlistDelete: Encodable { let reason: String; let requestId: String }

func organizationWatchlistMayWrite(page: OrganizationWatchlistPage, selectedOrganizationID: String, isImpersonating: Bool) -> Bool {
    !isImpersonating && !selectedOrganizationID.isEmpty && selectedOrganizationID == page.organization.id
        && page.organization.lifecycleStatus == "active" && page.sharedWatchlistContract.permissions.canWrite
}

extension DesktopAgentModel {
    var filteredOrganizationWatchlists: [OrganizationWatchlistItem] {
        guard let page = organizationWatchlistPage else { return [] }
        let terms = organizationWatchlistSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().split(whereSeparator: \.isWhitespace)
        return page.watchlistItems.filter { item in
            (organizationWatchlistStatusFilter == "all" || item.status.rawValue == organizationWatchlistStatusFilter)
                && terms.allSatisfy { "\(item.kind.rawValue) \(item.value) \(item.notes)".lowercased().contains($0) }
        }
    }

    var canWriteSelectedOrganizationWatchlists: Bool {
        guard let page = organizationWatchlistPage else { return false }
        return organizationWatchlistMayWrite(page: page, selectedOrganizationID: selectedOrganizationID,
                                             isImpersonating: !settings.impersonationToken.isEmpty || !settings.impersonatingUserID.isEmpty)
    }

    var canCleanupSelectedOrganizationWatchlists: Bool {
        guard canWriteSelectedOrganizationWatchlists, let page = organizationWatchlistPage else { return false }
        return page.sharedWatchlistContract.permissions.canCleanup
    }

    func loadOrganizationWatchlists() async {
        let organizationID = selectedOrganizationID
        guard hasHanasandAuth, !organizationID.isEmpty,
              organizationID.range(of: "^[A-Za-z0-9_.:@-]{1,200}$", options: .regularExpression) != nil,
              ![".", "..", "personal"].contains(organizationID) else {
            organizationWatchlistPage = nil
            organizationWatchlistStatus = hasHanasandAuth ? "Select an active organization to view its watchlists." : "Sign in to view organization watchlists."
            return
        }
        isLoadingOrganizationWatchlists = true
        organizationWatchlistStatus = "Loading organization watchlists"
        defer { isLoadingOrganizationWatchlists = false }
        do {
            let url = organizationWatchlistURL(organizationID: organizationID, itemID: nil, suffix: "", query: [URLQueryItem(name: "includeArchived", value: "true")])
            let page: OrganizationWatchlistPage = try await requestJSON(url, authenticated: true)
            guard selectedOrganizationID == organizationID, page.organization.id == organizationID,
                  page.sharedWatchlistContract.permissions.canRead else { throw OrganizationWatchlistError.scopeChanged }
            organizationWatchlistPage = page
            if !page.watchlistItems.contains(where: { $0.id == selectedOrganizationWatchlistItemID }) { selectedOrganizationWatchlistItemID = "" }
            organizationWatchlistStatus = page.watchlistItems.isEmpty ? "No watchlist terms in \(page.organization.name)." : "Loaded \(page.watchlistItems.count) watchlist terms for \(page.organization.name)."
        } catch {
            organizationWatchlistPage = nil
            organizationWatchlistStatus = "Could not load organization watchlists: \(error.localizedDescription)"
        }
    }

    func beginOrganizationWatchlistEdit(_ item: OrganizationWatchlistItem?) {
        guard canWriteSelectedOrganizationWatchlists else { return }
        organizationWatchlistFormPresented = true
        guard let item else {
            organizationWatchlistEditingID = ""
            organizationWatchlistDraftKind = .domain
            organizationWatchlistDraftValue = ""
            organizationWatchlistDraftNotes = ""
            return
        }
        guard canWriteSelectedOrganizationWatchlists, item.organizationId == selectedOrganizationID,
              item.status != .archived else { return }
        organizationWatchlistEditingID = item.id
        organizationWatchlistDraftKind = item.kind
        organizationWatchlistDraftValue = item.value
        organizationWatchlistDraftNotes = item.notes
    }

    func cancelOrganizationWatchlistEdit() {
        organizationWatchlistFormPresented = false
        organizationWatchlistEditingID = ""
        organizationWatchlistDraftKind = .domain
        organizationWatchlistDraftValue = ""
        organizationWatchlistDraftNotes = ""
    }

    func saveOrganizationWatchlistDraft() async {
        guard canWriteSelectedOrganizationWatchlists, !isMutatingOrganizationWatchlists,
              let page = organizationWatchlistPage else { organizationWatchlistStatus = "Refresh an editable organization watchlist first."; return }
        let value = organizationWatchlistDraftValue.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\0", with: "")
        let notes = organizationWatchlistDraftNotes.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\0", with: "")
        guard !value.isEmpty, value.count <= 240, notes.count <= 2000 else { organizationWatchlistStatus = "Enter a term of 1–240 characters and notes of at most 2000 characters."; return }
        guard organizationWatchlistEditingID.isEmpty || page.watchlistItems.contains(where: { $0.id == organizationWatchlistEditingID && $0.status != .archived }) else {
            organizationWatchlistStatus = "Refresh before editing this watchlist term."; return
        }
        isMutatingOrganizationWatchlists = true
        organizationWatchlistStatus = "Verifying organization access"
        let initialUser = userIDForRequests, initialToken = authTokenForRequests, orgID = page.organization.id
        let itemID = organizationWatchlistEditingID
        defer { isMutatingOrganizationWatchlists = false }
        do {
            let fresh: OrganizationWatchlistPage = try await requestJSON(organizationWatchlistURL(organizationID: orgID, itemID: nil, suffix: "", query: [URLQueryItem(name: "includeArchived", value: "true")]), authenticated: true)
            guard fresh.organization.id == orgID, fresh.sharedWatchlistContract.permissions.canWrite,
                  fresh.organization.lifecycleStatus == "active", selectedOrganizationID == orgID,
                  initialUser == userIDForRequests, initialToken == authTokenForRequests,
                  settings.impersonationToken.isEmpty, settings.impersonatingUserID.isEmpty else { throw OrganizationWatchlistError.scopeChanged }
            if !itemID.isEmpty && !fresh.watchlistItems.contains(where: { $0.id == itemID && $0.status != .archived }) { throw OrganizationWatchlistError.itemChanged }
            let draftValue: String
            switch organizationWatchlistDraftKind {
            case .domain: draftValue = value.lowercased().replacingOccurrences(of: "^https?://", with: "", options: .regularExpression).replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression).split(separator: "/").first.map(String.init) ?? ""
            case .actor, .keyword: draftValue = value.lowercased()
            case .company, .vendor: draftValue = value
            }
            guard !draftValue.isEmpty else { throw OrganizationWatchlistError.invalidDraft }
            let requestId = "desktop-watchlist-\(UUID().uuidString.lowercased())"
            let reason = itemID.isEmpty ? "Shared watchlist term added from the Desktop workspace." : "Shared watchlist term updated from the Desktop workspace."
            let payload = OrganizationWatchlistDraft(kind: organizationWatchlistDraftKind, value: draftValue, notes: notes, reason: reason, requestId: requestId)
            let method = itemID.isEmpty ? "POST" : "PUT"
            let url = organizationWatchlistURL(organizationID: orgID, itemID: itemID.isEmpty ? nil : itemID, suffix: "", query: [])
            let body = try JSONEncoder().encode(payload)
            let receipt: OrganizationWatchlistMutationReceipt = try await requestJSON(url, method: method, body: body, authenticated: true)
            guard receipt.watchlistItem.organizationId == orgID,
                  itemID.isEmpty || receipt.watchlistItem.id == itemID else { throw OrganizationWatchlistError.unconfirmed }
            organizationWatchlistEditingID = ""
            organizationWatchlistFormPresented = false
            organizationWatchlistDraftValue = ""
            organizationWatchlistDraftNotes = ""
            await loadOrganizationWatchlists()
            organizationWatchlistStatus = "Saved \(receipt.watchlistItem.value)."
        } catch {
            let message = error.localizedDescription
            await loadOrganizationWatchlists()
            organizationWatchlistStatus = "Watchlist save needs review: \(message). The item list was refreshed; check it before retrying."
        }
    }

    func changeOrganizationWatchlist(_ item: OrganizationWatchlistItem, action: String) async {
        guard canWriteSelectedOrganizationWatchlists, !isMutatingOrganizationWatchlists,
              let page = organizationWatchlistPage, item.organizationId == selectedOrganizationID,
              ["pause", "resume", "restore", "archive"].contains(action),
              page.watchlistItems.contains(where: { $0.id == item.id && $0.status == item.status }) else {
            organizationWatchlistStatus = "Refresh and select a current editable watchlist term first."; return
        }
        if action == "archive" && !page.sharedWatchlistContract.permissions.canArchive { organizationWatchlistStatus = "You do not have permission to archive this watchlist."; return }
        if action == "restore" && item.status != .archived || action == "resume" && item.status != .paused || action == "pause" && item.status != .active {
            organizationWatchlistStatus = "Refresh before changing this watchlist state."; return
        }
        isMutatingOrganizationWatchlists = true
        organizationWatchlistStatus = "Verifying organization access"
        let orgID = page.organization.id, initialUser = userIDForRequests, initialToken = authTokenForRequests
        defer { isMutatingOrganizationWatchlists = false }
        do {
            let fresh: OrganizationWatchlistPage = try await requestJSON(organizationWatchlistURL(organizationID: orgID, itemID: nil, suffix: "", query: [URLQueryItem(name: "includeArchived", value: "true")]), authenticated: true)
            guard selectedOrganizationID == orgID, fresh.organization.id == orgID,
                  fresh.sharedWatchlistContract.permissions.canWrite,
                  fresh.organization.lifecycleStatus == "active",
                  action != "archive" || fresh.sharedWatchlistContract.permissions.canArchive,
                  initialUser == userIDForRequests, initialToken == authTokenForRequests,
                  settings.impersonationToken.isEmpty, settings.impersonatingUserID.isEmpty,
                  let current = fresh.watchlistItems.first(where: { $0.id == item.id }), current.status == item.status else { throw OrganizationWatchlistError.scopeChanged }
            let requestId = "desktop-watchlist-\(UUID().uuidString.lowercased())"
            let url: URL
            let body: Data
            let method: String
            if action == "archive" {
                url = organizationWatchlistURL(organizationID: orgID, itemID: item.id, suffix: "", query: [])
                body = try JSONEncoder().encode(OrganizationWatchlistDelete(reason: "Watchlist term archived from the Desktop workspace.", requestId: requestId))
                method = "DELETE"
            } else {
                url = organizationWatchlistURL(organizationID: orgID, itemID: item.id, suffix: "/actions", query: [])
                body = try JSONEncoder().encode(OrganizationWatchlistAction(action: action, reason: "Watchlist term \(action)d from the Desktop workspace.", requestId: requestId))
                method = "POST"
            }
            let receipt: OrganizationWatchlistMutationReceipt = try await requestJSON(url, method: method, body: body, authenticated: true)
            let expected: OrganizationWatchlistStatus = action == "pause" ? .paused : action == "archive" ? .archived : .active
            guard receipt.watchlistItem.organizationId == orgID, receipt.watchlistItem.id == item.id, receipt.watchlistItem.status == expected else { throw OrganizationWatchlistError.unconfirmed }
            await loadOrganizationWatchlists()
            organizationWatchlistStatus = "\(item.value) \(action)d."
        } catch {
            let message = error.localizedDescription
            await loadOrganizationWatchlists()
            organizationWatchlistStatus = "Watchlist change needs review: \(message). The item list was refreshed; check it before retrying."
        }
    }

    func cleanupOrganizationWatchlists(itemIDs: [String]) async {
        guard canCleanupSelectedOrganizationWatchlists, !isMutatingOrganizationWatchlists,
              let page = organizationWatchlistPage, !itemIDs.isEmpty, itemIDs.count <= 50,
              Set(itemIDs).count == itemIDs.count,
              itemIDs.allSatisfy({ id in page.watchlistItems.contains(where: { $0.id == id && $0.status != .archived }) }) else {
            organizationWatchlistStatus = "Refresh and select 1–50 current, unarchived terms to archive."
            return
        }
        let organizationID = page.organization.id
        let userID = userIDForRequests
        let token = authTokenForRequests
        isMutatingOrganizationWatchlists = true
        organizationWatchlistStatus = "Verifying selected watchlist terms…"
        defer { isMutatingOrganizationWatchlists = false }
        do {
            let fresh: OrganizationWatchlistPage = try await requestJSON(organizationWatchlistURL(organizationID: organizationID, itemID: nil, suffix: "", query: [URLQueryItem(name: "includeArchived", value: "true")]), authenticated: true)
            guard selectedOrganizationID == organizationID, userID == userIDForRequests, token == authTokenForRequests,
                  settings.impersonationToken.isEmpty, settings.impersonatingUserID.isEmpty,
                  fresh.organization.id == organizationID, fresh.sharedWatchlistContract.permissions.canCleanup,
                  fresh.organization.lifecycleStatus == "active",
                  itemIDs.allSatisfy({ id in fresh.watchlistItems.contains(where: { $0.id == id && $0.status != .archived }) }) else { throw OrganizationWatchlistError.scopeChanged }
            let body = try JSONSerialization.data(withJSONObject: [
                "itemIds": itemIDs,
                "reason": "Selected organization watchlist terms archived from Hanasand Desktop.",
                "requestId": "desktop-watchlist-cleanup-\(UUID().uuidString.lowercased())"
            ])
            let receipt: OrganizationWatchlistCleanupReceipt = try await requestJSON(organizationWatchlistURL(organizationID: organizationID, itemID: nil, suffix: "/cleanup", query: []), method: "POST", body: body, authenticated: true)
            await loadOrganizationWatchlists()
            let count = receipt.cleanup?.archivedCount ?? 0
            let skipped = receipt.cleanup?.skippedItemIds?.count ?? 0
            organizationWatchlistStatus = "Archived \(count) selected term\(count == 1 ? "" : "s")\(skipped > 0 ? "; \(skipped) skipped" : "")."
        } catch {
            let message = error.localizedDescription
            await loadOrganizationWatchlists()
            organizationWatchlistStatus = "Cleanup needs review: \(message). The current list was refreshed before you retry."
        }
    }

    func rebuildOrganizationWatchlistAlerts() async {
        guard canWriteSelectedOrganizationWatchlists, !isMutatingOrganizationWatchlists,
              let page = organizationWatchlistPage else { return }
        let organizationID = page.organization.id
        let userID = userIDForRequests
        let token = authTokenForRequests
        isMutatingOrganizationWatchlists = true
        organizationWatchlistStatus = "Refreshing events from retained captures…"
        defer { isMutatingOrganizationWatchlists = false }
        do {
            let body = try JSONSerialization.data(withJSONObject: [
                "organizationId": organizationID, "tenantId": organizationID,
                "requestId": "desktop-org-events-\(UUID().uuidString.lowercased())"
            ])
            let receipt: OrganizationWatchlistAlertRebuildReceipt = try await requestJSON(settings.websiteBaseURL.normalizedBaseURL.appendingAPIPath("api/findings/alerts/rebuild"), method: "POST", body: body, authenticated: true)
            guard selectedOrganizationID == organizationID, userID == userIDForRequests, token == authTokenForRequests,
                  settings.impersonationToken.isEmpty, settings.impersonatingUserID.isEmpty else { throw OrganizationWatchlistError.scopeChanged }
            await loadOrganizationWatchlists()
            let count = receipt.savedAlertCount ?? receipt.alertIds?.count ?? 0
            organizationWatchlistStatus = count == 0 ? "No matching events were found in retained captures." : "Refreshed \(count) event\(count == 1 ? "" : "s") from retained captures."
        } catch {
            organizationWatchlistStatus = "Could not refresh events: \(error.localizedDescription)"
        }
    }

    func requestOrganizationFreshCollection() async {
        guard canWriteSelectedOrganizationWatchlists, !isMutatingOrganizationWatchlists,
              let page = organizationWatchlistPage, page.watchlistItems.contains(where: { $0.status == .active }) else {
            organizationWatchlistStatus = "Add or resume an active watchlist term before requesting a fresh collection."
            return
        }
        let organizationID = page.organization.id
        let userID = userIDForRequests
        let token = authTokenForRequests
        if organizationWatchlistCollectionRequestIdempotencyKey.isEmpty {
            organizationWatchlistCollectionRequestIdempotencyKey = "desktop-org-\(organizationID)-\(UUID().uuidString.lowercased())"
        }
        isMutatingOrganizationWatchlists = true
        organizationWatchlistStatus = "Requesting a fresh source collection…"
        defer { isMutatingOrganizationWatchlists = false }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["organizationId": organizationID, "tenantId": organizationID])
            let url = settings.websiteBaseURL.normalizedBaseURL.appendingAPIPath("api/organizations/\(encodedWatchlistPath(organizationID))/collection-requests")
            var request = self.request(url, method: "POST", body: body, authenticated: true)
            request.setValue(organizationWatchlistCollectionRequestIdempotencyKey, forHTTPHeaderField: "idempotency-key")
            let (data, response) = try await URLSession.shared.data(for: request)
            try validateHTTP(response)
            let receipt = try JSONDecoder().decode(OrganizationCollectionRequestEnvelope.self, from: data)
            guard selectedOrganizationID == organizationID, userID == userIDForRequests, token == authTokenForRequests,
                  settings.impersonationToken.isEmpty, settings.impersonatingUserID.isEmpty else { throw OrganizationWatchlistError.scopeChanged }
            organizationWatchlistCollectionRequest = receipt.collectionRequest
            organizationWatchlistCollectionRequestIdempotencyKey = ""
            let next = receipt.collectionRequest
            organizationWatchlistStatus = next.map { "Fresh collection \($0.status); \($0.captureCount ?? 0) captures and \($0.alertCount ?? 0) events reported." } ?? "Fresh collection request accepted."
        } catch {
            organizationWatchlistStatus = "Fresh collection outcome needs review: \(error.localizedDescription). Refresh request status before retrying."
        }
    }

    func refreshOrganizationCollectionRequest() async {
        guard let current = organizationWatchlistCollectionRequest, let page = organizationWatchlistPage,
              !isMutatingOrganizationWatchlists else { return }
        let organizationID = page.organization.id
        isMutatingOrganizationWatchlists = true
        defer { isMutatingOrganizationWatchlists = false }
        do {
            let url = settings.websiteBaseURL.normalizedBaseURL.appendingAPIPath("api/organizations/\(encodedWatchlistPath(organizationID))/collection-requests/\(encodedWatchlistPath(current.requestId))")
            let envelope: OrganizationCollectionRequestEnvelope = try await requestJSON(url, authenticated: true)
            guard selectedOrganizationID == organizationID else { throw OrganizationWatchlistError.scopeChanged }
            organizationWatchlistCollectionRequest = envelope.collectionRequest ?? current
            let next = organizationWatchlistCollectionRequest ?? current
            organizationWatchlistStatus = "Fresh collection \(next.status); \(next.captureCount ?? 0) captures and \(next.alertCount ?? 0) events reported."
        } catch {
            organizationWatchlistStatus = "Could not refresh collection status: \(error.localizedDescription)"
        }
    }

    private func organizationWatchlistURL(organizationID: String, itemID: String?, suffix: String, query: [URLQueryItem]) -> URL {
        let pathSafe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._:@")
        var path = "api/organizations/\(organizationID.addingPercentEncoding(withAllowedCharacters: pathSafe) ?? organizationID)/watchlists"
        if let itemID { path += "/\(itemID.addingPercentEncoding(withAllowedCharacters: pathSafe) ?? itemID)" }
        path += suffix
        var components = URLComponents(url: settings.websiteBaseURL.normalizedBaseURL.appendingAPIPath(path), resolvingAgainstBaseURL: false)
        components?.queryItems = query.isEmpty ? nil : query
        return components?.url ?? settings.websiteBaseURL.normalizedBaseURL.appendingAPIPath(path)
    }
}

private func encodedWatchlistPath(_ value: String) -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._:@")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

private enum OrganizationWatchlistError: LocalizedError {
    case scopeChanged
    case itemChanged
    case invalidDraft
    case unconfirmed
    var errorDescription: String? {
        switch self {
        case .scopeChanged: return "Selected organization access changed. Refresh before continuing."
        case .itemChanged: return "Watchlist item state changed. Refresh before continuing."
        case .invalidDraft: return "The watchlist term is invalid."
        case .unconfirmed: return "The server response did not confirm the requested watchlist change."
        }
    }
}
