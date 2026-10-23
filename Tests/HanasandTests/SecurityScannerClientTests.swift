import Foundation
import XCTest
@testable import Hanasand

final class SecurityScannerClientTests: XCTestCase {
    func testClientRequiresOwnSelectedOrganizationAndRejectsImpersonation() throws {
        var settings = scannerSettings()
        settings.selectedOrganizationID = ""
        XCTAssertThrowsError(try SecurityScannerClient(settings: settings)) { XCTAssertEqual(($0 as? SecurityScannerClientError)?.localizedDescription, SecurityScannerClientError.selectOrganization.localizedDescription) }
        settings.selectedOrganizationID = "org-1"
        settings.impersonatingUserID = "other"
        XCTAssertThrowsError(try SecurityScannerClient(settings: settings)) { XCTAssertEqual(($0 as? SecurityScannerClientError)?.localizedDescription, SecurityScannerClientError.impersonationUnsupported.localizedDescription) }
        settings.impersonatingUserID = ""
        settings.selectedOrganizationUserID = "other"
        XCTAssertThrowsError(try SecurityScannerClient(settings: settings))
    }

    func testDashboardUsesAuthenticatedScopedNoCookieRequestAndDecodesEmptyState() async throws {
        var captured: URLRequest?
        let client = try SecurityScannerClient(settings: scannerSettings(), send: { request in
            captured = request
            return (Data(#"{"assets":[],"engines":[],"runs":[],"assessments":[],"findings":[],"scannerError":"Scanner service paused"}"#.utf8), self.response(request, 200))
        })
        let dashboard = try await client.dashboard()
        XCTAssertTrue(dashboard.assets.isEmpty)
        XCTAssertEqual(dashboard.scannerError, "Scanner service paused")
        XCTAssertEqual(captured?.url?.host, "scanner.hanasand.com")
        XCTAssertEqual(captured?.url?.path, "/api/v1/uvm/dashboard")
        XCTAssertEqual(URLComponents(url: captured!.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "organizationId" })?.value, "org-1")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "eirik")
        XCTAssertNil(captured?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(captured?.value(forHTTPHeaderField: "x-impersonation-token"))
    }

    func testFindingSortSupportsSeverityAndFirstSeen() {
        let findings = [
            finding(id: "old-low", severity: "low", status: "open", firstSeen: "2026-01-01T00:00:00Z"),
            finding(id: "new-critical", severity: "critical", status: "open", firstSeen: "2026-03-01T00:00:00Z"),
            finding(id: "old-critical", severity: "critical", status: "open", firstSeen: "2026-02-01T00:00:00Z"),
            finding(id: "middle-critical", severity: "critical", status: "open", firstSeen: "2026-02-15T00:00:00Z")
        ]

        XCTAssertEqual(SecurityScannerFindingSort.severity.sorted(findings).map(\.id), ["old-critical", "middle-critical", "new-critical", "old-low"])
        XCTAssertEqual(SecurityScannerFindingSort.firstSeen.sorted(findings).map(\.id), ["old-low", "old-critical", "middle-critical", "new-critical"])
    }

    func testHistoryUsesRunsEnvelopeAndRunDetailUsesDirectRunContract() async throws {
        let run = #"{"id":"run-1","scannerRunId":null,"requestId":"request-1","assetId":"asset-1","target":"example.com","engine":"nmap","profile":"tcp-top-1000","status":"succeeded","createdAt":"2026-10-23T10:00:00Z","startedAt":null,"finishedAt":null,"error":null,"engineVersion":null,"rawXmlSha256":null,"coverage":null,"hosts":[{"address":"203.0.113.5","status":"up","timedOut":false,"ports":[{"port":443,"protocol":"tcp","state":"open","service":"https","product":"nginx","version":"1.2","extraInfo":null,"scriptResults":[{"id":"http-title","output":"Example","truncated":false}]}],"scriptResults":[]}],"findings":[]}"#
        let client = try SecurityScannerClient(settings: scannerSettings(), send: { request in
            if request.url?.path == "/api/v1/uvm/runs" {
                return (Data("{\"runs\":[\(run)],\"nextCursor\":\"older\"}".utf8), self.response(request, 200))
            }
            return (Data(run.utf8), self.response(request, 200))
        })
        let page = try await client.runHistory(cursor: nil)
        XCTAssertEqual(page.items.map(\.id), ["run-1"])
        XCTAssertEqual(page.nextCursor, "older")
        let detail = try await client.run(id: "run-1", engine: "nmap")
        XCTAssertEqual(detail.hosts?.first?.ports.first?.protocolName, "tcp")
        XCTAssertEqual(detail.hosts?.first?.ports.first?.scriptResults?.first?.scriptID, "http-title")
    }

    func testCreateAssetRevalidatesActiveEditorMembershipAndSubmitsScopedRequest() async throws {
        var requests: [URLRequest] = []
        let client = try SecurityScannerClient(settings: scannerSettings(), send: { request in
            requests.append(request)
            if request.url?.host == "identity.hanasand.com" {
                return (Data(#"{"organizations":[{"id":"org-1","name":"Hanasand","role":"editor","lifecycleStatus":"active"}]}"#.utf8), self.response(request, 200))
            }
            let asset = #"{"id":"asset-1","hostname":"example.com","verificationStatus":"pending","verificationRecordName":"_hanasand.example.com","verificationRecordValue":"verify-value","verificationMethod":"dns_txt","verifiedAt":null,"scanAuthorizedAt":null,"authorizedAddresses":[],"scheduleEnabled":false,"schedulePlan":[],"scheduleEngine":"nmap","scheduleScanId":null,"scheduleProfile":"tcp-top-1000","zapApiDefinitionPath":null,"intervalMinutes":60,"nextRunAt":null,"createdAt":"2026-10-23T10:00:00Z"}"#
            return (Data("{\"asset\":\(asset)}".utf8), self.response(request, 201))
        })
        let asset = try await client.createAsset(hostname: " Example.COM ")
        XCTAssertEqual(asset.hostname, "example.com")
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.url?.host, "identity.hanasand.com")
        XCTAssertEqual(requests.last?.httpMethod, "POST")
        XCTAssertEqual(URLComponents(url: requests.last!.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "organizationId" })?.value, "org-1")
        let bodyData = try XCTUnwrap(requests.last?.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["hostname"] as? String, "example.com")
        XCTAssertNil(body["actorId"])
    }

    func testViewerRoleCannotCreateAsset() async throws {
        var scannerWrites = 0
        let client = try SecurityScannerClient(settings: scannerSettings(), send: { request in
            if request.url?.host == "identity.hanasand.com" {
                return (Data(#"{"organizations":[{"id":"org-1","name":"Hanasand","role":"viewer","lifecycleStatus":"active"}]}"#.utf8), self.response(request, 200))
            }
            scannerWrites += 1
            return (Data(), self.response(request, 201))
        })
        do { _ = try await client.createAsset(hostname: "example.com"); XCTFail("viewer must be read-only") }
        catch { XCTAssertEqual((error as? SecurityScannerClientError)?.localizedDescription, SecurityScannerClientError.permissionDenied.localizedDescription) }
        XCTAssertEqual(scannerWrites, 0)
    }

    func testScanCannotBeSubmittedWithoutExplicitAuthorization() async throws {
        let client = try SecurityScannerClient(settings: scannerSettings(), send: { request in (Data(), self.response(request, 200)) })
        let asset = SecurityScannerAsset(id: "asset-1", hostname: "example.com", verificationStatus: "verified", verificationRecordName: "", verificationRecordValue: "", verificationMethod: "dns_txt", verifiedAt: nil, scanAuthorizedAt: nil, authorizedAddresses: ["203.0.113.1"], scheduleEnabled: false, schedulePlan: [], scheduleEngine: "nmap", scheduleScanId: nil, scheduleProfile: nil, zapApiDefinitionPath: nil, intervalMinutes: 60, nextRunAt: nil, createdAt: "2026-10-23T10:00:00Z")
        do { _ = try await client.runScan(asset: asset, engine: .nmap, authorized: false); XCTFail("authorization must be required") }
        catch { XCTAssertEqual((error as? SecurityScannerClientError)?.localizedDescription, SecurityScannerClientError.authorizationRequired.localizedDescription) }
    }

    private func scannerSettings() -> HanasandDesktopSettings {
        var settings = HanasandDesktopSettings()
        settings.userID = "eirik"
        settings.authToken = "token-123"
        settings.selectedOrganizationID = "org-1"
        settings.selectedOrganizationUserID = "eirik"
        return settings
    }

    private func finding(id: String, severity: String, status: String, firstSeen: String?) -> SecurityScannerFinding {
        SecurityScannerFinding(
            id: id, assetId: "asset-1", asset: "example.com", address: nil, engine: "nmap", externalId: id,
            title: id, severity: severity, cvssScore: nil, cveIds: [], description: nil, solution: nil, evidence: nil,
            status: status, triageNote: nil, firstSeen: firstSeen, lastSeen: nil, updatedAt: "2026-03-02T00:00:00Z"
        )
    }

    private func response(_ request: URLRequest, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    }
}
