import SwiftUI

struct NativeDomainMonitorPanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var snapshot: NativeDomainMonitorSnapshot?
    @State private var query = ""
    @State private var sort = MonitorSort.customer
    @State private var isLoading = false
    @State private var error = ""

    private var filteredRows: [NativeDomainMonitorRow] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rows = (snapshot?.rows ?? []).filter { row in
            term.isEmpty || [row.customer ?? "", row.domain, row.status ?? "", row.matchedTerms.joined(separator: " "), row.sources?.joined(separator: " ") ?? ""]
                .joined(separator: " ").lowercased().contains(term)
        }
        switch sort {
        case .customer: return rows.sorted { ($0.customer ?? "").localizedCaseInsensitiveCompare($1.customer ?? "") == .orderedAscending }
        case .domain: return rows.sorted { $0.domain.localizedCaseInsensitiveCompare($1.domain) == .orderedAscending }
        case .monitored: return rows.sorted { dateValue($0.monitoredSince) < dateValue($1.monitoredSince) }
        case .breaches: return rows.sorted { ($0.breachMentions ?? -1) > ($1.breachMentions ?? -1) }
        }
    }

    private var breachSummary: String {
        guard let snapshot, snapshot.captures.available else { return "Unavailable" }
        return number(snapshot.totalBreachMentions)
    }

    private var requestSummary: String {
        guard let snapshot, snapshot.trafficSummary.available else { return "Unavailable" }
        return number(snapshot.totalRequestsToday)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                NativeGroupPanel(title: "Monitored domains", subtitle: "Customer domains, threat intelligence mentions, and traffic activity.") {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(filteredRows.count) of \(snapshot?.rows.count ?? 0) domains shown")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                            Text("\(breachSummary) breach mentions · \(requestSummary) requests today")
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
                        }
                        Spacer(minLength: 0)
                        ActionButton(title: isLoading ? "Loading…" : "Refresh", icon: "arrow.clockwise") {
                            Task { await load() }
                        }.disabled(isLoading)
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            SearchFieldRow(placeholder: "Customer, domain, status, source", text: $query)
                            sortPicker
                            clearButton
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            SearchFieldRow(placeholder: "Customer, domain, status, source", text: $query)
                            HStack(spacing: 8) { sortPicker; clearButton; Spacer(minLength: 0) }
                        }
                    }

                    if let snapshot {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach([snapshot.trafficSummary, snapshot.trafficMetrics, snapshot.captures, snapshot.sourceOperations], id: \.title) { resource in
                                HStack(alignment: .firstTextBaseline, spacing: 7) {
                                    Image(systemName: resource.available ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(resource.available ? theme.green : theme.danger)
                                    Text("\(resource.title): \(resource.detail)")
                                        .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textSecondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    if !error.isEmpty { NativeNotice(message: error, title: "Monitor unavailable") }
                }

                if isLoading && snapshot == nil {
                    NativeEmptyState(title: "Loading monitored domains", message: "Retrieving traffic and threat intelligence domain data.")
                } else if let snapshot, filteredRows.isEmpty {
                    NativeEmptyState(
                        title: snapshot.rows.isEmpty ? "No monitored domains loaded" : "No monitored domains match",
                        message: snapshot.rows.isEmpty
                            ? "The available traffic summary and threat intelligence capture sources returned no domain rows. Check the source status above for unavailable data."
                            : "Clear the search or use a broader customer or domain term."
                    )
                } else if snapshot == nil && !isLoading {
                    NativeEmptyState(title: "Monitor data unavailable", message: error.isEmpty ? "Refresh to load current monitored domains." : error)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 520), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(filteredRows) { row in domainCard(row) }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { if snapshot == nil { await load() } }
        .onChange(of: workspaceKey) { _, _ in
            snapshot = nil
            error = ""
            Task { await load() }
        }
    }

    private var workspaceKey: String {
        [model.settings.websiteBaseURL, model.settings.cdnBaseURL, model.settings.selectedOrganizationID, model.userIDForRequests,
         model.hasHanasandAuth ? "signed-in" : "signed-out"].joined(separator: "|")
    }

    private var sortPicker: some View {
        Picker("Sort", selection: $sort) {
            ForEach(MonitorSort.allCases) { option in Text(option.title).tag(option) }
        }
        .pickerStyle(.menu)
        .frame(minWidth: 140, maxWidth: 190)
    }

    private var clearButton: some View {
        ActionButton(title: "Clear", icon: "line.3.horizontal.decrease.circle") { query = "" }
            .disabled(query.isEmpty)
    }

    private func domainCard(_ row: NativeDomainMonitorRow) -> some View {
        NativeGroupPanel(title: row.domain, subtitle: "Monitored domain") {
            HStack(spacing: 7) {
                Text(row.status ?? "Status unavailable")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(row.status == nil ? theme.danger : theme.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(theme.card, in: Capsule())
                if let since = row.monitoredSince {
                    Text("Monitored \(age(since))")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary)
                } else if snapshot?.captures.available == false {
                    Text("Monitoring age unavailable").font(.system(size: 10, weight: .medium)).foregroundStyle(theme.danger)
                } else {
                    Text("Traffic only").font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary)
                }
                Spacer(minLength: 0)
            }

            LazyVGrid(columns: [GridItem(.flexible(minimum: 100), alignment: .leading), GridItem(.flexible(minimum: 100), alignment: .leading)], alignment: .leading, spacing: 9) {
                metric("Customer", row.customer ?? "Unavailable")
                metric("Breach mentions (capture count)", row.breachMentions.map(number) ?? "Unavailable")
                metric("Last seen", row.lastSeenAt.map(dateLabel) ?? (snapshot?.captures.available == false ? "Unavailable" : "Not recorded"))
                metric("Requests today", row.requestsToday.map(number) ?? "Unavailable")
                metric("Requests this week", row.requestsThisWeek.map(number) ?? "Unavailable")
                metric("Requests this month", row.requestsThisMonth.map(number) ?? "Unavailable")
                metric("Requests total", row.requestsTotal.map(number) ?? "Unavailable")
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Matched terms (domain match)").font(.system(size: 9, weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.textTertiary)
                Text(row.matchedTerms.joined(separator: ", ")).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.text).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Sources").font(.system(size: 9, weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.textTertiary).padding(.top, 4)
                Text(sourceDescription(row))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(row.sources == nil ? theme.danger : theme.textSecondary)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 9, weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.textTertiary)
            Text(value).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text).lineLimit(2).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceDescription(_ row: NativeDomainMonitorRow) -> String {
        guard let sources = row.sources else { return "Unavailable: source-name access failed." }
        if !sources.isEmpty { return sources.joined(separator: ", ") }
        if (row.breachMentions ?? 0) > 0 { return "Source names are not present in the loaded source page." }
        return "Traffic monitor"
    }

    @MainActor private func load() async {
        guard !isLoading else { return }
        isLoading = true
        error = ""
        defer { isLoading = false }
        let requestedScope = workspaceKey
        let client = NativeDomainMonitorClient(settings: model.settings)
        let result = await client.loadSnapshot()
        guard requestedScope == workspaceKey else { return }
        snapshot = result
        if snapshot?.rows.isEmpty == true,
           [snapshot?.trafficSummary.available, snapshot?.trafficMetrics.available, snapshot?.captures.available].allSatisfy({ $0 == false }) {
            error = "Traffic summary, traffic metrics, and threat intelligence captures are unavailable. Review the endpoint results above and retry."
        }
    }

    private func number(_ value: Int?) -> String { value.map(number) ?? "0" }
    private func number(_ value: Int) -> String { value.formatted() }

    private func dateValue(_ value: String?) -> Date {
        guard let value else { return .distantPast }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }() ?? .distantPast
    }

    private func dateLabel(_ value: String) -> String {
        guard dateValue(value) != .distantPast else { return value }
        let date = dateValue(value)
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func age(_ value: String) -> String {
        let days = max(1, Calendar.current.dateComponents([.day], from: dateValue(value), to: .now).day ?? 1)
        return "\(days)d"
    }
}

private enum MonitorSort: String, CaseIterable, Identifiable {
    case customer, domain, monitored, breaches
    var id: String { rawValue }
    var title: String {
        switch self {
        case .customer: "Customer A–Z"
        case .domain: "Domain A–Z"
        case .monitored: "Time monitored"
        case .breaches: "Breach mentions"
        }
    }
}
