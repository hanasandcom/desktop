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
