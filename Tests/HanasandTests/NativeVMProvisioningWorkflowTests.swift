import XCTest
@testable import Hanasand

final class NativeVMProvisioningWorkflowTests: XCTestCase {
    func testSupportedOperatingSystemsResourcesAndServiceSet() {
        XCTAssertEqual(NativeVMProvisioningOptions.operatingSystems, ["ubuntu-22.04", "ubuntu-24.04", "ubuntu-26.04", "ubuntu-24.04-desktop"])
        XCTAssertEqual(NativeVMProvisioningOptions.resourcePlans.map(\.memory), ["2GiB", "4GiB", "8GiB"])
        XCTAssertTrue(NativeVMProvisioningOptions.services.contains("minecraft-java"))
        XCTAssertTrue(NativeVMProvisioningOptions.services.contains("website"))
    }

    func testSelectingUbuntuDesktopRequiresAtLeastEightGiB() {
        let plans = NativeVMProvisioningOptions.resourcePlans
        XCTAssertEqual(
            NativeVMProvisioningPolicy.resources(afterSelectingOperatingSystem: "ubuntu-24.04-desktop", current: plans[0]),
            plans[2]
        )
        XCTAssertTrue(NativeVMProvisioningPolicy.canSelect(plans[2], forOperatingSystem: "ubuntu-24.04-desktop"))
        XCTAssertFalse(NativeVMProvisioningPolicy.canSelect(plans[0], forOperatingSystem: "ubuntu-24.04-desktop"))
        XCTAssertFalse(NativeVMProvisioningPolicy.canSelect(plans[1], forOperatingSystem: "ubuntu-24.04-desktop"))
        XCTAssertTrue(NativeVMProvisioningPolicy.canSelect(.init(cpu: "1", memory: "8GiB", disk: "40GiB"), forOperatingSystem: "ubuntu-24.04-desktop"))
        XCTAssertFalse(NativeVMProvisioningPolicy.canSelect(.init(cpu: "1", memory: "7GiB", disk: "40GiB"), forOperatingSystem: "ubuntu-24.04-desktop"))
        XCTAssertTrue(NativeVMProvisioningPolicy.canSelect(plans[0], forOperatingSystem: "ubuntu-24.04"))
    }

    func testCustomResourceAllocationsMatchWebsiteBoundsAndExistingMinimums() throws {
        let minimum = NativeVMProvisioningPolicy.customAllocation(cpu: "1", memoryGiB: "1")
        let maximum = NativeVMProvisioningPolicy.customAllocation(cpu: "10", memoryGiB: "64")
        XCTAssertEqual(minimum, NativeVMResources(cpu: "1", memory: "1GiB", disk: "40GiB"))
        XCTAssertNoThrow(try NativeVMProvisioningPolicy.validated(.init(name: "fixture-vm", os: "ubuntu-24.04", resources: minimum, services: [])))
        XCTAssertNoThrow(try NativeVMProvisioningPolicy.validated(.init(name: "fixture-vm", os: "ubuntu-24.04", resources: maximum, services: [])))
        XCTAssertNoThrow(try NativeVMProvisioningPolicy.validated(.init(name: "fixture-vm", os: "ubuntu-24.04-desktop", resources: .init(cpu: "1", memory: "8GiB", disk: "40GiB"), services: [])))

        let invalidAllocations = [
            NativeVMResources(cpu: "0", memory: "4GiB", disk: "40GiB"),
            NativeVMResources(cpu: "11", memory: "4GiB", disk: "40GiB"),
            NativeVMResources(cpu: "2", memory: "0GiB", disk: "40GiB"),
            NativeVMResources(cpu: "2", memory: "65GiB", disk: "40GiB"),
            NativeVMResources(cpu: "3", memory: "4GiB", disk: "20GiB"),
        ]
        for allocation in invalidAllocations {
            XCTAssertThrowsError(try NativeVMProvisioningPolicy.validated(.init(name: "fixture-vm", os: "ubuntu-24.04", resources: allocation, services: [])))
        }
        XCTAssertThrowsError(try NativeVMProvisioningPolicy.validated(.init(name: "fixture-vm", os: "ubuntu-24.04-desktop", resources: .init(cpu: "1", memory: "7GiB", disk: "40GiB"), services: [])))

        let modded = NativeVMCreateInput(name: "fixture-vm", os: "ubuntu-24.04", resources: .init(cpu: "10", memory: "3GiB", disk: "40GiB"), services: ["minecraft-java"], minecraft_eula_accepted: true, minecraft_server_type: "FORGE")
        XCTAssertThrowsError(try NativeVMProvisioningPolicy.validated(modded))
        let generated = NativeVMCreateInput(name: "fixture-vm", os: "ubuntu-24.04", resources: .init(cpu: "2", memory: "3GiB", disk: "40GiB"), services: ["nodejs"], project_files: [.init(path: "package.json", content: #"{"dependencies":{"next":"1","react":"1","react-dom":"1"},"scripts":{"build":"next build","start":"next start --hostname 0.0.0.0 --port 3000"}}"#)])
        XCTAssertThrowsError(try NativeVMProvisioningPolicy.validated(generated))
    }

    func testCreateValidationEnforcesNameResourcesAndEULA() throws {
        let base = NativeVMCreateInput(name: "fixture-vm", os: "ubuntu-24.04", resources: NativeVMProvisioningOptions.resourcePlans[1], services: ["minecraft-java"], minecraft_eula_accepted: true, minecraft_server_type: "PAPER")
        XCTAssertEqual(try NativeVMProvisioningPolicy.validated(base), base)
        XCTAssertThrowsError(try NativeVMProvisioningPolicy.validated(NativeVMCreateInput(name: "Invalid_Name", os: base.os, resources: base.resources, services: [])))
        XCTAssertThrowsError(try NativeVMProvisioningPolicy.validated(NativeVMCreateInput(name: base.name, os: base.os, resources: NativeVMProvisioningOptions.resourcePlans[0], services: ["minecraft-java"], minecraft_eula_accepted: true)))
        XCTAssertThrowsError(try NativeVMProvisioningPolicy.validated(NativeVMCreateInput(name: base.name, os: base.os, resources: base.resources, services: ["minecraft-java"])))
        XCTAssertThrowsError(try NativeVMProvisioningPolicy.validated(NativeVMCreateInput(name: base.name, os: "ubuntu-24.04-desktop", resources: base.resources, services: [])))
    }

    func testMinecraftAddonListsAndServerAliasesMatchWebsiteChoices() throws {
        XCTAssertEqual(NativeVMProvisioningOptions.minecraftTypes, ["PAPER", "VANILLA", "FABRIC", "QUILT", "NEOFORGE", "FORGE", "PURPUR", "FOLIA"])
        XCTAssertEqual(NativeVMProvisioningOptions.minecraftAddonOptions["PAPER"]?.map(\.id), ["essentialsx", "luckperms", "viaversion", "worldedit", "spark"])
        XCTAssertEqual(NativeVMProvisioningOptions.minecraftAddonOptions["FABRIC"]?.map(\.id), ["fabric-api", "lithium", "ferritecore", "krypton", "spark"])
        XCTAssertEqual(NativeVMProvisioningOptions.minecraftAddonOptions["FORGE"]?.map(\.id), ["jei", "ferritecore", "modernfix", "spark"])
        XCTAssertEqual(NativeVMProvisioningPolicy.minecraftAddonKey("PURPUR"), "PAPER")
        XCTAssertEqual(NativeVMProvisioningPolicy.minecraftAddonKey("QUILT"), "FABRIC")
        XCTAssertEqual(NativeVMProvisioningPolicy.minecraftAddonKey("NEOFORGE"), "FORGE")
        XCTAssertNil(NativeVMProvisioningPolicy.minecraftAddonKey("FOLIA"))
    }

    func testMinecraftAddonPairsAndModdedMemoryRequirementAreValidated() throws {
        let standard = NativeVMProvisioningOptions.resourcePlans[1]
        let small = NativeVMProvisioningOptions.resourcePlans[0]
        func input(type: String, addons: [String], resources: NativeVMResources) -> NativeVMCreateInput {
            NativeVMCreateInput(name: "fixture-vm", os: "ubuntu-24.04", resources: resources, services: ["minecraft-java"],
                                minecraft_eula_accepted: true, minecraft_server_type: type, minecraft_addons: addons)
        }
        XCTAssertNoThrow(try NativeVMProvisioningPolicy.validated(input(type: "PAPER", addons: ["essentialsx"], resources: small)))
        XCTAssertNoThrow(try NativeVMProvisioningPolicy.validated(input(type: "PURPUR", addons: ["worldedit"], resources: small)))
        XCTAssertNoThrow(try NativeVMProvisioningPolicy.validated(input(type: "QUILT", addons: ["fabric-api"], resources: standard)))
        XCTAssertNoThrow(try NativeVMProvisioningPolicy.validated(input(type: "NEOFORGE", addons: ["modernfix"], resources: standard)))
        XCTAssertThrowsError(try NativeVMProvisioningPolicy.validated(input(type: "PAPER", addons: ["fabric-api"], resources: standard)))
        XCTAssertThrowsError(try NativeVMProvisioningPolicy.validated(input(type: "VANILLA", addons: ["spark"], resources: standard)))
        XCTAssertThrowsError(try NativeVMProvisioningPolicy.validated(input(type: "FORGE", addons: ["jei"], resources: small)))
        XCTAssertThrowsError(try NativeVMProvisioningPolicy.validated(input(type: "FOLIA", addons: ["spark"], resources: standard)))
    }

    func testPackagesAndWebsiteRequireSupportedValuesAndSelectedService() throws {
        let pkgInput = NativeVMCreateInput(name: "fixture-vm", os: "ubuntu-24.04", resources: NativeVMProvisioningOptions.resourcePlans[0], services: [], custom_apt_packages: ["git", "curl", "git"])
        XCTAssertEqual(try NativeVMProvisioningPolicy.validated(pkgInput).custom_apt_packages, ["curl", "git"])
        let unsafe = NativeVMCreateInput(name: "fixture-vm", os: "ubuntu-24.04", resources: NativeVMProvisioningOptions.resourcePlans[0], services: [], custom_apt_packages: ["curl;echo hacked"])
        XCTAssertThrowsError(try NativeVMProvisioningPolicy.validated(unsafe))
        let website = NativeVMWebsitePlan(title: "Site", tagline: "", sections: [], gallery: nil, contactEmail: nil)
        let invalid = NativeVMCreateInput(name: "fixture-vm", os: "ubuntu-24.04", resources: NativeVMProvisioningOptions.resourcePlans[0], services: [], website: website)
        XCTAssertThrowsError(try NativeVMProvisioningPolicy.validated(invalid))
        let valid = NativeVMCreateInput(name: "fixture-vm", os: "ubuntu-24.04", resources: NativeVMProvisioningOptions.resourcePlans[0], services: ["website"], website: website)
        XCTAssertNoThrow(try NativeVMProvisioningPolicy.validated(valid))
    }

    func testGeneratedProjectFilesRequireSafePathsManifestAndNodeCapacity() throws {
        let manifest = #"{"dependencies":{"next":"1","react":"1","react-dom":"1"},"scripts":{"build":"next build","start":"next start --hostname 0.0.0.0 --port 3000"}}"#
        let files = [NativeVMProjectFile(path: "package.json", content: manifest), NativeVMProjectFile(path: "app/page.tsx", content: "export default function Page(){return null}")]
        let valid = NativeVMCreateInput(name: "fixture-vm", os: "ubuntu-24.04", resources: NativeVMProvisioningOptions.resourcePlans[1], services: ["nodejs"], project_files: files)
        XCTAssertNoThrow(try NativeVMProvisioningPolicy.validated(valid))
        let traversal = NativeVMCreateInput(name: valid.name, os: valid.os, resources: valid.resources, services: valid.services, project_files: [files[0], .init(path: "../.env", content: "secret")])
        XCTAssertThrowsError(try NativeVMProvisioningPolicy.validated(traversal))
        let insufficient = NativeVMCreateInput(name: valid.name, os: valid.os, resources: NativeVMProvisioningOptions.resourcePlans[0], services: ["nodejs"], project_files: files)
        XCTAssertThrowsError(try NativeVMProvisioningPolicy.validated(insufficient))
    }

    func testAISetupPlanValidatesBeforeItCanBecomeDraft() throws {
        let plan = NativeVMSetupPlan(summary: "Reviewed starter", services: ["nodejs"], packages: ["git", "git"], website: nil, minecraftServerType: nil, projectFiles: nil)
        XCTAssertEqual(try NativeVMProvisioningPolicy.validateSetupPlan(plan).packages, ["git"])
        let forgePlan = NativeVMSetupPlan(summary: "Reviewed Minecraft setup", services: ["minecraft-java"], packages: [], website: nil, minecraftServerType: "FORGE", projectFiles: nil)
        XCTAssertEqual(try NativeVMProvisioningPolicy.validateSetupPlan(forgePlan).minecraftServerType, "FORGE")
        XCTAssertThrowsError(try NativeVMProvisioningPolicy.validateSetupPlan(.init(summary: "", services: ["sudo"], packages: [], website: nil, minecraftServerType: nil, projectFiles: nil)))
        XCTAssertThrowsError(try NativeVMProvisioningPolicy.validateSetupPlan(.init(summary: "", services: [], packages: [], website: nil, minecraftServerType: nil, projectFiles: nil)))
    }
}
