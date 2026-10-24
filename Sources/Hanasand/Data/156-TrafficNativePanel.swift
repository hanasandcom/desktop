import SwiftUI

struct TrafficNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var domains: [String] = []
    @State private var selectedDomain = ""
    @State private var metrics: TrafficMetricSnapshot?
    @State private var latestRecord: TrafficRecentRecord?
    @State private var status = "Traffic overview has not been loaded."
    @State private var lastUpdatedAt: Date?
    @State private var isLoading = false
    @State private var showHourlyValues = false
    @State private var requestGeneration = UUID()
    @State private var refreshGeneration = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    domainPicker
                    refreshButton
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 8) {
                    domainPicker.frame(maxWidth: .infinity, alignment: .leading)
                    HStack { Spacer(minLength: 0); refreshButton }
                }
            }

            Text(status)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(status.hasPrefix("Could not") ? theme.danger : theme.textSecondary)
                .textSelection(.enabled)

            if let lastUpdatedAt {
                Text("Updated \(lastUpdatedAt.formatted(date: .omitted, time: .standard)) · refreshes every 30 seconds while open.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            } else {
                Text("Refreshes every 30 seconds while open.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            }

            if let metrics {
                summary(metrics)
                if !selectedDomain.isEmpty {
                    hourlyTrend(metrics.requestsOverTime)
                }
                analytics(metrics)
            } else if isLoading {
                NativeEmptyState(title: "Loading traffic overview", message: "Fetching request statistics and the latest request.")
            } else {
                NativeEmptyState(title: "Traffic statistics unavailable", message: "Refresh to load request volume, response time, routes, and errors.")
            }
        }
        .onAppear {
            if selectedDomain.isEmpty, let initial = model.selectedNativeDashboardQuery["domain"], !initial.isEmpty {
                selectedDomain = initial
            }
        }
        .task(id: "\(selectedDomain):\(refreshGeneration.uuidString)") {
            await refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
                if !isLoading { await refresh() }
            }
        }
        .onDisappear { requestGeneration = UUID() }
    }

    private var domainPicker: some View {
        Picker("Domain", selection: $selectedDomain) {
            Text("All domains").tag("")
            ForEach(domains, id: \.self) { Text($0).tag($0) }
        }
        .pickerStyle(.menu)
        .frame(minWidth: 190, maxWidth: 360, alignment: .leading)
    }

    private var refreshButton: some View {
        Button {
            refreshGeneration = UUID()
        } label: {
            Label(isLoading ? "Loading" : "Refresh", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .disabled(isLoading)
    }

    private func summary(_ metrics: TrafficMetricSnapshot) -> some View {
        let errorPercent = (metrics.errorRate * 1000).rounded() / 10
        return NativeGroupPanel(title: "Traffic summary", subtitle: metrics.sampledAt.map { "Statistics sampled \(formattedDate($0))" } ?? "Request volume, response times, routes, and errors") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], alignment: .leading, spacing: 12) {
                lane(title: "Latest request", value: latestRecord.map { "\($0.method) · \($0.status)" } ?? "No requests",
                     detail: latestRecord.map { "\($0.domain)\($0.path)" },
                     footer: latestRecord?.timestamp.formatted(date: .abbreviated, time: .shortened),
                     warning: (latestRecord?.status ?? 0) >= 500)
                lane(title: "Busiest route", value: metrics.topPaths.first?.key ?? "No requests",
                     detail: metrics.topPaths.first.map { "\($0.count.formatted()) requests" },
                     footer: selectedDomain.isEmpty ? (metrics.topDomains.first?.key ?? "All domains") : selectedDomain)
                lane(title: "Response time", value: metrics.totalRequests == 0 ? "No requests" : "\(metrics.averageRequestTime.formatted(.number.precision(.fractionLength(0...1)))) ms",
                     detail: "\(metrics.totalRequests.formatted()) tracked requests",
                     footer: metrics.averageRequestTime > 1000 ? "Above 1,000 ms" : nil,
                     warning: metrics.averageRequestTime > 1000)
                lane(title: "Errors", value: "\(errorPercent.formatted(.number.precision(.fractionLength(1))))%",
                     detail: metrics.topErrorPaths.first?.key,
                     footer: "4xx/5xx share", warning: errorPercent > 5)
            }
        }
    }

    private func analytics(_ metrics: TrafficMetricSnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 12)], alignment: .leading, spacing: 12) {
            metricList("Methods", values: metrics.topMethods)
            metricList("Status codes", values: metrics.topStatusCodes)
            if selectedDomain.isEmpty {
                metricList("Domains", values: metrics.topDomains)
            }
            slowPathList(metrics.topSlowPaths)
            metricList("Operating systems", values: metrics.topOperatingSystems)
            metricList("Browsers", values: metrics.topBrowsers)
            metricList("Top paths", values: metrics.topPaths)
            metricList("Top error paths", values: metrics.topErrorPaths)
        }
    }

    private func hourlyTrend(_ values: [TrafficMetricSnapshot.Metric]) -> some View {
        NativeGroupPanel(title: "Requests over time", subtitle: "Hourly traffic for the selected domain") {
            if values.isEmpty {
                Text("No hourly observations recorded.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            } else {
                Canvas { context, size in
                    let maximum = max(1, values.map(\.count).max() ?? 1)
                    var path = Path()
                    for (index, item) in values.enumerated() {
                        let x = values.count < 2 ? size.width / 2 : size.width * CGFloat(index) / CGFloat(values.count - 1)
                        let y = size.height - size.height * CGFloat(item.count) / CGFloat(maximum)
                        let point = CGPoint(x: x, y: y)
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    context.stroke(path, with: .color(theme.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                .frame(height: 110)
                .accessibilityLabel("Hourly traffic trend with \(values.count) readings")
                Button(showHourlyValues ? "Hide hourly values" : "Show hourly values") {
                    showHourlyValues.toggle()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if showHourlyValues {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, item in
                        HStack {
                            Text(formattedDate(item.key))
                            Spacer()
                            Text("\(item.count.formatted()) requests")
                        }
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                    }
                }
            }
        }
    }

    private func metricList(_ title: String, values: [TrafficMetricSnapshot.Metric]) -> some View {
        NativeGroupPanel(title: title, subtitle: "") {
            if values.isEmpty {
                Text("No recorded breakdown.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            } else {
                ForEach(Array(values.prefix(10).enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.key).lineLimit(2).textSelection(.enabled)
                        Spacer(minLength: 4)
                        Text(item.count.formatted()).foregroundStyle(theme.textSecondary)
                    }
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
            }
        }
    }

    private func slowPathList(_ values: [TrafficMetricSnapshot.SlowMetric]) -> some View {
        NativeGroupPanel(title: "Top slow paths", subtitle: "Average response time") {
            if values.isEmpty {
                Text("No recorded slow paths.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            } else {
                ForEach(Array(values.prefix(10).enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.key).lineLimit(2).textSelection(.enabled)
                        Spacer(minLength: 4)
                        Text("\(item.averageTime.formatted(.number.precision(.fractionLength(0...1)))) ms")
                            .foregroundStyle(theme.textSecondary)
                    }
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
            }
        }
    }

    private func lane(title: String, value: String, detail: String?, footer: String?, warning: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
            Text(value).font(.system(size: 13, weight: .semibold)).foregroundStyle(warning ? theme.danger : theme.text).lineLimit(2).textSelection(.enabled)
            if let detail {
                Text(detail).font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textSecondary).lineLimit(2).textSelection(.enabled)
            }
            if let footer {
                Text(footer).font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .padding(10)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 9))
    }

    @MainActor
    private func refresh() async {
        let generation = UUID()
        requestGeneration = generation
        isLoading = true
        defer {
            if requestGeneration == generation { isLoading = false }
        }

        async let loadedDomains = capture { try await fetchDomains() }
        async let loadedMetrics = capture { try await fetchMetrics() }
        async let loadedRecords = capture { try await fetchRecords() }
        let (domainResult, metricsResult, recordsResult) = await (loadedDomains, loadedMetrics, loadedRecords)
        guard !Task.isCancelled, requestGeneration == generation,
              model.selectedDashboardPath == "/traffic" else { return }

        var failures: [String] = []
        if case let .success(value) = domainResult { domains = value }
        else if case let .failure(error) = domainResult { failures.append("Domains: \(error.localizedDescription)") }
        if case let .success(value) = metricsResult { metrics = value }
        else if case let .failure(error) = metricsResult { failures.append("Statistics: \(error.localizedDescription)") }
        if case let .success(value) = recordsResult { latestRecord = value.result.first }
        else if case let .failure(error) = recordsResult { failures.append("Latest request: \(error.localizedDescription)") }

        if failures.isEmpty {
            status = "Loaded traffic statistics and latest request."
            lastUpdatedAt = .now
        } else {
            status = "Could not refresh traffic: " + failures.joined(separator: " · ")
        }
    }

    private func capture<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }

    private func fetchDomains() async throws -> [String] {
        let url = try TrafficRecentClient.domainsURL(apiBaseURL: apiBaseURL)
        let request = try makeRequest(url)
        return try TrafficRecentClient.decodeDomains(await TrafficRecentClient.fetch(request))
    }

    private func fetchMetrics() async throws -> TrafficMetricSnapshot {
        let url = try TrafficRecentClient.metricsURL(apiBaseURL: apiBaseURL, domain: selectedDomain)
        let request = try makeRequest(url, timeoutInterval: 60)
        return try TrafficMetricSnapshot.decode(await TrafficRecentClient.fetch(request))
    }

    private func fetchRecords() async throws -> TrafficRecentPage {
        let url = try TrafficRecentClient.recordsURL(apiBaseURL: apiBaseURL, domain: selectedDomain, page: 1, limit: 12)
        let request = try makeRequest(url, timeoutInterval: 60)
        return try TrafficRecentClient.decodePage(await TrafficRecentClient.fetch(request))
    }

    private func makeRequest(_ url: URL, timeoutInterval: TimeInterval = 30) throws -> URLRequest {
        try TrafficRecentClient.request(
            url: url,
            userID: model.userIDForRequests,
            authToken: model.authTokenForRequests,
            impersonationToken: model.settings.impersonationToken,
            timeoutInterval: timeoutInterval
        )
    }

    private var apiBaseURL: URL { model.settings.apiBaseURL.normalizedBaseURL }

    private func formattedDate(_ value: String) -> String {
        let normalized = value.replacingOccurrences(of: " ", with: "T", range: value.range(of: " "))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: normalized) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: normalized)
        }()
        return date?.formatted(date: .abbreviated, time: .shortened) ?? value
    }
}
