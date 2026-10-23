import SwiftUI

struct ThreatDeliveryHistoryNativePanel: View {
    private let statusFilters: [ThreatDeliveryStatus] = [.delivered, .failed, .dryRun, .skipped]
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var history: ThreatDeliveryHistory?
    @State private var status = "Select an organization to review delivery history."
    @State private var search = ""
    @State private var selectedStatus: ThreatDeliveryStatus?
    @State private var visibleLimit = 30
    @State private var isLoading = false
    @State private var loadID = UUID()

    private var filtered: [ThreatDeliveryHistory.Attempt] {
        guard let attempts = history?.deliveries else { return [] }
        return attempts.filter { attempt in
            (selectedStatus == nil || attempt.status == selectedStatus)
                && searchPartsMatch(attempt)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                SearchFieldRow(placeholder: "Search finding ID, delivery ID, or event", text: $search)
                    .frame(minWidth: 0, maxWidth: .infinity)
                ActionButton(title: "Refresh", icon: "arrow.clockwise") { Task { await refresh() } }
                    .disabled(isLoading)
            }

            NativeGroupPanel(title: "Delivery history", subtitle: "Organization webhook and Discord attempts · latest 100") {
                Text("History is read-only here. Configure destinations in Integrations.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isLoading {
                    ProgressView(status).frame(maxWidth: .infinity, alignment: .leading)
                } else if history == nil {
                    NativeEmptyState(title: "Delivery history unavailable", message: status)
                } else if history?.deliveries.isEmpty == true {
                    NativeEmptyState(title: "No delivery attempts", message: "The selected organization has no retained delivery attempts.")
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            FilterChip(title: "All · \(history?.deliveries.count ?? 0)", active: selectedStatus == nil) {
                                selectedStatus = nil
                            }
                            ForEach(statusFilters, id: \.rawValue) { (value: ThreatDeliveryStatus) in
                                FilterChip(title: "\(value.statusLabel) · \(count(value))", active: selectedStatus == value) {
                                    selectedStatus = value
                                }
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }

                    if filtered.isEmpty {
                        NativeEmptyState(title: "No matching attempts", message: "Clear the search field or select another status.")
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                            ForEach(filtered.prefix(visibleLimit)) { attempt in attemptCard(attempt) }
                        }
                        if filtered.count > visibleLimit {
                            ActionButton(title: "Show 30 more", icon: "plus") { visibleLimit += 30 }
                        }
                        Text("Showing \(min(filtered.count, visibleLimit)) of \(filtered.count) matching attempts")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            }
        }
        .task(id: scopeKey) { await refresh() }
    }

    private var scopeKey: String {
        [model.settings.selectedOrganizationID, model.settings.selectedOrganizationUserID,
         model.settings.userID, model.settings.impersonatingUserID,
         model.settings.impersonationToken.isEmpty ? "own-account" : "impersonating"].joined(separator: "|")
    }

    private func refresh() async {
        let current = UUID()
        loadID = current
        history = nil
        visibleLimit = 30
        isLoading = true
        let requestedSettings = model.settings
        defer { if loadID == current { isLoading = false } }
        do {
            let client = try ThreatDeliveryHistoryClient(settings: requestedSettings)
            let result = try await client.load()
            guard !Task.isCancelled, loadID == current,
                  model.settings == requestedSettings,
                  model.settings.selectedOrganizationID == result.organizationID,
                  model.settings.selectedOrganizationUserID == model.settings.userID else { return }
            history = result
            status = result.deliveries.isEmpty ? "No retained delivery attempts." : "Loaded \(result.deliveries.count) delivery attempts."
        } catch {
            guard !Task.isCancelled, loadID == current else { return }
            status = (error as? LocalizedError)?.errorDescription ?? "Delivery history could not be loaded. Refresh to try again."
        }
    }

    private func count(_ value: ThreatDeliveryStatus) -> Int {
        history?.deliveries.filter { $0.status == value }.count ?? 0
    }

    private func searchPartsMatch(_ attempt: ThreatDeliveryHistory.Attempt) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return [attempt.alertId, attempt.id, attempt.eventType, attempt.statusLabel]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private func attemptCard(_ attempt: ThreatDeliveryHistory.Attempt) -> some View {
        NativeGroupPanel(title: attempt.statusLabel, subtitle: attempt.displayDate) {
            HStack(spacing: 8) {
                Label(attempt.dryRun ? "Dry run" : attempt.eventType.isEmpty ? "Delivery event" : attempt.eventType,
                      systemImage: attempt.dryRun ? "checkmark.shield" : "paperplane")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                Spacer(minLength: 0)
                if let attemptCount = attempt.attemptCount {
                    Text("\(attemptCount) \(attemptCount == 1 ? "attempt" : "attempts")")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            metadata(label: "Finding", value: compactID(attempt.alertId))
            metadata(label: "Delivery", value: compactID(attempt.id))
        }
    }

    private func metadata(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(theme.textSecondary)
            Spacer(minLength: 4)
            Text(value).foregroundStyle(theme.text).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
    }

    private func compactID(_ value: String) -> String {
        value.count > 20 ? "…\(value.suffix(16))" : value
    }
}
