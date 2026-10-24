import Foundation
import XCTest
@testable import Hanasand

final class NativeVMAdminClientTests: XCTestCase {
    private let base = URL(string: "https://api.hanasand.com/api")!
    private let user = "fixture-user"
    private var requests: [URLRequest] = []
    private var vmChanges: [String: Any] = [:]
    private var access: [String: Any] = ["allowed": true, "canEdit": true]
    private var mutationBody: Any = ["success": true, "message": "Queued", "vms": ["fixture-vm"]]
    private var mutationStatus = 200
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var client: NativeVMAdminClient!
    private let requestLock = NSLock()

    override func setUp() {
        requests = []
        vmChanges = [:]
        access = ["allowed": true, "canEdit": true]
        mutationBody = ["success": true, "message": "Queued", "vms": ["fixture-vm"]]
        mutationStatus = 200
        now = Date(timeIntervalSince1970: 1_800_000_000)
        client = try! makeClient()
    }

    func testAuthorizationReadsCurrentVMAndPlatformPermissionWithoutCookies() async throws {
        let authorization = try await client.loadAuthorization(for: "fixture-vm")
        XCTAssertEqual(authorization.vm.name, "fixture-vm")
        XCTAssertEqual(authorization.access, NativeVMAdminAccess(allowed: true, canEdit: true))
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.contains { $0.url?.path == "/api/vm/fixture-vm" && $0.httpMethod == "GET" })
        XCTAssertTrue(requests.contains { $0.url?.absoluteString == "https://identity.hanasand.com/api/management/organizations?internalPages=1" })
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "id"), user)
            XCTAssertEqual(request.httpShouldHandleCookies, false)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        }
    }

    func testOrganizationAssignmentUsesPutAndVerifiesExactReceipt() async throws {
        mutationBody = ["status": 200, "organization": ["id": "org-fixture", "name": "Fixture Org"]]
        let authorization = try await client.loadAuthorization(for: "fixture-vm")
        let result = try await client.assignOrganization(authorization, organizationID: "org-fixture")
        XCTAssertEqual(result, NativeVMAdminOrganizationReceipt(id: "org-fixture", name: "Fixture Org"))
        let request = try XCTUnwrap(requests.first { $0.httpMethod == "PUT" })
        XCTAssertEqual(request.url?.path, "/api/vm/fixture-vm/organization")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String], ["organizationId": "org-fixture"])
    }

    func testDeletionRequiresExactNameAndPlatformEditThenValidatesIdentity() async throws {
        let authorization = try await client.loadAuthorization(for: "fixture-vm")
        do {
            _ = try await client.scheduleDeletion(authorization, confirmation: "wrong")
            XCTFail("Expected exact-name confirmation requirement")
        } catch { XCTAssertEqual(error as? NativeVMAdminError, .invalidConfirmation) }
        XCTAssertFalse(requests.contains { $0.httpMethod == "DELETE" })

        mutationBody = ["message": "Scheduled", "vm": vmRow(["deleted_at": "2026-10-24T00:00:00Z"])]
        let receipt = try await client.scheduleDeletion(authorization, confirmation: "fixture-vm")
        XCTAssertEqual(receipt.vm.name, "fixture-vm")
        let request = try XCTUnwrap(requests.first { $0.httpMethod == "DELETE" })
        XCTAssertEqual(request.url?.path, "/api/vm/fixture-vm")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String], ["confirmation": "fixture-vm"])
    }

    func testRestoreRequiresDeletedVMAndUsesPost() async throws {
        vmChanges = ["deleted_at": "2026-10-23T00:00:00Z"]
        mutationBody = ["message": "Restored", "vm": vmRow([:])]
        let authorization = try await client.loadAuthorization(for: "fixture-vm")
        let result = try await client.restore(authorization)
        XCTAssertEqual(result.vm.deletedAt, nil)
        XCTAssertTrue(requests.contains { $0.url?.path == "/api/vm/fixture-vm/restore" && $0.httpMethod == "POST" })
    }

    func testStopAllIsPostOnlyAndPreservesVerifiedVMList() async throws {
        mutationBody = ["success": true, "message": "Queued shutdown for one VM.", "vms": ["fixture-vm"]]
        let authorization = try await client.loadAuthorization(for: "fixture-vm")
        let receipt = try await client.stopAll(authorization)
        XCTAssertEqual(receipt.vmNames, ["fixture-vm"])
        XCTAssertEqual(requests.filter { $0.url?.path == "/api/vms/stop" }.map(\.httpMethod), ["POST"])
    }

    func testNoPlatformEditStaleSnapshotWrongAccountScopeOrImpersonationCanMutate() async throws {
        access = ["allowed": true, "canEdit": false]
        let readOnly = try await client.loadAuthorization(for: "fixture-vm")
        do { _ = try await client.stopAll(readOnly); XCTFail("Expected edit denial") }
        catch { XCTAssertEqual(error as? NativeVMAdminError, .accessDenied) }

        access = ["allowed": true, "canEdit": true]
        let fresh = try await client.loadAuthorization(for: "fixture-vm")
        now.addTimeInterval(31)
        do { _ = try await client.stopAll(fresh); XCTFail("Expected stale snapshot denial") }
        catch { XCTAssertEqual(error as? NativeVMAdminError, .staleAuthorization) }

        now.addTimeInterval(-31)
        let otherClient = try makeClient(organization: "org-other")
        do { _ = try await otherClient.stopAll(fresh); XCTFail("Expected cross-scope denial") }
        catch { XCTAssertEqual(error as? NativeVMAdminError, .staleAuthorization) }

        XCTAssertFalse(requests.contains { $0.url?.path == "/api/vms/stop" })
        XCTAssertThrowsError(try NativeVMAdminClient(apiBaseURL: base, userID: user, token: "fixture-token", impersonationToken: "impersonation")) {
            XCTAssertEqual($0 as? NativeVMAdminError, .impersonationUnsupported)
        }
    }

    func testSelectedOrganizationMustMatchFreshVMAndReceipt() async throws {
        let organizationClient = try makeClient(organization: "org-current")
        vmChanges = ["organization_id": "org-other"]
        do { _ = try await organizationClient.loadAuthorization(for: "fixture-vm"); XCTFail("Expected foreign organization rejection") }
        catch { XCTAssertEqual(error as? NativeVMAdminError, .wrongScope) }
        XCTAssertFalse(requests.contains { $0.httpMethod == "DELETE" || $0.httpMethod == "POST" })
    }

    func testMalformedOrWrongVMReceiptIsUncertain() async throws {
        let authorization = try await client.loadAuthorization(for: "fixture-vm")
        mutationBody = ["message": "Scheduled", "vm": vmRow(["name": "other-vm"])]
        do { _ = try await client.scheduleDeletion(authorization, confirmation: "fixture-vm"); XCTFail("Expected identity mismatch") }
        catch { XCTAssertEqual(error as? NativeVMAdminError, .uncertainOutcome) }
    }

    func testInvalidNameEndpointOrOversizeFixtureResponseIsRejected() async throws {
        do { _ = try await client.loadAuthorization(for: "../other"); XCTFail("Expected invalid name") }
        catch { XCTAssertEqual(error as? NativeVMAdminError, .invalidInput) }
        XCTAssertThrowsError(try NativeVMAdminClient(apiBaseURL: URL(string: "http://example.invalid/api")!, userID: user, token: "fixture-token"))

        let largeClient = try NativeVMAdminClient(apiBaseURL: base, userID: user, token: "fixture-token", send: { request in
            (Data(repeating: 0x20, count: NativeVMAdminClient.maximumResponseBytes + 1), Self.response(for: request, status: 200))
        })
        do { _ = try await largeClient.loadAuthorization(for: "fixture-vm"); XCTFail("Expected size limit") }
        catch { XCTAssertEqual(error as? NativeVMAdminError, .responseTooLarge) }
    }

    private func makeClient(organization: String = "personal") throws -> NativeVMAdminClient {
        try NativeVMAdminClient(apiBaseURL: base, userID: user, token: "fixture-token", organizationID: organization,
                                send: { [weak self] request in
            guard let self else { throw NativeVMAdminError.requestFailed(0) }
            self.record(request)
            if request.url?.path.hasSuffix("/management/organizations") == true {
                return (try JSONSerialization.data(withJSONObject: self.access), Self.response(for: request, status: 200))
            }
            if request.httpMethod == "GET" {
                return (try JSONSerialization.data(withJSONObject: Self.vmRow(self.vmChanges)), Self.response(for: request, status: 200))
            }
            return (try JSONSerialization.data(withJSONObject: self.mutationBody), Self.response(for: request, status: self.mutationStatus))
        }, now: { [weak self] in self?.now ?? Date(timeIntervalSince1970: 0) })
    }

    private static func vmRow(_ changes: [String: Any]) -> [String: Any] {
        ["name": "fixture-vm", "owner": "fixture-user", "organization_id": NSNull(),
         "can_assign_organization": true, "deleted_at": NSNull()].merging(changes) { _, new in new }
    }

    private func vmRow(_ changes: [String: Any]) -> [String: Any] { Self.vmRow(changes) }

    private func record(_ request: URLRequest) {
        requestLock.lock()
        defer { requestLock.unlock() }
        requests.append(request)
    }

    private static func response(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    }
}
