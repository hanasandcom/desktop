import XCTest
@testable import Hanasand

final class VirtualMachinesNativePanelTests: XCTestCase {
    func testRouteDetailSelectionOpensOnlyTheExactVMAndDoesNotBecomeSearchText() {
        let items = [Self.vm("vm-17"), Self.vm("vm-170")]

        XCTAssertEqual(nativeVMDetailSelection("vm-17", from: items)?.name, "vm-17")
        XCTAssertNil(nativeVMDetailSelection("vm-1", from: items))
        XCTAssertNil(nativeVMDetailSelection(nil, from: items))
        XCTAssertEqual(nativeVMFilterInventory(items, filter: NativeVMInventoryFilter()).map(\.name), ["vm-17", "vm-170"])
    }

    func testInventoryFiltersNamePowerLifecycleEditorAndMinimumResources() {
        let items = [
            Self.vm("alpha", status: "running", cpu: "4", memory: "8GiB", editors: ["editor-1"]),
            Self.vm("beta", status: "frozen", cpu: "2", memory: "4 GB", editors: []),
            Self.vm("gamma", status: "shut off", cpu: "1", memory: "2GiB", deleteAfter: "2026-11-01T00:00:00Z", editors: ["editor-2"]),
        ]

        XCTAssertEqual(nativeVMFilterInventory(items, filter: NativeVMInventoryFilter(status: "running")).map(\.name), ["alpha", "beta"])
        XCTAssertEqual(nativeVMFilterInventory(items, filter: NativeVMInventoryFilter(status: "stopped")).map(\.name), ["gamma"])
        XCTAssertEqual(nativeVMFilterInventory(items, filter: NativeVMInventoryFilter(lifecycle: "active")).map(\.name), ["alpha", "beta"])
        XCTAssertEqual(nativeVMFilterInventory(items, filter: NativeVMInventoryFilter(lifecycle: "deleted")).map(\.name), ["gamma"])
        XCTAssertEqual(nativeVMFilterInventory(items, filter: NativeVMInventoryFilter(editor: "with")).map(\.name), ["alpha", "gamma"])
        XCTAssertEqual(nativeVMFilterInventory(items, filter: NativeVMInventoryFilter(editor: "editor-1")).map(\.name), ["alpha"])
        XCTAssertEqual(nativeVMFilterInventory(items, filter: NativeVMInventoryFilter(minimumCPU: "3", minimumMemoryGiB: "7")).map(\.name), ["alpha"])
        XCTAssertEqual(nativeVMFilterInventory(items, filter: NativeVMInventoryFilter(query: "BET")).map(\.name), ["beta"])
    }

    func testInventoryPagingClampsNegativeLimitAndPreservesSortedOrder() {
        let sorted = [Self.vm("alpha"), Self.vm("beta"), Self.vm("gamma")]
        XCTAssertEqual(nativeVMPage(sorted, limit: 2).map(\.name), ["alpha", "beta"])
        XCTAssertTrue(nativeVMPage(sorted, limit: -1).isEmpty)
        XCTAssertEqual(nativeVMPage(sorted, limit: 20), sorted)
    }

    func testMemoryUnitsConvertToGiB() {
        XCTAssertEqual(nativeVMMemoryGiB("8GiB"), 8)
        XCTAssertEqual(nativeVMMemoryGiB("4 GB"), 4)
        XCTAssertEqual(nativeVMMemoryGiB("1024MiB"), 1)
        XCTAssertNil(nativeVMMemoryGiB("unavailable"))
    }

    func testVMAccessAndHostOptionControlsRequireCredentialsAndOwnAccount() {
        XCTAssertTrue(NativeVMAccessPolicy.mayManage(canManage: true, isImpersonating: false, hasCredentials: true))
        XCTAssertFalse(NativeVMAccessPolicy.mayManage(canManage: false, isImpersonating: false, hasCredentials: true))
        XCTAssertFalse(NativeVMAccessPolicy.mayManage(canManage: true, isImpersonating: true, hasCredentials: true))
        XCTAssertFalse(NativeVMAccessPolicy.mayManage(canManage: true, isImpersonating: false, hasCredentials: false))
        XCTAssertTrue(NativeVMAccessPolicy.mayRevealSudoPassword(isImpersonating: false, hasCredentials: true))
        XCTAssertFalse(NativeVMAccessPolicy.mayRevealSudoPassword(isImpersonating: true, hasCredentials: true))
        XCTAssertFalse(NativeVMAccessPolicy.mayRevealSudoPassword(isImpersonating: false, hasCredentials: false))
    }

    func testCPUHistoryIsOldestToNewestAndSplitsUnavailableSamples() {
        let newestFirst = [
            Self.metric(id: "new", cpu: "50"),
            Self.metric(id: "missing", cpu: nil),
            Self.metric(id: "old", cpu: "25"),
        ]
        let segments = nativeVMCPUHistorySegments(newestFirst)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0], [NativeVMChartPoint(x: 0, y: 0.75)])
        XCTAssertEqual(segments[1], [NativeVMChartPoint(x: 1, y: 0.5)])
    }

    @MainActor
    func testUncertainPowerActionRequiresCompleteTargetAndAccessReviewBeforeAcknowledgement() throws {
        let gate = NativeVMPowerActionGate()
        let scope = "account-a|personal"
        let intent = try XCTUnwrap(gate.begin(scope: scope, vmName: "vm-17", action: "restart"))

        XCTAssertNil(gate.begin(scope: scope, vmName: "vm-18", action: "stop"))
        XCTAssertTrue(gate.finish(scope: scope, token: intent.token, uncertain: true))
        XCTAssertFalse(gate.canAcknowledge(scope: scope, token: intent.token))
        XCTAssertFalse(gate.markReviewed(scope: scope, token: intent.token, vmName: "vm-17", currentStatus: "running", inventoryComplete: false, targetFound: true, managementReadSucceeded: true))
        XCTAssertFalse(gate.markReviewed(scope: scope, token: intent.token, vmName: "vm-18", currentStatus: "running", inventoryComplete: true, targetFound: true, managementReadSucceeded: true))
        XCTAssertFalse(gate.markReviewed(scope: scope, token: intent.token, vmName: "vm-17", currentStatus: "running", inventoryComplete: true, targetFound: true, managementReadSucceeded: false))

        XCTAssertTrue(gate.markReviewed(scope: scope, token: intent.token, vmName: "VM-17", currentStatus: "running", inventoryComplete: true, targetFound: true, managementReadSucceeded: true))
        XCTAssertTrue(gate.canAcknowledge(scope: scope, token: intent.token))
        XCTAssertFalse(gate.acknowledge(scope: scope, token: "another-token"))
        XCTAssertTrue(gate.acknowledge(scope: scope, token: intent.token))
        XCTAssertNil(gate.intent(for: scope))
        XCTAssertNotNil(gate.begin(scope: scope, vmName: "vm-18", action: "stop"))
    }

    @MainActor
    func testDefinitePowerRejectionReleasesGateAndUncertainFailuresAreScopedToDispatchedRequests() throws {
        let gate = NativeVMPowerActionGate()
        let scope = "account-a|personal"
        let rejected = try XCTUnwrap(gate.begin(scope: scope, vmName: "vm-17", action: "stop"))
        XCTAssertTrue(gate.finish(scope: scope, token: rejected.token, uncertain: false))
        XCTAssertNil(gate.intent(for: scope))

        XCTAssertFalse(nativeVMPowerActionNeedsReviewAfterFailure(DashboardRequestError.httpStatus(403), requestWasDispatched: true))
        XCTAssertFalse(nativeVMPowerActionNeedsReviewAfterFailure(DashboardRequestError.httpStatus(429), requestWasDispatched: true))
        XCTAssertTrue(nativeVMPowerActionNeedsReviewAfterFailure(DashboardRequestError.httpStatus(504), requestWasDispatched: true))
        XCTAssertTrue(nativeVMPowerActionNeedsReviewAfterFailure(DashboardRequestError.httpStatus(500), requestWasDispatched: true))
        XCTAssertTrue(nativeVMPowerActionNeedsReviewAfterFailure(URLError(.timedOut), requestWasDispatched: true))
        XCTAssertFalse(nativeVMPowerActionNeedsReviewAfterFailure(URLError(.timedOut), requestWasDispatched: false))
    }

    @MainActor
    func testPowerActionGateScopesByServiceAccountOrganizationAndOwnership() {
        let api = URL(string: "https://api.hanasand.com")!
        let personal = nativeVMPowerActionScopeKey(apiBaseURL: api, userID: "user-1", organizationID: "personal", isImpersonating: false)
        XCTAssertEqual(personal, nativeVMPowerActionScopeKey(apiBaseURL: api, userID: "user-1", organizationID: "personal", isImpersonating: false))
        XCTAssertNotEqual(personal, nativeVMPowerActionScopeKey(apiBaseURL: api, userID: "user-2", organizationID: "personal", isImpersonating: false))
        XCTAssertNotEqual(personal, nativeVMPowerActionScopeKey(apiBaseURL: api, userID: "user-1", organizationID: "org-1", isImpersonating: false))
        XCTAssertNotEqual(personal, nativeVMPowerActionScopeKey(apiBaseURL: api, userID: "user-1", organizationID: "personal", isImpersonating: true))
    }

    private static func vm(
        _ name: String,
        status: String? = nil,
        cpu: String? = nil,
        memory: String? = nil,
        deleteAfter: String? = nil,
        editors: [String] = []
    ) -> NativeVMInventoryItem {
        NativeVMInventoryItem(
            name: name, owner: "owner-\(name)", createdBy: nil, organizationID: nil, organizationName: nil,
            accessUsers: editors, managed: nil, canAssignOrganization: nil, status: status, statusReason: nil,
            statusCheckedAt: nil, deletedAt: nil, deleteAfter: deleteAfter, deletionError: nil,
            restoredInstanceMissing: nil, primaryHost: nil, failoverHost: nil, failoverPremium: nil,
            failoverEnabled: nil, alwaysRunningPremium: nil, alwaysRunningEnabled: nil, type: nil,
            architecture: nil, created: nil, lastUsed: nil, cpuLimit: cpu, memoryLimit: memory,
            imageDescription: nil, imageOS: nil, imageVersion: nil, ipv4: nil, lastChecked: nil
        )
    }

    private static func metric(id: String, cpu: String?) -> NativeVMMetric {
        NativeVMMetric(id: id, recordedAt: nil, powerState: nil, poweredOnAt: nil, poweredOffAt: nil,
            values: cpu.map { [("CPU usage (%)", $0)] } ?? [])
    }
}
