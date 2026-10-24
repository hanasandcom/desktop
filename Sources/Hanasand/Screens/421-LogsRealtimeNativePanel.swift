import AppKit
import SwiftUI

struct LogsRealtimeNativePanel: View {
  @EnvironmentObject private var model: DesktopAgentModel
  @Environment(\.desktopTheme) private var theme
  @State private var events: [LogsRealtimeEvent] = []
  @State private var summaryRows: [LogsSearchSummaryRow] = []
  @State private var summarize: String?
  @State private var filters = LogsRealtimeFilters()
  @State private var appliedFilters = LogsRealtimeFilters()
  @State private var nextCursor: String?
  @State private var totalEvents: Int?
  @State private var browsingOlder = false
  @State private var errorMessage = ""
  @State private var connectionStatus = "Connecting"
  @State private var lastUpdated: Date?
  @State private var isRefreshing = false
  @State private var requestID = UUID()
  @State private var copiedEventID = ""
  @State private var pollGeneration = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Realtime logs")
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(theme.text)
          Text("High and critical events · refreshes every 10 seconds")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(theme.textSecondary)
        }
        Spacer(minLength: 8)
        ActionButton(title: isRefreshing ? "Refreshing" : "Refresh", icon: "arrow.clockwise") {
          Task { await refresh() }
        }
        .disabled(isRefreshing)
      }

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) { timeRangePicker; tablePicker; serviceField; searchField; applyFiltersButton }
        VStack(alignment: .leading, spacing: 8) { timeRangePicker; tablePicker; serviceField; searchField; applyFiltersButton }
      }
      Toggle("Advanced HQL query", isOn: $filters.advanced)
        .toggleStyle(.checkbox)
      if filters.advanced {
        TextEditor(text: $filters.hql)
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .frame(minHeight: 64, maxHeight: 130)
          .padding(5)
          .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.divider, lineWidth: 1))
        Text("Realtime HQL still limits results to high and critical events. Cursor paging is available in standard mode.")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(theme.textTertiary)
      }

      HStack(spacing: 8) {
        Circle()
          .fill(errorMessage.isEmpty ? theme.green : theme.accent)
          .frame(width: 8, height: 8)
        Text(statusText)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(theme.textSecondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        Text("\(events.count)\(totalEvents.map { " / \($0)" } ?? "")")
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
          .foregroundStyle(theme.textTertiary)
      }

      if !errorMessage.isEmpty {
        NativeNotice(
          message: errorMessage,
          title: lastUpdated == nil ? "Connection failed" : "Showing saved results", tone: .error)
      }

      if let summarize {
        NativeGroupPanel(title: "Summary by \(summarize)", subtitle: "Counts for the selected time range and filters") {
          if summaryRows.isEmpty {
            NativeEmptyState(title: "No matching groups", message: "The query completed without matching summary rows.")
          } else {
            ForEach(Array(summaryRows.enumerated()), id: \.offset) { _, row in
              HStack(spacing: 10) {
                Text(row.value.isEmpty ? "(empty)" : row.value)
                  .font(.system(size: 12, weight: .medium, design: .monospaced))
                  .foregroundStyle(theme.text)
                  .lineLimit(2)
                  .textSelection(.enabled)
                Spacer(minLength: 4)
                Text(row.count.formatted())
                  .font(.system(size: 12, weight: .semibold, design: .monospaced))
                  .foregroundStyle(theme.textSecondary)
              }
              .padding(.vertical, 4)
            }
          }
        }
      } else if events.isEmpty {
        NativeEmptyState(
          title: isRefreshing ? "Loading recent events" : "No high severity events",
          message: isRefreshing
            ? "The log service is checking the last 24 hours."
            : "No high or critical log events were returned in the last 24 hours."
        )
      } else {
        LazyVStack(alignment: .leading, spacing: 9) {
          ForEach(events) { event in eventRow(event) }
        }
      }
      if nextCursor != nil {
        HStack {
          Spacer()
          ActionButton(title: isRefreshing ? "Loading…" : "Load older events", icon: "arrow.down") {
            Task { await loadOlder() }
          }
          .disabled(isRefreshing)
          Spacer()
        }
      }
    }
    .task(id: taskScope) {
      requestID = UUID()
      isRefreshing = false
      events = []
      summaryRows = []
      summarize = nil
      nextCursor = nil
      totalEvents = nil
      browsingOlder = false
      lastUpdated = nil
      errorMessage = ""
      filters = LogsRealtimeFilters.fromRouteQuery(model.selectedNativeDashboardQuery)
      appliedFilters = filters
      await poll()
    }
  }

  private var timeRangePicker: some View {
    Picker("Time range", selection: $filters.hours) {
      Text("1 hour").tag(1)
      Text("24 hours").tag(24)
      Text("7 days").tag(168)
      Text("30 days").tag(720)
      Text("90 days").tag(2_160)
    }
    .frame(maxWidth: 160, alignment: .leading)
  }

  private var tablePicker: some View {
    Picker("Log type", selection: $filters.table) {
      Text("All log types").tag("Logs")
      ForEach(LogsSearchClient.tables.dropFirst(), id: \.self) { table in
        Text(table).tag(table)
      }
    }
    .disabled(filters.advanced)
    .frame(maxWidth: 190, alignment: .leading)
  }

  private var serviceField: some View {
    TextField("Service (optional)", text: $filters.service)
      .textFieldStyle(.roundedBorder)
      .frame(minWidth: 150, maxWidth: 240)
  }

  private var searchField: some View {
    TextField("Search messages", text: $filters.search)
      .textFieldStyle(.roundedBorder)
      .disabled(filters.advanced)
      .onSubmit { applyFilters() }
  }

  private var applyFiltersButton: some View {
    ActionButton(title: "Apply filters", icon: "line.3.horizontal.decrease.circle") {
      applyFilters()
    }
  }

  private func applyFilters() {
    events = []
    summaryRows = []
    summarize = nil
    nextCursor = nil
    totalEvents = nil
    browsingOlder = false
    errorMessage = ""
    appliedFilters = filters
    pollGeneration += 1
  }

  private var statusText: String {
    guard let lastUpdated else { return connectionStatus }
    let age = Date().timeIntervalSince(lastUpdated)
    let ageLabel = age < 60 ? "just now" : "\(Int(age / 60))m ago"
    return errorMessage.isEmpty ? "Updated \(ageLabel)" : "Stale · last updated \(ageLabel)"
  }

  @ViewBuilder
  private func eventRow(_ event: LogsRealtimeEvent) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(
        systemName: event.severity == "critical"
          ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
      )
      .font(.system(size: 14, weight: .bold))
      .foregroundStyle(theme.danger)
      .frame(width: 28, height: 28)
      .background(theme.cardRaised)
      .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 7) {
          Text(event.severity.uppercased())
            .foregroundStyle(theme.danger)
          Text(event.service)
            .foregroundStyle(theme.text)
          if !event.host.isEmpty {
            Text(event.host)
              .foregroundStyle(theme.textTertiary)
              .lineLimit(1)
          }
        }
        .font(.system(size: 11, weight: .bold))
        .lineLimit(1)
        Text(event.message.isEmpty ? "No message" : event.message)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(theme.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
        Text(event.timestamp)
          .font(.system(size: 10, weight: .medium, design: .monospaced))
          .foregroundStyle(theme.textTertiary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(event.copyJSON, forType: .string)
        copiedEventID = event.id
      } label: {
        Image(systemName: copiedEventID == event.id ? "checkmark" : "doc.on.doc")
          .foregroundStyle(theme.textTertiary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(copiedEventID == event.id ? "Copied log JSON" : "Copy log JSON")
      .help("Copy event JSON")
    }
    .padding(11)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(theme.card)
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.divider, lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private func poll() async {
    let client: LogsRealtimeClient
    do {
      client = try LogsRealtimeClient(
        apiBaseURL: model.settings.apiBaseURL.normalizedBaseURL,
        userID: model.settings.userID,
        token: model.settings.authToken,
        impersonationToken: model.settings.impersonationToken,
        impersonatingUserID: model.settings.impersonatingUserID
      )
    } catch {
      errorMessage = error.localizedDescription
      connectionStatus = "Disconnected"
      return
    }

    while !Task.isCancelled {
      await refresh(using: client, filters: appliedFilters)
      do { try await Task.sleep(for: LogsRealtimeClient.refreshInterval) } catch { return }
    }
  }

  @MainActor
  private func refresh() async {
    let client: LogsRealtimeClient
    do {
      client = try LogsRealtimeClient(
        apiBaseURL: model.settings.apiBaseURL.normalizedBaseURL,
        userID: model.settings.userID,
        token: model.settings.authToken,
        impersonationToken: model.settings.impersonationToken,
        impersonatingUserID: model.settings.impersonatingUserID
      )
    } catch {
      errorMessage = error.localizedDescription
      connectionStatus = "Disconnected"
      return
    }
    await refresh(using: client, filters: appliedFilters)
  }

  @MainActor
  private func refresh(using client: LogsRealtimeClient, filters: LogsRealtimeFilters) async {
    guard !isRefreshing else { return }
    let request = UUID()
    requestID = request
    isRefreshing = true
    if lastUpdated == nil { connectionStatus = "Connecting" }
    defer { if requestID == request { isRefreshing = false } }
    do {
      let page = try await client.load(filters: filters)
      guard requestID == request, !Task.isCancelled else { return }
      var seen = Set<String>()
      events = (page.rows + events).filter { seen.insert($0.id).inserted }.prefix(LogsRealtimeClient.retainedLimit).map { $0 }
      summarize = page.summarize
      summaryRows = page.summaryRows
      if !browsingOlder { nextCursor = page.nextCursor }
      totalEvents = page.totalEvents
      lastUpdated = Date()
      errorMessage = ""
      connectionStatus = "Live · polling every 10 seconds"
    } catch {
      guard requestID == request, !Task.isCancelled else { return }
      errorMessage = error.localizedDescription
      connectionStatus = "Disconnected · retrying in 10 seconds"
    }
  }

  @MainActor
  private func loadOlder() async {
    guard !isRefreshing, let cursor = nextCursor else { return }
    let client: LogsRealtimeClient
    do {
      client = try LogsRealtimeClient(
        apiBaseURL: model.settings.apiBaseURL.normalizedBaseURL,
        userID: model.settings.userID,
        token: model.settings.authToken,
        impersonationToken: model.settings.impersonationToken,
        impersonatingUserID: model.settings.impersonatingUserID
      )
    } catch {
      errorMessage = error.localizedDescription
      return
    }
    let request = UUID()
    requestID = request
    isRefreshing = true
    defer { if requestID == request { isRefreshing = false } }
    do {
      let page = try await client.load(filters: appliedFilters, cursor: cursor)
      guard requestID == request, !Task.isCancelled else { return }
      var seen = Set(events.map(\.id))
      events = (events + page.rows).filter { seen.insert($0.id).inserted }.prefix(LogsRealtimeClient.retainedLimit).map { $0 }
      nextCursor = page.nextCursor
      browsingOlder = true
      totalEvents = page.totalEvents ?? totalEvents
      lastUpdated = Date()
      errorMessage = ""
    } catch {
      guard requestID == request, !Task.isCancelled else { return }
      errorMessage = error.localizedDescription
    }
  }

  private var sessionScope: String {
    "\(model.settings.apiBaseURL)|\(model.settings.userID)|\(model.settings.authToken.hashValue)|\(model.settings.impersonationToken.hashValue)|\(model.settings.impersonatingUserID)"
  }

  private var taskScope: String {
    "\(sessionScope)|\(routeFilterScope)|\(pollGeneration)"
  }

  private var routeFilterScope: String {
    let keys = ["hours", "service", "search", "table", "hql", "kql"]
    return keys.map { "\($0)=\(model.selectedNativeDashboardQuery[$0] ?? "")" }.joined(separator: "&")
  }
}
