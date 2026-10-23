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
    var filteredHosts: [HostOverviewEnvelope.Host] {
        guard let hosts = hostOverview?.hosts else { return [] }
        let query = hostAccessSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return hosts }
        return hosts.filter { "\($0.name) \($0.id.rawValue) \($0.address) \($0.username) \($0.hostname ?? "") \($0.operatingSystem ?? "")".lowercased().contains(query) }
    }

    var filteredHostUsers: [HostOverviewEnvelope.AccessUser] {
        guard let users = hostOverview?.users else { return [] }
        let terms = hostUserSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().split(whereSeparator: \.isWhitespace)
        return users.filter { user in
            terms.allSatisfy { "\(user.name) \(user.username)".lowercased().contains($0) }
        }
    }

    var filteredHostUpdatePackages: [HostUpdateEnvelope.Status.Package] {
        guard let packages = hostUpdates?.status.pending else { return [] }
        let query = hostUpdatesSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return packages }
        return packages.filter { "\($0.name) \($0.version) \($0.repository) \($0.origin) \($0.security ? "security" : "regular")".lowercased().contains(query) }
    }

    var filteredHostUpdateHistory: [HostUpdateEnvelope.HistoryEntry] {
        guard let history = hostUpdates?.history else { return [] }
        let query = hostUpdatesSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return history }
        return history.filter { "\($0.status) \($0.packages.joined(separator: " ")) \($0.error ?? "")".lowercased().contains(query) }
    }

    var filteredHostInstalledPackages: [HostUpdateEnvelope.Status.InstalledPackage] {
        guard let installed = hostUpdates?.status.installed else { return [] }
        let query = hostUpdatesSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return installed }
        return installed.filter { "\($0.name) \($0.version)".lowercased().contains(query) }
    }

    func loadHostOverview() async {
        let loadID = UUID()
        hostOverviewLoadID = loadID
        hostOverview = nil
        hostAccessSearch = ""
        hostUserSearch = ""
        visibleHostUserLimit = 30
        expandedHostID = ""
        guard hostOverviewMayLoad(hasAuth: hasHanasandAuth,
                                  isImpersonating: !settings.impersonationToken.isEmpty || !settings.impersonatingUserID.isEmpty) else {
            isLoadingHostOverview = false
            hostOverviewStatus = hasHanasandAuth ? "Return to your own account to review host access." : "Sign in to review host access."
            return
        }

        isLoadingHostOverview = true
        hostOverviewStatus = "Loading hosts and SSH access"
        defer { if hostOverviewLoadID == loadID { isLoadingHostOverview = false } }
        do {
            let envelope: HostOverviewEnvelope = try await requestJSON(
                settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("host-overview"), authenticated: true
            )
            guard !Task.isCancelled, hostOverviewLoadID == loadID, selectedDashboardPath == "/system/hosts" else { return }
            hostOverview = envelope
            hostOverviewStatus = envelope.hosts.isEmpty ? "No hosts were reported." : "Loaded \(envelope.hosts.count) hosts and \(envelope.users.count) SSH access users."
        } catch {
            guard !Task.isCancelled, hostOverviewLoadID == loadID else { return }
            hostOverview = nil
            hostOverviewStatus = "Could not load hosts: \(error.localizedDescription)"
        }
    }

    func loadHostUpdateStatus(for host: HostUpdateTarget) async {
        let loadID = UUID()
        hostUpdatesLoadID = loadID
        selectedHostUpdatesHost = host
        hostUpdates = nil
        hostUpdatesSearch = ""
        visibleHostUpdateLimit = 30
        guard hasHanasandAuth else {
            isLoadingHostUpdates = false
            hostUpdatesStatus = "Sign in to review automatic host updates."
            return
        }

        isLoadingHostUpdates = true
        hostUpdatesStatus = "Loading \(host.title) update status"
        defer { if hostUpdatesLoadID == loadID { isLoadingHostUpdates = false } }
        do {
            let url = URLComponents(url: settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("system/updates"), resolvingAgainstBaseURL: false)
                .map { components -> URL in
                    var value = components
                    value.queryItems = [URLQueryItem(name: "host", value: host.rawValue)]
                    return value.url ?? settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("system/updates")
                } ?? settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("system/updates")
            let envelope: HostUpdateEnvelope = try await requestJSON(url, authenticated: true)
            guard !Task.isCancelled, hostUpdatesLoadID == loadID, selectedDashboardPath == "/system/updates", selectedHostUpdatesHost == host, envelope.host == host else { return }
            hostUpdates = envelope
            hostUpdatesStatus = envelope.status.status == "unknown" ? "Waiting for \(host.title) to report." : "Loaded \(host.title) update status and \(envelope.history.count) history entries."
        } catch {
            guard !Task.isCancelled, hostUpdatesLoadID == loadID else { return }
            hostUpdates = nil
            hostUpdatesStatus = "Could not load \(host.title) updates: \(error.localizedDescription)"
        }
    }
}
