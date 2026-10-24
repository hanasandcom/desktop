import XCTest
@testable import Hanasand

final class ThreatIntelligenceOverviewNativePanelTests: XCTestCase {
    func testStatusCountsNormalizeEmptyAndWhitespaceValues() {
        XCTAssertEqual(
            ThreatIntelligenceOverviewMetrics.statusCounts(["active", " active ", "paused", nil, "  "]),
            ["active": 2, "paused": 1, "not reported": 2]
        )
    }

    func testDeliverySampleCountsRecordsWithMissingStagesAndAnomalies() throws {
        let items = try JSONDecoder().decode(
            [ThreatIntelligenceTimelinessSnapshot.Item].self,
            from: Data(#"""
            [
              {"id":"one","actorName":"A","sourceName":"S","sourceFamily":"feed","title":"One","summary":"","status":"awaiting_delivery","updatedAt":"2026-10-24T10:00:00Z","stages":{"alert":"complete"},"missingStages":["delivery"],"sources":[],"timestampAnomalies":[]},
              {"id":"two","actorName":"B","sourceName":"S","sourceFamily":"feed","title":"Two","summary":"","status":"complete","updatedAt":"2026-10-24T09:00:00Z","stages":{"alert":"complete","delivery":"complete"},"missingStages":[],"sources":[],"timestampAnomalies":["published_at_after_updated_at"]},
              {"id":"three","actorName":"C","sourceName":"S","sourceFamily":"feed","title":"Three","summary":"","status":"complete","updatedAt":"2026-10-24T08:00:00Z","stages":{},"missingStages":[],"sources":[],"timestampAnomalies":[]}
            ]
            """#.utf8)
        )

        XCTAssertEqual(ThreatIntelligenceOverviewMetrics.recordsWithMissingStages(items), 1)
        XCTAssertEqual(ThreatIntelligenceOverviewMetrics.recordsWithTimestampAnomalies(items), 1)
    }
}
