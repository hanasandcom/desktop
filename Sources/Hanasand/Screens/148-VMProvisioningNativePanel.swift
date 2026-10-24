import SwiftUI

struct VMProvisioningNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    let resumeName: String?
    let onFinished: () -> Void

    @State private var name = ""
    @State private var os = "ubuntu-24.04"
    @State private var resources = NativeVMProvisioningOptions.resourcePlans[0]
    @State private var usesCustomResources = false
    @State private var customCPU = "2"
    @State private var customMemoryGiB = "4"
    @State private var services: Set<String> = []
    @State private var packageText = ""
    @State private var minecraftType = "PAPER"
    @State private var minecraftAddons: Set<String> = []
    @State private var acceptedEULA = false
    @State private var website = NativeVMWebsitePlan(title: "", tagline: "", sections: [], gallery: nil, contactEmail: nil)
    @State private var hasWebsiteContent = false
    @State private var prompt = ""
    @State private var planSummary = ""
    @State private var projectFiles: [NativeVMProjectFile] = []
    @State private var appliedPlanKey = ""
    @State private var authorization: NativeVMProvisioningAuthorization?
    @State private var pendingConfirmation = false
    @State private var pendingPlanConfirmation = false
    @State private var isLoadingAuthorization = false
    @State private var isWorking = false
    @State private var status = ""

    private var scopeKey: String {
        "\(model.settings.apiBaseURL.normalizedBaseURL.absoluteString)|\(model.userIDForRequests)|\(model.authTokenForRequests.hashValue)|\(model.selectedOrganizationID)|\(resumeName ?? "new")"
    }

    private var canSubmit: Bool { authorization != nil && model.hasHanasandAuth && !model.isProfileIdentityImpersonating && !isWorking }

    private var selectedResources: NativeVMResources {
        usesCustomResources
            ? NativeVMProvisioningPolicy.customAllocation(cpu: customCPU, memoryGiB: customMemoryGiB)
            : resources
    }

    private var resourceError: String? {
        NativeVMProvisioningPolicy.resourceValidationError(
            selectedResources, operatingSystem: os, services: services,
            minecraftServerType: services.contains("minecraft-java") ? minecraftType : "",
            hasGeneratedProject: !projectFiles.isEmpty)
    }

    var body: some View {
        NativeGroupPanel(title: resumeName == nil ? "Create virtual machine" : "Resume setup: \(resumeName!)",
                         subtitle: "Review the host configuration before sending a provisioning request.") {
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(theme.textSecondary).textSelection(.enabled) }
            if model.isProfileIdentityImpersonating {
                Text("Return to your own account before creating or resuming a VM.").font(.caption).foregroundStyle(theme.textSecondary)
            }
            if isLoadingAuthorization { ProgressView("Checking current VM access…") }
            ActionButton(title: isLoadingAuthorization ? "Refreshing access…" : "Refresh setup access", icon: "arrow.clockwise") {
                Task { await refreshAuthorization() }
            }.disabled(isLoadingAuthorization || isWorking || model.isProfileIdentityImpersonating)

            LabeledContent("VM name") {
                TextField("lowercase-name", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                    .disabled(resumeName != nil || !canSubmit)
            }
            if resumeName != nil {
                TextField("Type \(resumeName!) to confirm resuming setup", text: $nameConfirmation)
                    .textFieldStyle(.roundedBorder).disabled(!canSubmit)
            }
            Text("Operating system").font(.caption.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(NativeVMProvisioningOptions.operatingSystems, id: \.self) { option in
                    FilterChip(title: option, active: os == option) {
                        if os != option {
                            os = option
                            resources = NativeVMProvisioningPolicy.resources(afterSelectingOperatingSystem: option, current: resources)
                            if option == "ubuntu-24.04-desktop" {
                                usesCustomResources = false
                            }
                            clearAppliedPlan()
                        }
                    }
                }
            }
            Text("Resource plan").font(.caption.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(NativeVMProvisioningOptions.resourcePlans, id: \.cpu) { plan in
                    FilterChip(title: "\(plan.cpu) CPU · \(plan.memory) · \(plan.disk)", active: !usesCustomResources && resources == plan,
                               disabled: !NativeVMProvisioningPolicy.canSelect(plan, forOperatingSystem: os)) {
                        usesCustomResources = false
                        resources = plan
                    }
                }
                FilterChip(
                    title: "Custom allocation",
                    active: usesCustomResources
                ) {
                    usesCustomResources = true
                    if os == "ubuntu-24.04-desktop" {
                        customCPU = "4"
                        customMemoryGiB = "8"
                    }
                }
            }
            if usesCustomResources {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("vCPU · 1–10").font(.caption).foregroundStyle(theme.textSecondary)
                        TextField("vCPU", text: $customCPU).textFieldStyle(.roundedBorder).frame(maxWidth: 220).disabled(!canSubmit)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Memory · \(minimumMemoryGiB)–64 GiB").font(.caption).foregroundStyle(theme.textSecondary)
                        TextField("Memory in GiB", text: $customMemoryGiB).textFieldStyle(.roundedBorder).frame(maxWidth: 220).disabled(!canSubmit)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Disk").font(.caption).foregroundStyle(theme.textSecondary)
                        Text("40 GiB").font(.system(size: 13, weight: .medium)).frame(height: 28, alignment: .leading)
                    }
                }
                Text("Custom allocations use a fixed 40 GiB disk.")
                    .font(.caption).foregroundStyle(theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            if let resourceError {
                Text(resourceError).font(.caption).foregroundStyle(theme.danger).fixedSize(horizontal: false, vertical: true)
            }
            Text("Services").font(.caption.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(NativeVMProvisioningOptions.services, id: \.self) { service in
                    FilterChip(title: service, active: services.contains(service)) {
                        if services.contains(service) { services.remove(service) } else { services.insert(service) }
                        if service == "minecraft-java", !services.contains(service) { acceptedEULA = false; minecraftAddons = [] }
                        if service == "website", !services.contains(service) { hasWebsiteContent = false }
                    }
                }
            }
            TextField("Ubuntu packages (comma separated, up to 12)", text: $packageText).textFieldStyle(.roundedBorder).disabled(!canSubmit)
            if services.contains("minecraft-java") {
                Picker("Minecraft server", selection: Binding(get: { minecraftType }, set: { setMinecraftServerType($0) })) {
                    ForEach(NativeVMProvisioningOptions.minecraftTypes, id: \.self) { Text($0).tag($0) }
                }.frame(maxWidth: 300).disabled(!canSubmit)
                if let addonKey = NativeVMProvisioningPolicy.minecraftAddonKey(minecraftType),
                   let addons = NativeVMProvisioningOptions.minecraftAddonOptions[addonKey] {
                    Text(["PAPER", "PURPUR"].contains(minecraftType) ? "Popular plugins" : "Popular mods").font(.caption.bold())
                    Text("Matched to the latest Minecraft release when the server is installed.")
                        .font(.caption).foregroundStyle(theme.textSecondary)
                    ForEach(addons) { addon in
                        Toggle(isOn: Binding(get: { minecraftAddons.contains(addon.id) }, set: { enabled in
                            if enabled { minecraftAddons.insert(addon.id) } else { minecraftAddons.remove(addon.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(addon.label).font(.system(size: 13, weight: .semibold))
                                Text(addon.description).font(.caption).foregroundStyle(theme.textSecondary)
                            }
                        }.disabled(!canSubmit)
                    }
                }
                Toggle("I accept the Minecraft EULA", isOn: $acceptedEULA).disabled(!canSubmit)
                Text(NativeVMProvisioningOptions.fourGiBServerTypes.contains(minecraftType)
                    ? "This server software requires at least 4 GiB of memory. Review the EULA before accepting."
                    : "Review the EULA before accepting. This server software can use the small resource plan.")
                    .font(.caption).foregroundStyle(theme.textSecondary)
                Link("Read Minecraft EULA", destination: URL(string: "https://www.minecraft.net/eula")!)
            }
            if services.contains("website") {
                Toggle("Configure website content", isOn: $hasWebsiteContent).disabled(!canSubmit)
                if hasWebsiteContent {
                    TextField("Website title", text: $website.title).textFieldStyle(.roundedBorder).disabled(!canSubmit)
                    TextField("Tagline", text: $website.tagline).textFieldStyle(.roundedBorder).disabled(!canSubmit)
                    TextField("Contact email", text: Binding(get: { website.contactEmail ?? "" }, set: { website.contactEmail = $0.isEmpty ? nil : $0 }))
                        .textFieldStyle(.roundedBorder).disabled(!canSubmit)
                    Text("Website sections").font(.caption.bold())
                    ForEach(website.sections.indices, id: \.self) { index in
                        NativeGroupPanel(title: "Section \(index + 1)", subtitle: "Website content") {
                            TextField("Heading", text: $website.sections[index].heading).textFieldStyle(.roundedBorder).disabled(!canSubmit)
                            TextField("Body", text: $website.sections[index].body, axis: .vertical).lineLimit(2...6)
                                .textFieldStyle(.roundedBorder).disabled(!canSubmit)
                            ActionButton(title: "Remove section", icon: "minus.circle") { website.sections.remove(at: index) }
                                .disabled(!canSubmit)
                        }
                    }
                    ActionButton(title: "Add website section", icon: "plus.circle") {
                        guard website.sections.count < 5 else { return }
                        website.sections.append(.init(heading: "", body: ""))
                    }.disabled(!canSubmit || website.sections.count >= 5)
                    Text("Gallery images").font(.caption.bold())
                    ForEach((website.gallery ?? []).indices, id: \.self) { index in
                        NativeGroupPanel(title: "Gallery image \(index + 1)", subtitle: "Use a public HTTPS image URL") {
                            TextField("HTTPS image URL", text: galleryField(index, keyPath: \.url)).textFieldStyle(.roundedBorder).disabled(!canSubmit)
                            TextField("Alt text", text: galleryField(index, keyPath: \.alt)).textFieldStyle(.roundedBorder).disabled(!canSubmit)
                            TextField("Caption", text: galleryField(index, keyPath: \.caption)).textFieldStyle(.roundedBorder).disabled(!canSubmit)
                            ActionButton(title: "Remove gallery image", icon: "minus.circle") { website.gallery?.remove(at: index) }
                                .disabled(!canSubmit)
                        }
                    }
                    ActionButton(title: "Add gallery image", icon: "plus.circle") {
                        guard (website.gallery?.count ?? 0) < 8 else { return }
                        website.gallery = (website.gallery ?? []) + [.init(url: "", alt: "", caption: "")]
                    }.disabled(!canSubmit || (website.gallery?.count ?? 0) >= 8)
                }
            }
            TextField("Describe a setup for AI planning", text: Binding(get: { prompt }, set: { value in
                if prompt != value { prompt = value; clearAppliedPlan() }
            }), axis: .vertical)
                .lineLimit(3...7).textFieldStyle(.roundedBorder).disabled(!canSubmit)
            ActionButton(title: "Review AI setup request", icon: "sparkles") { pendingPlanConfirmation = true }
                .disabled(!canSubmit || prompt.trimmingCharacters(in: .whitespacesAndNewlines).count < 5)
            if !planSummary.isEmpty {
                Text(planSummary).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.textSecondary)
            }
            if !projectFiles.isEmpty {
                Text("Generated project files · review before creation").font(.caption.bold())
                Text("The generated project requires Node.js and at least 4 GiB. Files are installed and built on the VM.")
                    .font(.caption).foregroundStyle(theme.textSecondary)
                ForEach(projectFiles.indices, id: \.self) { index in
                    NativeGroupPanel(title: projectFiles[index].path, subtitle: "Generated source") {
                        TextEditor(text: $projectFiles[index].content).font(.system(.caption, design: .monospaced)).frame(minHeight: 130)
                    }
                }
                ActionButton(title: "Remove generated project", icon: "trash") { projectFiles = [] }
                    .disabled(!canSubmit)
            }
            if isWorking { ProgressView("Sending VM setup request…") }
            ActionButton(title: resumeName == nil ? "Review VM creation" : "Review resumed setup", icon: "checkmark.circle") {
                pendingConfirmation = true
            }.disabled(!canSubmit || !isInputReady || resourceError != nil)
        }
        .confirmationDialog(resumeName == nil ? "Create this virtual machine?" : "Resume this VM setup?", isPresented: $pendingConfirmation, titleVisibility: .visible) {
            Button(resumeName == nil ? "Create VM" : "Resume setup", role: .destructive) { Task { await submit() } }
            Button("Cancel", role: .cancel) { pendingConfirmation = false }
        } message: {
            Text("\(name) · \(os) · \(selectedResources.cpu) CPU / \(selectedResources.memory) RAM / \(selectedResources.disk) disk. \(services.sorted().joined(separator: ", ").isEmpty ? "Base system" : services.sorted().joined(separator: ", ")). The server queues provisioning; acceptance does not mean the VM is running. A timeout can leave provisioning in progress, so refresh inventory before retrying.")
        }
        .confirmationDialog("Generate setup plan?", isPresented: $pendingPlanConfirmation, titleVisibility: .visible) {
            Button("Generate suggestion") { Task { await generatePlan() } }
            Button("Cancel", role: .cancel) { pendingPlanConfirmation = false }
        } message: {
            Text("This sends the description to the configured AI setup service. It does not create a VM. Review the returned services, packages, website content and every generated file before creating.")
        }
        .task(id: scopeKey) { name = resumeName ?? ""; authorization = nil; await refreshAuthorization() }
    }

    @State private var nameConfirmation = ""

    private var isInputReady: Bool {
        !name.isEmpty && (resumeName == nil || nameConfirmation == resumeName)
    }

    private var minimumMemoryGiB: Int {
        if os == "ubuntu-24.04-desktop" { return 8 }
        if !projectFiles.isEmpty || services.contains("minecraft-java") && NativeVMProvisioningOptions.fourGiBServerTypes.contains(minecraftType) { return 4 }
        return 1
    }

    private func galleryField(_ index: Int, keyPath: WritableKeyPath<NativeVMWebsitePlan.GalleryImage, String>) -> Binding<String> {
        Binding(get: { website.gallery?.indices.contains(index) == true ? website.gallery![index][keyPath: keyPath] : "" },
                set: { value in
                    guard website.gallery?.indices.contains(index) == true else { return }
                    website.gallery![index][keyPath: keyPath] = value
                })
    }

    private func makeClient() throws -> NativeVMProvisioningClient {
        try NativeVMProvisioningClient(apiBaseURL: model.settings.apiBaseURL.normalizedBaseURL,
            userID: model.userIDForRequests, token: model.authTokenForRequests,
            organizationID: model.selectedOrganizationID.isEmpty ? "personal" : model.selectedOrganizationID,
            impersonationToken: model.settings.impersonationToken,
            impersonatingUserID: model.settings.impersonatingUserID)
    }

    @MainActor private func refreshAuthorization() async {
        authorization = nil
        guard model.hasHanasandAuth, !model.isProfileIdentityImpersonating else {
            status = "Sign in with your own account before setting up a virtual machine."
            return
        }
        isLoadingAuthorization = true
        defer { isLoadingAuthorization = false }
        let requestedScope = scopeKey
        do {
            let client = try makeClient()
            let fresh: NativeVMProvisioningAuthorization
            if let resumeName { fresh = try await client.loadResumeAuthorization(for: resumeName) }
            else { fresh = try await client.loadCreationAuthorization() }
            guard requestedScope == scopeKey else { return }
            authorization = fresh
            status = "Current VM setup access verified."
        } catch { status = error.localizedDescription }
    }

    @MainActor private func generatePlan() async {
        guard canSubmit else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let plan = try await makeClient().suggestSetup(prompt: prompt, os: os)
            services = Set(plan.services)
            packageText = plan.packages.joined(separator: ", ")
            if let website = plan.website { self.website = website; hasWebsiteContent = true }
            else { website = NativeVMWebsitePlan(title: "", tagline: "", sections: [], gallery: nil, contactEmail: nil); hasWebsiteContent = false }
            minecraftType = plan.minecraftServerType ?? "PAPER"
            minecraftAddons = []
            if NativeVMProvisioningOptions.fourGiBServerTypes.contains(minecraftType), resources.memory == "2GiB" {
                resources = NativeVMProvisioningOptions.resourcePlans[1]
            }
            if NativeVMProvisioningOptions.fourGiBServerTypes.contains(minecraftType), usesCustomResources,
                (Int(customMemoryGiB) ?? 0) < 4 {
                customMemoryGiB = "4"
            }
            acceptedEULA = false
            projectFiles = plan.projectFiles ?? []
            if !projectFiles.isEmpty, resources.memory == "2GiB" {
                resources = NativeVMProvisioningOptions.resourcePlans[1]
            }
            if !projectFiles.isEmpty, usesCustomResources, (Int(customMemoryGiB) ?? 0) < 4 {
                customMemoryGiB = "4"
            }
            appliedPlanKey = "\(os):\(prompt.trimmingCharacters(in: .whitespacesAndNewlines))"
            planSummary = plan.summary + "\nReview every selected service, package, website field and generated file before creating the VM."
            status = "Setup suggestion ready for your review. No VM was created."
        } catch { status = error.localizedDescription }
    }

    private func clearAppliedPlan() {
        guard !appliedPlanKey.isEmpty else { return }
        services = []
        packageText = ""
        website = NativeVMWebsitePlan(title: "", tagline: "", sections: [], gallery: nil, contactEmail: nil)
        hasWebsiteContent = false
        minecraftType = "PAPER"
        minecraftAddons = []
        acceptedEULA = false
        projectFiles = []
        planSummary = ""
        appliedPlanKey = ""
    }

    private func setMinecraftServerType(_ value: String) {
        guard minecraftType != value else { return }
        minecraftType = value
        minecraftAddons = []
        if NativeVMProvisioningOptions.fourGiBServerTypes.contains(value), resources.memory == "2GiB" {
            resources = NativeVMProvisioningOptions.resourcePlans[1]
        }
        if NativeVMProvisioningOptions.fourGiBServerTypes.contains(value), usesCustomResources,
            (Int(customMemoryGiB) ?? 0) < 4 {
            customMemoryGiB = "4"
        }
    }

    @MainActor private func submit() async {
        guard canSubmit, let authorization else { return }
        isWorking = true
        pendingConfirmation = false
        defer { isWorking = false }
        let packages = packageText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let input = NativeVMCreateInput(name: name, os: os, resources: selectedResources, services: services.sorted(),
            custom_apt_packages: packages.isEmpty ? nil : packages,
            minecraft_eula_accepted: services.contains("minecraft-java") ? acceptedEULA : nil,
            minecraft_server_type: services.contains("minecraft-java") ? minecraftType : nil,
            minecraft_addons: minecraftAddons.sorted(),
            website: services.contains("website") && hasWebsiteContent ? website : nil,
            project_files: projectFiles.isEmpty ? nil : projectFiles,
            organization_id: model.selectedOrganizationID == "personal" ? nil : model.selectedOrganizationID)
        do {
            let client = try makeClient()
            let receipt: NativeVMProvisioningReceipt
            if resumeName != nil {
                receipt = try await client.resume(input, authorization: authorization, confirmation: nameConfirmation)
            } else {
                receipt = try await client.create(input, authorization: authorization)
            }
            status = "\(receipt.name): creation accepted (201). Refresh inventory to observe provisioning and host state."
            onFinished()
        } catch {
            status = error.localizedDescription
            self.authorization = nil
        }
    }
}
