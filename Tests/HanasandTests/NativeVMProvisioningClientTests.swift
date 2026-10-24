import Foundation
import XCTest
@testable import Hanasand

final class NativeVMProvisioningClientTests: XCTestCase {
    private let base = URL(string: "https://api.hanasand.com/api")!
    private let user = "fixture-user"
    private var requests: [URLRequest] = []

    func testCreationReadsOrganizationMembershipThenPostsExactScopedPayload() async throws {
        let client = try makeClient(organization: "org-fixture") { request in
            self.requests.append(request)
            switch request.url?.path {
            case "/api/vms/fixture-user": return self.reply(request, status: 200, json: "[]")
            case "/api/organizations": return self.reply(request, status: 200, json: #"{"organizations":[{"id":"org-fixture","lifecycleStatus":"active","role":"admin"}]}"#)
            case "/api/vm":
                return self.reply(request, status: 201, json: #"{"name":"fixture-vm","organization_id":"org-fixture","owner":"fixture-user"}"#)
            default: XCTFail("Unexpected request \(request.url?.absoluteString ?? "")"); return self.reply(request, status: 500, json: "{}")
            }
        }
        let auth = try await client.loadCreationAuthorization()
        let input = NativeVMCreateInput(name: "fixture-vm", os: "ubuntu-24.04", resources: NativeVMProvisioningOptions.resourcePlans[0], services: ["python"], organization_id: "org-fixture")
        let receipt = try await client.create(input, authorization: auth)
        XCTAssertEqual(receipt, NativeVMProvisioningReceipt(name: "fixture-vm", organizationID: "org-fixture", acceptedStatus: 201))
        XCTAssertEqual(requests.map(\.url?.path), ["/api/vms/fixture-user", "/api/organizations", "/api/vms/fixture-user", "/api/organizations", "/api/vm"])
        let post = try XCTUnwrap(requests.last)
        XCTAssertEqual(post.httpMethod, "POST")
        XCTAssertEqual(post.timeoutInterval, 180, accuracy: 0.1)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(post.httpBody)) as? [String: Any])
        XCTAssertEqual(body["organization_id"] as? String, "org-fixture")
        XCTAssertEqual(body["name"] as? String, "fixture-vm")
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "id"), user)
            XCTAssertFalse(request.httpShouldHandleCookies)
        }
    }

    func testCreateRejectsUnreviewedOrganizationRoleBeforeMutation() async throws {
        let client = try makeClient(organization: "org-fixture") { request in
            self.requests.append(request)
            if request.url?.path == "/api/vms/fixture-user" { return self.reply(request, status: 200, json: "[]") }
            return self.reply(request, status: 200, json: #"{"organizations":[{"id":"org-fixture","lifecycleStatus":"active","role":"member"}]}"#)
        }
        do { _ = try await client.loadCreationAuthorization(); XCTFail("Expected access denial") }
        catch { XCTAssertEqual(error as? NativeVMProvisioningError, .accessDenied) }
        XCTAssertFalse(requests.contains { $0.httpMethod == "POST" })
    }

    func testSetupPlanIsExplicitAndReturnsValidatedSuggestion() async throws {
        let client = try makeClient { request in
            self.requests.append(request)
            if request.url?.path == "/api/vms/fixture-user" { return self.reply(request, status: 200, json: "[]") }
            return self.reply(request, status: 200, json: #"{"summary":"Node app","services":["nodejs"],"packages":["git"],"website":null,"minecraftServerType":null,"projectFiles":null}"#)
        }
        let plan = try await client.suggestSetup(prompt: "Make a Node service", os: "ubuntu-24.04")
        XCTAssertEqual(plan.services, ["nodejs"])
        let request = try XCTUnwrap(requests.last)
        XCTAssertEqual(request.url?.path, "/api/vm/setup-plan")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 30, accuracy: 0.1)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String], ["prompt": "Make a Node service", "os": "ubuntu-24.04"])
    }

    func testResumeRequiresEmptyDetailsAndExactConfirmation() async throws {
        let client = try makeClient { request in
            self.requests.append(request)
            switch request.url?.path {
            case "/api/vm/fixture-vm": return self.reply(request, status: 200, json: #"{"name":"fixture-vm","owner":"fixture-user","organization_id":null,"deleted_at":null}"#)
            case "/api/vm/details/fixture-vm": return self.reply(request, status: 200, json: "null")
            case "/api/management/organizations": return self.reply(request, status: 200, json: #"{"allowed":true,"canEdit":false}"#)
            case "/api/vm": return self.reply(request, status: 201, json: #"{"name":"fixture-vm","owner":"fixture-user"}"#)
            default: XCTFail("Unexpected request \(request.url?.absoluteString ?? "")"); return self.reply(request, status: 500, json: "{}")
            }
        }
        let authorization = try await client.loadResumeAuthorization(for: "fixture-vm")
        let input = NativeVMCreateInput(name: "fixture-vm", os: "ubuntu-24.04", resources: NativeVMProvisioningOptions.resourcePlans[0], services: [])
        do { _ = try await client.resume(input, authorization: authorization, confirmation: "wrong"); XCTFail("Expected exact name check") }
        catch { XCTAssertEqual(error as? NativeVMProvisioningError, .invalidInput("Type the exact VM name to confirm resuming its setup.")) }
        XCTAssertFalse(requests.contains { $0.httpMethod == "POST" })
        _ = try await client.resume(input, authorization: authorization, confirmation: "fixture-vm")
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
    }

    func testResumeDoesNotProceedWhenDetailsAlreadyExistOrReadFails() async throws {
        let client = try makeClient { request in
            self.requests.append(request)
            switch request.url?.path {
            case "/api/vm/fixture-vm": return self.reply(request, status: 200, json: #"{"name":"fixture-vm","owner":"fixture-user","organization_id":null,"deleted_at":null}"#)
            case "/api/vm/details/fixture-vm": return self.reply(request, status: 200, json: #"{"name":"fixture-vm","status":"running"}"#)
            default: return self.reply(request, status: 200, json: #"{"allowed":true,"canEdit":true}"#)
            }
        }
        do { _ = try await client.loadResumeAuthorization(for: "fixture-vm"); XCTFail("Existing details forbid resume") }
        catch { XCTAssertEqual(error as? NativeVMProvisioningError, .invalidInput("This VM already has stored details and cannot be resumed through setup.")) }
        XCTAssertFalse(requests.contains { $0.httpMethod == "POST" })
    }

    func testCreationTransportFailureIsUncertainAndNeverAutomaticallyRetried() async throws {
        let client = try makeClient { request in
            self.requests.append(request)
            if request.url?.path == "/api/vms/fixture-user" { return self.reply(request, status: 200, json: "[]") }
            if request.httpMethod == "POST" { throw URLError(.timedOut) }
            return self.reply(request, status: 200, json: #"{"organizations":[]}"#)
        }
        let auth = try await client.loadCreationAuthorization()
        let input = NativeVMCreateInput(name: "fixture-vm", os: "ubuntu-24.04", resources: NativeVMProvisioningOptions.resourcePlans[0], services: [])
        do { _ = try await client.create(input, authorization: auth); XCTFail("Expected uncertain write") }
        catch { XCTAssertEqual(error as? NativeVMProvisioningError, .uncertainOutcome) }
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
    }

    func testCreateEncodesExactMinecraftAddonIDsAndForgeServerType() async throws {
        let client = try makeClient { request in
            self.requests.append(request)
            if request.url?.path == "/api/vms/fixture-user" { return self.reply(request, status: 200, json: "[]") }
            return self.reply(request, status: 201, json: #"{"name":"fixture-vm","owner":"fixture-user"}"#)
        }
        let authorization = try await client.loadCreationAuthorization()
        let input = NativeVMCreateInput(name: "fixture-vm", os: "ubuntu-24.04", resources: NativeVMProvisioningOptions.resourcePlans[1],
            services: ["minecraft-java"], minecraft_eula_accepted: true, minecraft_server_type: "FORGE",
            minecraft_addons: ["modernfix", "jei"])
        _ = try await client.create(input, authorization: authorization)
        let request = try XCTUnwrap(requests.last)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["minecraft_server_type"] as? String, "FORGE")
        XCTAssertEqual(Set(body["minecraft_addons"] as? [String] ?? []), Set(["jei", "modernfix"]))
        XCTAssertEqual(body["minecraft_eula_accepted"] as? Bool, true)
    }

    func testCreateEncodesCustomResourceAllocationExactly() async throws {
        let client = try makeClient { request in
            self.requests.append(request)
            if request.url?.path == "/api/vms/fixture-user" { return self.reply(request, status: 200, json: "[]") }
            return self.reply(request, status: 201, json: #"{"name":"fixture-vm","owner":"fixture-user"}"#)
        }
        let authorization = try await client.loadCreationAuthorization()
        let input = NativeVMCreateInput(
            name: "fixture-vm", os: "ubuntu-24.04",
            resources: NativeVMResources(cpu: "10", memory: "64GiB", disk: "40GiB"), services: ["python"])

        _ = try await client.create(input, authorization: authorization)

        let request = try XCTUnwrap(requests.last)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["resources"] as? [String: String], ["cpu": "10", "memory": "64GiB", "disk": "40GiB"])
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
    }

    func testInvalidCustomAllocationIsRejectedBeforeAnyRequest() async throws {
        let client = try makeClient { request in
            self.requests.append(request)
            return self.reply(request, status: 500, json: "{}")
        }
        let input = NativeVMCreateInput(
            name: "fixture-vm", os: "ubuntu-24.04",
            resources: NativeVMResources(cpu: "11", memory: "64GiB", disk: "40GiB"), services: [])
        let authorization = NativeVMProvisioningAuthorization(scope: "unused", capturedAt: Date(), organizationID: "personal")

        do {
            _ = try await client.create(input, authorization: authorization)
            XCTFail("Expected invalid custom allocation to be rejected.")
        } catch {
            guard let provisioningError = error as? NativeVMProvisioningError else { return XCTFail("Unexpected error: \(error)") }
            if case .invalidInput = provisioningError {} else { XCTFail("Unexpected error: \(provisioningError)") }
        }
        XCTAssertTrue(requests.isEmpty)
    }

    func testDefiniteClientRejectionIsNotReportedAsAnUncertainProvisioningTimeout() async throws {
        let client = try makeClient { request in
            self.requests.append(request)
            if request.url?.path == "/api/vms/fixture-user" { return self.reply(request, status: 200, json: "[]") }
            return self.reply(request, status: 403, json: #"{"error":"forbidden"}"#)
        }
        let authorization = try await client.loadCreationAuthorization()
        let input = NativeVMCreateInput(name: "fixture-vm", os: "ubuntu-24.04", resources: NativeVMProvisioningOptions.resourcePlans[0], services: [])
        do { _ = try await client.create(input, authorization: authorization); XCTFail("Expected HTTP rejection") }
        catch { XCTAssertEqual(error as? NativeVMProvisioningError, .requestFailed(403)) }
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
    }

    private func makeClient(organization: String = "personal", send: @escaping NativeVMProvisioningClient.Sender) throws -> NativeVMProvisioningClient {
        try NativeVMProvisioningClient(apiBaseURL: base, userID: user, token: "fixture-token", organizationID: organization, send: send)
    }

    private func reply(_ request: URLRequest, status: Int, json: String) -> (Data, URLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }
}
