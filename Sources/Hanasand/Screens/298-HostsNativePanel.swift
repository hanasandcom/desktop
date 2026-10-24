import SwiftUI
import Foundation

struct HostsNativePanel: View {
    @EnvironmentObject var model: DesktopAgentModel
    @Environment(\.desktopTheme) var theme
    @State private var consoleHost: HostOverviewEnvelope.Host?
    @State private var initialConsoleHostID: String?

    init(initialConsoleHostID: String? = nil) {
        _initialConsoleHostID = State(initialValue: initialConsoleHostID)
    }

    private let columns = [GridItem(.adaptive(minimum: 310), spacing: 12, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                SearchFieldRow(placeholder: "Search hosts by name, address, or system", text: $model.hostAccessSearch)
                ActionButton(title: "Refresh", icon: "arrow.clockwise") { Task { await model.loadHostOverview() } }
                ActionButton(title: "SSH keys", icon: "key.horizontal") { model.openNativeDashboard(path: "/profile", label: "Profile") }
            }

            if model.isLoadingHostOverview {
                ProgressView(model.hostOverviewStatus)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(theme.card, in: RoundedRectangle(cornerRadius: 12))
            } else if model.hostOverview == nil {
                NativeEmptyState(title: "Hosts unavailable", message: model.hostOverviewStatus)
            } else if model.hostOverview?.hosts.isEmpty == true {
                NativeEmptyState(title: "No hosts reported", message: "The host access service returned no servers.")
            } else if model.filteredHosts.isEmpty {
                NativeEmptyState(title: "No matching hosts", message: "Clear or adjust the search field.")
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(model.filteredHosts) { host in hostCard(host) }
                }
            }
            Text("Host access is read-only here. Manage your own SSH keys in Profile.")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
        }
        .sheet(item: $consoleHost) { host in
            HostConsoleView(host: host,
                            apiBaseURL: model.settings.apiBaseURL,
                            userID: model.userIDForRequests,
                            token: model.authTokenForRequests,
                            isImpersonating: !model.settings.impersonationToken.isEmpty || !model.settings.impersonatingUserID.isEmpty)
        }
        .task(id: model.hostOverview?.hosts.map { $0.id.rawValue }.joined(separator: ",") ?? "") {
            guard let initialConsoleHostID,
                  let host = model.hostOverview?.hosts.first(where: { $0.id.rawValue == initialConsoleHostID }) else { return }
            consoleHost = host
            self.initialConsoleHostID = nil
        }
    }

    private func hostCard(_ host: HostOverviewEnvelope.Host) -> some View {
        NativeGroupPanel(title: host.name, subtitle: host.id.rawValue.uppercased()) {
            HStack(spacing: 8) {
                ActionButton(title: "Console", icon: "terminal") { consoleHost = host }
                    .disabled(!hostConsoleMayOpen(
                        hasAuth: model.hasHanasandAuth,
                        isImpersonating: !model.settings.impersonationToken.isEmpty || !model.settings.impersonatingUserID.isEmpty,
                        userID: model.userIDForRequests,
                        token: model.authTokenForRequests
                    ))
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(statusColor(host.status)).frame(width: 8, height: 8)
                    Text(statusLabel(host.status))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(statusColor(host.status))
                    Spacer(minLength: 0)
                }
                Text("Address: \(host.address.isEmpty ? "Not reported" : host.address)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            metadata(label: "SSH user", value: host.username.isEmpty ? "Not reported" : host.username)
            metadata(label: "Hostname", value: host.hostname?.isEmpty == false ? host.hostname! : "Not reported")
            metadata(label: "Operating system", value: host.operatingSystem?.isEmpty == false ? host.operatingSystem! : "Not reported")

            Button {
                if model.expandedHostID == host.id.rawValue {
                    model.expandedHostID = ""
                } else {
                    model.expandedHostID = host.id.rawValue
                    model.hostUserSearch = ""
                    model.visibleHostUserLimit = 30
                }
            } label: {
                Label(model.expandedHostID == host.id.rawValue ? "Hide SSH access" : "Review SSH access", systemImage: "key.horizontal")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.bordered)

            if model.expandedHostID == host.id.rawValue {
                Divider().overlay(theme.divider)
                Text("Users with SSH keys")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text)
                SearchFieldRow(placeholder: "Find by name or username", text: $model.hostUserSearch)
                let users = model.filteredHostUsers
                if users.isEmpty {
                    NativeEmptyState(title: model.hostUserSearch.isEmpty ? "No SSH keys reported" : "No matching users", message: model.hostUserSearch.isEmpty ? "The service did not report any recognized SSH keys." : "Try another name or username.")
                } else {
                    ForEach(users.prefix(model.visibleHostUserLimit)) { user in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(user.name) · @\(user.username)")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(theme.text)
                                if user.id == model.userIDForRequests {
                                    Text("This account")
                                        .font(.system(size: 11))
                                        .foregroundStyle(theme.textSecondary)
                                }
                            }
                            Spacer()
                            Text(user.keyCount.map { "\($0) \($0 == 1 ? "key" : "keys")" } ?? "Key count not reported")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                    if users.count > model.visibleHostUserLimit {
                        ActionButton(title: "Show 30 more", icon: "plus") { model.visibleHostUserLimit += 30 }
                    }
                }
            }
        }
    }

    private func metadata(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(theme.textSecondary)
            Spacer()
            Text(value).foregroundStyle(theme.text)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.system(size: 12))
    }

    private func statusLabel(_ status: HostAvailability) -> String {
        switch status { case .online: "Online"; case .offline: "Offline"; case .unknown: "Status not reported" }
    }

    private func statusColor(_ status: HostAvailability) -> Color {
        switch status { case .online: theme.green; case .offline: theme.danger; case .unknown: theme.textSecondary }
    }
}

struct HostUpdatesNativePanel: View {
    @EnvironmentObject var model: DesktopAgentModel
    @Environment(\.desktopTheme) var theme

    private let columns = [GridItem(.adaptive(minimum: 210), spacing: 10, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Picker("Host", selection: $model.selectedHostUpdatesHost) {
                    ForEach(HostUpdateTarget.allCases) { host in Text(host.title).tag(host) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                .onChange(of: model.selectedHostUpdatesHost) { _, host in Task { await model.loadHostUpdateStatus(for: host) } }
                ActionButton(title: "Refresh", icon: "arrow.clockwise") { Task { await model.loadHostUpdateStatus(for: model.selectedHostUpdatesHost) } }
            }

            if model.isLoadingHostUpdates {
                ProgressView(model.hostUpdatesStatus)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(theme.card, in: RoundedRectangle(cornerRadius: 12))
            } else if let data = model.hostUpdates {
                updateOverview(data)
                updateContents(data)
            } else {
                NativeEmptyState(title: "Update status unavailable", message: model.hostUpdatesStatus)
            }
            Text("Updates install automatically on the server. This view reports status and history; it does not install or restart packages.")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
        }
    }

    private func updateOverview(_ data: HostUpdateEnvelope) -> some View {
        let status = data.status
        let pending = status.pending
        let securityCount = pending.filter(\.security).count
        let label = status.status == "unknown" ? "Waiting for host check-in" : status.status.capitalized
        return VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                FeatureCard(title: "Update check", value: label, icon: status.status == "failed" ? "exclamationmark.triangle" : "arrow.down.circle")
                FeatureCard(title: "Pending", value: status.status == "unknown" ? "Not reported" : "\(pending.count) packages", icon: "shippingbox")
                FeatureCard(title: "Security", value: status.status == "unknown" ? "Not reported" : "\(securityCount) packages", icon: "shield")
            }
            NativeGroupPanel(title: "\(model.selectedHostUpdatesHost.title) · Ubuntu", subtitle: "Automatic update status") {
                metadata(label: "Checked", value: formatDate(status.checkedAt))
                metadata(label: "Last installed", value: formatDate(status.lastUpdateAt))
                metadata(label: "Updated packages", value: status.lastUpdatedPackages.isEmpty ? "None reported" : status.lastUpdatedPackages.joined(separator: ", "))
                metadata(label: "Policy", value: status.policy?.nonSecurityDelayHours.map { "Security updates immediately; other updates after \($0) hours." } ?? "Not reported")
                metadata(label: "Verification", value: status.policy?.repositoryVerification ?? "Not reported")
                if let error = status.lastError, !error.isEmpty {
                    Text(error).font(.system(size: 12)).foregroundStyle(theme.danger)
                }
            }
        }
    }

    @ViewBuilder private func updateContents(_ data: HostUpdateEnvelope) -> some View {
        HStack(spacing: 8) {
            ForEach(HostUpdateView.allCases) { view in
                Button("\(view.title) · \(count(for: view, data: data))") {
                    model.selectedHostUpdatesView = view
                    model.hostUpdatesSearch = ""
                    model.visibleHostUpdateLimit = 30
                }
                .buttonStyle(.borderedProminent)
                .tint(model.selectedHostUpdatesView == view ? theme.accent : theme.card)
            }
        }

        NativeGroupPanel(title: model.selectedHostUpdatesView.title, subtitle: "Status reported by the host") {
            SearchFieldRow(placeholder: "Filter packages or status", text: $model.hostUpdatesSearch)
            switch model.selectedHostUpdatesView {
            case .pending:
                let items = model.filteredHostUpdatePackages
                if items.isEmpty { emptyResult(label: "pending packages") }
                ForEach(items.prefix(model.visibleHostUpdateLimit)) { item in packageRow(item, delay: data.status.policy?.nonSecurityDelayHours) }
                if items.count > model.visibleHostUpdateLimit { showMore }
            case .installed:
                let items = model.filteredHostInstalledPackages
                if items.isEmpty { emptyResult(label: "installed packages") }
                ForEach(items.prefix(model.visibleHostUpdateLimit)) { item in
                    HStack { Text(item.name).fontWeight(.semibold); Spacer(); Text(item.version.isEmpty ? "Version not reported" : item.version).foregroundStyle(theme.textSecondary) }
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
                if items.count > model.visibleHostUpdateLimit { showMore }
            case .history:
                let items = model.filteredHostUpdateHistory
                if items.isEmpty { emptyResult(label: "update history") }
                ForEach(items.prefix(model.visibleHostUpdateLimit)) { item in historyRow(item) }
                if items.count > model.visibleHostUpdateLimit { showMore }
            }
        }
    }

    private func packageRow(_ item: HostUpdateEnvelope.Status.Package, delay: Int?) -> some View {
        let age = hostUpdateAgeHours(firstSeen: item.reportedAt, delayHours: delay)
        let timing = item.security ? "Security · immediate policy" : age.map { $0 >= (delay ?? 0) ? "Ready under reported policy" : "\($0) of \(delay ?? 0) hours elapsed" } ?? "Waiting for reported timing"
        return VStack(alignment: .leading, spacing: 4) {
            HStack { Text(item.name).fontWeight(.semibold); Spacer(); Text(item.security ? "Security" : "Regular").foregroundStyle(item.security ? theme.danger : theme.textSecondary) }
            Text(item.version.isEmpty ? "Version not reported" : item.version).foregroundStyle(theme.textSecondary)
            Text(timing).foregroundStyle(theme.textSecondary)
            if !item.repository.isEmpty || !item.origin.isEmpty { Text([item.repository, item.origin].filter { !$0.isEmpty }.joined(separator: " · ")).foregroundStyle(theme.textSecondary) }
        }
        .font(.system(size: 12, design: .monospaced))
        .textSelection(.enabled)
    }

    private func historyRow(_ item: HostUpdateEnvelope.HistoryEntry) -> some View {
        let text = item.error?.isEmpty == false ? (item.error ?? "Update failed") : item.status.capitalized
        return VStack(alignment: .leading, spacing: 4) {
            HStack { Text(item.isToday ? "Today" : formatDate(item.occurredAt)).foregroundStyle(theme.textSecondary); Spacer(); Text(text).fontWeight(.semibold).foregroundStyle(item.status == "failed" || item.error?.isEmpty == false ? theme.danger : theme.text) }
            Text(item.packages.isEmpty ? (item.isToday ? "Nothing installed yet." : "No packages installed.") : item.packages.joined(separator: ", "))
                .font(.system(size: 12)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
        }
    }

    private var showMore: some View {
        ActionButton(title: "Show 30 more", icon: "plus") { model.visibleHostUpdateLimit += 30 }
    }

    private func emptyResult(label: String) -> some View {
        NativeEmptyState(title: "No matching \(label)", message: model.hostUpdatesSearch.isEmpty ? "The host did not report any \(label)." : "Try a different search.")
    }

    private func count(for view: HostUpdateView, data: HostUpdateEnvelope) -> Int {
        switch view { case .pending: data.status.pending.count; case .history: data.history.count; case .installed: data.status.installed.count }
    }

    private func metadata(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(theme.textSecondary)
            Spacer()
            Text(value).foregroundStyle(theme.text).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.system(size: 12))
    }

    private func formatDate(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "Not reported" }
        if let date = ISO8601DateFormatter().date(from: value) { return date.formatted(date: .abbreviated, time: .shortened) }
        if let seconds = Double(value) { return Date(timeIntervalSince1970: seconds).formatted(date: .abbreviated, time: .shortened) }
        return value
    }
}
