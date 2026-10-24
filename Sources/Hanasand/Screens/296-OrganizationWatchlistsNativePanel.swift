import AppKit
import ApplicationServices
import Combine
import CryptoKit
import Darwin
import Foundation
import Network
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

private struct PendingOrganizationWatchlistAction: Identifiable {
    let item: OrganizationWatchlistItem
    let action: String
    var id: String { "\(action):\(item.id)" }
}

struct OrganizationWatchlistsNativePanel: View {
    let initialOrganizationID: String?

    init(initialOrganizationID: String? = nil) {
        self.initialOrganizationID = initialOrganizationID?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var pending: PendingOrganizationWatchlistAction?
    @State private var initialOrganizationResolved = false
    @State private var initialOrganizationError = ""
    @State private var cleanupSelection = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let initialOrganizationID, !initialOrganizationID.isEmpty,
               model.selectedOrganizationID != initialOrganizationID,
               initialOrganizationResolved, !initialOrganizationError.isEmpty {
                NativeEmptyState(title: "Organization link unavailable", message: initialOrganizationError)
                ActionButton(title: "Open organization directory", icon: "building.2") {
                    model.openNativeDashboard(path: "/organizations", label: "Organizations")
                }
            } else if !initialOrganizationResolved
                || (initialOrganizationID?.isEmpty == false && model.selectedOrganizationID != initialOrganizationID) {
                NativeEmptyState(title: "Opening organization watchlists", message: "Validating the organization link before loading its watch terms.")
            } else if model.selectedOrganizationID.isEmpty {
                NativeEmptyState(title: "Select an organization", message: "Watchlists belong to an organization. Select an active organization in the directory before viewing or changing its terms.")
                ActionButton(title: "Open organization directory", icon: "building.2") {
                    model.openNativeDashboard(path: "/organizations", label: "Organizations")
                }
            } else {
                NativeGroupPanel(title: model.organizationWatchlistPage?.organization.name ?? "Organization watchlists", subtitle: "Organization \(model.selectedOrganizationID)") {
                    HStack(spacing: 8) {
                        ActionButton(title: "Refresh", icon: "arrow.clockwise") { Task { await model.loadOrganizationWatchlists() } }
                            .disabled(model.isLoadingOrganizationWatchlists || model.isMutatingOrganizationWatchlists)
                        ActionButton(title: model.isMutatingOrganizationWatchlists ? "Saving…" : "Add watch term", icon: "plus") {
                            model.beginOrganizationWatchlistEdit(nil)
                        }
                        .disabled(!model.canWriteSelectedOrganizationWatchlists || model.isMutatingOrganizationWatchlists)
                    }
                    if !model.organizationWatchlistStatus.isEmpty {
                        Text(model.organizationWatchlistStatus).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary).textSelection(.enabled)
                    }
                }

                if model.organizationWatchlistFormPresented {
                    editForm
                }

                if model.organizationWatchlistPage != nil {
                    NativeGroupPanel(title: "Watch terms", subtitle: "Search and filter the selected organization") {
                        SearchFieldRow(placeholder: "Term, type, or notes", text: $model.organizationWatchlistSearch)
                        HStack(spacing: 8) {
                            ForEach(["all", "active", "paused", "archived"], id: \.self) { value in
                                FilterChip(title: value == "all" ? "All states" : value.capitalized, active: model.organizationWatchlistStatusFilter == value) { model.organizationWatchlistStatusFilter = value }
                            }
                        }
                        if model.isLoadingOrganizationWatchlists && model.filteredOrganizationWatchlists.isEmpty {
                            NativeEmptyState(title: "Loading watchlists", message: "Retrieving terms for the selected organization.")
                        } else if model.filteredOrganizationWatchlists.isEmpty {
                            NativeEmptyState(title: "No matching watch terms", message: "Try another search or state filter.")
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                                ForEach(model.filteredOrganizationWatchlists) { item in itemCard(item) }
                            }
                        }
                    }

                    maintenancePanel
                }
            }
        }
        .task(id: initialOrganizationID) {
            guard let initialOrganizationID, !initialOrganizationID.isEmpty else {
                initialOrganizationError = ""
                initialOrganizationResolved = true
                return
            }
            initialOrganizationResolved = false
            initialOrganizationError = ""
            if initialOrganizationID == model.selectedOrganizationID {
                initialOrganizationResolved = true
                return
            }
            guard await model.selectOrganizationFromDeepLink(initialOrganizationID),
                  model.selectedOrganizationID == initialOrganizationID else {
                initialOrganizationError = model.organizationDirectoryError.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "This link does not target an active organization you can access."
                initialOrganizationResolved = true
                return
            }
            initialOrganizationResolved = true
            await model.loadOrganizationWatchlists()
        }
        .onChange(of: model.selectedOrganizationID) { _, _ in Task { await model.loadOrganizationWatchlists() } }
        .confirmationDialog(pending?.action == "archive" ? "Archive watch term?" : "Pause watch term?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button(pending?.action == "archive" ? "Archive" : "Pause", role: .destructive) {
                guard let change = pending else { return }
                pending = nil
                Task { await model.changeOrganizationWatchlist(change.item, action: change.action) }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { Text(pending?.item.value ?? "") }
    }

    private var editForm: some View {
        NativeGroupPanel(title: model.organizationWatchlistEditingID.isEmpty ? "Add watch term" : "Edit watch term", subtitle: "Saved terms are scoped to the selected organization") {
            Picker("Type", selection: $model.organizationWatchlistDraftKind) {
                ForEach(OrganizationWatchlistKind.allCases, id: \.self) { kind in Text(kind.rawValue.capitalized).tag(kind) }
            }
            .pickerStyle(.segmented)
            TextField("Term", text: $model.organizationWatchlistDraftValue).textFieldStyle(.roundedBorder)
            TextField("Notes (optional)", text: $model.organizationWatchlistDraftNotes, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                ActionButton(title: model.isMutatingOrganizationWatchlists ? "Saving…" : "Save term", icon: "checkmark") {
                    Task { await model.saveOrganizationWatchlistDraft() }
                }
                .disabled(!model.canWriteSelectedOrganizationWatchlists || model.isMutatingOrganizationWatchlists || model.organizationWatchlistDraftValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                ActionButton(title: "Cancel", icon: "xmark") { model.cancelOrganizationWatchlistEdit() }
                    .disabled(model.isMutatingOrganizationWatchlists)
            }
        }
    }

    private func itemCard(_ item: OrganizationWatchlistItem) -> some View {
        NativeGroupPanel(title: item.value, subtitle: "\(item.kind.rawValue.capitalized) · \(item.status.rawValue.capitalized)") {
            if !item.notes.isEmpty { Text(item.notes).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary).textSelection(.enabled) }
            Text("Item \(item.id) · Updated \(item.updatedAt.isEmpty ? "not reported" : item.updatedAt)")
                .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(theme.textTertiary).textSelection(.enabled)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { itemActions(item) }
                VStack(alignment: .leading, spacing: 8) { itemActions(item) }
            }
        }
    }

    @ViewBuilder private func itemActions(_ item: OrganizationWatchlistItem) -> some View {
        if item.status != .archived {
            ActionButton(title: "Edit", icon: "pencil") { model.beginOrganizationWatchlistEdit(item) }
                .disabled(!model.canWriteSelectedOrganizationWatchlists || model.isMutatingOrganizationWatchlists)
        }
        if item.status == .active {
            ActionButton(title: "Pause", icon: "pause") { pending = PendingOrganizationWatchlistAction(item: item, action: "pause") }
                .disabled(!model.canWriteSelectedOrganizationWatchlists || model.isMutatingOrganizationWatchlists)
        } else if item.status == .paused {
            ActionButton(title: "Resume", icon: "play") { Task { await model.changeOrganizationWatchlist(item, action: "resume") } }
                .disabled(!model.canWriteSelectedOrganizationWatchlists || model.isMutatingOrganizationWatchlists)
        } else {
            ActionButton(title: "Restore", icon: "arrow.uturn.backward") { Task { await model.changeOrganizationWatchlist(item, action: "restore") } }
                .disabled(!model.canWriteSelectedOrganizationWatchlists || model.isMutatingOrganizationWatchlists)
        }
        if item.status != .archived {
            ActionButton(title: "Archive", icon: "archivebox") { pending = PendingOrganizationWatchlistAction(item: item, action: "archive") }
                .disabled(!model.canWriteSelectedOrganizationWatchlists || model.isMutatingOrganizationWatchlists)
        }
    }

    private var maintenancePanel: some View {
        NativeGroupPanel(title: "Watchlist maintenance", subtitle: "Archive terms in a batch, rebuild events, or request a fresh source collection") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { maintenanceActions }
                VStack(alignment: .leading, spacing: 8) { maintenanceActions }
            }
            if let request = model.organizationWatchlistCollectionRequest {
                HStack(spacing: 8) {
                    Label("Fresh collection: \(request.status)", systemImage: request.status == "failed" ? "exclamationmark.triangle" : "arrow.triangle.2.circlepath")
                    Text("\(request.captureCount ?? 0) captures · \(request.alertCount ?? 0) events")
                    if ["queued", "running"].contains(request.status.lowercased()) {
                        ActionButton(title: "Check status", icon: "arrow.clockwise") { Task { await model.refreshOrganizationCollectionRequest() } }
                            .disabled(model.isMutatingOrganizationWatchlists)
                    }
                }
                .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textSecondary)
                if let error = request.errors?.first, !error.isEmpty { NativeNotice(message: error) }
            }
            DisclosureGroup("Archive selected terms (\(cleanupSelection.count))") {
                Text("Choose up to 50 current terms. Archiving stops monitoring; archived terms can be restored later.")
                    .font(.system(size: 10)).foregroundStyle(theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                if eligibleCleanupItems.isEmpty {
                    NativeEmptyState(title: "No terms to archive", message: "All watchlist terms are already archived.")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(eligibleCleanupItems) { item in
                                Toggle(isOn: Binding(get: { cleanupSelection.contains(item.id) }, set: { selected in
                                    if selected, cleanupSelection.count < 50 { cleanupSelection.insert(item.id) }
                                    else { cleanupSelection.remove(item.id) }
                                })) {
                                    Text("\(item.value) · \(item.kind.rawValue)").font(.system(size: 11)).lineLimit(2)
                                }
                                .toggleStyle(.checkbox)
                                .disabled(model.isMutatingOrganizationWatchlists || (!cleanupSelection.contains(item.id) && cleanupSelection.count >= 50))
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                    HStack(spacing: 8) {
                        ActionButton(title: "Archive selected (\(cleanupSelection.count))", icon: "archivebox", tone: .danger) {
                            let selected = cleanupSelection.sorted()
                            cleanupSelection.removeAll()
                            Task { await model.cleanupOrganizationWatchlists(itemIDs: selected) }
                        }
                        .disabled(cleanupSelection.isEmpty || !model.canCleanupSelectedOrganizationWatchlists || model.isMutatingOrganizationWatchlists)
                        ActionButton(title: "Clear selection", icon: "xmark") { cleanupSelection.removeAll() }
                            .disabled(cleanupSelection.isEmpty || model.isMutatingOrganizationWatchlists)
                    }
                }
            }
            .font(.system(size: 11, weight: .semibold))
        }
    }

    @ViewBuilder private var maintenanceActions: some View {
        ActionButton(title: model.isMutatingOrganizationWatchlists ? "Refreshing…" : "Rebuild events", icon: "arrow.clockwise") {
            Task { await model.rebuildOrganizationWatchlistAlerts() }
        }
        .disabled(!model.canWriteSelectedOrganizationWatchlists || model.isMutatingOrganizationWatchlists)
        ActionButton(title: model.isMutatingOrganizationWatchlists ? "Requesting…" : "Fresh collection", icon: "antenna.radiowaves.left.and.right") {
            Task { await model.requestOrganizationFreshCollection() }
        }
        .disabled(!model.canWriteSelectedOrganizationWatchlists || model.isMutatingOrganizationWatchlists
                  || !(model.organizationWatchlistPage?.watchlistItems.contains(where: { $0.status == .active }) ?? false))
    }

    private var eligibleCleanupItems: [OrganizationWatchlistItem] {
        model.organizationWatchlistPage?.watchlistItems.filter { $0.status != .archived } ?? []
    }
}
