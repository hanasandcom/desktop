import Foundation
import XCTest
@testable import Hanasand

final class DashboardMonitoringOverviewParityTests: XCTestCase {
    func testSnapshotMetricDetailsMatchWebsiteSemantics() throws {
        let recentDate = ISO8601DateFormatter().string(from: Date())
        let json = #"""
        {
          "schemaVersion":"dwm.product.v1","generatedAt":"2026-10-25T12:00:00Z","tenantId":"user-1",
          "watchlist":[{"value":"example.test","kind":"domain"}],
          "alerts":[
            {"reviewState":"open","firstSeenAt":"\#(recentDate)","evidence":[{"sourceName":"Public channel","observedAt":"\#(recentDate)"}]}
          ],
          "sourceCoverage":[
            {"family":"telegram_public","label":"Telegram","sourceCount":1,"activeCount":1,"health":"healthy","detail":"Live"},
            {"family":"clear_web","label":"Clear web","sourceCount":1,"activeCount":0,"health":"missing","detail":"Not connected"}
          ],
          "readiness":{"decision":"blocked_missing_live_sources","blockers":[]}
        }
        """#
        let snapshot = try JSONDecoder().decode(DashboardMonitoringOverview.self, from: Data(json.utf8))

        XCTAssertEqual(snapshot.watchlistDetail, "companies, domains, brands, and vendors")
        XCTAssertEqual(snapshot.recentMatchDetail, "relevant activity found")
        XCTAssertEqual(snapshot.openAlertDetail, "ready to review")
        XCTAssertEqual(snapshot.sourceHealthValue, "1/2")
        XCTAssertEqual(snapshot.sourceHealthDetail, "healthy source families")
        XCTAssertEqual(snapshot.latestEvidenceValue, "Available")
        XCTAssertEqual(snapshot.latestEvidenceDetail, "Public channel")
    }

    func testEmptySnapshotExplainsNoMatchesAlertsCoverageOrEvidence() throws {
        let json = #"""
        {
          "schemaVersion":"dwm.product.v1","generatedAt":"2026-10-25T12:00:00Z","tenantId":"user-1",
          "watchlist":[{"value":"example.test","kind":"domain"}],"alerts":[],"sourceCoverage":[],
          "readiness":{"decision":"blocked_missing_live_sources","blockers":[]}
        }
        """#
        let snapshot = try JSONDecoder().decode(DashboardMonitoringOverview.self, from: Data(json.utf8))

        XCTAssertEqual(snapshot.recentMatchDetail, "no new matches")
        XCTAssertEqual(snapshot.openAlertDetail, "no new alerts")
        XCTAssertEqual(snapshot.sourceHealthValue, "—")
        XCTAssertEqual(snapshot.sourceHealthDetail, "No source coverage yet")
        XCTAssertEqual(snapshot.latestEvidenceValue, "None yet")
        XCTAssertEqual(snapshot.latestEvidenceDetail, "No retained evidence")
    }

    func testOpenCaseMetricDistinguishesLoadingEmptyActiveAndUnavailable() {
        XCTAssertEqual(DashboardMonitoringOverviewState.loading.openCaseValue, "—")
        XCTAssertEqual(DashboardMonitoringOverviewState.loading.openCaseDetail, "Loading cases…")

        let empty = DashboardMonitoringOverviewState(snapshot: nil, openCaseCount: 0, isLoading: false, errorMessage: nil, casesErrorMessage: nil)
        XCTAssertEqual(empty.openCaseValue, "0")
        XCTAssertEqual(empty.openCaseDetail, "no open cases")

        let active = DashboardMonitoringOverviewState(snapshot: nil, openCaseCount: 3, isLoading: false, errorMessage: nil, casesErrorMessage: nil)
        XCTAssertEqual(active.openCaseValue, "3")
        XCTAssertEqual(active.openCaseDetail, "active customer work")

        let unavailable = DashboardMonitoringOverviewState(snapshot: nil, openCaseCount: nil, isLoading: false, errorMessage: nil, casesErrorMessage: "offline")
        XCTAssertEqual(unavailable.openCaseValue, "—")
        XCTAssertEqual(unavailable.openCaseDetail, "Case data unavailable")
    }
}
