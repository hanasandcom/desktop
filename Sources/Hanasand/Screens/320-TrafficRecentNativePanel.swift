import SwiftUI

struct TrafficRecentNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var domains: [String] = []
    @State private var selectedDomain = ""
    @State private var records: [TrafficRecentRecord] = []
    @State private var total = 0
    @State private var page = 1
    @State private var query = ""
    @State private var selectedMethod = "All methods"
    @State private var statusPrefix = "All statuses"
    @State private var expandedRecordID: String?
    @State private var status = "Recent traffic has not been loaded."
    @State private var lastUpdatedAt: Date?
    @State private var isLoading = false
    @State private var requestGeneration = UUID()

    private let pageSize = TrafficRecentClient.pageSize

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], alignment: .leading, spacing: 12) {
                FeatureCard(title: "Retained requests", value: total.formatted(), icon: "arrow.left.arrow.right")
                FeatureCard(title: "Loaded", value: "\(records.count)", icon: "doc.text.magnifyingglass")
                FeatureCard(title: "Domains", value: "\(domains.count)", icon: "globe")
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    SearchFieldRow(placeholder: "Search domain, path, or user agent", text: $query)
                    refreshButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    SearchFieldRow(placeholder: "Search domain, path, or user agent", text: $query)
                    HStack { Spacer(minLength: 0); refreshButton }
                }
            }

            ViewThatFits(in: .horizontal) {
                filterControls
                stackedFilterControls
            }

            Label("Search, method, and status filters apply to this loaded page only. Domain filtering is applied by the Traffic API.", systemImage: "info.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Text(status)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(status.hasPrefix("Could not") || status.contains("unavailable") ? theme.danger : theme.textSecondary)
                .textSelection(.enabled)

            Text(refreshStatus)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if isLoading && records.isEmpty {
                NativeEmptyState(title: "Loading recent requests", message: "Fetching the latest traffic records.")
            } else if filteredRecords.isEmpty {
                NativeEmptyState(
                    title: records.isEmpty && status.hasPrefix("Could not") ? "Recent traffic unavailable" : (records.isEmpty ? "No traffic records loaded" : "No matching requests"),
                    message: records.isEmpty && status.hasPrefix("Could not") ? "\(status) Refresh to try again." : (records.isEmpty ? "Refresh to load recent requests from the Traffic API." : "Change the search or filters to see matching requests.")
                )
            } else {
                LazyVStack(alignment: .leading, spacing: 9) {
                    ForEach(filteredRecords) { record in
                        recordRow(record)
                    }
                }
            }

            ViewThatFits(in: .horizontal) {
                paginationControls
                VStack(alignment: .leading, spacing: 8) {
                    Text("Page \(page) · \(total.formatted()) retained requests")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    HStack { Spacer(minLength: 0); previousPageButton; nextPageButton }
                }
            }
        }
        .task {
            await load()
            await refreshWhileVisible()
        }
        .onAppear {
            if selectedDomain.isEmpty, let initial = model.selectedNativeDashboardQuery["domain"], !initial.isEmpty {
                selectedDomain = initial
            }
        }
        .onDisappear { requestGeneration = UUID() }
    }

    private var refreshButton: some View {
        Button {
            page = 1
            Task { await load() }
        } label: {
            Label(isLoading ? "Loading" : "Refresh", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .disabled(isLoading)
    }

    private var paginationControls: some View {
        HStack {
            Text("Page \(page) · \(total.formatted()) retained requests")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            Spacer(minLength: 12)
            previousPageButton
            nextPageButton
        }
    }

    private var previousPageButton: some View {
        Button("Previous") {
            guard page > 1 else { return }
            page -= 1
            Task { await loadRecordsOnly() }
        }
        .disabled(page <= 1 || isLoading)
    }

    private var nextPageButton: some View {
        Button("Next") {
            guard page < max(1, (total + pageSize - 1) / pageSize) else { return }
            page += 1
            Task { await loadRecordsOnly() }
        }
        .disabled(page >= max(1, (total + pageSize - 1) / pageSize) || isLoading)
    }

    @ViewBuilder
    private var filterControls: some View {
        HStack(spacing: 8) {
            domainPicker
            methodPicker
            statusPicker
        }
        .pickerStyle(.menu)
    }

    @ViewBuilder
    private var stackedFilterControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            domainPicker.frame(maxWidth: .infinity, alignment: .leading)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 8)], alignment: .leading, spacing: 8) {
                methodPicker
                statusPicker
            }
        }
        .pickerStyle(.menu)
    }

    private var domainPicker: some View {
        Picker("Domain", selection: $selectedDomain) {
            Text("All domains").tag("")
            ForEach(domains, id: \.self) { Text($0).tag($0) }
        }
        .frame(minWidth: 190, maxWidth: 330)
        .onChange(of: selectedDomain) { _, _ in
            page = 1
            Task { await loadRecordsOnly() }
        }
    }

    private var methodPicker: some View {
        Picker("Method", selection: $selectedMethod) {
            ForEach(methodOptions, id: \.self) { Text($0).tag($0) }
        }
        .frame(width: 145)
    }

    private var statusPicker: some View {
        Picker("Status", selection: $statusPrefix) {
            ForEach(statusOptions, id: \.self) { Text($0).tag($0) }
        }
        .frame(width: 145)
    }

    private var methodOptions: [String] {
        ["All methods"] + Array(Set(records.map(\.method))).sorted()
    }

    private var statusOptions: [String] { ["All statuses", "2xx", "3xx", "4xx", "5xx"] }

    private var filteredRecords: [TrafficRecentRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return records.filter { record in
            let matchesMethod = selectedMethod == "All methods" || record.method == selectedMethod
            let matchesStatus = statusPrefix == "All statuses" || String(record.status).hasPrefix(String(statusPrefix.prefix(1)))
            let matchesQuery = needle.isEmpty || "\(record.domain) \(record.path) \(record.userAgent)".lowercased().contains(needle)
            return matchesMethod && matchesStatus && matchesQuery
        }
    }

    @ViewBuilder
    private func recordRow(_ record: TrafficRecentRecord) -> some View {
        let expanded = expandedRecordID == record.id
        VStack(alignment: .leading, spacing: 9) {
            Button {
                expandedRecordID = expanded ? nil : record.id
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Text(record.status == 0 ? "Unknown" : "\(record.status)")
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .foregroundStyle(record.status >= 500 ? theme.danger : theme.text)
                        .frame(width: 46, height: 34)
                        .background(theme.cardRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(record.method)  \(record.domain)\(record.path)")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.text)
                            .lineLimit(expanded ? 3 : 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(record.requestTime, specifier: "%.1f") ms · \(record.timestamp.formatted(date: .abbreviated, time: .standard)) · \(record.countryISO ?? "Location unknown")")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    detailLine("Request ID", record.id)
                    detailLine("User agent", record.userAgent.isEmpty ? "Not recorded" : record.userAgent)
                    detailLine("Referrer", record.referer.isEmpty ? "Not recorded" : record.referer)
                }
                .padding(.leading, 58)
            }
        }
        .padding(12)
        .background(theme.card)
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(theme.divider, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func detailLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title).foregroundStyle(theme.textTertiary).frame(width: 80, alignment: .leading)
            Text(value).foregroundStyle(theme.textSecondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11, weight: .medium))
        .fixedSize(horizontal: false, vertical: true)
    }

    @MainActor
    private func load() async {
        let generation = UUID()
        requestGeneration = generation
        isLoading = true
        defer { if requestGeneration == generation { isLoading = false } }
        async let loadedDomains = capture { try await fetchDomains() }
        async let loadedPage = capture { try await fetchRecords(page: page) }
        let (domainResult, pageResult) = await (loadedDomains, loadedPage)
        guard !Task.isCancelled, requestGeneration == generation else { return }

        var failures: [String] = []
        if case let .success(value) = domainResult { domains = value }
        else if case let .failure(error) = domainResult { failures.append("Domains: \(error.localizedDescription)") }
        if case let .success(value) = pageResult {
            records = value.result
            total = value.total
        } else if case let .failure(error) = pageResult {
            failures.append("Requests: \(error.localizedDescription)")
        }
        if failures.isEmpty {
            lastUpdatedAt = .now
            status = "Loaded \(records.count) recent requests."
        } else {
            status = "Could not refresh recent traffic: " + failures.joined(separator: " · ")
        }
    }

    @MainActor
    private func loadRecordsOnly() async {
        let generation = UUID()
        requestGeneration = generation
        isLoading = true
        defer { if requestGeneration == generation { isLoading = false } }
        do {
            let result = try await fetchRecords(page: page)
            guard requestGeneration == generation else { return }
            records = result.result
            total = result.total
            lastUpdatedAt = .now
            status = "Loaded \(records.count) recent requests."
        } catch {
            guard requestGeneration == generation else { return }
            status = "Could not load recent traffic: \(error.localizedDescription)"
        }
    }

    private func fetchDomains() async throws -> [String] {
        let url = try TrafficRecentClient.domainsURL(apiBaseURL: apiBaseURL)
        let request = try TrafficRecentClient.request(url: url, userID: model.userIDForRequests, authToken: model.authTokenForRequests, impersonationToken: model.settings.impersonationToken)
        return try TrafficRecentClient.decodeDomains(await TrafficRecentClient.fetch(request))
    }

    private func fetchRecords(page: Int) async throws -> TrafficRecentPage {
        let url = try TrafficRecentClient.recordsURL(apiBaseURL: apiBaseURL, domain: selectedDomain, page: page)
        let request = try TrafficRecentClient.request(url: url, userID: model.userIDForRequests, authToken: model.authTokenForRequests, impersonationToken: model.settings.impersonationToken)
        return try TrafficRecentClient.decodePage(await TrafficRecentClient.fetch(request))
    }

    private func capture<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }

    private var apiBaseURL: URL {
        model.settings.apiBaseURL.normalizedBaseURL
    }

    private var refreshStatus: String {
        guard let lastUpdatedAt else { return "Updates automatically every 30 seconds while viewing page 1." }
        let updatedTime = lastUpdatedAt.formatted(date: .omitted, time: .standard)
        return "Updated \(updatedTime) · Auto-refreshes every 30 seconds on page 1."
    }

    @MainActor
    private func refreshWhileVisible() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(TrafficRecentClient.autoRefreshIntervalSeconds))
            } catch {
                return
            }

            guard !Task.isCancelled,
                  TrafficRecentClient.shouldAutoRefresh(page: page, isLoading: isLoading) else { continue }
            await loadRecordsOnly()
        }
    }
}
