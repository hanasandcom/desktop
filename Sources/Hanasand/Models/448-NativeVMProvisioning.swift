import Foundation

enum NativeVMProvisioningOptions {
    static let operatingSystems = ["ubuntu-22.04", "ubuntu-24.04", "ubuntu-26.04", "ubuntu-24.04-desktop"]
    static let services = ["nodejs", "postgresql", "mysql", "sqlite", "redis", "python", "bun", "rust", "ruby", "cpp", "docker", "java", "go", "php", "nginx", "website", "minecraft-java"]
    static let minecraftTypes = ["PAPER", "VANILLA", "FABRIC", "QUILT", "NEOFORGE", "FORGE", "PURPUR", "FOLIA"]
    static let minecraftAddonOptions: [String: [NativeVMMinecraftAddon]] = [
        "PAPER": [
            .init(id: "essentialsx", label: "EssentialsX", description: "Homes, warps and useful server commands"),
            .init(id: "luckperms", label: "LuckPerms", description: "Groups and permissions"),
            .init(id: "viaversion", label: "ViaVersion", description: "Let newer Minecraft clients join"),
            .init(id: "worldedit", label: "WorldEdit", description: "Build and edit large areas"),
            .init(id: "spark", label: "spark", description: "Server performance profiler")
        ],
        "FABRIC": [
            .init(id: "fabric-api", label: "Fabric API", description: "Common library required by many Fabric mods"),
            .init(id: "lithium", label: "Lithium", description: "Server-side performance improvements"),
            .init(id: "ferritecore", label: "FerriteCore", description: "Reduce server memory use"),
            .init(id: "krypton", label: "Krypton", description: "Optimize Minecraft networking"),
            .init(id: "spark", label: "spark", description: "Server performance profiler")
        ],
        "FORGE": [
            .init(id: "jei", label: "Just Enough Items", description: "Browse recipes and items"),
            .init(id: "ferritecore", label: "FerriteCore", description: "Reduce server memory use"),
            .init(id: "modernfix", label: "ModernFix", description: "Performance and memory optimizations"),
            .init(id: "spark", label: "spark", description: "Server performance profiler")
        ]
    ]
    static let fourGiBServerTypes: Set<String> = ["FABRIC", "QUILT", "FORGE", "NEOFORGE", "FOLIA"]
    static let resourcePlans: [NativeVMResources] = [
        .init(cpu: "1", memory: "2GiB", disk: "10GiB"),
        .init(cpu: "2", memory: "4GiB", disk: "20GiB"),
        .init(cpu: "4", memory: "8GiB", disk: "40GiB")
    ]
}

struct NativeVMMinecraftAddon: Equatable, Identifiable {
    let id: String
    let label: String
    let description: String
}

struct NativeVMResources: Equatable, Codable {
    var cpu: String
    var memory: String
    var disk: String
}

struct NativeVMWebsitePlan: Equatable, Codable {
    var title: String
    var tagline: String
    var sections: [Section]
    var gallery: [GalleryImage]?
    var contactEmail: String?

    struct Section: Equatable, Codable { var heading: String; var body: String }
    struct GalleryImage: Equatable, Codable { var url: String; var alt: String; var caption: String }
}

struct NativeVMProjectFile: Equatable, Codable, Identifiable {
    var path: String
    var content: String
    var id: String { path }
}

struct NativeVMSetupPlan: Equatable, Codable {
    var summary: String
    var services: [String]
    var packages: [String]
    var website: NativeVMWebsitePlan?
    var minecraftServerType: String?
    var projectFiles: [NativeVMProjectFile]?
}

struct NativeVMCreateInput: Equatable, Codable {
    var name: String
    var os: String
    var resources: NativeVMResources
    var services: [String]
    var custom_apt_packages: [String]?
    var minecraft_eula_accepted: Bool?
    var minecraft_server_type: String?
    var minecraft_addons: [String]?
    var website: NativeVMWebsitePlan?
    var project_files: [NativeVMProjectFile]?
    var organization_id: String?
}

struct NativeVMProvisioningReceipt: Equatable {
    let name: String
    let organizationID: String?
    let acceptedStatus: Int
}

struct NativeVMProvisioningAuthorization: Equatable {
    let scope: String
    let capturedAt: Date
    let organizationID: String
}

enum NativeVMProvisioningError: LocalizedError, Equatable {
    case signInRequired, impersonationUnsupported, invalidEndpoint, invalidInput(String), invalidResponse
    case responseTooLarge, accessDenied, staleAuthorization, wrongScope, requestFailed(Int), uncertainOutcome

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to set up a virtual machine."
        case .impersonationUnsupported: "Return to your own account before setting up a virtual machine."
        case .invalidEndpoint: "Use a secure API address for virtual machine setup."
        case let .invalidInput(message): message
        case .invalidResponse: "The VM setup service returned an invalid response."
        case .responseTooLarge: "The VM setup response exceeded its size limit."
        case .accessDenied: "Current owner or admin access to the selected organization is required."
        case .staleAuthorization: "Refresh current account and organization access before continuing."
        case .wrongScope: "The VM setup response belongs to a different account or organization."
        case let .requestFailed(status): "VM setup failed (HTTP \(status))."
        case .uncertainOutcome: "VM creation may still be provisioning. Refresh the VM inventory before trying again."
        }
    }
}

enum NativeVMProvisioningPolicy {
    static func validated(_ input: NativeVMCreateInput) throws -> NativeVMCreateInput {
        guard input.name.range(of: #"^[a-z][a-z0-9-]{0,61}[a-z0-9]$"#, options: .regularExpression) != nil else {
            throw NativeVMProvisioningError.invalidInput("Use 2–63 lowercase letters, numbers or hyphens, starting with a letter.")
        }
        guard NativeVMProvisioningOptions.operatingSystems.contains(input.os),
              NativeVMProvisioningOptions.resourcePlans.contains(input.resources) else {
            throw NativeVMProvisioningError.invalidInput("Choose a supported Ubuntu version and resource plan.")
        }
        guard input.services.count <= NativeVMProvisioningOptions.services.count,
              Set(input.services).count == input.services.count,
              input.services.allSatisfy(NativeVMProvisioningOptions.services.contains) else {
            throw NativeVMProvisioningError.invalidInput("Choose supported VM services.")
        }
        let minecraft = input.services.contains("minecraft-java")
        guard minecraft == (input.minecraft_eula_accepted == true) else {
            throw NativeVMProvisioningError.invalidInput("Accept the Minecraft EULA when Minecraft is selected.")
        }
        guard input.os != "ubuntu-24.04-desktop" || input.resources.memory == "8GiB" else {
            throw NativeVMProvisioningError.invalidInput("Ubuntu Desktop requires the largest resource plan.")
        }
        guard input.minecraft_server_type == nil || (minecraft && NativeVMProvisioningOptions.minecraftTypes.contains(input.minecraft_server_type!)) else {
            throw NativeVMProvisioningError.invalidInput("Choose a supported Minecraft server type.")
        }
        guard !minecraft || input.minecraft_server_type != nil else {
            throw NativeVMProvisioningError.invalidInput("Choose Minecraft server software.")
        }
        let serverType = minecraft ? (input.minecraft_server_type ?? "PAPER") : nil
        let addons = input.minecraft_addons ?? []
        let addonKey = Self.minecraftAddonKey(serverType)
        let allowedAddons = addonKey.flatMap { NativeVMProvisioningOptions.minecraftAddonOptions[$0] }?.map(\.id) ?? []
        guard addons.count <= allowedAddons.count, Set(addons).count == addons.count,
              addons.allSatisfy(allowedAddons.contains) else {
            throw NativeVMProvisioningError.invalidInput("Choose add-ons supported by the selected Minecraft server software.")
        }
        let requiresFourGiB = NativeVMProvisioningOptions.fourGiBServerTypes.contains(serverType ?? "")
            || input.project_files?.isEmpty == false
        guard !requiresFourGiB || input.resources.memory != "2GiB" else {
            throw NativeVMProvisioningError.invalidInput("This Minecraft server type or generated project requires the standard 4 GiB plan or larger.")
        }
        let packages = try validatePackages(input.custom_apt_packages ?? [])
        if input.website != nil && !input.services.contains("website") {
            throw NativeVMProvisioningError.invalidInput("Select the website service to configure website content.")
        }
        if input.project_files != nil && (!input.services.contains("nodejs") || input.resources.memory == "2GiB") {
            throw NativeVMProvisioningError.invalidInput("Generated projects require Node.js and at least 4 GiB of memory.")
        }
        let website = try input.website.map(validateWebsite)
        let projectFiles = try input.project_files.map(validateProjectFiles)
        return NativeVMCreateInput(name: input.name, os: input.os, resources: input.resources,
            services: input.services, custom_apt_packages: input.custom_apt_packages == nil ? nil : packages,
            minecraft_eula_accepted: input.minecraft_eula_accepted, minecraft_server_type: input.minecraft_server_type,
            minecraft_addons: input.minecraft_addons == nil ? nil : addons,
            website: website, project_files: projectFiles, organization_id: input.organization_id)
    }

    static func minecraftAddonKey(_ serverType: String?) -> String? {
        switch serverType {
        case "PAPER", "PURPUR": "PAPER"
        case "FABRIC", "QUILT": "FABRIC"
        case "FORGE", "NEOFORGE": "FORGE"
        default: nil
        }
    }

    static func validateSetupPlan(_ plan: NativeVMSetupPlan) throws -> NativeVMSetupPlan {
        guard plan.summary.count <= 400, plan.services.count <= NativeVMProvisioningOptions.services.count,
              Set(plan.services).count == plan.services.count,
              plan.services.allSatisfy(NativeVMProvisioningOptions.services.contains),
              plan.minecraftServerType == nil || NativeVMProvisioningOptions.minecraftTypes.contains(plan.minecraftServerType!) else {
            throw NativeVMProvisioningError.invalidResponse
        }
        let packages = try validatePackages(plan.packages)
        let website = try plan.website.map(validateWebsite)
        let projectFiles = try plan.projectFiles.map(validateProjectFiles)
        guard website == nil || plan.services.contains("website"),
              (projectFiles ?? []).isEmpty || plan.services.contains("nodejs"),
              plan.minecraftServerType == nil || plan.services.contains("minecraft-java") else {
            throw NativeVMProvisioningError.invalidResponse
        }
        guard !plan.services.isEmpty || !packages.isEmpty || website != nil || !(projectFiles ?? []).isEmpty else {
            throw NativeVMProvisioningError.invalidResponse
        }
        return NativeVMSetupPlan(summary: plan.summary, services: plan.services, packages: packages,
            website: website, minecraftServerType: plan.minecraftServerType, projectFiles: projectFiles)
    }

    static func validateProjectFiles(_ files: [NativeVMProjectFile]) throws -> [NativeVMProjectFile] {
        guard files.count <= 96 else { throw NativeVMProvisioningError.invalidInput("Generated project contains too many files.") }
        var totalBytes = 0
        var seen = Set<String>()
        for file in files {
            let parts = file.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard file.path.count <= 180, file.content.utf8.count <= 48 * 1024,
                  file.path.range(of: #"^[A-Za-z0-9_.@/-]+$"#, options: .regularExpression) != nil,
                  !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.lowercased().hasPrefix(".env") && !["node_modules", ".next", ".git"].contains($0.lowercased()) }),
                  seen.insert(file.path).inserted else {
                throw NativeVMProvisioningError.invalidInput("Generated project contains an unsupported or duplicate file path.")
            }
            totalBytes += file.content.utf8.count
            guard totalBytes <= 120 * 1024 else { throw NativeVMProvisioningError.invalidInput("Generated project exceeds 120 KiB.") }
        }
        guard let manifest = files.first(where: { $0.path == "package.json" }),
              let data = manifest.content.data(using: .utf8),
              let manifestJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = manifestJSON["scripts"] as? [String: Any] else {
            throw NativeVMProvisioningError.invalidInput("Generated project needs a valid package.json.")
        }
        let dependencies = manifestJSON["dependencies"] as? [String: Any] ?? [:]
        let devDependencies = manifestJSON["devDependencies"] as? [String: Any] ?? [:]
        let combined = dependencies.merging(devDependencies) { current, _ in current }
        guard ["next", "react", "react-dom"].allSatisfy({ combined[$0] != nil }),
              scripts["build"] as? String == "next build", scripts["start"] as? String == "next start --hostname 0.0.0.0 --port 3000",
              ["prebuild", "postbuild", "prestart", "poststart"].allSatisfy({ scripts[$0] == nil }) else {
            throw NativeVMProvisioningError.invalidInput("Generated project has unsupported build or start settings.")
        }
        return files
    }

    private static func validatePackages(_ packages: [String]) throws -> [String] {
        guard packages.count <= 12, packages.allSatisfy({ $0.range(of: #"^[a-z0-9][a-z0-9+.-]{0,127}$"#, options: .regularExpression) != nil }) else {
            throw NativeVMProvisioningError.invalidInput("Use up to 12 Ubuntu package names containing lowercase letters, numbers, dots, plus signs or hyphens.")
        }
        return Array(Set(packages)).sorted()
    }

    private static func validateWebsite(_ website: NativeVMWebsitePlan) throws -> NativeVMWebsitePlan {
        guard !website.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, website.title.count <= 120,
              website.tagline.count <= 120, website.sections.count <= 5,
              website.sections.allSatisfy({ $0.heading.count <= 100 && $0.body.count <= 500 }),
              (website.gallery?.count ?? 0) <= 8 else {
            throw NativeVMProvisioningError.invalidInput("Review website title, sections and gallery limits.")
        }
        if let email = website.contactEmail, !email.isEmpty,
           email.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) == nil {
            throw NativeVMProvisioningError.invalidInput("Enter a valid website contact email.")
        }
        for image in website.gallery ?? [] {
            guard image.alt.count > 0, image.alt.count <= 240, image.caption.count <= 240,
                  let url = URL(string: image.url), url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else {
                throw NativeVMProvisioningError.invalidInput("Website gallery images need a secure URL and description.")
            }
        }
        return website
    }
}
