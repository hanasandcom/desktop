import SwiftUI

struct TrafficMapNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var domains: [String] = []
    @State private var selectedDomain = ""
    @State private var records: [TrafficRecentRecord] = []
    @State private var selectedCountry = ""
    @State private var status = "Traffic map has not been loaded."
    @State private var isLoading = false
    @State private var requestGeneration = UUID()

    private var countries: [TrafficMapCountry] { TrafficMapCountry.summarize(records) }
    private var selectedRecords: [TrafficRecentRecord] {
        records.filter { $0.countryISO?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == selectedCountry }
            .sorted { $0.timestamp > $1.timestamp }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], alignment: .leading, spacing: 12) {
                FeatureCard(title: "Located requests", value: countries.reduce(0) { $0 + $1.requestCount }.formatted(), icon: "mappin.and.ellipse")
                FeatureCard(title: "Countries", value: countries.count.formatted(), icon: "globe")
                FeatureCard(title: "Snapshot", value: records.count.formatted(), icon: "arrow.left.arrow.right")
            }

            HStack(spacing: 10) {
                Picker("Domain", selection: $selectedDomain) {
                    Text("All domains").tag("")
                    ForEach(domains, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 190, maxWidth: 360, alignment: .leading)
                Button {
                    Task { await load() }
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

            if countries.isEmpty {
                NativeEmptyState(
                    title: records.isEmpty ? "No traffic snapshot" : "No located requests",
                    message: records.isEmpty
                        ? "Refresh to load the latest retained traffic records."
                        : "The current snapshot has no requests with a supported country code."
                )
            } else {
                mapView
                countryPicker
                selectedCountryDetails
            }
        }
        .task(id: selectedDomain) { await load() }
        .onDisappear { requestGeneration = UUID() }
    }

    private var mapView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(theme.card)
            VStack(spacing: 9) {
                Image(systemName: "map")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                Text("Country codes are available; coordinates are not")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text("The traffic API returns country codes without latitude or longitude, so request markers cannot be placed on a map.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            .padding(24)
        }
        .frame(height: 250)
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(theme.divider, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Map unavailable because traffic responses include country codes but no coordinates")
    }

    private var countryPicker: some View {
        NativeGroupPanel(title: "Countries in this snapshot", subtitle: "Select a marker or country to inspect its requests") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(countries) { country in
                    Button {
                        select(country)
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
        NativeGroupPanel(title: selectedCountryName, subtitle: "Recent requests in the loaded snapshot") {
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

    private var selectedCountryName: String {
        countries.first(where: { $0.iso == selectedCountry })?.name ?? "Country focus"
    }

    private func select(_ country: TrafficMapCountry) {
        selectedCountry = country.iso
    }

    @MainActor
    private func load() async {
        let generation = UUID()
        requestGeneration = generation
        isLoading = true
        defer { if requestGeneration == generation { isLoading = false } }

        do {
            async let loadedDomains = fetchDomains()
            async let loadedPage = fetchRecords()
            let (newDomains, page) = try await (loadedDomains, loadedPage)
            guard requestGeneration == generation else { return }
            domains = newDomains
            records = page.result
            if !countries.contains(where: { $0.iso == selectedCountry }) {
                if let first = countries.first { select(first) }
                else { selectedCountry = "" }
            }
            status = "Loaded \(records.count) recent requests · \(page.total.formatted()) retained in this domain filter. Country counts describe the loaded sample."
        } catch {
            guard requestGeneration == generation else { return }
            status = "Could not load traffic map: \(error.localizedDescription)"
        }
    }

    private func fetchDomains() async throws -> [String] {
        let url = try TrafficRecentClient.domainsURL(apiBaseURL: apiBaseURL)
        let request = try TrafficRecentClient.request(url: url, userID: model.userIDForRequests, authToken: model.authTokenForRequests, impersonationToken: model.settings.impersonationToken)
        return try TrafficRecentClient.decodeDomains(await TrafficRecentClient.fetch(request))
    }

    private func fetchRecords() async throws -> TrafficRecentPage {
        let url = try TrafficRecentClient.recordsURL(apiBaseURL: apiBaseURL, domain: selectedDomain, page: 1)
        let request = try TrafficRecentClient.request(url: url, userID: model.userIDForRequests, authToken: model.authTokenForRequests, impersonationToken: model.settings.impersonationToken)
        return try TrafficRecentClient.decodePage(await TrafficRecentClient.fetch(request))
    }

    private var apiBaseURL: URL { model.settings.apiBaseURL.normalizedBaseURL }
}
