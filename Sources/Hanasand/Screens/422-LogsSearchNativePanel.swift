import AppKit
import SwiftUI

struct LogsSearchNativePanel: View {
  @EnvironmentObject private var model: DesktopAgentModel
  @Environment(\.desktopTheme) private var theme
  @State private var filters = LogsSearchFilters()
  @State private var events: [LogsSearchEvent] = []
  @State private var summaryRows: [LogsSearchSummaryRow] = []
  @State private var summarize: String?
  @State private var nextCursor: String?
  @State private var loadedFilters: LogsSearchFilters?
  @State private var errorMessage = ""
  @State private var isLoading = false
  @State private var hasLoaded = false
  @State private var requestID = UUID()
  @State private var copiedEventID = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Search logs")
          .font(.system(size: 18, weight: .bold))
          .foregroundStyle(theme.text)
        Text("Filter and page recent events by time, service, severity, log type, or HQL.")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(theme.textSecondary)
      }

      VStack(alignment: .leading, spacing: 10) {
        Toggle("Advanced HQL query", isOn: $filters.advanced)
          .toggleStyle(.checkbox)
        if filters.advanced {
          TextEditor(text: $filters.hql)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .frame(minHeight: 76, maxHeight: 150)
            .padding(5)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.divider, lineWidth: 1))
          Text("Supports where, project, order by, take, and summarize count() by. Put where before order by; take must be last.")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.textTertiary)
        }
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 10) {
            timeRangePicker
            severityPicker
            tablePicker
            Spacer(minLength: 0)
          }
          VStack(alignment: .leading, spacing: 8) {
            timeRangePicker
            severityPicker
            tablePicker
          }
        }

        ViewThatFits(in: .horizontal) {
          HStack(spacing: 10) {
            serviceField
              .frame(maxWidth: 240)
            searchField
            searchButton
          }
          VStack(alignment: .leading, spacing: 8) {
            serviceField
            searchField
            searchButton
          }
        }
      }

      HStack(spacing: 8) {
        Circle()
          .fill(errorMessage.isEmpty ? theme.green : theme.danger)
          .frame(width: 8, height: 8)
        Text(statusText)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(theme.textSecondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        if hasLoaded {
          Text(summarize.map { "\(summaryRows.count) groups · \($0)" } ?? "\(events.count) events")
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(theme.textTertiary)
        }
      }

      if let loadedFilters, loadedFilters != filters {
        NativeNotice(message: "Filters changed. Search again to apply them.", tone: .info)
      }

      if !errorMessage.isEmpty {
        NativeNotice(message: errorMessage, title: "Search failed", tone: .error)
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
          title: isLoading
            ? "Searching log events" : hasLoaded ? "No matching events" : "Search logs",
          message: isLoading
            ? "The service is searching the selected time range."
            : hasLoaded
              ? "No events matched these filters. Try a wider time range or fewer filters."
              : "Choose filters, then search your organization's processed log events."
        )
      } else {
        LazyVStack(alignment: .leading, spacing: 9) {
          ForEach(events) { event in eventRow(event) }
        }
      }

      if nextCursor != nil, loadedFilters == filters {
        HStack {
          Spacer()
          ActionButton(title: isLoading ? "Loading…" : "Load older events", icon: "arrow.down") {
            Task { await search(reset: false) }
          }
          .disabled(isLoading)
          Spacer()
        }
      }
    }
    .task(id: "\(sessionScope)|\(routeFilterScope)") {
      requestID = UUID()
      isLoading = false
      events = []
      summaryRows = []
      summarize = nil
      nextCursor = nil
      loadedFilters = nil
      hasLoaded = false
      errorMessage = ""
      filters = LogsSearchFilters.fromRouteQuery(model.selectedNativeDashboardQuery)
      await search(reset: true)
    }
  }

  private var statusText: String {
    if isLoading { return "Loading authenticated organization logs" }
    if !errorMessage.isEmpty { return "Results may be out of date" }
    if loadedFilters != nil, loadedFilters != filters { return "Filters changed · Search to apply" }
    return hasLoaded ? "Search complete" : "Ready"
  }

  private var timeRangePicker: some View {
    Picker("Time range", selection: $filters.hours) {
      Text("1 hour").tag(1)
      Text("24 hours").tag(24)
      Text("7 days").tag(168)
      Text("30 days").tag(720)
      Text("90 days").tag(2_160)
    }
    .frame(maxWidth: 190, alignment: .leading)
  }

  private var severityPicker: some View {
    Picker("Severity", selection: $filters.severity) {
      Text("All severities").tag("all")
      Text("Low").tag("low")
      Text("Medium").tag("medium")
      Text("High").tag("high")
      Text("Critical").tag("critical")
    }
    .frame(maxWidth: 190, alignment: .leading)
  }

  private var tablePicker: some View {
    Picker("Log type", selection: $filters.table) {
      Text("All log types").tag("Logs")
      ForEach(LogsSearchClient.tables.dropFirst(), id: \.self) { table in
        Text(table).tag(table)
      }
    }
    .disabled(filters.advanced)
    .frame(maxWidth: 210, alignment: .leading)
  }

  private var serviceField: some View {
    TextField("Service (optional)", text: $filters.service)
      .textFieldStyle(.roundedBorder)
  }

  private var searchField: some View {
    TextField("Search message text", text: $filters.search)
      .textFieldStyle(.roundedBorder)
      .disabled(filters.advanced)
      .onSubmit { Task { await search(reset: true) } }
  }

  private var searchButton: some View {
    ActionButton(title: isLoading ? "Searching…" : "Search", icon: "magnifyingglass") {
      Task { await search(reset: true) }
    }
    .disabled(isLoading)
  }

  @ViewBuilder
  private func eventRow(_ event: LogsSearchEvent) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(
        systemName: event.severity == "critical" || event.severity == "high"
          ? "exclamationmark.triangle.fill" : "text.alignleft"
      )
      .font(.system(size: 14, weight: .bold))
      .foregroundStyle(
        event.severity == "critical" || event.severity == "high"
          ? theme.danger : theme.accent
      )
      .frame(width: 28, height: 28)
      .background(theme.cardRaised)
      .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

      VStack(alignment: .leading, spacing: 5) {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 7) { eventHeading(event) }
          VStack(alignment: .leading, spacing: 3) { eventHeading(event) }
        }
        .font(.system(size: 11, weight: .bold))
        Text(event.message.isEmpty ? "No message" : event.message)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(theme.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
        Text(event.timestamp)
          .font(.system(size: 10, weight: .medium, design: .monospaced))
          .foregroundStyle(theme.textTertiary)
          .lineLimit(1)
        detectionLinks(event.detectionPresentation)
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

  @ViewBuilder
  private func eventHeading(_ event: LogsSearchEvent) -> some View {
    Text(event.severity.uppercased()).foregroundStyle(
      event.severity == "critical" || event.severity == "high" ? theme.danger : theme.textTertiary)
    Text(event.service).foregroundStyle(theme.text)
    if !event.host.isEmpty { Text(event.host).foregroundStyle(theme.textTertiary).lineLimit(1) }
    if !event.type.isEmpty { Text(event.type).foregroundStyle(theme.textTertiary).lineLimit(1) }
  }

  @ViewBuilder
  private func detectionLinks(_ presentation: LogsDetectionPresentation) -> some View {
    LogsDetectionLinks(presentation: presentation)
  }

  @MainActor
  private func search(reset: Bool) async {
    guard !isLoading else { return }
    let request = UUID()
    requestID = request
    isLoading = true
    defer { if requestID == request { isLoading = false } }
    if reset {
      events = []
      summaryRows = []
      summarize = nil
      nextCursor = nil
      loadedFilters = nil
      errorMessage = ""
    }
    do {
      let activeFilters = filters
      let client = try LogsSearchClient(
        apiBaseURL: model.settings.apiBaseURL.normalizedBaseURL,
        userID: model.settings.userID,
        token: model.settings.authToken,
        impersonationToken: model.settings.impersonationToken,
        impersonatingUserID: model.settings.impersonatingUserID
      )
      let page = try await client.load(filters: activeFilters, cursor: reset ? nil : nextCursor)
      guard requestID == request, !Task.isCancelled else { return }
      summarize = page.summarize
      summaryRows = page.summaryRows
      var seen = Set(events.map(\.id))
      events = (events + page.rows).filter { seen.insert($0.id).inserted }.prefix(600).map { $0 }
      nextCursor = page.nextCursor
      loadedFilters = activeFilters
      hasLoaded = true
      errorMessage = ""
    } catch {
      guard requestID == request, !Task.isCancelled else { return }
      errorMessage = error.localizedDescription
      if reset { hasLoaded = false }
    }
  }

  private var sessionScope: String {
    "\(model.settings.apiBaseURL)|\(model.settings.userID)|\(model.settings.authToken.hashValue)|\(model.settings.impersonationToken.hashValue)|\(model.settings.impersonatingUserID)"
  }

  private var routeFilterScope: String {
    let keys = ["hours", "service", "search", "severity", "table", "hql", "kql"]
    return keys.map { "\($0)=\(model.selectedNativeDashboardQuery[$0] ?? "")" }.joined(separator: "&")
  }
}

struct LogsDetectionLinks: View {
  @EnvironmentObject private var model: DesktopAgentModel
  @Environment(\.desktopTheme) private var theme
  let presentation: LogsDetectionPresentation

  private let columns = [GridItem(.adaptive(minimum: 148, maximum: 280), alignment: .leading)]

  var body: some View {
    if !presentation.detections.isEmpty || presentation.additionalCount > 0 {
      VStack(alignment: .leading, spacing: 6) {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
          ForEach(presentation.detections) { detection in
            Button {
              model.openNativeDashboard(
                path: "/rules/detail", label: "Rule: \(detection.summary)", detailID: detection.ruleID)
            } label: {
              Label(detection.summary, systemImage: "arrow.up.right.square")
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(theme.cardRaised)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.accent)
            .accessibilityLabel("Open matched rule: \(detection.summary)")
          }
        }
        if presentation.additionalCount > 0 {
          Text("\(presentation.additionalCount) additional match\(presentation.additionalCount == 1 ? "" : "es")")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(theme.textTertiary)
            .accessibilityLabel("\(presentation.additionalCount) additional log matches omitted")
        }
      }
    }
  }
}
