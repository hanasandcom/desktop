import Foundation
import XCTest
@testable import Hanasand

final class DashboardMonitoringOverviewTests: XCTestCase {
    private var settings: HanasandDesktopSettings {
        var value = HanasandDesktopSettings()
        value.websiteBaseURL = "https://hanasand.example.test"
        value.userID = "user-1"
        value.authToken = "token-1"
        return value
    }

    private var snapshotJSON: String {
        let current = ISO8601DateFormatter()
        let recent = current.string(from: Date().addingTimeInterval(-60 * 60))
        let older = current.string(from: Date().addingTimeInterval(-2 * 60 * 60))
        return #"""
    {
      "schemaVersion":"dwm.product.v1","generatedAt":"\#(recent)","tenantId":"user-1",
      "watchlist":[{"value":"example.test","kind":"domain"}],
      "alerts":[
        {"reviewState":"open","firstSeenAt":"\#(recent)","evidence":[{"sourceName":"Public channel","observedAt":"2026-10-24T09:30:00Z","provenance":{"collectedAt":"2026-10-24T09:31:00.123Z"}}]},
        {"reviewState":"resolved","firstSeenAt":"\#(older)","evidence":[]}
      ],
      "sourceCoverage":[
        {"family":"telegram_public","label":"Telegram","sourceCount":3,"activeCount":2,"approvalState":"active","health":"healthy","detail":"Live"},
        {"family":"clear_web","label":"Clear web","sourceCount":2,"activeCount":0,"approvalState":"missing","health":"missing","detail":"Not connected"}
      ],
      "actorOverviews":[],"onDemandQueue":[],
      "readiness":{"decision":"blocked_missing_live_sources","blockers":["Connect a live source."],"advantages":[],"nextWorkItem":"Connect source"}
    }
    """#
    }

    private func response(_ request: URLRequest, _ body: String, status: Int = 200) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }

    func testSnapshotDerivesAlertSourceEvidenceAndReadinessMetrics() throws {
        let snapshot = try JSONDecoder().decode(DashboardMonitoringOverview.self, from: Data(snapshotJSON.utf8))
        XCTAssertEqual(snapshot.watchlist.count, 1)
        XCTAssertEqual(snapshot.openAlertCount, 1)
        XCTAssertEqual(snapshot.recentMatchCount, 2)
        XCTAssertEqual(snapshot.healthySourceCount, 1)
        XCTAssertEqual(snapshot.latestEvidence?.sourceName, "Public channel")
        XCTAssertEqual(snapshot.latestEvidence?.latestTimestamp, "2026-10-24T09:31:00.123Z")
        XCTAssertFalse(snapshot.isReady)
        XCTAssertEqual(snapshot.readiness.blockers.first, "Connect a live source.")
    }

    func testPersonalOverviewUsesAuthenticatedNativeAPIAndValidatesTenant() async throws {
        var requests: [URLRequest] = []
        let client = try DashboardMonitoringOverviewClient(settings: settings) { request in
            requests.append(request)
            return self.response(request, self.snapshotJSON)
        }

        let result = try await client.load()

        XCTAssertEqual(result.tenantId, "user-1")
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.path, "/api/findings/product")
        XCTAssertNil(URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "organizationId" }))
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "id"), "user-1")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Cache-Control"), "no-store")
    }

    func testOrganizationOverviewIsExplicitlyScopedAndRejectsOtherTenant() async throws {
        var orgSettings = settings
        orgSettings.selectedOrganizationID = "org-1"
        orgSettings.selectedOrganizationUserID = "user-1"
        var request: URLRequest?
        let body = snapshotJSON.replacingOccurrences(of: #""tenantId":"user-1""#, with: #""tenantId":"org-1""#)
        let client = try DashboardMonitoringOverviewClient(settings: orgSettings) { next in
            request = next
            return self.response(next, body)
        }

        _ = try await client.load()
        XCTAssertEqual(URLComponents(url: request!.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "organizationId" })?.value, "org-1")

        let mismatchedClient = try DashboardMonitoringOverviewClient(settings: orgSettings) { next in self.response(next, self.snapshotJSON) }
        do {
            _ = try await mismatchedClient.load()
            XCTFail("A personal tenant response must not be shown in the organization workspace")
        } catch DashboardMonitoringOverviewError.invalidResponse {
            // Expected: the response scope is independently confirmed.
        }
    }

    func testOpenCasesSummaryUsesSamePersonalOrOrganizationScope() async throws {
        var orgSettings = settings
        orgSettings.selectedOrganizationID = "org-2"
        orgSettings.selectedOrganizationUserID = "user-1"
        var request: URLRequest?
        let client = try DashboardMonitoringOverviewClient(settings: orgSettings) { next in
            request = next
            return self.response(next, #"{"total":4,"warnings":[]}"#)
        }

        let count = await client.loadOpenCaseCount()

        XCTAssertEqual(try count.get(), 4)
        XCTAssertEqual(request?.url?.path, "/api/cases")
        let query = URLComponents(url: request!.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first(where: { $0.name == "summary" })?.value, "true")
        XCTAssertEqual(query.first(where: { $0.name == "openOnly" })?.value, "true")
        XCTAssertEqual(query.first(where: { $0.name == "organizationId" })?.value, "org-2")
    }

    func testRejectsNonIntegerCaseCountAndUnconfirmedOrganizationOwner() async throws {
        var orgSettings = settings
        orgSettings.selectedOrganizationID = "org-2"
        orgSettings.selectedOrganizationUserID = "different-user"
        XCTAssertThrowsError(try DashboardMonitoringOverviewClient(settings: orgSettings)) { error in
            XCTAssertEqual(error as? DashboardMonitoringOverviewError, .scopeChanged)
        }

        let client = try DashboardMonitoringOverviewClient(settings: settings) { request in
            self.response(request, #"{"total":1.5}"#)
        }
        guard case .failure(.invalidResponse) = await client.loadOpenCaseCount() else {
            return XCTFail("Case summaries must contain a nonnegative integer")
        }
    }

    func testRejectsImpersonationAndMalformedSnapshot() async throws {
        var impersonated = settings
        impersonated.impersonationToken = "impersonation"
        XCTAssertThrowsError(try DashboardMonitoringOverviewClient(settings: impersonated)) { error in
            XCTAssertEqual(error as? DashboardMonitoringOverviewError, .impersonationUnsupported)
        }
        let client = try DashboardMonitoringOverviewClient(settings: settings) { request in self.response(request, #"{"tenantId":"user-1"}"#) }
        do {
            _ = try await client.load()
            XCTFail("Incomplete snapshot should be rejected")
        } catch DashboardMonitoringOverviewError.invalidResponse {
            // Expected.
        }
    }
}
