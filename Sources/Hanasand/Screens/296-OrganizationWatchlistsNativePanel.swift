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
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var pending: PendingOrganizationWatchlistAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.selectedOrganizationID.isEmpty {
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
                }
            }
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
            HStack(spacing: 8) {
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
        }
    }
}
