import SwiftUI

struct TrafficMapNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var domains: [String] = []
    @State private var selectedDomain = ""
    @State private var records: [TrafficRecentRecord] = []
    @State private var metrics: TrafficMetricSnapshot?
    @State private var liveCountryDeltas: [String: TrafficMapCountryLiveDelta] = [:]
    @State private var selectedCountry = "NO"
    @State private var status = "Traffic map has not been loaded."
    @State private var isLoading = false
    @State private var requestGeneration = UUID()
    @State private var refreshGeneration = UUID()
    @State private var liveStatus = "Connecting"
    @State private var liveNotice = ""
    @State private var streamCursor = "0"
    @State private var livePings: [TrafficMapLivePing] = []
    @State private var lastBatchCount: Int?
    @State private var nextPingID = 0
    @State private var liveClock = Date()
    @State private var mapSize = CGSize.zero
    @State private var mapZoom: CGFloat = 1
    @State private var mapOffset = CGSize.zero
    @State private var dragOrigin = CGSize.zero

    private var countries: [TrafficMapCountry] {
        let snapshot = TrafficMapCountry.summarize(records, liveDeltas: liveCountryDeltas)
        guard liveStatus == "Live" else { return snapshot }
        return snapshot.filter { liveClock.timeIntervalSince($0.lastSeen) < TrafficMapLiveAggregation.expiry }
    }
    private var locatedRequestCount: Int { countries.reduce(0) { $0 + $1.requestCount } }
    private var sampledMetricsDescription: String? {
        guard let value = metrics?.sampledAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }()
        return date?.formatted(date: .abbreviated, time: .shortened) ?? value
    }
    private var selectedRecords: [TrafficRecentRecord] {
        records.filter { $0.countryISO?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == selectedCountry }
            .sorted { $0.timestamp > $1.timestamp }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], alignment: .leading, spacing: 12) {
                FeatureCard(title: "Located sample + live", value: countries.reduce(0) { $0 + $1.requestCount }.formatted(), icon: "mappin.and.ellipse")
                FeatureCard(title: "Countries", value: countries.count.formatted(), icon: "globe")
                FeatureCard(title: "Retained requests", value: metrics?.totalRequests.formatted() ?? "—", icon: "arrow.left.arrow.right")
            }

            HStack(spacing: 10) {
                Picker("Domain", selection: $selectedDomain) {
                    Text("All domains").tag("")
                    ForEach(domains, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 190, maxWidth: 360, alignment: .leading)
                Button {
                    refreshGeneration = UUID()
                } label: {
                    Label(isLoading ? "Loading" : "Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(isLoading)
                Spacer(minLength: 0)
            }

            Text(status)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(status.hasPrefix("Could not") ? theme.danger : theme.textSecondary)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Circle()
                    .fill(liveStatus == "Live" ? theme.accent : theme.textTertiary)
                    .frame(width: 7, height: 7)
                Text(liveStatus)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(liveStatus == "Access refresh required" ? theme.danger : theme.textSecondary)
                if let lastBatchCount {
                    Text("· latest live batch: \(lastBatchCount) requests")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                }
                if !liveNotice.isEmpty {
                    Text("· \(liveNotice)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            if countries.isEmpty {
                NativeEmptyState(
                    title: records.isEmpty ? "No traffic snapshot" : "No located requests",
                    message: records.isEmpty
                        ? "Refresh to load the latest retained traffic records."
                        : "The current snapshot has no requests with a supported country code."
                )
            }
            mapView
            if !countries.isEmpty {
                countryPicker
                selectedCountryDetails
            }

            trafficActivity
        }
        .task(id: "\(selectedDomain):\(refreshGeneration.uuidString)") { await monitorTraffic() }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) }
                catch { return }
                liveClock = .now
                liveCountryDeltas = liveCountryDeltas.filter { liveClock.timeIntervalSince($0.value.lastSeen) < TrafficMapLiveAggregation.expiry }
            }
        }
        .onAppear {
            if selectedDomain.isEmpty, let initial = model.selectedNativeDashboardQuery["domain"], !initial.isEmpty {
                selectedDomain = initial
            }
        }
        .onDisappear { requestGeneration = UUID() }
    }

    private var mapView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Country markers show approximate country centers; borders are not shown.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                Spacer(minLength: 4)
                Button("Zoom in") { mapZoom = min(4, mapZoom * 1.25) }
                    .disabled(mapZoom >= 4)
                Button("Zoom out") { mapZoom = max(1, mapZoom / 1.25); if mapZoom == 1 { mapOffset = .zero; dragOrigin = .zero } }
                    .disabled(mapZoom <= 1)
                Button("Reset map") { resetMap() }
                    .disabled(mapZoom == 1 && mapOffset == .zero)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            GeometryReader { geometry in
                let size = geometry.size
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(theme.card)
                    Canvas { context, canvasSize in
                        var grid = Path()
                        for longitude in stride(from: -150.0, through: 150.0, by: 30.0) {
                            let x = (longitude + 180) / 360 * canvasSize.width
                            grid.move(to: CGPoint(x: x, y: 0))
                            grid.addLine(to: CGPoint(x: x, y: canvasSize.height))
                        }
                        for latitude in stride(from: -60.0, through: 60.0, by: 30.0) {
                            let y = (90 - latitude) / 180 * canvasSize.height
                            grid.move(to: CGPoint(x: 0, y: y))
                            grid.addLine(to: CGPoint(x: canvasSize.width, y: y))
                        }
                        context.stroke(grid, with: .color(theme.divider.opacity(0.55)), lineWidth: 1)
                    }

                    ForEach(countries) { country in
                        if let point = displayedPoint(iso: country.iso, size: size) {
                            Button {
                                select(country, focusOnMap: true)
                            } label: {
                                Circle()
                                    .fill(theme.accent.opacity(selectedCountry == country.iso ? 0.95 : 0.65))
                                    .frame(width: markerDiameter(for: country), height: markerDiameter(for: country))
                                    .overlay(Circle().stroke(theme.text, lineWidth: selectedCountry == country.iso ? 2 : 0.75))
                                    .frame(width: 34, height: 34)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help("\(country.name): \(country.requestCount) located requests")
                            .accessibilityLabel("\(country.name), \(country.requestCount) located requests")
                            .position(point)
                        }
                    }

                    TimelineView(.animation(minimumInterval: 0.2, paused: livePings.isEmpty)) { timeline in
                        ForEach(livePings) { ping in
                            let age = max(0, timeline.date.timeIntervalSince(ping.receivedAt))
                            if age < 2.2, let point = displayedPoint(iso: ping.iso, size: size) {
                                let progress = age / 2.2
                                Circle()
                                    .stroke(theme.accent.opacity(1 - progress), lineWidth: 1.5)
                                    .frame(width: 16 + CGFloat(progress) * 38, height: 16 + CGFloat(progress) * 38)
                                    .position(point)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(theme.divider, lineWidth: 1))
                .contentShape(Rectangle())
                .simultaneousGesture(DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        guard mapZoom > 1 else { return }
                        mapOffset = clampedOffset(CGSize(width: dragOrigin.width + value.translation.width,
                                                         height: dragOrigin.height + value.translation.height), size: size)
                    }
                    .onEnded { _ in dragOrigin = mapOffset })
                .onAppear { mapSize = size }
                .onChange(of: size) { _, value in mapSize = value }
            }
            .aspectRatio(2, contentMode: .fit)
            .frame(maxWidth: .infinity)

            Text("Drag to pan when zoomed. Select a country marker or country below to focus it.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textTertiary)
        }
    }

    private var countryPicker: some View {
        NativeGroupPanel(title: "Countries in this snapshot", subtitle: "Select a country to inspect its requests") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(countries) { country in
                    Button {
                        select(country, focusOnMap: true)
                    } label: {
                        HStack(spacing: 8) {
                            Text(country.iso)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(theme.textSecondary)
                            Text(country.name)
                                .lineLimit(1)
                                .foregroundStyle(theme.text)
                            Spacer(minLength: 2)
                            Text(country.requestCount.formatted())
                                .foregroundStyle(theme.textSecondary)
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(selectedCountry == country.iso ? theme.cardRaised : theme.card, in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var selectedCountryDetails: some View {
        NativeGroupPanel(title: selectedCountryName, subtitle: countryFocusSummary) {
            if selectedRecords.isEmpty {
                Text("No located requests for this country in the current snapshot.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(selectedRecords.prefix(10)) { record in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(record.status)")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(record.status >= 500 ? theme.danger : theme.text)
                                .frame(width: 38)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(record.method)  \(record.domain)\(record.path)")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(theme.text)
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                                Text("\(record.requestTime, specifier: "%.1f") ms · \(record.timestamp.formatted(date: .abbreviated, time: .standard))")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(theme.textSecondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(9)
                        .background(theme.card, in: RoundedRectangle(cornerRadius: 9))
                    }
                    if selectedRecords.count > 10 {
                        Text("Showing the latest 10 of \(selectedRecords.count) requests for this country.")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
            }
        }
    }

    private var countryFocusSummary: String {
        guard let country = countries.first(where: { $0.iso == selectedCountry }) else {
            return "Recent requests in the loaded snapshot"
        }
        let share = locatedRequestCount == 0 ? 0 : Double(country.requestCount) / Double(locatedRequestCount) * 100
        let rank = (countries.firstIndex(where: { $0.iso == country.iso }) ?? 0) + 1
        let capital = TrafficMapGeography.capitalNames[country.iso] ?? "Capital unavailable"
        let distance = TrafficMapGeography.distanceFromNorwayKilometers(iso: country.iso).map { " · \($0.formatted()) km from Norway" } ?? ""
        return "\(country.requestCount.formatted()) requests · \(String(format: "%.1f%%", share)) of located · hotspot #\(rank) · \(capital)\(distance) · last seen \(country.lastSeen.formatted(date: .abbreviated, time: .shortened))"
    }

    private var trafficActivity: some View {
        NativeGroupPanel(title: "Retained traffic activity", subtitle: sampledMetricsDescription.map { "Statistics sampled \($0)" } ?? "Aggregate statistics for the selected domain") {
            if let metrics {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], alignment: .leading, spacing: 12) {
                    metricValue("Average response", value: "\(metrics.averageRequestTime.formatted(.number.precision(.fractionLength(0...1)))) ms")
                    metricValue("Error rate", value: String(format: "%.1f%%", metrics.errorRate * 100))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], alignment: .leading, spacing: 12) {
                    metricList("Top paths", values: metrics.topPaths)
                    metricList("Methods", values: metrics.topMethods)
                    metricList("Statuses", values: metrics.topStatusCodes)
                }
            } else {
                Text("Traffic activity statistics are unavailable.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    private func metricValue(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
            Text(value).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metricList(_ title: String, values: [TrafficMetricSnapshot.Metric]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text)
            if values.isEmpty {
                Text("No data").font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textSecondary)
            } else {
                ForEach(values.prefix(5)) { metric in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(metric.key).lineLimit(2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        Spacer(minLength: 2)
                        Text(metric.count.formatted()).foregroundStyle(theme.textSecondary)
                    }
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 9))
    }

    private var selectedCountryName: String {
        countries.first(where: { $0.iso == selectedCountry })?.name
            ?? Locale.current.localizedString(forRegionCode: selectedCountry)
            ?? "Country focus"
    }

    private func markerDiameter(for country: TrafficMapCountry) -> CGFloat {
        let strongest = max(1, countries.map(\.requestCount).max() ?? 1)
        return 10 + 14 * CGFloat(country.requestCount) / CGFloat(strongest)
    }

    private func displayedPoint(iso: String, size: CGSize) -> CGPoint? {
        guard let point = TrafficMapGeography.point(iso: iso, size: size) else { return nil }
        return CGPoint(
            x: (point.x - size.width / 2) * mapZoom + size.width / 2 + mapOffset.width,
            y: (point.y - size.height / 2) * mapZoom + size.height / 2 + mapOffset.height
        )
    }

    private func clampedOffset(_ value: CGSize, size: CGSize) -> CGSize {
        let horizontalLimit = size.width * max(0, mapZoom - 1) / 2
        let verticalLimit = size.height * max(0, mapZoom - 1) / 2
        return CGSize(
            width: min(horizontalLimit, max(-horizontalLimit, value.width)),
            height: min(verticalLimit, max(-verticalLimit, value.height))
        )
    }

    private func resetMap() {
        mapZoom = 1
        mapOffset = .zero
        dragOrigin = .zero
    }

    private func select(_ country: TrafficMapCountry, focusOnMap: Bool = false) {
        selectedCountry = country.iso
        guard focusOnMap, mapSize.width > 0, mapSize.height > 0,
              let point = TrafficMapGeography.point(iso: country.iso, size: mapSize) else { return }
        mapZoom = 2.4
        let desired = CGSize(
            width: mapSize.width / 2 - point.x * mapZoom,
            height: mapSize.height / 2 - point.y * mapZoom
        )
        mapOffset = clampedOffset(desired, size: mapSize)
        dragOrigin = mapOffset
    }

    @MainActor
    private func monitorTraffic() async {
        liveStatus = "Connecting"
        liveNotice = ""
        streamCursor = "0"
        livePings = []
        lastBatchCount = nil
        await load()
        guard !Task.isCancelled else { return }
        streamCursor = records.compactMap { UInt64($0.id) }.max().map(String.init) ?? "0"

        let snapshots = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) }
                catch { break }
                guard !Task.isCancelled else { break }
                await load()
            }
        }
        defer { snapshots.cancel() }

        var failures = 0
        while !Task.isCancelled {
            do {
                let request = try TrafficMapLiveClient.request(
                    apiBaseURL: apiBaseURL,
                    userID: model.userIDForRequests,
                    authToken: model.authTokenForRequests,
                    impersonationToken: model.settings.impersonationToken,
                    domain: selectedDomain,
                    after: streamCursor == "0" ? nil : streamCursor
                )
                liveStatus = failures == 0 ? "Connecting" : "Reconnecting"
                try await TrafficMapLiveClient.listen(
                    request: request,
                    expectedHost: apiBaseURL.host ?? "",
                    afterCursor: streamCursor,
                    onReady: {
                        liveStatus = "Live"
                        liveNotice = ""
                    },
                    onBatch: { batches in
                        let receivedAt = Date()
                        lastBatchCount = batches.reduce(0) { $0 + $1.count }
                        liveCountryDeltas = TrafficMapLiveAggregation.applying(batches, to: liveCountryDeltas, receivedAt: receivedAt)
                        let known = batches.filter { TrafficMapGeography.centroids[$0.iso] != nil }
                        for batch in known {
                            nextPingID += 1
                            livePings.append(TrafficMapLivePing(id: nextPingID, iso: batch.iso, count: batch.count, receivedAt: receivedAt))
                        }
                        if livePings.count > 40 { livePings.removeFirst(livePings.count - 40) }
                        if let cursor = batches.compactMap({ UInt64($0.maxID) }).max() {
                            streamCursor = String(max(UInt64(streamCursor) ?? 0, cursor))
                        }
                    }
                )
                if Task.isCancelled { break }
                failures += 1
                liveNotice = "Live feed disconnected; recent snapshots remain available."
            } catch is CancellationError {
                break
            } catch let error as TrafficMapLiveError {
                if error.isAuthorizationFailure {
                    liveStatus = "Access refresh required"
                    liveNotice = "Refresh after checking account access."
                    snapshots.cancel()
                    return
                }
                failures += 1
                liveNotice = "Live feed disconnected; recent snapshots remain available."
            } catch {
                failures += 1
                liveNotice = "Live feed disconnected; recent snapshots remain available."
            }

            if failures >= 5 {
                liveStatus = "Polling snapshots"
                liveNotice = "Live reconnect paused after repeated failures."
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) }
                    catch { break }
                }
                break
            }
            liveStatus = "Reconnecting"
            let delay = min(15, 1 << min(failures, 4))
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { break }
        }
    }

    @MainActor
    private func load() async {
        let generation = UUID()
        requestGeneration = generation
        isLoading = true
        defer { if requestGeneration == generation { isLoading = false } }

        async let domainsResult = fetchDomainsResult()
        async let recordsResult = fetchRecordsResult()
        async let metricsResult = fetchMetricsResult()
        let (newDomains, page, newMetrics) = await (domainsResult, recordsResult, metricsResult)
        guard requestGeneration == generation else { return }

        if case let .success(value) = newDomains { domains = value }
        if case let .success(value) = page {
            records = value.result
            liveCountryDeltas = [:]
            if let cursor = value.result.compactMap({ UInt64($0.id) }).max() {
                streamCursor = String(max(UInt64(streamCursor) ?? 0, cursor))
            }
        }
        if case let .success(value) = newMetrics { metrics = value }

        let failures = [
            newDomains.failureDescription("domains"),
            page.failureDescription("recent requests"),
            newMetrics.failureDescription("traffic metrics"),
        ].compactMap { $0 }
        if failures.isEmpty {
            status = "Loaded \(records.count) recent requests · \((page.successValue?.total ?? records.count).formatted()) retained in this domain filter. Country counts describe the loaded sample."
        } else if page.isSuccess || newDomains.isSuccess || newMetrics.isSuccess {
            status = "Some traffic map data could not be refreshed: \(failures.joined(separator: "; ")). Showing the latest available data."
        } else {
            status = "Could not load traffic map: \(failures.joined(separator: "; "))"
        }
    }

    private func fetchDomainsResult() async -> Result<[String], Error> {
        do { return .success(try await fetchDomains()) }
        catch { return .failure(error) }
    }

    private func fetchRecordsResult() async -> Result<TrafficRecentPage, Error> {
        do { return .success(try await fetchRecords()) }
        catch { return .failure(error) }
    }

    private func fetchMetricsResult() async -> Result<TrafficMetricSnapshot, Error> {
        do { return .success(try await fetchMetrics()) }
        catch { return .failure(error) }
    }

    private func fetchDomains() async throws -> [String] {
        let url = try TrafficRecentClient.domainsURL(apiBaseURL: apiBaseURL)
        let request = try TrafficRecentClient.request(url: url, userID: model.userIDForRequests, authToken: model.authTokenForRequests, impersonationToken: model.settings.impersonationToken)
        return try TrafficRecentClient.decodeDomains(await TrafficRecentClient.fetch(request))
    }

    private func fetchRecords() async throws -> TrafficRecentPage {
        let url = try TrafficRecentClient.recordsURL(apiBaseURL: apiBaseURL, domain: selectedDomain, page: 1, limit: 200)
        let request = try TrafficRecentClient.request(url: url, userID: model.userIDForRequests, authToken: model.authTokenForRequests, impersonationToken: model.settings.impersonationToken)
        return try TrafficRecentClient.decodePage(await TrafficRecentClient.fetch(request))
    }

    private func fetchMetrics() async throws -> TrafficMetricSnapshot {
        let url = try TrafficRecentClient.metricsURL(apiBaseURL: apiBaseURL, domain: selectedDomain)
        let request = try TrafficRecentClient.request(url: url, userID: model.userIDForRequests, authToken: model.authTokenForRequests, impersonationToken: model.settings.impersonationToken)
        return try TrafficMetricSnapshot.decode(await TrafficRecentClient.fetch(request))
    }

    private var apiBaseURL: URL { model.settings.apiBaseURL.normalizedBaseURL }
}

private extension Result where Failure == Error {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var successValue: Success? {
        try? get()
    }

    func failureDescription(_ endpoint: String) -> String? {
        guard case let .failure(error) = self else { return nil }
        return "\(endpoint): \(error.localizedDescription)"
    }
}
