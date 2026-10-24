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

private struct ThreatSearchPayload: Encodable { let query: String }
private struct ThreatSavedSearchReceipt: Decodable { let savedSearch: ThreatSavedSearch?; let ok: Bool? }

extension DesktopAgentModel {
    var threatIntelligenceSearchScope: ThreatIntelligenceSearchScope {
        ThreatIntelligenceSearchScope(
            userID: userIDForRequests,
            organizationID: settings.selectedOrganizationID,
            websiteBaseURL: settings.websiteBaseURL,
            apiBaseURL: settings.apiBaseURL,
            routePath: selectedDashboardPath ?? "",
            routeDetailID: selectedNativeDashboardDetailID,
            routeQuery: selectedNativeDashboardQuery["q"] ?? ""
        )
    }

    func cancelThreatIntelligenceSearch() {
        isLoadingThreatSearch = false
    }

    func loadThreatSavedSearches() async {
        guard hasHanasandAuth, settings.impersonationToken.isEmpty, settings.impersonatingUserID.isEmpty else {
            threatSavedSearches = []
            threatSavedSearchStatus = "Return to your own account to manage saved searches."
            return
        }
        threatSavedSearchStatus = "Loading saved searches"
        do {
            let list: ThreatSavedSearchList = try await requestJSON(tiBackendURL(path: "ti/saved-searches"), authenticated: true)
            threatSavedSearches = list.savedSearches
            threatSavedSearchStatus = list.savedSearches.isEmpty ? "No saved searches" : "Loaded \(list.savedSearches.count) saved searches"
        } catch { threatSavedSearchStatus = "Could not load saved searches: \(error.localizedDescription)" }
    }

    @discardableResult
    func searchThreatIntelligence(refresh: Bool = false, expectedScope: ThreatIntelligenceSearchScope? = nil) async -> Bool {
        let query = threatSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasHanasandAuth else { threatSearchStatus = "Sign in to search threat intelligence."; return false }
        guard (2...200).contains(query.count) else { threatSearchStatus = "Enter a search between 2 and 200 characters."; return false }
        let requestScope = threatIntelligenceSearchScope
        guard expectedScope == nil || expectedScope == requestScope else { return false }
        isLoadingThreatSearch = true
        threatSearchStatus = refresh ? "Refreshing threat intelligence" : "Searching threat intelligence"
        defer { if !Task.isCancelled { isLoadingThreatSearch = false } }
        do {
            var components = URLComponents(url: settings.websiteBaseURL.normalizedBaseURL.appendingAPIPath("api/ti/search"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "cached", value: refresh ? "false" : "true")]
            let result: ThreatIntelSearchResult = try await requestJSON(components?.url ?? settings.websiteBaseURL.normalizedBaseURL.appendingAPIPath("api/ti/search"), authenticated: true)
            guard !Task.isCancelled,
                  threatSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(query) == .orderedSame,
                  threatIntelligenceSearchScope == requestScope,
                  expectedScope == nil || expectedScope == threatIntelligenceSearchScope else { return false }
            guard result.query.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(query) == .orderedSame else {
                throw ThreatIntelClientError.invalidResponse
            }
            threatSearchResult = result
            threatSearchQuery = result.query
            threatSearchResultLimit = 20
            threatSearchStatus = result.status == "unavailable" ? "Threat intelligence is temporarily unavailable." : "Loaded \(result.query)"
            return true
        } catch {
            guard !Task.isCancelled,
                  threatSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(query) == .orderedSame,
                  threatIntelligenceSearchScope == requestScope else { return false }
            threatSearchStatus = "Could not search threat intelligence: \(error.localizedDescription)"
            return false
        }
    }

    func changeThreatSavedSearch(_ query: String, save: Bool) async {
        guard hasHanasandAuth, settings.impersonationToken.isEmpty, settings.impersonatingUserID.isEmpty else {
            threatSavedSearchStatus = "Return to your own account to manage saved searches."
            return
        }
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...200).contains(clean.count) else { threatSavedSearchStatus = "Enter a search between 2 and 200 characters."; return }
        guard !isMutatingThreatSavedSearch else { return }
        isMutatingThreatSavedSearch = true
        threatSavedSearchStatus = save ? "Saving search" : "Removing saved search"
        defer { isMutatingThreatSavedSearch = false }
        do {
            var components = URLComponents(url: tiBackendURL(path: "ti/saved-searches"), resolvingAgainstBaseURL: false)
            let method = save ? "POST" : "DELETE"
            let body = save ? try JSONEncoder().encode(ThreatSearchPayload(query: clean)) : nil
            if !save { components?.queryItems = [URLQueryItem(name: "query", value: clean)] }
            let receipt: ThreatSavedSearchReceipt = try await requestJSON(components?.url ?? tiBackendURL(path: "ti/saved-searches"), method: method, body: body, authenticated: true)
            guard save ? receipt.savedSearch?.query == clean : receipt.ok == true else { throw ThreatIntelClientError.unconfirmedMutation }
            await loadThreatSavedSearches()
        } catch { threatSavedSearchStatus = "Saved-search change needs review: \(error.localizedDescription). Refresh the list before trying again." }
    }

    func openThreatEvidence(_ url: URL?) {
        guard let url, url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else { return }
        openURL(url.absoluteString, label: "Threat evidence")
    }

    private func tiBackendURL(path: String) -> URL {
        let website = settings.websiteBaseURL.normalizedBaseURL
        let base = website.host?.lowercased() == "hanasand.com" ? URL(string: "https://ti.hanasand.com")! : website
        return base.appendingAPIPath("api/backend/\(path)")
    }
}

private enum ThreatIntelClientError: LocalizedError {
    case invalidResponse
    case unconfirmedMutation
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The threat-intelligence service returned a response for a different search."
        case .unconfirmedMutation: return "The saved-search change could not be confirmed."
        }
    }
}
