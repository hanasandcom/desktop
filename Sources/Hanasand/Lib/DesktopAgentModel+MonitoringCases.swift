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
    var resolutionMethod: String?
    var confirmResolutionId: String?
}
private struct MonitoringCaseReceipt: Decodable { let ok: Bool }

private enum MonitoringCaseClientError: LocalizedError, Equatable {
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

enum MonitoringCaseMutationOutcome {
    static func needsReview(for error: Error, requestDispatched: Bool) -> Bool {
        guard requestDispatched else { return false }
        if error is DecodingError || error is URLError || error is MonitoringCaseMutationError { return true }
        if case DashboardRequestError.httpStatus(let status) = error { return status == 408 || status >= 500 }
        return false
    }
}

extension DesktopAgentModel {
    var filteredMonitoringCases: [MonitoringCase] {
        monitoringCases.filter { item in
            let active = !["resolved", "closed", "suppressed", "false_positive"].contains(item.status)
            let statusMatches = monitoringCaseStatusFilter == "all"
                || monitoringCaseStatusFilter == "active" && active
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

    @discardableResult
    func loadMonitoringCases() async -> Bool {
        if let requestedOrganizationID = nativeCaseHandoffContext?.organizationID,
           !requestedOrganizationID.isEmpty,
           requestedOrganizationID != settings.selectedOrganizationID {
            guard await selectOrganizationFromDeepLink(requestedOrganizationID) else {
                nativeDashboardStatus = organizationDirectoryError ?? "This case link belongs to a different organization, and its membership could not be verified."
                selectedMonitoringCase = nil
                return false
            }
        }
        if !selectedNativeDashboardDetailID.isEmpty,
           !isValidMonitoringCaseID(selectedNativeDashboardDetailID) {
            nativeDashboardStatus = "This case link has an invalid case ID."
            selectedMonitoringCase = nil
            return false
        }
        guard hasHanasandAuth else {
            monitoringCases = []
            selectedMonitoringCase = nil
            nativeDashboardStatus = "Sign in to view monitoring cases."
            return false
        }
        isLoadingNativeDashboard = true
        nativeDashboardStatus = "Loading monitoring cases"
        defer { isLoadingNativeDashboard = false }
        let organizationAtRequest = settings.selectedOrganizationID
        do {
            let url = monitoringCaseURL(path: "cases/monitoring", query: [URLQueryItem(name: "view", value: "summary")])
            let response: MonitoringCaseList = try await requestJSON(url, authenticated: true)
            guard settings.selectedOrganizationID == organizationAtRequest,
                  response.items.allSatisfy({ MonitoringCase.matchesOrganizationScope(organizationId: $0.organizationId, selectedOrganizationID: organizationAtRequest) }) else {
                throw MonitoringCaseClientError.accessChanged
            }
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
            return nativeDashboardStatus.hasPrefix("Loaded") || nativeDashboardStatus == "No monitoring cases"
        } catch {
            if error as? MonitoringCaseClientError == .accessChanged {
                monitoringCases = []
                selectedMonitoringCase = nil
            }
            nativeDashboardStatus = "Could not load monitoring cases: \(error.localizedDescription)"
            return false
        }
    }

    func refreshMonitoringCasesForReview() async {
        guard monitoringCaseMutationNeedsReview else {
            _ = await loadMonitoringCases()
            return
        }
        monitoringCaseMutationReviewRefreshed = false
        guard await loadMonitoringCases() else { return }
        monitoringCaseMutationReviewRefreshed = true
        nativeDashboardStatus = "Current case records are refreshed. Review the case history before acknowledging the earlier change."
    }

    func acknowledgeMonitoringCaseMutationReview() {
        guard monitoringCaseMutationNeedsReview, monitoringCaseMutationReviewRefreshed else { return }
        monitoringCaseMutationNeedsReview = false
        monitoringCaseMutationReviewRefreshed = false
        nativeDashboardStatus = "Review acknowledged. The earlier case change remains unconfirmed."
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
        let organizationAtRequest = settings.selectedOrganizationID
        do {
            let url = monitoringCaseURL(path: "cases/monitoring/\(id)", query: [URLQueryItem(name: "eventsPage", value: "0")])
            let response: MonitoringCaseDetail = try await requestJSON(url, authenticated: true)
            guard response.case.id == id || response.case.id == id.replacingOccurrences(of: "MON-", with: "HA-") else {
                throw MonitoringCaseClientError.invalidResponse
            }
            guard settings.selectedOrganizationID == organizationAtRequest,
                  MonitoringCase.matchesOrganizationScope(organizationId: response.case.organizationId, selectedOrganizationID: organizationAtRequest) else {
                throw MonitoringCaseClientError.accessChanged
            }
            selectedMonitoringCase = response.case
            nativeDashboardStatus = "Loaded case \(response.case.id)"
        } catch {
            if error as? MonitoringCaseClientError == .accessChanged {
                selectedMonitoringCase = nil
            }
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
        let organizationAtRequest = settings.selectedOrganizationID
        do {
            let url = monitoringCaseURL(path: "cases/monitoring/\(selected.id)", query: [
                URLQueryItem(name: "eventsPage", value: String(page)),
                URLQueryItem(name: "eventsAt", value: selected.eventSnapshot),
            ])
            let response: MonitoringCaseDetail = try await requestJSON(url, authenticated: true)
            guard settings.selectedOrganizationID == organizationAtRequest,
                  MonitoringCase.matchesOrganizationScope(organizationId: response.case.organizationId, selectedOrganizationID: organizationAtRequest) else {
                throw MonitoringCaseClientError.accessChanged
            }
            guard response.case.id == selected.id,
                  response.case.eventPage == page,
                  response.case.eventSnapshot == selected.eventSnapshot else {
                throw MonitoringCaseClientError.invalidResponse
            }
            selectedMonitoringCase = response.case
            nativeDashboardStatus = "Loaded check run page \(page + 1)"
        } catch {
            if error as? MonitoringCaseClientError == .accessChanged {
                monitoringCases = []
                selectedMonitoringCase = nil
            }
            nativeDashboardStatus = "Could not load check run page: \(error.localizedDescription)"
        }
    }

    func updateMonitoringCase(status: String? = nil, severity: String? = nil, notificationsEnabled: Bool? = nil, comment: String? = nil, resolutionMethod: String? = nil, confirmResolutionId: String? = nil) async {
        guard !monitoringCaseMutationNeedsReview else {
            nativeDashboardStatus = "Refresh case records and review the previous change before making another change."
            return
        }
        guard hasHanasandAuth, settings.impersonationToken.isEmpty, settings.impersonatingUserID.isEmpty,
              let item = selectedMonitoringCase, item.canManage,
              status.map({ ["open", "in_progress", "resolved", "closed"].contains($0) }) ?? true,
              severity.map({ ["low", "medium", "high", "critical"].contains($0) }) ?? true,
              MonitoringCaseResolutionPolicy.allowsResolutionMethod(resolutionMethod, status: status),
              comment.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 5000 }) ?? true,
              confirmResolutionId.map({ !$0.isEmpty && status == nil && severity == nil && notificationsEnabled == nil && comment == nil && resolutionMethod == nil }) ?? true,
              !["resolved", "closed"].contains(status ?? "") || comment?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            nativeDashboardStatus = "Refresh a manageable case and provide a resolution comment before making this change."
            return
        }
        let payload = MonitoringCaseUpdate(status: status, severity: severity, notificationsEnabled: notificationsEnabled, comment: comment?.trimmingCharacters(in: .whitespacesAndNewlines), resolutionMethod: resolutionMethod, confirmResolutionId: confirmResolutionId)
        var mutationDispatched = false
        do {
            isLoadingNativeDashboard = true
            nativeDashboardStatus = "Verifying current case access"
            let initialUserID = userIDForRequests
            let initialToken = authTokenForRequests
            let initialOrganizationID = settings.selectedOrganizationID
            let currentURL = monitoringCaseURL(path: "cases/monitoring/\(item.id)", query: [URLQueryItem(name: "eventsPage", value: "0")])
            let current: MonitoringCaseDetail = try await requestJSON(currentURL, authenticated: true)
            guard current.case.id == item.id, current.case.canManage,
                  MonitoringCase.matchesOrganizationScope(organizationId: current.case.organizationId, selectedOrganizationID: initialOrganizationID),
                  selectedMonitoringCase?.id == item.id,
                  initialUserID == userIDForRequests, initialToken == authTokenForRequests,
                  initialOrganizationID == settings.selectedOrganizationID,
                  settings.impersonationToken.isEmpty, settings.impersonatingUserID.isEmpty,
                  confirmResolutionId.map({ current.case.needsHumanReview && MonitoringCase.stringValue(current.case.resolution, key: "id") == $0 }) ?? true else {
                throw MonitoringCaseClientError.accessChanged
            }

            nativeDashboardStatus = "Saving case change"
            let body = try JSONEncoder().encode(payload)
            let url = monitoringCaseURL(path: "cases/monitoring/\(item.id)", query: [])
            mutationDispatched = true
            let receipt: MonitoringCaseReceipt = try await requestJSON(url, method: "PATCH", body: body, authenticated: true)
            guard receipt.ok else { throw MonitoringCaseMutationError.unconfirmed }
            nativeDashboardStatus = "Saved case change"
            monitoringCaseComment = ""
            await loadMonitoringCases()
        } catch {
            if MonitoringCaseMutationOutcome.needsReview(for: error, requestDispatched: mutationDispatched) {
                monitoringCaseMutationNeedsReview = true
                monitoringCaseMutationReviewRefreshed = false
            }
            nativeDashboardStatus = "\(error.localizedDescription)"
        }
        isLoadingNativeDashboard = false
    }

    private func monitoringCaseURL(path: String, query: [URLQueryItem]) -> URL {
        var components = URLComponents(url: settings.apiBaseURL.normalizedBaseURL.appendingAPIPath(path), resolvingAgainstBaseURL: false)
        let scopedQuery = query + MonitoringCaseNativeRoute.organizationQuery(selectedOrganizationID: settings.selectedOrganizationID)
        components?.queryItems = scopedQuery.isEmpty ? nil : scopedQuery
        return components?.url ?? settings.apiBaseURL.normalizedBaseURL.appendingAPIPath(path)
    }
}
