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

struct VMsNativePanel: View {
    @EnvironmentObject var model: DesktopAgentModel
    @Environment(\.desktopTheme) var theme
    @State var searchText: String
    @State var selectedStatus = "all"
    @State private var selectedVMName: String?
    @State private var pendingPowerAction: (vm: DashboardVM, action: String)?
    @State private var detailReloadToken = 0
    @State private var selectedDetails: NativeVMWorkspaceDetails?
    @State private var selectedMetrics: [NativeVMMetric] = []
    @State private var selectedManagement: NativeVMManagementAccess?
    @State private var detailStatus = ""

    init(initialVMID: String? = nil) {
        _searchText = State(initialValue: initialVMID ?? "")
    }

    let columns = [
        GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                FeatureCard(title: "VMs", value: "\(model.virtualMachines.count)", icon: "display.2")
                FeatureCard(title: "Running", value: "\(model.virtualMachines.filter { ($0.status ?? "").lowercased() == "running" }.count)", icon: "play.circle")
                FeatureCard(title: "Stopped", value: "\(model.virtualMachines.filter { ($0.status ?? "").lowercased() == "stopped" }.count)", icon: "pause.circle")
            }

            HStack(spacing: 10) {
                SearchFieldRow(placeholder: "Search VMs by name, owner, IP, status, or tags", text: $searchText)
                ActionButton(title: "Refresh", icon: "arrow.clockwise") {
                    Task { await model.loadNativeDashboardData() }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(statuses, id: \.self) { status in
                        FilterChip(title: status.capitalized, active: selectedStatus == status) {
                            selectedStatus = status
                        }
                    }
                }
            }

            if model.virtualMachines.isEmpty {
                NativeEmptyState(title: "No VMs loaded", message: "Use Refresh to load VM access data. Configure auth and user id in Settings if this stays empty.")
            } else if filteredVMs.isEmpty {
                NativeGroupPanel(title: "No matching VMs", subtitle: "Adjust status or search filters.") {
                    Text("VM data is loaded, but no machines match the active filters.")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                }
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(filteredVMs) { vm in
                        vmCard(vm)
                    }
                }
            }

            if let selectedVM = model.virtualMachines.first(where: { $0.name == selectedVMName }) {
                vmDetails(selectedVM)
            }
        }
        .confirmationDialog(
            pendingPowerAction.map { "\($0.action.capitalized) \($0.vm.name)?" } ?? "Review VM action",
            isPresented: Binding(
                get: { pendingPowerAction != nil },
                set: { if !$0 { pendingPowerAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingPowerAction {
                Button("Confirm \(pendingPowerAction.action)", role: pendingPowerAction.action == "stop" ? .destructive : nil) {
                    Task { await model.runVirtualMachineAction(pendingPowerAction.vm, action: pendingPowerAction.action) }
                    self.pendingPowerAction = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingPowerAction = nil }
        } message: {
            if let pendingPowerAction {
                Text("Send one \(pendingPowerAction.action) request for \(pendingPowerAction.vm.name). Refresh afterward to check the host state.")
            }
        }
        .task(id: "\(selectedVMName ?? ""):\(detailReloadToken)") {
            await loadSelectedVMDetails()
        }
    }

    var statuses: [String] {
        let values = Set(model.virtualMachines.map { ($0.status ?? "unknown").lowercased() })
        return ["all"] + values.sorted()
    }

    var filteredVMs: [DashboardVM] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return model.virtualMachines.filter { vm in
            let statusMatch = selectedStatus == "all" || (vm.status ?? "unknown").lowercased() == selectedStatus
            let searchable = [
                vm.name,
                vm.ownerLabel,
                vm.statusLabel,
                vm.description ?? "",
                vm.ipv4 ?? "",
                vm.tags.joined(separator: " "),
            ].joined(separator: " ").lowercased()
            return statusMatch && (query.isEmpty || searchable.contains(query))
        }
    }

    func vmCard(_ vm: DashboardVM) -> some View {
        NativeGroupPanel(title: vm.name, subtitle: vm.ownerLabel) {
            HStack(spacing: 10) {
                FeatureCard(title: "Status", value: vm.statusLabel, icon: vm.statusLabel.lowercased() == "running" ? "checkmark.circle" : "circle.dashed")
                FeatureCard(title: "CPU", value: vm.cpuLimit ?? "Unknown", icon: "cpu")
                FeatureCard(title: "Memory", value: vm.memoryLimit ?? "Unknown", icon: "memorychip")
            }

            if let description = vm.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Image(systemName: "calendar")
                Text("Created \(vm.createdLabel)")
                Spacer()
                Image(systemName: "clock.arrow.circlepath")
                Text(vm.lastUsedLabel)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.textTertiary)

            if !vm.tags.isEmpty {
                HStack(spacing: 8) {
                    ForEach(vm.tags.prefix(4), id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(theme.textSecondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(theme.cardRaised)
                            .clipShape(Capsule())
                    }
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                ActionButton(title: "Details", icon: "info.circle") {
                    selectedVMName = vm.name
                }
                ActionButton(title: "Console", icon: "terminal") {
                    model.openNativeDashboard(path: "/vms/console", label: "VM console", detailID: vm.name)
                }
            }
        }
    }

    private func reviewPowerAction(_ vm: DashboardVM, action: String) {
        guard nativeVMActionPath(vmName: vm.name, action: action, isImpersonating: model.isProfileIdentityImpersonating) != nil else {
            return
        }
        pendingPowerAction = (vm, action)
    }

    @ViewBuilder
    private func vmDetails(_ vm: DashboardVM) -> some View {
        NativeGroupPanel(title: "\(vm.name) details", subtitle: "Host inventory, metrics, and public services") {
            HStack(spacing: 8) {
                ActionButton(title: "Refresh details", icon: "arrow.clockwise") { detailReloadToken += 1 }
                ActionButton(title: "Close details", icon: "xmark") { selectedVMName = nil }
            }
            if !detailStatus.isEmpty {
                Text(detailStatus)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .textSelection(.enabled)
            }
            if let selectedManagement {
                if selectedManagement.canManage && !model.isProfileIdentityImpersonating {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                        ActionButton(title: "Start", icon: "play.circle") { reviewPowerAction(vm, action: "start") }
                            .disabled(!model.hasHanasandAuth)
                        ActionButton(title: "Restart", icon: "arrow.clockwise") { reviewPowerAction(vm, action: "restart") }
                            .disabled(!model.hasHanasandAuth)
                        ActionButton(title: "Stop", icon: "stop.circle", tone: .danger) { reviewPowerAction(vm, action: "stop") }
                            .disabled(!model.hasHanasandAuth)
                    }
                } else {
                    Text(model.isProfileIdentityImpersonating
                         ? "Power actions are unavailable while impersonating."
                         : "This account does not have permission to manage this VM.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            if let selectedDetails {
                ForEach(Array(selectedDetails.fields.enumerated()), id: \.offset) { _, field in
                    detailRow(field.0, value: field.1)
                }
                if !selectedDetails.profiles.isEmpty {
                    detailRow("Profiles", value: selectedDetails.profiles.joined(separator: ", "))
                }
            }
            if let latestMetric = selectedMetrics.first {
                Text("Latest metrics · \(latestMetric.recordedAt ?? "time unavailable") · \(latestMetric.powerState ?? "power state unavailable")")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.textSecondary)
                ForEach(Array(latestMetric.values.enumerated()), id: \.offset) { _, field in
                    detailRow(field.0, value: field.1)
                }
            } else if selectedDetails != nil {
                Text("No VM metrics were returned.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            }
            Text("Public services")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(theme.textSecondary)
            if selectedManagement?.services.isEmpty != false {
                Text("No public services were returned.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            } else {
                ForEach(Array((selectedManagement?.services ?? []).enumerated()), id: \.offset) { _, service in
                    detailRow(service.0, value: service.1)
                }
            }
        }
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .foregroundStyle(theme.textTertiary)
                .frame(width: 150, alignment: .leading)
            Text(value)
                .foregroundStyle(theme.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12, weight: .medium))
    }

    @MainActor
    private func loadSelectedVMDetails() async {
        selectedDetails = nil
        selectedMetrics = []
        selectedManagement = nil
        guard let name = selectedVMName else { return }
        guard model.hasHanasandAuth else {
            detailStatus = "Sign in to load VM details."
            return
        }
        detailStatus = "Loading VM details, metrics, and services…"
        do {
            let client = try NativeVMWorkspaceClient(
                apiBaseURL: model.settings.apiBaseURL,
                userID: model.userIDForRequests,
                token: model.authTokenForRequests,
                organizationID: model.selectedOrganizationID.isEmpty ? nil : model.selectedOrganizationID
            )
            async let details = captureVMRead { try await client.loadDetails(for: name) }
            async let metrics = captureVMRead { try await client.loadMetrics(for: name) }
            async let management = captureVMRead { try await client.loadManagement(for: name) }
            let (detailsResult, metricsResult, managementResult) = await (details, metrics, management)
            guard !Task.isCancelled, selectedVMName == name else { return }
            selectedDetails = try? detailsResult.get()
            selectedMetrics = (try? metricsResult.get()) ?? []
            selectedManagement = try? managementResult.get()
            let failures = [
                vmReadFailure(detailsResult),
                vmReadFailure(metricsResult),
                vmReadFailure(managementResult),
            ].compactMap { $0 }
            if let failure = failures.first {
                detailStatus = selectedDetails == nil
                    ? "Some VM data could not be loaded: \(failure)"
                    : "Some VM data is unavailable: \(failure)"
            } else {
                detailStatus = selectedDetails == nil ? "No stored host details were returned." : "VM details refreshed."
            }
        } catch {
            guard !Task.isCancelled, selectedVMName == name else { return }
            detailStatus = "VM details could not be loaded: \(error.localizedDescription)"
        }
    }

    private func captureVMRead<Value>(_ operation: () async throws -> Value) async -> Result<Value, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }

    private func vmReadFailure<Value>(_ result: Result<Value, Error>) -> String? {
        guard case let .failure(error) = result else { return nil }
        return error.localizedDescription
    }
}
