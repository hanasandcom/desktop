import AppKit
import SwiftUI

struct LogErrorsNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var filters = LogErrorsFilters()
    @State private var loadedFilters: LogErrorsFilters?
    @State private var envelope: LogErrorsEnvelope?
    @State private var errorMessage = ""
    @State private var statusMessage = ""
    @State private var isLoading = false
    @State private var expandedIDs = Set<String>()
    @State private var requestID = UUID()

    private let statusOptions: [(String, Int?)] = [
        ("All status codes", nil), ("400", 400), ("401", 401), ("403", 403), ("404", 404),
        ("429", 429), ("500", 500), ("502", 502), ("503", 503),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            filterControls

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !errorMessage.isEmpty {
                NativeNotice(message: errorMessage, title: "Error history unavailable", tone: .error)
            }
            if let envelope {
                if envelope.summaryAvailable == false || envelope.summary == nil {
                    NativeNotice(
                        message: envelope.summaryWarning ?? envelope.warnings.first ?? "Historical error totals are unavailable. Recent error records remain available.",
                        title: "Summary unavailable", tone: .info)
                }
                if let summary = envelope.summary, envelope.summaryAvailable != false {
                    summaryCards(summary)
                    breakdown(summary)
                }
                eventList(envelope.errors)
            } else if isLoading {
                NativeEmptyState(title: "Loading application errors", message: "Requesting recent API, authentication, and website errors.")
            } else if errorMessage.isEmpty {
                NativeEmptyState(title: "Review application errors", message: "Refresh to load recent errors from API, authentication, and website activity.")
            }
        }
        .task(id: sessionScope) {
            envelope = nil
            loadedFilters = nil
            expandedIDs = []
            errorMessage = ""
            statusMessage = ""
            await refresh()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Errors")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(theme.text)
                Text("Recent API, authentication, and website errors · up to \(LogErrorsClient.pageSize) records")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            ActionButton(title: isLoading ? "Refreshing…" : "Refresh errors", icon: "arrow.clockwise") {
                Task { await refresh() }
            }
            .disabled(isLoading)
        }
    }

    private var filterControls: some View {
        NativeGroupPanel(title: "Filters", subtitle: "Narrow the recent error list") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 9) {
                    surfaceField
                    statusPicker
                    errorCodeField
                }
                VStack(alignment: .leading, spacing: 8) {
                    surfaceField
                    statusPicker
                    errorCodeField
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 9) { queryField; includeExpectedToggle; searchButton }
                VStack(alignment: .leading, spacing: 8) { queryField; includeExpectedToggle; searchButton }
            }
            if let loadedFilters, loadedFilters != filters {
                NativeNotice(message: "Filters changed. Search to apply them.", tone: .info)
            }
        }
    }

    private var surfaceField: some View {
        TextField("Surface (optional)", text: $filters.surface)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 110, maxWidth: 220)
    }

    private var statusPicker: some View {
        Picker("Status", selection: $filters.statusCode) {
            ForEach(Array(statusOptions.enumerated()), id: \.offset) { _, option in
                Text(option.0).tag(option.1)
            }
        }
        .frame(minWidth: 140, maxWidth: 220)
    }

    private var errorCodeField: some View {
        TextField("Error code (optional)", text: $filters.errorCode)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 130, maxWidth: 260)
    }

    private var queryField: some View {
        TextField("Search message, path, or metadata", text: $filters.query)
            .textFieldStyle(.roundedBorder)
            .onSubmit { Task { await refresh() } }
    }

    private var includeExpectedToggle: some View {
        Toggle("Include expected probes", isOn: $filters.includeExpected)
            .toggleStyle(.checkbox)
            .fixedSize()
    }

    private var searchButton: some View {
        ActionButton(title: isLoading ? "Searching…" : "Apply filters", icon: "magnifyingglass") {
            Task { await refresh() }
        }
        .disabled(isLoading)
    }

    @ViewBuilder
    private func summaryCards(_ summary: LogErrorsSummary) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 155, maximum: 260), spacing: 10)], alignment: .leading, spacing: 10) {
            FeatureCard(title: "Errors", value: summary.total.formatted(), icon: "ladybug")
            FeatureCard(title: "Last hour", value: summary.lastHour.formatted(), icon: "clock")
            FeatureCard(title: "Server errors", value: summary.serverErrors.formatted(), icon: "exclamationmark.triangle")
            FeatureCard(title: "Client errors", value: summary.clientErrors.formatted(), icon: "shield.lefthalf.filled")
        }
    }

    @ViewBuilder
    private func breakdown(_ summary: LogErrorsSummary) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                breakdownCard("Top error codes", summary.codeCounts)
                breakdownCard("Top surfaces", summary.surfaceCounts)
            }
            VStack(alignment: .leading, spacing: 10) {
                breakdownCard("Top error codes", summary.codeCounts)
                breakdownCard("Top surfaces", summary.surfaceCounts)
            }
        }
    }

    private func breakdownCard(_ title: String, _ rows: [LogErrorCount]) -> some View {
        NativeGroupPanel(title: title, subtitle: rows.isEmpty ? "No errors in this window" : "Most frequent in the summary window") {
            if rows.isEmpty {
                Text("No records")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            } else {
                ForEach(Array(rows.prefix(8).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 10) {
                        Text(row.label)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(theme.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 4)
                        Text(row.count.formatted())
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func eventList(_ events: [LogErrorEvent]) -> some View {
        NativeGroupPanel(title: "Recent errors", subtitle: "Showing \(events.count) records · refreshed \(envelope?.generatedAt ?? "unknown")") {
            if events.isEmpty {
                NativeEmptyState(title: "No errors found", message: "No tracked errors matched the current filters.")
            } else {
                LazyVStack(alignment: .leading, spacing: 9) {
                    ForEach(events) { event in eventRow(event) }
                }
            }
        }
    }

    private func eventRow(_ event: LogErrorEvent) -> some View {
        let isOpen = expandedIDs.contains(event.id)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: (event.statusCode ?? 0) >= 500 ? "exclamationmark.triangle.fill" : "shield.lefthalf.filled")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle((event.statusCode ?? 0) >= 500 ? theme.danger : theme.accent)
                    .frame(width: 28, height: 28)
                    .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Button {
                            if isOpen { expandedIDs.remove(event.id) } else { expandedIDs.insert(event.id) }
                        } label: {
                            Text(event.errorCode ?? "uncategorized")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(theme.text)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .textSelection(.enabled)
                        }
                        .buttonStyle(.plain)
                        if let status = event.statusCode {
                            Text(String(status))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(status >= 500 ? theme.danger : theme.textSecondary)
                        }
                        Spacer(minLength: 0)
                        Button {
                            copy(event.prettyJSON)
                        } label: {
                            Label("Copy JSON", systemImage: "doc.on.doc")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                        .help("Copy full error record as JSON")
                    }
                    Text(event.message.flatMap { $0.isEmpty ? nil : $0 } ?? "No message")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { eventMetadata(event) }
                        VStack(alignment: .leading, spacing: 3) { eventMetadata(event) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if isOpen {
                ScrollView([.vertical, .horizontal]) {
                    Text(event.prettyJSON)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                }
                .frame(maxHeight: 260)
                .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.divider, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func eventMetadata(_ event: LogErrorEvent) -> some View {
        Text([event.createdAt, event.surface ?? event.source, event.method.map { "\($0) \(event.path ?? "")" }, event.userID.map { "User: \($0)" }]
            .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(theme.textTertiary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var sessionScope: String {
        "\(model.settings.apiBaseURL)|\(model.settings.userID)|\(model.settings.authToken.hashValue)|\(model.settings.impersonationToken.hashValue)|\(model.settings.impersonatingUserID)"
    }

    @MainActor
    private func refresh() async {
        let request = UUID()
        requestID = request
        isLoading = true
        statusMessage = ""
        defer { if requestID == request { isLoading = false } }
        do {
            let client = try LogErrorsClient(
                apiBaseURL: model.settings.apiBaseURL.normalizedBaseURL,
                userID: model.settings.userID,
                token: model.settings.authToken,
                impersonationToken: model.settings.impersonationToken,
                impersonatingUserID: model.settings.impersonatingUserID)
            let result = try await client.load(filters: filters)
            guard requestID == request, !Task.isCancelled else { return }
            envelope = result
            loadedFilters = filters
            expandedIDs = []
            errorMessage = ""
            statusMessage = "Updated \(result.generatedAt) · API access requires an active Hanasand owner or editor role."
        } catch {
            guard requestID == request, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            statusMessage = envelope.map { "Showing last successful result from \($0.generatedAt)." } ?? ""
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = "Error record copied as JSON."
    }
}
