import Foundation
import XCTest
@testable import Hanasand

final class InfrastructureViewsTests: XCTestCase {
    private let api = URL(string: "https://api.example.test/api")!
    private let cdn = URL(string: "https://cdn.example.test/api")!

    func testBlocklistReadUsesAuthenticatedCDNEndpointAndParsesOnlyBoundedRows() async throws {
        var captured: URLRequest?
        let body = #"[{"id":7,"type":"ip","value":"192.0.2.4","is_vpn":true,"is_proxy":false,"is_tor":false,"is_relay":true,"owner":"Example ISP","location":{"country":"NO","city":"Oslo"},"requests":12,"created_at":"2026-10-20T12:00:00Z","updated_at":"2026-10-21T12:00:00Z"}]"#.data(using: .utf8)!
        let client = try makeClient { request in
            captured = request
            return (body, Self.response(for: request, status: 200))
        }

        let entries = try await client.loadBlocklist()

        XCTAssertEqual(captured?.url?.absoluteString, "https://cdn.example.test/api/blocklist/overview")
        XCTAssertEqual(captured?.httpMethod, "GET")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "owner.test")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].kind, .ip)
        XCTAssertEqual(entries[0].requests, 12)
        XCTAssertEqual(entries[0].location, "NO, Oslo")
        XCTAssertEqual(entries[0].signals, ["VPN", "Relay"])
    }

    func testBlocklistChangesUseAllowlistedFieldsAndRequireOwnAccount() async throws {
        var captured: URLRequest?
        let client = try makeClient { request in
            captured = request
            let result = #"{"id":9,"metric":"ip","value":"2001:db8::1"}"#.data(using: .utf8)!
            return (result, Self.response(for: request, status: 201))
        }
        let draft = InfrastructureBlocklistDraft(kind: .ip, value: "2001:db8::1", isVPN: true, isProxy: false, isTor: true)

        try await client.createBlocklistEntry(draft)

        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.url?.absoluteString, "https://cdn.example.test/api/blocklist")
        let body = try XCTUnwrap(captured?.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(payload, ["metric": "ip", "value": "2001:db8::1"])

        let impersonated = try makeClient(impersonationToken: "proxy-token") { request in
            (Data("[]".utf8), Self.response(for: request, status: 200))
        }
        do {
            _ = try await impersonated.loadBlocklist()
            XCTFail("Impersonated account must not read global traffic controls")
        } catch let error as InfrastructureViewsError {
            XCTAssertEqual(error.localizedDescription, InfrastructureViewsError.ownAccountRequired.localizedDescription)
        }
    }

    func testBlocklistUpdateRequiresEntryFromCurrentSnapshotAndUsesFixedColumnNames() async throws {
        var captured: URLRequest?
        let client = try makeClient { request in
            captured = request
            let row = #"{"id":3,"metric":"user_agent","value":"Updated","is_vpn":false,"is_proxy":true,"is_tor":false,"is_relay":false}"#.data(using: .utf8)!
            return (row, Self.response(for: request, status: 200))
        }
        let entry = InfrastructureBlocklistEntry(id: 3, kind: .userAgent, value: "Example", isVPN: true, isProxy: false,
            isTor: true, isRelay: false, owner: "", location: "", requests: nil, createdAt: "", updatedAt: "")
        let edited = InfrastructureBlocklistDraft(kind: .userAgent, value: "Updated", isVPN: false, isProxy: true, isTor: false)

        try await client.updateBlocklistEntry(entry, draft: edited, currentEntries: [entry])

        XCTAssertEqual(captured?.httpMethod, "PUT")
        XCTAssertEqual(captured?.url?.absoluteString, "https://cdn.example.test/api/blocklist/3")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(captured?.httpBody)) as? [String: Any])
        XCTAssertEqual(payload["metric"] as? String, "user_agent")
        XCTAssertEqual(payload["value"] as? String, "Updated")
        XCTAssertEqual(payload["is_vpn"] as? Bool, false)
        XCTAssertEqual(payload["is_proxy"] as? Bool, true)
        XCTAssertNil(payload["owner"])
        XCTAssertNil(payload["hits"])

        do {
            try await client.updateBlocklistEntry(entry, draft: edited, currentEntries: [])
            XCTFail("Stale or foreign entries must not be edited")
        } catch let error as InfrastructureViewsError {
            XCTAssertEqual(error.localizedDescription, InfrastructureViewsError.invalidScope.localizedDescription)
        }
    }

    func testContainerSnapshotCarriesScopeAndValidatesBoundedUniqueInventory() async throws {
        let sample = #"{"generated_at":"2026-10-22T10:00:00Z","systemTelemetry":{"system":{}},"dockerTelemetry":{"generated_at":"2026-10-22T10:00:00Z","source":"docker_engine","containers":[{"id":"0123456789abcdef","name":"api","image":"hanasand/api","state":"running","health":"healthy","stats":{"cpu_percent":12.5,"memory_bytes":2048,"memory_limit_bytes":4096,"memory_percent":50},"restart_count":2,"ports":[{"ip":"127.0.0.1","private_port":8080,"public_port":443,"type":"tcp"}]}]}}"#.data(using: .utf8)!
        let client = try makeClient { request in (sample, Self.response(for: request, status: 200)) }

        let snapshot = try await client.loadContainers()

        XCTAssertEqual(snapshot.source, "docker_engine")
        XCTAssertEqual(snapshot.activeContainers.count, 1)
        XCTAssertEqual(snapshot.activeContainers[0].cpuLabel, "12.5%")
        XCTAssertEqual(snapshot.activeContainers[0].ports.first?.publicPort, 443)
        XCTAssertEqual(snapshot.accountScope, client.accountScope)
    }

    func testContainerLogsHandoffTargetsNativeLogsWithServiceFilter() {
        let container = InfrastructureContainer(
            id: "0123456789abcdef", name: "api-worker", image: "hanasand/api", state: "running",
            health: "healthy", cpuPercent: nil, memoryBytes: nil, memoryLimitBytes: nil,
            memoryPercent: nil, uptimeSeconds: nil, restartCount: nil, createdAt: "",
            statsUpdatedAt: "", unavailableReason: "", ports: [])

        let route = InfrastructureContainerLogsRoute.nativeRoute(for: container)

        XCTAssertEqual(route.path, "/logs")
        XCTAssertEqual(route.label, "Logs")
        XCTAssertEqual(route.query["service"], "api-worker")
    }

    func testContainerRestartRequiresFreshAuthorizedOwnAccountSnapshot() async throws {
        var captured: URLRequest?
        let sample = #"{"ok":true,"detail":{"restarted":true}}"#.data(using: .utf8)!
        let client = try makeClient { request in
            captured = request
            return (sample, Self.response(for: request, status: 200))
        }
        let container = InfrastructureContainer(id: "0123456789abcdef", name: "api", image: "image", state: "running", health: "healthy",
            cpuPercent: nil, memoryBytes: nil, memoryLimitBytes: nil, memoryPercent: nil, uptimeSeconds: nil, restartCount: nil,
            createdAt: "", statsUpdatedAt: "", unavailableReason: "", ports: [])
        let snapshot = InfrastructureContainersSnapshot(accountScope: client.accountScope, generatedAt: ISO8601DateFormatter().string(from: Date()),
            source: "docker_engine", unavailableReason: "", containers: [container])
        let access = InfrastructureViewsAccess(accountScope: client.accountScope, canRead: true, canWrite: true)

        try await client.restart(container: container, snapshot: snapshot, access: access)

        XCTAssertEqual(captured?.httpMethod, "GET")
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.example.test/api/restart/0123456789abcdef")
    }

    func testOversizedResponsesAndInvalidBlocklistDraftsAreRejected() async throws {
        let oversized = try makeClient { request in
            (Data(repeating: 0x20, count: InfrastructureViewsClient.maximumResponseBytes + 1), Self.response(for: request, status: 200))
        }
        do {
            _ = try await oversized.loadBlocklist()
            XCTFail("Oversized response must be rejected")
        } catch let error as InfrastructureViewsError {
            XCTAssertEqual(error.localizedDescription, InfrastructureViewsError.responseTooLarge.localizedDescription)
        }

        let invalid = try makeClient { request in (Data("[]".utf8), Self.response(for: request, status: 200)) }
        do {
            try await invalid.createBlocklistEntry(.init(kind: .ip, value: "not-an-ip", isVPN: false, isProxy: false, isTor: false))
            XCTFail("Invalid IP values must be rejected")
        } catch let error as InfrastructureViewsError {
            XCTAssertEqual(error.localizedDescription, InfrastructureViewsError.invalidDraft.localizedDescription)
        }
    }

    private func makeClient(impersonationToken: String = "", impersonatingUserID: String = "", send: @escaping InfrastructureViewsClient.Sender) throws -> InfrastructureViewsClient {
        try InfrastructureViewsClient(apiBaseURL: api, cdnBaseURL: cdn, userID: "owner.test", token: "session-token",
            impersonationToken: impersonationToken, impersonatingUserID: impersonatingUserID, send: send)
    }

    private static func response(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    }
}
