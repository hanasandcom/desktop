import XCTest
@testable import Hanasand

final class ThreatFindingsTests: XCTestCase {
    private let response = #"""
    {"organization":{"id":"org","name":"Example"},"visibilityDecision":{"allowed":true},"total":51,"nextCursor":"opaque:/+=cursor","alerts":[{"id":"finding-1","tenantId":"org","organizationId":"org","company":"Example Company","actor":"Example Group","matchedTerm":{"value":"example.test"},"severity":"high","reviewState":"new","deliveryState":"pending","observedMatchSummary":"One source reports a domain match.","recommendedAction":"Review the retained evidence.","sourceFamily":"darkweb_metadata","firstSeenAt":"2026-10-22T10:00:00Z","lastSeenAt":"2026-10-23T10:00:00Z","evidenceSummary":{"lastObservedAt":"2026-10-23T10:00:00Z"},"matchTiming":{"kind":"new_evidence"},"workflowContext":{"tenantId":"org","organizationId":"org","caseId":"case-1"},"evidence":[{"id":"evidence-1","sourceName":"Report","captureMode":"metadata_only","redactionState":"metadata_only","safeToShow":true,"excerpt":"Source excerpt","observedAt":"2026-10-23T10:00:00Z","contentHash":"sha256-value","provenance":{"captureId":"capture-1","publishedAt":"2026-10-23T09:30:00Z","collectedAt":"2026-10-23T10:05:00Z"}}]}]}
    """#

    func testDecodesScopedFindingAndItsEvidenceProvenance() throws {
        let page = try JSONDecoder().decode(ThreatFindingPage.self, from: Data(response.utf8))
        XCTAssertTrue(page.visibilityDecision.allowed)
        XCTAssertEqual(page.nextCursor, "opaque:/+=cursor")
        XCTAssertEqual(page.alerts.first?.tenantID, "org")
        XCTAssertEqual(page.alerts.first?.title, "Example Company")
        XCTAssertEqual(page.alerts.first?.observation, "New observation")
        XCTAssertEqual(page.alerts.first?.caseID, "case-1")
        XCTAssertEqual(page.alerts.first?.evidence.first?.captureID, "capture-1")
        XCTAssertEqual(page.alerts.first?.evidence.first?.publishedAt, "2026-10-23T09:30:00Z")
    }

    func testDoesNotExposeRestrictedExcerptOrCredentialMaterial() throws {
        let restricted = response.replacingOccurrences(of: #""safeToShow":true,"excerpt":"Source excerpt""#, with: #""safeToShow":false,"excerpt":"Private prose token=do-not-show https://discord.com/api/webhooks/id/secret""#)
        let page = try JSONDecoder().decode(ThreatFindingPage.self, from: Data(restricted.utf8))
        XCTAssertFalse(page.alerts[0].evidence[0].safeToShow)
        XCTAssertEqual(page.alerts[0].evidence[0].excerpt, "")
        XCTAssertFalse(page.alerts[0].evidence[0].excerpt.contains("do-not-show"))

        let credentials = response.replacingOccurrences(of: "Source excerpt", with: "Safe text token=private-value")
        let clean = try JSONDecoder().decode(ThreatFindingPage.self, from: Data(credentials.utf8))
        XCTAssertFalse(clean.alerts[0].evidence[0].excerpt.contains("private-value"))

        let structuredEvidence = response.replacingOccurrences(of: "Source excerpt", with: #"{\"actor\":\"Example\",\"private\":\"do-not-display\"}"#)
        let evidence = try JSONDecoder().decode(ThreatFindingPage.self, from: Data(structuredEvidence.utf8)).alerts[0].evidence[0].excerpt
        XCTAssertFalse(evidence.contains("do-not-display"))

        let structuredSummary = response.replacingOccurrences(of: "One source reports a domain match.", with: #"{\"actor\":\"Example\",\"private\":\"do-not-display\"}"#)
        let safeSummary = try JSONDecoder().decode(ThreatFindingPage.self, from: Data(structuredSummary.utf8)).alerts[0].summary
        XCTAssertFalse(safeSummary.contains("do-not-display"))
    }

    func testRejectsMismatchedTenantInvalidPageAndDuplicateEvidence() throws {
        let validPage = try JSONDecoder().decode(ThreatFindingPage.self, from: Data(response.utf8))
        XCTAssertThrowsError(try validPage.validate(tenantID: "other", organizationID: "org", requestedCursor: nil))
        XCTAssertThrowsError(try validPage.validate(tenantID: "org", organizationID: "other", requestedCursor: nil))
        XCTAssertThrowsError(try validPage.validate(tenantID: "org", organizationID: "org", requestedCursor: validPage.nextCursor))

        var invalidVisibility = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        invalidVisibility["visibilityDecision"] = ["allowed": false]
        XCTAssertThrowsError(try JSONDecoder().decode(ThreatFindingPage.self, from: JSONSerialization.data(withJSONObject: invalidVisibility)))

        var mismatch = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        var mismatchAlerts = try XCTUnwrap(mismatch["alerts"] as? [[String: Any]])
        mismatchAlerts[0]["tenantId"] = "other"; mismatch["alerts"] = mismatchAlerts
        XCTAssertThrowsError(try JSONDecoder().decode(ThreatFindingPage.self, from: JSONSerialization.data(withJSONObject: mismatch)))

        var duplicateEvidence = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        var alerts = try XCTUnwrap(duplicateEvidence["alerts"] as? [[String: Any]])
        var evidence = try XCTUnwrap(alerts[0]["evidence"] as? [[String: Any]])
        evidence.append(evidence[0]); alerts[0]["evidence"] = evidence; duplicateEvidence["alerts"] = alerts
        let encoded = try JSONSerialization.data(withJSONObject: duplicateEvidence)
        XCTAssertThrowsError(try JSONDecoder().decode(ThreatFindingPage.self, from: encoded))
    }

    func testFilteringUsesOnlyRecordedWorkflowStateAndText() throws {
        let page = try JSONDecoder().decode(ThreatFindingPage.self, from: Data(response.utf8))
        let finding = try XCTUnwrap(page.alerts.first)
        XCTAssertTrue(finding.needsReview)
        XCTAssertTrue(finding.contains("example.test"))
        let resolved = try JSONDecoder().decode(ThreatFinding.self, from: Data(#"{"id":"f2","tenantId":"user","matchedTerm":{"value":"x"},"evidence":[],"reviewState":"false_positive","deliveryState":"pending"}"#.utf8))
        XCTAssertFalse(resolved.needsReview)
        XCTAssertFalse(resolved.contains("missing"))
    }
}
