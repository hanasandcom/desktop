import SwiftUI

struct PublicExposureActivityNativePanel: View {
    @Environment(\.desktopTheme) private var theme
    @StateObject private var model: PublicExposureActivityViewModel
    @State private var filters = PublicExposureActivityFilters()
    @State private var appliedFilters = PublicExposureActivityFilters()
    @State private var filtersOpen = false

    @MainActor
    init(viewModel: PublicExposureActivityViewModel? = nil) {
        _model = StateObject(wrappedValue: viewModel ?? PublicExposureActivityViewModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NativeGroupPanel(title: "Latest company mentions", subtitle: statusSummary) {
                HStack(spacing: 8) {
                    TextField("Search activity", text: $filters.q)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { applyFilters() }
                    Button { applyFilters() } label: {
                        Label(model.isLoading ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
                    }.disabled(model.isLoading || model.isLoadingMore)
                    Button(filtersOpen ? "Hide filters" : "Filters") { filtersOpen.toggle() }
                }
                if filtersOpen { filterFields }
                if filtersOpen {
                    HStack {
                        Button("Apply filters") { applyFilters() }
                            .buttonStyle(.borderedProminent)
                        Button("Clear") {
                            let cleared = PublicExposureActivityFilters()
                            filters = cleared
                            appliedFilters = cleared
                            Task { await model.refresh(filters: cleared) }
                        }.buttonStyle(.bordered)
                    }
                }
                if let error = model.errorMessage { NativeNotice(message: error) }
            }

            if model.isLoading && model.page == nil {
                NativeEmptyState(title: "Loading activity", message: "Retrieving the latest public company exposure reports.")
            } else if model.page == nil, model.errorMessage != nil {
                NativeEmptyState(title: "Activity unavailable", message: "Review the error above, then retry the request.")
                Button("Try again") { Task { await model.refresh(filters: appliedFilters) } }
            } else if let page = model.page, model.items.isEmpty {
                NativeEmptyState(title: "No activity found", message: "No public company mentions match the current filters.")
                freshness(page)
            } else if let page = model.page {
                freshness(page)
                NativeGroupPanel(title: "Exposure reports", subtitle: "\(page.counts?.total ?? model.items.count) total reported · \(model.items.count) loaded") {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        exposure(item)
                        if index != model.items.count - 1 { Divider() }
                    }
                    if model.nextOffset != nil {
                        Button {
                            Task { await model.loadMore(filters: appliedFilters) }
                        } label: {
                            HStack {
                                Spacer()
                                if model.isLoadingMore { ProgressView().controlSize(.small) }
                                Text(model.isLoadingMore ? "Loading more…" : "Load more")
                                Spacer()
                            }
                        }.disabled(model.isLoadingMore)
                    }
                }
            }
        }
        .padding(16)
        .task { await model.refresh(filters: appliedFilters) }
    }

    private var statusSummary: String {
        guard let page = model.page else { return "Public reports of company data exposure, independent of the threat intelligence activity feed." }
        let status = page.status.capitalized
        let latest = page.freshness?.latestClaimAt ?? page.freshness?.latestCollectedAt ?? page.generatedAt
        return "\(status) snapshot · latest activity \(displayDate(latest))"
    }

    private var filterFields: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                filter("Company", text: $filters.company)
                filter("Actor", text: $filters.actor)
                filter("Category", text: $filters.category)
            }
            GridRow {
                filter("Data size", text: $filters.size)
                filter("Country", text: $filters.country)
                filter("From (date)", text: $filters.from)
            }
            GridRow {
                filter("To (date)", text: $filters.to)
                Spacer()
                Spacer()
            }
        }
    }

    private func filter(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text).textFieldStyle(.roundedBorder)
    }

    private func freshness(_ page: PublicExposureActivityPage) -> some View {
        HStack(spacing: 12) {
            Label("\(page.counts?.needsReview ?? 0) need review", systemImage: "eye")
            Label("\(page.counts?.metadataOnly ?? 0) metadata only", systemImage: "doc.text.magnifyingglass")
            Spacer()
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(theme.textTertiary)
    }

    private func exposure(_ item: PublicExposureActivityPage.Item) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.company).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                Spacer()
                Text(displayDate(item.claimTime ?? item.collectedAt)).font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary)
            }
            Text("Actor: \(item.actor)").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
            Text("Claimed data: \(item.claimedData) · Size: \(item.claimedDataSize)")
                .font(.system(size: 11)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
            HStack {
                Label(item.country ?? "Not disclosed by TA", systemImage: "globe")
                Text(item.status.capitalized)
                if let confidence = item.confidence { Text("\(Int((confidence * 100).rounded()))% confidence") }
                if let source = item.sourceName { Text(source) }
            }
            .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary)
        }
        .padding(.vertical, 7)
    }

    private func displayDate(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "pending" }
        return formatDateText(value, fallback: value)
    }

    private func applyFilters() {
        appliedFilters = filters
        Task { await model.refresh(filters: filters) }
    }
}
