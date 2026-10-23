import SwiftUI

struct LogsRealtimeNativePanel: View {
  @EnvironmentObject private var model: DesktopAgentModel
  @Environment(\.desktopTheme) private var theme
  @State private var events: [LogsRealtimeEvent] = []
  @State private var errorMessage = ""
  @State private var connectionStatus = "Connecting"
  @State private var lastUpdated: Date?
  @State private var isRefreshing = false

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
        Text("\(events.count) / \(LogsRealtimeClient.retainedLimit)")
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
          .foregroundStyle(theme.textTertiary)
      }

      if !errorMessage.isEmpty {
        NativeNotice(
          message: errorMessage,
          title: lastUpdated == nil ? "Connection failed" : "Showing saved results", tone: .error)
      }

      if events.isEmpty {
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
    }
    .task { await poll() }
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
      await refresh(using: client)
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
    await refresh(using: client)
  }

  @MainActor
  private func refresh(using client: LogsRealtimeClient) async {
    guard !isRefreshing else { return }
    isRefreshing = true
    if lastUpdated == nil { connectionStatus = "Connecting" }
    defer { isRefreshing = false }
    do {
      let page = try await client.load()
      var seen = Set<String>()
      events = (page.rows + events).filter { seen.insert($0.id).inserted }.prefix(
        LogsRealtimeClient.retainedLimit
      ).map { $0 }
      lastUpdated = Date()
      errorMessage = ""
      connectionStatus = "Live · polling every 10 seconds"
    } catch {
      errorMessage = error.localizedDescription
      connectionStatus = "Disconnected · retrying in 10 seconds"
    }
  }
}
