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

private struct MonitoringCaseUpdate: Encodable {
    var status: String?
    var severity: String?
    var notificationsEnabled: Bool?
    var comment: String?
    var confirmResolutionId: String?
}
private struct MonitoringCaseReceipt: Decodable { let ok: Bool }

private enum MonitoringCaseClientError: LocalizedError {
    case invalidResponse
    case accessChanged
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The cases service returned an invalid response."
        case .accessChanged: return "Case access or state changed. Refresh before making another change."
        }
    }
}

private enum MonitoringCaseMutationError: LocalizedError {
    case unconfirmed
    var errorDescription: String? { "The case change could not be confirmed. Refresh and review before trying again." }
}

extension DesktopAgentModel {
    var filteredMonitoringCases: [MonitoringCase] {
        monitoringCases.filter { item in
            let statusMatches = monitoringCaseStatusFilter == "all"
                || monitoringCaseStatusFilter == "active" && ["open", "in_progress"].contains(item.status)
                || item.status == monitoringCaseStatusFilter
            let severityMatches = monitoringCaseSeverityFilter == "all" || item.severity == monitoringCaseSeverityFilter
            let ownerMatches = monitoringCaseOwnerFilter == "all"
                || monitoringCaseOwnerFilter == "unassigned" && item.assignedOwner.isEmpty
                || item.assignedOwner == monitoringCaseOwnerFilter
            let resolutionMatches = monitoringCaseResolutionFilter == "all" || item.resolutionType == monitoringCaseResolutionFilter
            let reviewMatches = monitoringCaseReviewFilter == "all"
                || monitoringCaseReviewFilter == "pending" && item.needsHumanReview
                || monitoringCaseReviewFilter == "confirmed" && item.humanReviewed
            return statusMatches && severityMatches && ownerMatches && resolutionMatches && reviewMatches && item.contains(monitoringCaseSearch)
        }
    }

    func loadMonitoringCases() async {
        if let requestedOrganizationID = nativeMonitoringCaseContext?.organizationID,
           !requestedOrganizationID.isEmpty,
           requestedOrganizationID != settings.selectedOrganizationID {
            nativeDashboardStatus = "This case link belongs to a different organization. Switch to that organization, then open the link again."
            selectedMonitoringCase = nil
            return
        }
        if !selectedNativeDashboardDetailID.isEmpty,
           !isValidMonitoringCaseID(selectedNativeDashboardDetailID) {
            nativeDashboardStatus = "This case link has an invalid case ID."
            selectedMonitoringCase = nil
            return
        }
        guard hasHanasandAuth else {
            monitoringCases = []
            selectedMonitoringCase = nil
            nativeDashboardStatus = "Sign in to view monitoring cases."
            return
        }
        isLoadingNativeDashboard = true
        nativeDashboardStatus = "Loading monitoring cases"
        defer { isLoadingNativeDashboard = false }
        do {
            let url = monitoringCaseURL(path: "cases/monitoring", query: [URLQueryItem(name: "view", value: "summary")])
            let response: MonitoringCaseList = try await requestJSON(url, authenticated: true)
            monitoringCases = response.items
            if let current = selectedMonitoringCase, let refreshed = response.items.first(where: { $0.id == current.id }) {
                selectedMonitoringCase = refreshed
            } else if let current = selectedMonitoringCase, !response.items.contains(where: { $0.id == current.id }) {
                selectedMonitoringCase = nil
            }
            nativeDashboardStatus = response.items.isEmpty ? "No monitoring cases" : "Loaded \(response.items.count) monitoring cases"
            if !selectedNativeDashboardDetailID.isEmpty {
                await loadMonitoringCaseDetail(id: selectedNativeDashboardDetailID)
            } else if let selectedMonitoringCase {
                await loadMonitoringCaseDetail(id: selectedMonitoringCase.id)
            }
        } catch {
            nativeDashboardStatus = "Could not load monitoring cases: \(error.localizedDescription)"
        }
    }

    func loadMonitoringCaseDetail(id: String) async {
        guard isValidMonitoringCaseID(id) else {
            nativeDashboardStatus = "This case link has an invalid case ID."
            selectedMonitoringCase = nil
            return
        }
        guard hasHanasandAuth else {
            nativeDashboardStatus = "Sign in to view monitoring cases."
            selectedMonitoringCase = nil
            return
        }
        isLoadingNativeDashboard = true
        nativeDashboardStatus = "Loading case details"
        defer { isLoadingNativeDashboard = false }
        do {
            let url = monitoringCaseURL(path: "cases/monitoring/\(id)", query: [URLQueryItem(name: "eventsPage", value: "0")])
            let response: MonitoringCaseDetail = try await requestJSON(url, authenticated: true)
            guard response.case.id == id || response.case.id == id.replacingOccurrences(of: "MON-", with: "HA-") else {
                throw MonitoringCaseClientError.invalidResponse
            }
            selectedMonitoringCase = response.case
            nativeDashboardStatus = "Loaded case \(response.case.id)"
        } catch {
            nativeDashboardStatus = "Could not load case details: \(error.localizedDescription)"
        }
    }

    private func isValidMonitoringCaseID(_ id: String) -> Bool {
        id.range(of: "^(HA|MON)-[1-9][0-9]*$", options: .regularExpression) != nil
    }

    func loadMonitoringCaseEventPage(page: Int) async {
        guard let selected = selectedMonitoringCase, page >= 0, page <= 100_000,
              !selected.eventSnapshot.isEmpty, hasHanasandAuth else { return }
        isLoadingNativeDashboard = true
        nativeDashboardStatus = "Loading check run page"
        defer { isLoadingNativeDashboard = false }
        do {
            let url = monitoringCaseURL(path: "cases/monitoring/\(selected.id)", query: [
                URLQueryItem(name: "eventsPage", value: String(page)),
                URLQueryItem(name: "eventsAt", value: selected.eventSnapshot),
            ])
            let response: MonitoringCaseDetail = try await requestJSON(url, authenticated: true)
            guard response.case.id == selected.id, response.case.eventPage == page,
                  response.case.eventSnapshot == selected.eventSnapshot else {
                throw MonitoringCaseClientError.invalidResponse
            }
            selectedMonitoringCase = response.case
            nativeDashboardStatus = "Loaded check run page \(page + 1)"
        } catch {
            nativeDashboardStatus = "Could not load check run page: \(error.localizedDescription)"
        }
    }

    func updateMonitoringCase(status: String? = nil, severity: String? = nil, notificationsEnabled: Bool? = nil, comment: String? = nil, confirmResolutionId: String? = nil) async {
        guard hasHanasandAuth, settings.impersonationToken.isEmpty, settings.impersonatingUserID.isEmpty,
              let item = selectedMonitoringCase, item.canManage,
              status.map({ ["open", "in_progress", "resolved", "closed"].contains($0) }) ?? true,
              severity.map({ ["low", "medium", "high", "critical"].contains($0) }) ?? true,
              comment.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 5000 }) ?? true,
              confirmResolutionId.map({ !$0.isEmpty && status == nil && severity == nil && notificationsEnabled == nil && comment == nil }) ?? true,
              !["resolved", "closed"].contains(status ?? "") || comment?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            nativeDashboardStatus = "Refresh a manageable case and provide a resolution comment before making this change."
            return
        }
        let payload = MonitoringCaseUpdate(status: status, severity: severity, notificationsEnabled: notificationsEnabled, comment: comment?.trimmingCharacters(in: .whitespacesAndNewlines), confirmResolutionId: confirmResolutionId)
        do {
            isLoadingNativeDashboard = true
            nativeDashboardStatus = "Verifying current case access"
            let initialUserID = userIDForRequests
            let initialToken = authTokenForRequests
            let currentURL = monitoringCaseURL(path: "cases/monitoring/\(item.id)", query: [URLQueryItem(name: "eventsPage", value: "0")])
            let current: MonitoringCaseDetail = try await requestJSON(currentURL, authenticated: true)
            guard current.case.id == item.id, current.case.canManage,
                  selectedMonitoringCase?.id == item.id,
                  initialUserID == userIDForRequests, initialToken == authTokenForRequests,
                  settings.impersonationToken.isEmpty, settings.impersonatingUserID.isEmpty,
                  confirmResolutionId.map({ current.case.needsHumanReview && MonitoringCase.stringValue(current.case.resolution, key: "id") == $0 }) ?? true else {
                throw MonitoringCaseClientError.accessChanged
            }

            nativeDashboardStatus = "Saving case change"
            let body = try JSONEncoder().encode(payload)
            let url = monitoringCaseURL(path: "cases/monitoring/\(item.id)", query: [])
            let receipt: MonitoringCaseReceipt = try await requestJSON(url, method: "PATCH", body: body, authenticated: true)
            guard receipt.ok else { throw MonitoringCaseMutationError.unconfirmed }
            nativeDashboardStatus = "Saved case change"
            monitoringCaseComment = ""
            await loadMonitoringCases()
        } catch {
            nativeDashboardStatus = "\(error.localizedDescription)"
        }
        isLoadingNativeDashboard = false
    }

    private func monitoringCaseURL(path: String, query: [URLQueryItem]) -> URL {
        var components = URLComponents(url: settings.apiBaseURL.normalizedBaseURL.appendingAPIPath(path), resolvingAgainstBaseURL: false)
        components?.queryItems = query.isEmpty ? nil : query
        return components?.url ?? settings.apiBaseURL.normalizedBaseURL.appendingAPIPath(path)
    }
}
