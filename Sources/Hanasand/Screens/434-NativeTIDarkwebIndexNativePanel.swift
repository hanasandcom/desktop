import SwiftUI

struct NativeTIDarkwebIndexNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var filters = NativeTIDarkwebFilters()
    @State private var appliedFilters = NativeTIDarkwebFilters()
    @State private var statusResponse: NativeTIDarkwebStatusResponse?
    @State private var searchResponse: NativeTIDarkwebSearchResponse?
    @State private var statusError: String?
    @State private var searchError: String?
    @State private var isLoading = false

    private var indexStatus: NativeTIDarkwebStatusResponse.Status? { statusResponse?.index }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                NativeGroupPanel(title: "Exposure source map", subtitle: "Search monitored sources, company mentions, and metadata-only exposure records.") {
                    HStack(alignment: .top, spacing: 10) {
                        Label("Company alerts", systemImage: "bell.badge")
                        Label("Leak sites", systemImage: "eye")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    Text("Use public indexes as seeds, then verify fresh exposure-source changes only where collection is approved.")
                        .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                statusCards
                productTiles

                NativeGroupPanel(title: "Search exposure activity", subtitle: "Search companies, groups, domains, sectors, and monitored metadata.") {
                    filterFields
                    HStack(spacing: 8) {
                        Button {
                            appliedFilters = filters
                            Task { await search() }
                        } label: {
                            Label(isLoading ? "Searching…" : "Find", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isLoading)

                        Button("Clear") {
                            filters = NativeTIDarkwebFilters()
                            appliedFilters = filters
                            Task { await search() }
                        }
                        .disabled(isLoading || filters == NativeTIDarkwebFilters())

                        Button {
                            Task { await refresh() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(isLoading)
                    }
                    if let searchError {
                        NativeNotice(message: searchError, title: "Search unavailable")
                    }
                }

                if isLoading && searchResponse == nil {
                    NativeEmptyState(title: "Loading exposure activity", message: "Retrieving the current public dark web index.")
                } else if let response = searchResponse {
                    searchResults(response)
                } else if !isLoading {
                    NativeEmptyState(title: "Exposure activity unavailable", message: searchError ?? "Refresh to retry the public index.")
                }

                breakdowns
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await refresh() }
    }

    private var statusCards: some View {
        NativeGroupPanel(title: "Index status", subtitle: statusSummary) {
            if let statusError {
                NativeNotice(message: statusError, title: "Status unavailable")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 8) {
                metric("Monitored sources", number(indexStatus?.monitoredSourceCount, fallback: "Unavailable"))
                metric("Indexed records", number(indexStatus?.indexedRecordCount, fallback: "Unavailable"))
                metric("Matches", matchSummary)
                metric("Latest record", date(indexStatus?.latestRecordAt))
            }
        }
    }

    private var statusSummary: String {
        guard let indexStatus else { return "Public monitoring snapshot · status is being checked" }
        let generated = date(indexStatus.generatedAt)
        return "\(indexStatus.metadataOnly == true ? "Metadata only · " : "")Latest snapshot \(generated)"
    }

    private var matchSummary: String {
        if let count = searchResponse?.count { return number(count) }
        if searchResponse?.records.isEmpty == false { return "Matched" }
        return searchResponse == nil ? "Checking" : "No current match"
    }

    private var productTiles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), alignment: .top)], alignment: .leading, spacing: 10) {
            productTile("Source verification", detail: "Use public indexes as seeds, then verify approved source changes.", icon: "checkmark.shield")
            productTile("Company watchlists", detail: "Match customers, vendors, domains, and brands against new exposure posts.", icon: "building.2")
            productTile("Monitoring mix", detail: "Track monitored source infrastructure and exposure records together.", icon: "globe")
        }
    }

    private var filterFields: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
            filterField("Search", placeholder: "company, group, domain, sector…", text: $filters.query)
            filterField("Network", placeholder: "tor, i2p, clear web", text: $filters.network)
            filterField("Review type", placeholder: "approved, review", text: $filters.legalTriage)
            filterField("Status", placeholder: "ready, watching", text: $filters.reviewState)
            filterField("Category", placeholder: "exposure type", text: $filters.category)
        }
        .onSubmit {
            appliedFilters = filters
            Task { await search() }
        }
    }

    @ViewBuilder private func searchResults(_ response: NativeTIDarkwebSearchResponse) -> some View {
        let records = response.records
        NativeGroupPanel(title: "Exposure activity", subtitle: "\(records.count) shown\(response.nextCursor == nil ? "" : " · more available")") {
            if records.isEmpty {
                NativeEmptyState(
                    title: emptyTitle(response),
                    message: emptyDescription(response)
                )
                if let identity = response.canonicalIdentity, let url = canonicalURL(identity.canonicalPath) {
                    Button {
                        model.openURL(url.absoluteString, label: "\(identity.canonicalName) intelligence")
                    } label: {
                        Label("Open \(identity.canonicalName) intelligence", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                ForEach(records) { record in
                    recordRow(record)
                    if record.id != records.last?.id { Divider() }
                }
            }
        }
    }

    private var breakdowns: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .top)], alignment: .leading, spacing: 10) {
            breakdown("Networks", values: indexStatus?.counts?.byNetwork)
            breakdown("Review type", values: indexStatus?.counts?.byLegalTriage)
            breakdown("Freshness", values: indexStatus?.counts?.byLiveness)
            breakdown("Status", values: indexStatus?.counts?.byReviewState)
        }
    }

    private func filterField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(theme.textTertiary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Text(value).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                .multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func productTile(_ title: String, detail: String, icon: String) -> some View {
        NativeGroupPanel(title: title, subtitle: "") {
            Label(title, systemImage: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text)
            Text(detail).font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func recordRow(_ record: NativeTIDarkwebSearchResponse.Record) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(record.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text("Reference \(record.safeLocatorHash)").font(.system(size: 9, design: .monospaced)).foregroundStyle(theme.textTertiary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(record.safeSummary).font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                chip(record.network)
                chip(label(record.reviewState))
            }
            hints("Groups", record.actorHints)
            hints("Companies", record.victimHints)
            hints("Data claims", record.datasetHints)
            hints("Sectors", record.sectorHints)
            hints("Countries", record.countryHints)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), alignment: .leading)], alignment: .leading, spacing: 8) {
                detailValue("Activity type", label(record.category))
                detailValue("Review", label(record.legalTriage))
                detailValue("Freshness", label(record.liveness))
                detailValue("Last seen", date(record.lastSeen))
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.system(size: 8, weight: .semibold)).foregroundStyle(theme.textTertiary)
            Text(value).font(.system(size: 10)).foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func hints(_ title: String, _ values: [String]?) -> some View {
        if let values, !values.isEmpty {
            HStack(alignment: .top, spacing: 5) {
                Text("\(title):").font(.system(size: 9)).foregroundStyle(theme.textTertiary)
                Text(values.joined(separator: " · ")).font(.system(size: 9)).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .medium)).foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func breakdown(_ title: String, values: [String: Int]?) -> some View {
        NativeGroupPanel(title: title, subtitle: "") {
            let entries = (values ?? [:]).sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(8)
            if entries.isEmpty {
                Text("Available when matching exposure records enter the index.")
                    .font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(entries), id: \.key) { entry in
                    HStack(spacing: 8) {
                        Text(label(entry.key)).font(.system(size: 10)).foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Text(String(entry.value)).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.text)
                    }
                }
            }
        }
    }

    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let settings = model.settings
        let client = NativeTIDarkwebIndexClient(settings: settings)
        async let statusResult = capture { try await client.loadStatus() }
        async let searchResult = capture { try await client.search(filters: appliedFilters) }
        let (newStatus, newSearch) = await (statusResult, searchResult)
        guard model.settings == settings, !Task.isCancelled else { return }
        switch newStatus {
        case .success(let value): statusResponse = value; statusError = nil
        case .failure(let error): statusError = error.localizedDescription
        }
        switch newSearch {
        case .success(let value): searchResponse = value; searchError = nil
        case .failure(let error): searchError = error.localizedDescription
        }
    }

    private func search() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            searchResponse = try await NativeTIDarkwebIndexClient(settings: model.settings).search(filters: appliedFilters)
            searchError = nil
        } catch {
            searchError = error.localizedDescription
        }
    }

    private func capture<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }

    private func emptyTitle(_ response: NativeTIDarkwebSearchResponse) -> String {
        if let identity = response.canonicalIdentity {
            return "\(identity.canonicalName) is known, but has no approved restricted-network records"
        }
        return appliedFilters.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Search company and actor activity"
            : "No matching activity in the current index"
    }

    private func emptyDescription(_ response: NativeTIDarkwebSearchResponse) -> String {
        if let identity = response.canonicalIdentity {
            return "The query resolves to \(identity.canonicalName) in threat intelligence. This index contains zero approved metadata-only restricted-network captures for the current filters."
        }
        return appliedFilters.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Enter a company, group, domain, supplier, or sector to review monitored exposure records."
            : "Try a broader company, group, sector, or domain. Alerts are useful when a watched term appears; empty searches stay quiet."
    }

    private func canonicalURL(_ rawPath: String) -> URL? {
        guard rawPath.hasPrefix("/ti/"), !rawPath.contains("\\"),
              let url = URL(string: "https://hanasand.com\(rawPath)"),
              url.host == "hanasand.com", url.path.hasPrefix("/ti/") else { return nil }
        return url
    }

    private func number(_ value: Int?, fallback: String = "Checking") -> String {
        value.map { NumberFormatter.localizedString(from: NSNumber(value: $0), number: .decimal) } ?? fallback
    }

    private func date(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "Unavailable" }
        guard let parsed = ISO8601DateFormatter().date(from: raw) else { return raw }
        return DateFormatter.localizedString(from: parsed, dateStyle: .medium, timeStyle: .none)
    }

    private func label(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .split(separator: " ").map { $0.capitalized }.joined(separator: " ")
    }
}
