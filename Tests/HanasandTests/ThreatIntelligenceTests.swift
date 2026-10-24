import XCTest
@testable import Hanasand

final class ThreatIntelligenceTests: XCTestCase {
    func testNativeThreatSearchRouteUsesItsDetailAsTheInitialQuery() {
        XCTAssertEqual(
            ThreatIntelligenceRouteSearch.initialQuery(path: "/ti", detailID: "  CVE-2026-1234  "),
            "CVE-2026-1234"
        )
        XCTAssertNil(ThreatIntelligenceRouteSearch.initialQuery(path: "/ti", detailID: "  "))
        XCTAssertNil(ThreatIntelligenceRouteSearch.initialQuery(path: "/ti/sources", detailID: "feed-123"))
        XCTAssertEqual(ThreatIntelligenceRouteSearch.initialQuery(path: "/ti", detailID: "", query: "domain.example"), "domain.example")
        XCTAssertEqual(ThreatIntelligenceRouteSearch.initialQuery(path: "/ti", detailID: "CVE-1", query: "ignored"), "CVE-1")
        XCTAssertNil(ThreatIntelligenceRouteSearch.initialQuery(path: "/ti", detailID: "  ", query: "  "))
    }

    func testDecodesSearchEvidenceAndMarksCatalogOnlyIdentity() throws {
        let result = try JSONDecoder().decode(ThreatIntelSearchResult.self, from: Data(#"""
        {"query":"Example Actor","summary":"Public reporting summary","status":"ready","mode":"seeded","generatedAt":"2026-01-01T00:00:00Z","confidence":0.82,"aliases":["Alias"],"notes":["Review source"],"actorIdentity":{"catalogMatched":true,"activityEvidenceAvailable":false,"candidates":[{"canonicalName":"Example Actor","description":"Catalog match","sourceUrl":"https://reports.example.org/a","associatedNames":["Alias"]}]},"sources":[{"id":"s1","name":"Report","type":"public_report","provenance":"Publisher report","url":"https://reports.example.org/a","lastCollectedAt":"2026-01-01T00:00:00Z"}],"recentActivity":[{"title":"Reported incident","detail":"Claim under review","date":"2026-01-01","sourceIds":["s1"],"reviewState":"unverified","corroborationState":"single_source","url":"https://reports.example.org/a"}],"ttps":[{"attackId":"T1001","name":"Data Obfuscation","tactic":"Command and Control","detail":"Description","sourceIds":["s1"]}],"targets":[{"sector":"Finance","regions":["Europe"],"rationale":"Publicly reported"}]}
        """#.utf8))
        XCTAssertEqual(result.query, "Example Actor")
        XCTAssertTrue(result.catalogOnly)
        XCTAssertEqual(result.candidates.first?.name, "Example Actor")
        XCTAssertEqual(result.candidates.first?.aliases, ["Alias"])
        XCTAssertEqual(result.sources.first?.id, "s1")
        XCTAssertEqual(result.activity.first?.corroboration, "single_source")
        XCTAssertEqual(result.techniques.first?.attackID, "T1001")
        XCTAssertEqual(result.targets.first?.regions, ["Europe"])
        XCTAssertEqual(result.confidence, 0.82)
    }

    func testThreatRefreshIntervalsAreBoundedAndTerminalStatusesStopPolling() {
        XCTAssertNil(ThreatSearchPollingBudget.intervalSeconds(status: "pending", refreshAfterSeconds: 0))
        XCTAssertEqual(ThreatSearchPollingBudget.intervalSeconds(status: "pending", refreshAfterSeconds: 1), 3)
        XCTAssertEqual(ThreatSearchPollingBudget.intervalSeconds(status: "pending", refreshAfterSeconds: 18), 18)
        XCTAssertEqual(ThreatSearchPollingBudget.intervalSeconds(status: "pending", refreshAfterSeconds: 120), 60)
        for status in ["ready", "unavailable", "blocked_unsafe_target"] {
            XCTAssertNil(ThreatSearchPollingBudget.intervalSeconds(status: status, refreshAfterSeconds: 10), status)
        }
    }

    func testThreatRefreshBudgetStopsAfterFiveAutomaticRefreshes() {
        let scope = searchScope()
        var budget = ThreatSearchPollingBudget(query: "Example Actor", scope: scope)

        for remaining in stride(from: 4, through: 0, by: -1) {
            XCTAssertEqual(
                budget.nextIntervalSeconds(
                    resultQuery: "example actor",
                    resultStatus: "pending",
                    refreshAfterSeconds: 7,
                    currentQuery: " Example Actor ",
                    currentScope: scope
                ),
                7
            )
            XCTAssertEqual(budget.remainingRefreshes, remaining)
        }
        XCTAssertNil(budget.nextIntervalSeconds(
            resultQuery: "Example Actor", resultStatus: "pending", refreshAfterSeconds: 7,
            currentQuery: "Example Actor", currentScope: scope
        ))
    }

    func testThreatRefreshBudgetStopsWhenCancelledQueryOrScopeChanges() {
        let scope = searchScope()
        let otherScope = searchScope(organizationID: "org-2")
        var budget = ThreatSearchPollingBudget(query: "Example Actor", scope: scope)

        XCTAssertNil(budget.nextIntervalSeconds(
            resultQuery: "Example Actor", resultStatus: "pending", refreshAfterSeconds: 7,
            currentQuery: "Different actor", currentScope: scope
        ))
        XCTAssertNil(budget.nextIntervalSeconds(
            resultQuery: "Example Actor", resultStatus: "pending", refreshAfterSeconds: 7,
            currentQuery: "Example Actor", currentScope: otherScope
        ))
        XCTAssertEqual(budget.remainingRefreshes, ThreatSearchPollingBudget.maximumRefreshes)

        budget.cancel()
        XCTAssertNil(budget.nextIntervalSeconds(
            resultQuery: "Example Actor", resultStatus: "pending", refreshAfterSeconds: 7,
            currentQuery: "Example Actor", currentScope: scope
        ))
        XCTAssertEqual(budget.remainingRefreshes, 0)
    }

    func testThreatSearchResponseBoundsRefreshInterval() throws {
        let maximum = try JSONDecoder().decode(ThreatIntelSearchResult.self, from: Data(#"{"query":"Acme","status":"pending","refreshAfterSeconds":120}"#.utf8))
        let negative = try JSONDecoder().decode(ThreatIntelSearchResult.self, from: Data(#"{"query":"Acme","status":"pending","refreshAfterSeconds":-4}"#.utf8))
        let missing = try JSONDecoder().decode(ThreatIntelSearchResult.self, from: Data(#"{"query":"Acme","status":"pending"}"#.utf8))

        XCTAssertEqual(maximum.refreshAfterSeconds, 60)
        XCTAssertEqual(negative.refreshAfterSeconds, 0)
        XCTAssertEqual(missing.refreshAfterSeconds, 0)
    }

    func testRejectsUnsafeEvidenceURLsAndOutOfRangeConfidence() throws {
        let result = try JSONDecoder().decode(ThreatIntelSearchResult.self, from: Data(#"""
        {"query":"Acme","summary":"","actorIdentity":{"catalogMatched":true,"activityEvidenceAvailable":false,"candidates":[{"canonicalName":"Acme","description":"x","sourceUrl":"http://unsafe.example/a","associatedNames":[]}]},"sources":[{"id":"s1","url":"https://user:secret@example.org/a"}],"recentActivity":[],"ttps":[],"targets":[],"confidence":3}
        """#.utf8))
        XCTAssertNil(result.candidates.first?.url)
        XCTAssertNil(result.sources.first?.url)
        XCTAssertNil(result.confidence)
    }

    func testDecodesSavedSearchTimestampVariants() throws {
        let first = try JSONDecoder().decode(ThreatSavedSearch.self, from: Data(#"{"query":"Acme","savedAt":"2026-01-01T00:00:00Z"}"#.utf8))
        let second = try JSONDecoder().decode(ThreatSavedSearch.self, from: Data(#"{"query":"CVE-2026-1234","saved_at":"2026-01-02T00:00:00Z"}"#.utf8))
        XCTAssertEqual(first.savedAt, "2026-01-01T00:00:00Z")
        XCTAssertEqual(second.savedAt, "2026-01-02T00:00:00Z")
    }

    private func searchScope(organizationID: String = "org-1") -> ThreatIntelligenceSearchScope {
        ThreatIntelligenceSearchScope(
            userID: "user-1", organizationID: organizationID,
            websiteBaseURL: "https://hanasand.com", apiBaseURL: "https://api.hanasand.com",
            routePath: "/ti", routeDetailID: "", routeQuery: ""
        )
    }
}
