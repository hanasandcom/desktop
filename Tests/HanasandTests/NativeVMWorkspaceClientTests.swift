import Foundation
import XCTest
@testable import Hanasand

final class NativeVMWorkspaceClientTests: XCTestCase {
    func testDetailsRequestKeepsBasePathAndAddsScopedAuthentication() async throws {
        let client = try NativeVMWorkspaceClient(
            apiBaseURL: "https://api.example.test/api",
            userID: "user-1",
            token: "token-value",
            organizationID: "org-2",
            send: { request in
                XCTAssertEqual(request.url?.path, "/api/vm/details/vm-17")
                XCTAssertEqual(request.value(forHTTPHeaderField: "id"), "user-1")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-value")
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-organization-id"), "org-2")
                let data = Data(#"{"name":"vm-17","status":"Running","profiles":["default"],"limits_cpu":"4"}"#.utf8)
                return (data, try Self.response(for: request, status: 200))
            }
        )

        let details = try await client.loadDetails(for: "vm-17")
        XCTAssertEqual(details?.name, "vm-17")
        XCTAssertEqual(details?.profiles, ["default"])
        XCTAssertTrue(details?.fields.contains(where: { $0.0 == "Status" && $0.1 == "Running" }) == true)
    }

    func testMetricsRejectRowsForAnotherVM() async throws {
        let client = try NativeVMWorkspaceClient(
            apiBaseURL: "https://api.example.test/api/",
            userID: "user-1",
            token: "token-value",
            send: { request in
                XCTAssertEqual(request.url?.path, "/api/vm/metrics/vm-17")
                let data = Data(#"[{"name":"vm-18","cpu_usage_percent":12,"power_state":"running"}]"#.utf8)
                return (data, try Self.response(for: request, status: 200))
            }
        )

        do {
            _ = try await client.loadMetrics(for: "vm-17")
            XCTFail("A metrics response for a different VM must be rejected.")
        } catch let error as NativeVMWorkspaceClientError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testManagementReadReturnsCurrentAuthorizationAndServices() async throws {
        let client = try NativeVMWorkspaceClient(
            apiBaseURL: "https://api.example.test/api",
            userID: "user-1",
            token: "token-value",
            send: { request in
                XCTAssertEqual(request.url?.path, "/api/vm/vm-17/public-services")
                let data = Data(#"{"canManage":true,"services":[{"id":"route-1","name":"site","type":"http","port":8080,"hostname":"site.example.test","createdAt":"2026-10-24T10:00:00Z"}]}"#.utf8)
                return (data, try Self.response(for: request, status: 200))
            }
        )

        let access = try await client.loadManagement(for: "vm-17")
        XCTAssertTrue(access.canManage)
        XCTAssertEqual(access.services.first?.id, "route-1")
        XCTAssertEqual(access.services.first?.name, "site")
        XCTAssertEqual(access.services.first?.port, 8080)
        XCTAssertEqual(access.services.first?.hostname, "site.example.test")
        XCTAssertEqual(access.services.first?.createdAt, "2026-10-24T10:00:00Z")
    }

    func testManagementReadAcceptsUnavailableHostname() async throws {
        let client = try NativeVMWorkspaceClient(
            apiBaseURL: "https://api.example.test/api",
            userID: "user-1",
            token: "token-value",
            send: { request in
                let data = Data(#"{"canManage":false,"services":[{"id":"route-1","name":"reserved","type":"http","port":8080,"hostname":null,"createdAt":"2026-10-24T10:00:00Z"}]}"#.utf8)
                return (data, try Self.response(for: request, status: 200))
            }
        )

        let access = try await client.loadManagement(for: "vm-17")
        XCTAssertFalse(access.canManage)
        XCTAssertEqual(access.vmName, "vm-17")
        XCTAssertNil(access.services.first?.hostname)
    }

    func testCreatePublicServiceUsesCurrentAuthorizationAndValidatesReceipt() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let client = try NativeVMWorkspaceClient(
            apiBaseURL: "https://api.example.test/api",
            userID: "user-1",
            token: "token-value",
            organizationID: "org-2",
            now: { now },
            send: { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "id"), "user-1")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-value")
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-organization-id"), "org-2")
                switch (request.httpMethod, request.url?.path) {
                case ("GET", "/api/vm/vm-17/public-services"):
                    return (Data(#"{"canManage":true,"services":[]}"#.utf8), try Self.response(for: request, status: 200))
                case ("POST", "/api/vm/vm-17/public-services"):
                    let payload = try XCTUnwrap(request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
                    XCTAssertEqual(payload["name"] as? String, "survival")
                    XCTAssertEqual(payload["type"] as? String, "minecraft-java")
                    XCTAssertEqual(payload["port"] as? Int, 25565)
                    return (Data(#"{"id":"route-2","name":"survival","type":"minecraft-java","port":25565,"hostname":"survival.hanasand.com","createdAt":"2026-10-24T10:00:00Z"}"#.utf8), try Self.response(for: request, status: 201))
                default:
                    XCTFail("Unexpected VM public service request: \(String(describing: request.url))")
                    return (Data(), try Self.response(for: request, status: 500))
                }
            }
        )

        let authorization = try await client.loadManagement(for: "vm-17")
        let created = try await client.createPublicService(for: "vm-17", authorization: authorization,
                                                           name: " Survival ", type: "minecraft-java", port: 25565)
        XCTAssertEqual(created.id, "route-2")
        XCTAssertEqual(created.hostname, "survival.hanasand.com")
    }

    func testCreatePublicServiceRejectsBadInputBeforeSendingMutation() async throws {
        let client = try NativeVMWorkspaceClient(
            apiBaseURL: "https://api.example.test/api",
            userID: "user-1",
            token: "token-value",
            send: { request in
                XCTAssertEqual(request.httpMethod, "GET")
                return (Data(#"{"canManage":true,"services":[]}"#.utf8), try Self.response(for: request, status: 200))
            }
        )
        let authorization = try await client.loadManagement(for: "vm-17")

        for (name, type, port) in [("-bad", "http", 80), ("port-8080", "http", 8080), ("valid", "udp", 53), ("valid", "http", 65_536)] {
            do {
                _ = try await client.createPublicService(for: "vm-17", authorization: authorization, name: name, type: type, port: port)
                XCTFail("Invalid public service input must be rejected.")
            } catch let error as NativeVMWorkspaceClientError {
                XCTAssertEqual(error, .invalidServiceInput)
            }
        }
    }

    func testPublicServiceMutationRejectsStaleOrUnmanagedSnapshot() async throws {
        let sampledAt = Date(timeIntervalSince1970: 1_800_000_000)
        let readClient = try NativeVMWorkspaceClient(
            apiBaseURL: "https://api.example.test/api", userID: "user-1", token: "token-value",
            now: { sampledAt },
            send: { request in
                (Data(#"{"canManage":true,"services":[]}"#.utf8), try Self.response(for: request, status: 200))
            }
        )
        let authorization = try await readClient.loadManagement(for: "vm-17")
        let staleClient = try NativeVMWorkspaceClient(
            apiBaseURL: "https://api.example.test/api", userID: "user-1", token: "token-value",
            now: { sampledAt.addingTimeInterval(31) },
            send: { request in
                XCTFail("A stale authorization snapshot must not send a mutation.")
                return (Data(), try Self.response(for: request, status: 500))
            }
        )
        do {
            _ = try await staleClient.createPublicService(for: "vm-17", authorization: authorization, name: "site", type: "http", port: 80)
            XCTFail("A stale authorization snapshot must be rejected.")
        } catch let error as NativeVMWorkspaceClientError {
            XCTAssertEqual(error, .staleManagementSnapshot)
        }

        let unmanaged = NativeVMManagementAccess(scope: authorization.scope, vmName: "vm-17", capturedAt: sampledAt,
                                                 canManage: false, services: [])
        do {
            _ = try await readClient.createPublicService(for: "vm-17", authorization: unmanaged, name: "site", type: "http", port: 80)
            XCTFail("An unmanaged snapshot must be rejected.")
        } catch let error as NativeVMWorkspaceClientError {
            XCTAssertEqual(error, .permissionDenied)
        }
    }

    func testRemovePublicServiceRequiresIDInCurrentSnapshotAndValidatesReceipt() async throws {
        let client = try NativeVMWorkspaceClient(
            apiBaseURL: "https://api.example.test/api", userID: "user-1", token: "token-value",
            send: { request in
                switch (request.httpMethod, request.url?.path) {
                case ("GET", "/api/vm/vm-17/public-services"):
                    return (Data(#"{"canManage":true,"services":[{"id":"route-1","name":"site","type":"http","port":80,"hostname":"site.hanasand.com"}]}"#.utf8), try Self.response(for: request, status: 200))
                case ("DELETE", "/api/vm/vm-17/public-services/route-1"):
                    return (Data(#"{"ok":true}"#.utf8), try Self.response(for: request, status: 200))
                default:
                    XCTFail("Unexpected VM public service request: \(String(describing: request.url))")
                    return (Data(), try Self.response(for: request, status: 500))
                }
            }
        )
        let authorization = try await client.loadManagement(for: "vm-17")
        do {
            try await client.removePublicService(for: "vm-17", authorization: authorization, serviceID: "route-2")
            XCTFail("An ID absent from the current service snapshot must not be deleted.")
        } catch let error as NativeVMWorkspaceClientError {
            XCTAssertEqual(error, .staleManagementSnapshot)
        }
        try await client.removePublicService(for: "vm-17", authorization: authorization, serviceID: "route-1")
    }

    func testPublicServiceMutationNetworkFailureIsUncertain() async throws {
        let client = try NativeVMWorkspaceClient(
            apiBaseURL: "https://api.example.test/api", userID: "user-1", token: "token-value",
            send: { request in
                if request.httpMethod == "GET" {
                    return (Data(#"{"canManage":true,"services":[]}"#.utf8), try Self.response(for: request, status: 200))
                }
                throw URLError(.timedOut)
            }
        )
        let authorization = try await client.loadManagement(for: "vm-17")
        do {
            _ = try await client.createPublicService(for: "vm-17", authorization: authorization, name: "site", type: "http", port: 80)
            XCTFail("A lost mutation response must require a refresh before retrying.")
        } catch let error as NativeVMWorkspaceClientError {
            XCTAssertEqual(error, .uncertainOutcome)
        }
    }

    func testPublicServiceRedirectResponseRequiresRefreshBeforeRetry() async throws {
        let client = try NativeVMWorkspaceClient(
            apiBaseURL: "https://api.example.test/api", userID: "user-1", token: "token-value",
            send: { request in
                if request.httpMethod == "GET" {
                    return (Data(#"{"canManage":true,"services":[]}"#.utf8), try Self.response(for: request, status: 200))
                }
                return (Data(#"{"ok":true}"#.utf8), try Self.response(for: request, status: 302))
            }
        )
        let authorization = try await client.loadManagement(for: "vm-17")

        do {
            _ = try await client.createPublicService(for: "vm-17", authorization: authorization, name: "site", type: "http", port: 80)
            XCTFail("A redirect after a service mutation must be treated as an uncertain outcome.")
        } catch let error as NativeVMWorkspaceClientError {
            XCTAssertEqual(error, .uncertainOutcome)
        }
    }

    func testInventoryMergesOwnedAndAccessibleRowsAndCarriesWorkspaceHeader() async throws {
        let client = try NativeVMWorkspaceClient(
            apiBaseURL: "https://api.example.test/api",
            userID: "user-1",
            token: "token-value",
            organizationID: "org-2",
            send: { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-organization-id"), "org-2")
                switch request.url?.path {
                case "/api/vms/user-1":
                    return (Data(#"[{"name":"vm-17","owner":"user-1","organization_id":"org-2","status":"running","limits_cpu":"4","limits_memory":"8GiB","access_users":["editor-1"]}]"#.utf8), try Self.response(for: request, status: 200))
                case "/api/vms/access/user-1":
                    return (Data(#"[{"name":"vm-17","owner":"user-1","organization_id":"org-2","status":"running"},{"name":"vm-18","owner":"other","organization_id":"org-2","deleted_at":"2026-10-20T10:00:00Z"}]"#.utf8), try Self.response(for: request, status: 200))
                default: XCTFail("Unexpected VM inventory URL: \(String(describing: request.url))"); throw NativeVMWorkspaceClientError.invalidResponse
                }
            }
        )

        let snapshot = try await client.loadInventory()
        XCTAssertTrue(snapshot.isComplete)
        XCTAssertEqual(snapshot.items.map(\.name), ["vm-17", "vm-18"])
        XCTAssertEqual(snapshot.items.first?.accessUsers, ["editor-1"])
        XCTAssertEqual(snapshot.items.last?.isScheduledForDeletion, true)
    }

    func testInventoryReturnsPartialRowsWhenOneSourceFails() async throws {
        let client = try NativeVMWorkspaceClient(
            apiBaseURL: "https://api.example.test/api",
            userID: "user-1",
            token: "token-value",
            send: { request in
                if request.url?.path == "/api/vms/user-1" {
                    return (Data(#"[{"name":"vm-17","owner":"user-1"}]"#.utf8), try Self.response(for: request, status: 200))
                }
                return (Data(#"{"error":"unavailable"}"#.utf8), try Self.response(for: request, status: 503))
            }
        )

        let snapshot = try await client.loadInventory()
        XCTAssertFalse(snapshot.isComplete)
        XCTAssertEqual(snapshot.items.map(\.name), ["vm-17"])
        XCTAssertEqual(snapshot.warnings.count, 1)
    }

    func testHistoricalMetricsRetainFullFieldsAndSortNewestFirst() async throws {
        let client = try NativeVMWorkspaceClient(
            apiBaseURL: "https://api.example.test/api",
            userID: "user-1",
            token: "token-value",
            send: { request in
                let data = Data(#"[{"id":1,"name":"vm-17","created_at":"2026-10-24T09:00:00Z","cpu_usage_percent":12.5,"gpu_memory_used_mb":256,"disk_read_iops":20,"powered_on_at":"2026-10-23T09:00:00Z"},{"id":2,"name":"vm-17","created_at":"2026-10-24T10:00:00Z","cpu_usage_percent":25}]"#.utf8)
                return (data, try Self.response(for: request, status: 200))
            }
        )

        let metrics = try await client.loadMetrics(for: "vm-17")
        XCTAssertEqual(metrics.count, 2)
        XCTAssertEqual(metrics.first?.id, "2")
        XCTAssertEqual(metrics.first?.values.first(where: { $0.0 == "CPU usage (%)" })?.1, "25")
        XCTAssertTrue(metrics.last?.values.contains(where: { $0.0 == "GPU memory used (MB)" && $0.1 == "256" }) == true)
        XCTAssertEqual(metrics.last?.poweredOnAt, "2026-10-23T09:00:00Z")
    }

    func testDetailsIncludeHardwareAndNetworkFields() async throws {
        let client = try NativeVMWorkspaceClient(
            apiBaseURL: "https://api.example.test/api",
            userID: "user-1",
            token: "token-value",
            send: { request in
                let data = Data(#"{"name":"vm-17","device_eth0_ipv4_address":"192.0.2.8","device_eth0_name":"eth0","device_eth0_network":"lan0","volatile_eth0_hwaddr":"00:11:22:33:44:55","volatile_last_state_power":"RUNNING","ephemeral":false}"#.utf8)
                return (data, try Self.response(for: request, status: 200))
            }
        )
        let details = try await client.loadDetails(for: "vm-17")
        XCTAssertTrue(details?.fields.contains(where: { $0.0 == "Network interface" && $0.1 == "eth0" }) == true)
        XCTAssertTrue(details?.fields.contains(where: { $0.0 == "Network MAC" && $0.1 == "00:11:22:33:44:55" }) == true)
        XCTAssertTrue(details?.fields.contains(where: { $0.0 == "Ephemeral" && $0.1 == "0" || $0.0 == "Ephemeral" && $0.1 == "false" }) == true)
    }

    func testVMNameAndEndpointValidation() throws {
        XCTAssertThrowsError(try NativeVMWorkspaceClient(apiBaseURL: "http://api.example.test/api", userID: "u", token: "t"))
        XCTAssertThrowsError(try NativeVMWorkspaceClient(apiBaseURL: "https://user:pass@api.example.test/api", userID: "u", token: "t"))
        XCTAssertNil(nativeVMActionPath(vmName: "node/other", action: "start", isImpersonating: false))
        XCTAssertNil(nativeVMActionPath(vmName: "node-1", action: "delete", isImpersonating: false))
        XCTAssertNil(nativeVMActionPath(vmName: "node-1", action: "start", isImpersonating: true))
        XCTAssertEqual(nativeVMActionPath(vmName: "node-1", action: "restart", isImpersonating: false), "vm/node-1/restart")
    }

    private static func response(for request: URLRequest, status: Int) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil))
    }
}
