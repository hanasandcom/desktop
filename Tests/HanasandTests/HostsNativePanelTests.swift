import XCTest
@testable import Hanasand

final class HostsNativePanelTests: XCTestCase {
    func testDecodesHostOverviewAndTreatsUnrecognizedStatusAsUnknown() throws {
        let data = Data(#"{"hosts":[{"id":"inspur","name":"Inspur","address":"host.example:22","username":"operator","status":"online","hostname":"edge-1","operatingSystem":"Linux 6.8"},{"id":"ovh","name":"OVH","address":"","username":"root","status":"maintenance","hostname":null,"operatingSystem":null}],"users":[{"id":"user-1","name":"Sam Example","username":"sam","keyCount":2},{"id":"user-2","name":"Pat Example","username":"pat","keyCount":-1}]}"#.utf8)
        let result = try JSONDecoder().decode(HostOverviewEnvelope.self, from: data)

        XCTAssertEqual(result.hosts.map(\.id.rawValue), ["inspur", "ovh"])
        XCTAssertEqual(result.hosts[0].status, .online)
        XCTAssertEqual(result.hosts[1].status, .unknown)
        XCTAssertEqual(result.hosts[0].operatingSystem, "Linux 6.8")
        XCTAssertEqual(result.users[0].keyCount, 2)
        XCTAssertNil(result.users[1].keyCount)
    }

    func testRejectsUnknownHostAndDuplicateIdentity() {
        let unknownHost = Data(#"{"hosts":[{"id":"worker-2","name":"Worker","address":"","username":"root","status":"online"}],"users":[]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(HostOverviewEnvelope.self, from: unknownHost))

        let duplicateUser = Data(#"{"hosts":[],"users":[{"id":"u1","name":"One","username":"one","keyCount":1},{"id":"u1","name":"Duplicate","username":"two","keyCount":1}]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(HostOverviewEnvelope.self, from: duplicateUser))
    }

    func testDecodesUpdateStatusAndHistoryContract() throws {
        let result = try JSONDecoder().decode(HostUpdateEnvelope.self, from: Data(#"{"host":"ovhcloud","status":{"schema_version":1,"host":"ovhcloud","run_id":"run-7","checked_at":"2026-10-22T12:00:00Z","status":"pending","pending_updates":[{"package":"openssl","version":"3.2","repo":"main","origin":"Ubuntu","security":true,"first_seen":1792670400}],"installed_packages":[{"package":"curl","version":"8.5"}],"last_updated_packages":["curl"],"last_update_at":"2026-10-20T12:00:00Z","policy":{"non_security_delay_hours":72,"security_install":"immediate","allowed_origin":"Ubuntu","repository_verification":"signed"}},"history":[{"run_id":"2026-10-22","status":"pending","occurred_at":"2026-10-22","is_today":true,"packages":["curl v8.5"],"error":null}]}"#.utf8))

        XCTAssertEqual(result.host, .ovhcloud)
        XCTAssertEqual(result.status.status, "pending")
        XCTAssertEqual(result.status.pending.first?.name, "openssl")
        XCTAssertEqual(result.status.pending.first?.repository, "main")
        XCTAssertEqual(result.status.pending.first?.security, true)
        XCTAssertEqual(result.status.policy?.nonSecurityDelayHours, 72)
        XCTAssertEqual(result.status.installed.first?.version, "8.5")
        XCTAssertEqual(result.history.first?.packages, ["curl v8.5"])
    }

    func testHostAccessRequiresAuthenticationAndOwnAccount() {
        XCTAssertTrue(hostOverviewMayLoad(hasAuth: true, isImpersonating: false))
        XCTAssertFalse(hostOverviewMayLoad(hasAuth: false, isImpersonating: false))
        XCTAssertFalse(hostOverviewMayLoad(hasAuth: true, isImpersonating: true))
    }

    func testHostConsoleConnectsToAuthenticatedNativeWebSocketEndpoint() throws {
        XCTAssertEqual(hostConsoleWebSocketURL(apiBaseURL: "https://api.hanasand.com/api/", host: .inspur)?.absoluteString,
                       "wss://api.hanasand.com/api/ws/host/inspur/console")
        XCTAssertEqual(hostConsoleWebSocketURL(apiBaseURL: "https://api.hanasand.com/api", host: .ovh)?.absoluteString,
                       "wss://api.hanasand.com/api/ws/host/ovh/console")
        XCTAssertEqual(hostConsoleWebSocketURL(apiBaseURL: "http://localhost:3000/api", host: .inspur)?.absoluteString,
                       "ws://localhost:3000/api/ws/host/inspur/console")
        XCTAssertNil(hostConsoleWebSocketURL(apiBaseURL: "https://user:password@api.hanasand.com/api", host: .inspur))
        XCTAssertNil(hostConsoleWebSocketURL(apiBaseURL: "https://api.hanasand.com/api?token=secret", host: .inspur))
        XCTAssertNil(hostConsoleWebSocketURL(apiBaseURL: "file:///tmp/api", host: .inspur))
        XCTAssertNil(hostConsoleWebSocketURL(apiBaseURL: "http://api.hanasand.com/api", host: .inspur))
    }

    func testHostConsoleRequiresOwnAuthenticatedNonImpersonatedAccount() {
        XCTAssertTrue(hostConsoleMayOpen(hasAuth: true, isImpersonating: false, userID: "user-1", token: "secret"))
        XCTAssertFalse(hostConsoleMayOpen(hasAuth: false, isImpersonating: false, userID: "user-1", token: "secret"))
        XCTAssertFalse(hostConsoleMayOpen(hasAuth: true, isImpersonating: true, userID: "user-1", token: "secret"))
        XCTAssertFalse(hostConsoleMayOpen(hasAuth: true, isImpersonating: false, userID: "", token: "secret"))
        XCTAssertFalse(hostConsoleMayOpen(hasAuth: true, isImpersonating: false, userID: "user-1", token: ""))
    }

    func testUpdateAgeUsesReportedEpochSecondsAndNeverGoesNegative() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertEqual(hostUpdateAgeHours(firstSeen: 1_996_400, delayHours: 72, now: now), 1)
        XCTAssertEqual(hostUpdateAgeHours(firstSeen: 2_000_100, delayHours: 72, now: now), 0)
        XCTAssertNil(hostUpdateAgeHours(firstSeen: nil, delayHours: 72, now: now))
        XCTAssertNil(hostUpdateAgeHours(firstSeen: 1, delayHours: -1, now: now))
    }
}
