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

func nativeVMDetailSelection(_ routeVMName: String?, from items: [NativeVMInventoryItem]) -> NativeVMInventoryItem? {
    guard let routeVMName, !routeVMName.isEmpty else { return nil }
    return items.first { $0.name == routeVMName }
}

struct VMsNativePanel: View {
    @EnvironmentObject var model: DesktopAgentModel
    @Environment(\.desktopTheme) var theme
    @State private var inventoryFilter = NativeVMInventoryFilter()
    @State private var inventorySnapshot: NativeVMInventorySnapshot?
    @State private var inventoryError = ""
    @State private var inventoryRefreshToken = 0
    @State private var inventoryLimit = 30
    @State private var isRefreshingInventory = false
    @State private var showMoreFilters = false
    @State private var selectedVMName: String?
    @State private var pendingPowerAction: (vm: DashboardVM, action: String)?
    @State private var detailReloadToken = 0
    @State private var selectedMetricIndex: Int?
    @State private var metricLimit = 20
    @State private var selectedDetails: NativeVMWorkspaceDetails?
    @State private var selectedMetrics: [NativeVMMetric] = []
    @State private var selectedManagement: NativeVMManagementAccess?
    @State private var detailStatus = ""
    @State private var showProvisioning = false
    @State private var provisioningResumeName: String?
    @State private var publicServiceName = ""
    @State private var publicServiceType = NativeVMPublicServiceType.minecraftJava
    @State private var publicServicePort = "25565"
    @State private var publicServiceStatus = ""
    @State private var isManagingPublicServices = false
    @State private var pendingPublicServiceCreate = false
    @State private var pendingPublicServiceRemoval: NativeVMPublicService?

    init(initialVMID: String? = nil) {
        _selectedVMName = State(initialValue: initialVMID)
    }

    let columns = [
        GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                SearchFieldRow(placeholder: "Search VM names", text: $inventoryFilter.query)
                ActionButton(title: "Create VM", icon: "plus.circle") { showProvisioning = true; provisioningResumeName = nil }
                    .disabled(!model.hasHanasandAuth || model.isProfileIdentityImpersonating)
                ActionButton(title: isRefreshingInventory ? "Refreshing…" : "Refresh", icon: "arrow.clockwise") {
                    inventoryRefreshToken += 1
                }
                .disabled(isRefreshingInventory || !model.hasHanasandAuth)
            }
            VMPlatformAdministrationControls()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], alignment: .leading, spacing: 8) {
                FilterChip(title: "Any power state", active: inventoryFilter.status == "all") { inventoryFilter.status = "all" }
                FilterChip(title: "Running", active: inventoryFilter.status == "running") { inventoryFilter.status = "running" }
                FilterChip(title: "Stopped", active: inventoryFilter.status == "stopped") { inventoryFilter.status = "stopped" }
                FilterChip(title: "All lifecycle states", active: inventoryFilter.lifecycle == "all") { inventoryFilter.lifecycle = "all" }
                FilterChip(title: "Active", active: inventoryFilter.lifecycle == "active") { inventoryFilter.lifecycle = "active" }
                FilterChip(title: "Scheduled deletion", active: inventoryFilter.lifecycle == "deleted") { inventoryFilter.lifecycle = "deleted" }
            }
            ActionButton(title: showMoreFilters ? "Hide CPU, memory, and editor filters" : "CPU, memory, and editor filters", icon: "line.3.horizontal.decrease") {
                showMoreFilters.toggle()
            }
            if showMoreFilters {
                NativeGroupPanel(title: "Filter inventory", subtitle: "Filters apply to owned and accessible VMs.") {
                    LabeledContent("Minimum CPU cores") {
                        TextField("Any", text: $inventoryFilter.minimumCPU).textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                    }
                    LabeledContent("Minimum memory (GiB)") {
                        TextField("Any", text: $inventoryFilter.minimumMemoryGiB).textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                    }
                    LabeledContent("Editor access") {
                        TextField("Any, with, without, or exact ID", text: $inventoryFilter.editor).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                    }
                }
            }

            if !inventoryError.isEmpty {
                Text(inventoryError).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.danger).textSelection(.enabled)
            }
            if showProvisioning || provisioningResumeName != nil {
                VMProvisioningNativePanel(resumeName: provisioningResumeName) {
                    inventoryRefreshToken += 1
                }
                ActionButton(title: "Close setup", icon: "xmark") { showProvisioning = false; provisioningResumeName = nil }
            }
            if let inventorySnapshot {
                let filtered = nativeVMFilterInventory(inventorySnapshot.items, filter: inventoryFilter)
                if !inventorySnapshot.isComplete {
                    Text("Partial inventory: one source could not be loaded. Refresh for a complete result.")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.accent)
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    FeatureCard(title: "Loaded", value: "\(inventorySnapshot.items.count)", icon: "display.2")
                    FeatureCard(title: "Running", value: "\(inventorySnapshot.items.filter { ["running", "frozen", "starting"].contains(($0.status ?? "").lowercased()) }.count)", icon: "play.circle")
                    FeatureCard(title: "Stopped", value: "\(inventorySnapshot.items.filter { ["stopped", "shut off"].contains(($0.status ?? "").lowercased()) }.count)", icon: "pause.circle")
                }
                Text("\(filtered.count) matching / \(inventorySnapshot.items.count) loaded VMs")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                if filtered.isEmpty {
                    NativeGroupPanel(title: "No matching VMs", subtitle: "Adjust or clear the active filters.") {
                        Text("No loaded machines match these filters.").font(.system(size: 13, weight: .medium)).foregroundStyle(theme.textSecondary)
                        ActionButton(title: "Clear filters", icon: "xmark") { inventoryFilter = NativeVMInventoryFilter() }
                    }
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(nativeVMPage(filtered, limit: inventoryLimit)) { vm in vmCard(vm) }
                    }
                    if inventoryLimit < filtered.count {
                        ActionButton(title: "Show more loaded VMs", icon: "ellipsis") { inventoryLimit += 30 }
                    }
                }
            } else if model.hasHanasandAuth {
                NativeEmptyState(title: isRefreshingInventory ? "Loading VM inventory" : "VM inventory unavailable", message: isRefreshingInventory ? "Reading owned and accessible machines." : "Refresh to retry the inventory request.")
            } else {
                NativeEmptyState(title: "Sign in to load VMs", message: "VM inventory requires an authenticated Hanasand session.")
            }

            if let selectedVM = nativeVMDetailSelection(selectedVMName, from: inventorySnapshot?.items ?? []) {
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
        .confirmationDialog("Publish public service?", isPresented: $pendingPublicServiceCreate, titleVisibility: .visible) {
            Button("Publish service") {
                guard let vm = nativeVMDetailSelection(selectedVMName, from: inventorySnapshot?.items ?? []) else { return }
                Task { await createPublicService(for: vm) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Publish \(publicServiceName.isEmpty ? "this service" : publicServiceName) as \(publicServiceType.title) through the shared Hanasand gateway to guest port \(publicServicePort).")
        }
        .confirmationDialog("Remove public service?", isPresented: Binding(
            get: { pendingPublicServiceRemoval != nil },
            set: { if !$0 { pendingPublicServiceRemoval = nil } }
        ), titleVisibility: .visible) {
            if let service = pendingPublicServiceRemoval {
                Button("Remove \(service.name)", role: .destructive) {
                    guard let vm = nativeVMDetailSelection(selectedVMName, from: inventorySnapshot?.items ?? []) else { return }
                    Task { await removePublicService(service, from: vm) }
                }
            }
            Button("Cancel", role: .cancel) { pendingPublicServiceRemoval = nil }
        } message: {
            Text("This removes the current public route. The service running inside the VM is not changed.")
        }
        .task(id: "\(inventoryScope):\(inventoryRefreshToken)") {
            await loadWorkspaceInventory()
        }
        .task(id: "\(selectedVMName ?? ""):\(detailReloadToken):\(inventoryScope)") {
            await loadSelectedVMDetails()
        }
        .onChange(of: inventoryFilter) { _, _ in inventoryLimit = 30 }
        .onChange(of: selectedVMName) { _, _ in
            selectedMetricIndex = nil
            metricLimit = 20
            publicServiceName = ""
            publicServiceType = .minecraftJava
            publicServicePort = "25565"
            publicServiceStatus = ""
            pendingPublicServiceCreate = false
            pendingPublicServiceRemoval = nil
        }
        .onChange(of: model.selectedOrganizationID) { _, _ in
            selectedVMName = nil
            inventorySnapshot = nil
            inventoryError = ""
            inventoryRefreshToken += 1
        }
    }

    private var inventoryScope: String {
        "\(model.settings.apiBaseURL)|\(model.userIDForRequests)|\(model.authTokenForRequests.hashValue)|\(model.selectedOrganizationID)"
    }

    func vmCard(_ vm: NativeVMInventoryItem) -> some View {
        NativeGroupPanel(title: vm.name, subtitle: vm.organizationName ?? vm.organizationID ?? "Personal") {
            LazyVGrid(columns: [GridItem(.flexible(minimum: 0), alignment: .leading)], alignment: .leading, spacing: NativeVMCardLayout.metricSpacing) {
                FeatureCard(title: "Status", value: vm.status?.capitalized ?? "Unknown", icon: (vm.status ?? "").lowercased() == "running" ? "checkmark.circle" : "circle.dashed")
                FeatureCard(title: "CPU", value: vm.cpuLimit ?? "Unknown", icon: "cpu")
                FeatureCard(title: "Memory", value: vm.memoryLimit ?? "Unknown", icon: "memorychip")
            }
            Text("Owner \(vm.owner)\(vm.createdBy.map { " · created by \($0)" } ?? "")")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
            if let description = vm.imageDescription, !description.isEmpty {
                Text(description)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Image(systemName: "calendar")
                Text("Created \(vm.created ?? "Unavailable")")
                Spacer()
                Image(systemName: "clock.arrow.circlepath")
                Text("Last used \(vm.lastUsed ?? "Unavailable")")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.textTertiary)

            let tags = [vm.type, vm.architecture, vm.ipv4].compactMap { $0 }
            if !tags.isEmpty {
                HStack(spacing: 8) {
                    ForEach(tags.prefix(4), id: \.self) { tag in
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
    private func vmDetails(_ vm: NativeVMInventoryItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
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
                        ActionButton(title: "Start", icon: "play.circle") { reviewPowerAction(vm.dashboardVM, action: "start") }
                            .disabled(!model.hasHanasandAuth)
                        ActionButton(title: "Restart", icon: "arrow.clockwise") { reviewPowerAction(vm.dashboardVM, action: "restart") }
                            .disabled(!model.hasHanasandAuth)
                        ActionButton(title: "Stop", icon: "stop.circle", tone: .danger) { reviewPowerAction(vm.dashboardVM, action: "stop") }
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
            if detailStatus == "No stored host details were returned." && !vm.isScheduledForDeletion {
                ActionButton(title: "Resume setup", icon: "arrow.clockwise.circle") {
                    provisioningResumeName = vm.name
                    showProvisioning = false
                }.disabled(!model.hasHanasandAuth || model.isProfileIdentityImpersonating)
                Text("Resume is available only when a fresh VM details read confirms no stored setup details and your account owns the VM or has platform edit access.")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary)
            }
            VMAdministrationControls(vm: vm) {
                inventoryRefreshToken += 1
                detailReloadToken += 1
            }
            if let selectedDetails {
                Text("Stored host details").font(.system(size: 12, weight: .bold)).foregroundStyle(theme.textSecondary)
                ForEach(Array(selectedDetails.fields.enumerated()), id: \.offset) { _, field in
                    detailRow(field.0, value: field.1)
                }
                if !selectedDetails.profiles.isEmpty {
                    detailRow("Profiles", value: selectedDetails.profiles.joined(separator: ", "))
                }
            }
            if !selectedMetrics.isEmpty {
                Text("CPU history · oldest to newest · \(selectedMetrics.count) samples")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(theme.textSecondary)
                GeometryReader { geometry in
                    cpuHistoryPath(in: geometry.size)
                        .stroke(theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .accessibilityLabel("CPU metric history")
                }
                .frame(height: 100)
                let latestMetric = selectedMetrics[0]
                Text("Latest metrics · \(latestMetric.recordedAt ?? "time unavailable") · \(latestMetric.powerState ?? "power state unavailable")")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.textSecondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(Array(latestMetric.values.enumerated()), id: \.offset) { _, field in detailRow(field.0, value: field.1) }
                }
                Text("Inspect a sample").font(.system(size: 12, weight: .bold)).foregroundStyle(theme.textSecondary)
                ForEach(Array(selectedMetrics.prefix(metricLimit).enumerated()), id: \.offset) { index, sample in
                    ActionButton(
                        title: "\(selectedMetricIndex == index ? "✓ " : "")\(sample.recordedAt ?? "Sample \(index + 1)") · CPU \(sample.values.first(where: { $0.0 == "CPU usage (%)" })?.1 ?? "unavailable")%",
                        icon: "waveform.path"
                    ) { selectedMetricIndex = selectedMetricIndex == index ? nil : index }
                }
                if metricLimit < selectedMetrics.count {
                    ActionButton(title: "Show more metric samples", icon: "ellipsis") { metricLimit += 20 }
                }
                if let selectedMetricIndex, selectedMetrics.indices.contains(selectedMetricIndex) {
                    let sample = selectedMetrics[selectedMetricIndex]
                    Text("Sample · \(sample.recordedAt ?? "timestamp unavailable") · \(sample.powerState ?? "power state unavailable")")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(theme.textSecondary)
                    ForEach(Array(sample.values.enumerated()), id: \.offset) { _, field in detailRow(field.0, value: field.1) }
                    if let poweredOnAt = sample.poweredOnAt { detailRow("Powered on at", value: poweredOnAt) }
                    if let poweredOffAt = sample.poweredOffAt { detailRow("Powered off at", value: poweredOffAt) }
                }
            } else if selectedDetails != nil {
                Text("No VM metrics were returned.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            }
            publicServicesSection(for: vm)
          }
          NativeVMAccessPanel(vm: vm, canManage: selectedManagement?.canManage == true) {
              inventoryRefreshToken += 1
              detailReloadToken += 1
          }
        }
    }

    private func cpuHistoryPath(in size: CGSize) -> Path {
        var path = Path()
        for segment in nativeVMCPUHistorySegments(selectedMetrics) {
            guard let first = segment.first else { continue }
            path.move(to: CGPoint(x: first.x * Double(size.width), y: first.y * Double(size.height)))
            for point in segment.dropFirst() {
                path.addLine(to: CGPoint(x: point.x * Double(size.width), y: point.y * Double(size.height)))
            }
        }
        return path
    }

    @ViewBuilder
    private func publicServicesSection(for vm: NativeVMInventoryItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Public services")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(theme.textSecondary)
            Text("Publish a hostname through the shared HTTPS gateway. The guest port stays private; SSH and other plain TCP or UDP services need a different route.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let management = selectedManagement {
                if management.services.isEmpty {
                    Text("No public services are configured.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                } else {
                    ForEach(management.services) { service in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(service.hostname ?? "\(service.name) (hostname unavailable)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("\(serviceTypeLabel(service.type)) · guest port \(service.port)\(service.createdAt.map { " · created \($0)" } ?? "")")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 8) { publicServiceActions(service) }
                                VStack(alignment: .leading, spacing: 8) { publicServiceActions(service) }
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.card, in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            } else {
                Text("Public service permission and inventory have not been loaded.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            }

            if selectedManagement?.canManage == true, !model.isProfileIdentityImpersonating {
                NativeGroupPanel(title: "Add public service", subtitle: "Create an HTTPS gateway route for this VM") {
                    publicServiceFields
                    ActionButton(title: isManagingPublicServices ? "Updating services…" : "Review add service", icon: "plus.circle") {
                        pendingPublicServiceCreate = true
                    }
                    .disabled(isManagingPublicServices || (selectedManagement?.services.count ?? 0) >= 1_000 || !publicServiceInputReady)
                    if (selectedManagement?.services.count ?? 0) >= 1_000 {
                        Text("A VM can have up to 1,000 public services.")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary)
                    }
                }
            }
            if !publicServiceStatus.isEmpty {
                Text(publicServiceStatus)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(publicServiceStatus.localizedCaseInsensitiveContains("uncertain") || publicServiceStatus.localizedCaseInsensitiveContains("failed") ? theme.danger : theme.textSecondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var publicServiceFields: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 10) {
            TextField("Service name", text: $publicServiceName, prompt: Text("survival"))
                .textFieldStyle(.roundedBorder)
                .onChange(of: publicServiceName) { _, value in normalizePublicServiceName(value) }
            Picker("Service type", selection: $publicServiceType) {
                ForEach(NativeVMPublicServiceType.allCases) { type in
                    Text(type.title).tag(type)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: publicServiceType) { _, type in publicServicePort = type.defaultPort }
            TextField("Guest port", text: $publicServicePort, prompt: Text("25565"))
                .textFieldStyle(.roundedBorder)
                .onChange(of: publicServicePort) { _, value in
                    let normalized = String(value.filter(\.isNumber).prefix(5))
                    if normalized != value { publicServicePort = normalized }
                }
        }
    }

    private func normalizePublicServiceName(_ value: String) {
        let normalized = String(value.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }.prefix(40))
        if normalized != value { publicServiceName = normalized }
    }

    @ViewBuilder
    private func publicServiceActions(_ service: NativeVMPublicService) -> some View {
        if let hostname = service.hostname {
            ActionButton(title: "Copy \(hostname):443", icon: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(hostname):443", forType: .string)
                publicServiceStatus = "Copied \(hostname):443."
            }
        }
        if selectedManagement?.canManage == true, !model.isProfileIdentityImpersonating {
            ActionButton(title: "Remove \(service.name)", icon: "trash", tone: .danger) {
                pendingPublicServiceRemoval = service
            }
            .disabled(isManagingPublicServices)
        }
    }

    private var publicServiceInputReady: Bool {
        let name = publicServiceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.range(of: #"^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$"#, options: .regularExpression) != nil,
              !name.hasPrefix("port-"),
              let port = Int(publicServicePort), (1...65_535).contains(port) else { return false }
        return true
    }

    private func serviceTypeLabel(_ type: String) -> String {
        switch type {
        case "http": "Website · HTTPS"
        case "tls": "TLS over TCP"
        case "minecraft-java": "Minecraft Java"
        default: type
        }
    }

    @MainActor
    private func createPublicService(for vm: NativeVMInventoryItem) async {
        pendingPublicServiceCreate = false
        guard publicServiceInputReady, !isManagingPublicServices else { return }
        await updatePublicService(for: vm) { client, authorization in
            _ = try await client.createPublicService(for: vm.name, authorization: authorization,
                                                     name: publicServiceName, type: publicServiceType.rawValue,
                                                     port: Int(publicServicePort) ?? 0)
            publicServiceName = ""
            return "Public service added. Refresh the route before relying on it."
        }
    }

    @MainActor
    private func removePublicService(_ service: NativeVMPublicService, from vm: NativeVMInventoryItem) async {
        pendingPublicServiceRemoval = nil
        guard !isManagingPublicServices else { return }
        await updatePublicService(for: vm) { client, authorization in
            try await client.removePublicService(for: vm.name, authorization: authorization, serviceID: service.id)
            return "Public service \(service.name) removed. The application inside the VM was not changed."
        }
    }

    @MainActor
    private func updatePublicService(
        for vm: NativeVMInventoryItem,
        operation: (NativeVMWorkspaceClient, NativeVMManagementAccess) async throws -> String
    ) async {
        let capturedScope = inventoryScope
        isManagingPublicServices = true
        defer { isManagingPublicServices = false }
        do {
            let client = try makeWorkspaceClient()
            let fresh = try await client.loadManagement(for: vm.name)
            guard capturedScope == inventoryScope, selectedVMName == vm.name,
                  !model.isProfileIdentityImpersonating else {
                selectedManagement = nil
                publicServiceStatus = "Account, organization, or selected VM changed. Refresh before trying again."
                return
            }
            guard fresh.canManage else { throw NativeVMWorkspaceClientError.permissionDenied }
            let result = try await operation(client, fresh)
            guard capturedScope == inventoryScope, selectedVMName == vm.name else {
                selectedManagement = nil
                publicServiceStatus = "The service change may have been accepted. Refresh the current VM before continuing."
                return
            }
            selectedManagement = try await client.loadManagement(for: vm.name)
            publicServiceStatus = result
        } catch {
            publicServiceStatus = error.localizedDescription
            if error as? NativeVMWorkspaceClientError == .uncertainOutcome { detailReloadToken += 1 }
        }
    }

    private func makeWorkspaceClient() throws -> NativeVMWorkspaceClient {
        try NativeVMWorkspaceClient(
            apiBaseURL: model.settings.apiBaseURL,
            userID: model.userIDForRequests,
            token: model.authTokenForRequests,
            organizationID: model.selectedOrganizationID.isEmpty || model.selectedOrganizationID == "personal" ? nil : model.selectedOrganizationID
        )
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
    private func loadWorkspaceInventory() async {
        guard model.hasHanasandAuth else {
            inventorySnapshot = nil
            inventoryError = "Sign in to load VM inventory."
            return
        }
        let currentScope = inventoryScope
        isRefreshingInventory = true
        inventoryError = ""
        defer { if !Task.isCancelled && inventoryScope == currentScope { isRefreshingInventory = false } }
        do {
            let client = try NativeVMWorkspaceClient(
                apiBaseURL: model.settings.apiBaseURL,
                userID: model.userIDForRequests,
                token: model.authTokenForRequests,
                organizationID: model.selectedOrganizationID.isEmpty || model.selectedOrganizationID == "personal" ? nil : model.selectedOrganizationID
            )
            let result = try await client.loadInventory()
            guard !Task.isCancelled, inventoryScope == currentScope else { return }
            inventorySnapshot = result
            if result.isComplete { inventoryError = "" }
            if result.isComplete, let selectedVMName, !result.items.contains(where: { $0.name == selectedVMName }) {
                self.selectedVMName = nil
            }
        } catch {
            guard !Task.isCancelled, inventoryScope == currentScope else { return }
            inventorySnapshot = nil
            inventoryError = "VM inventory could not be loaded: \(error.localizedDescription)"
        }
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
        let currentScope = inventoryScope
        detailStatus = "Loading VM details, metric history, and public services…"
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
            guard !Task.isCancelled, selectedVMName == name, inventoryScope == currentScope else { return }
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
            guard !Task.isCancelled, selectedVMName == name, inventoryScope == currentScope else { return }
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
