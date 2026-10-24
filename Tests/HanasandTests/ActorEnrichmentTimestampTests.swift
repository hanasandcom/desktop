import XCTest

@testable import Hanasand

final class ActorEnrichmentTimestampTests: XCTestCase {
    func testParsesFractionalAndWholeSecondISO8601Timestamps() throws {
        let fractional = try XCTUnwrap(ActorEnrichmentOverview.date(from: "2026-10-23T10:00:00.123Z"))
        let wholeSecond = try XCTUnwrap(ActorEnrichmentOverview.date(from: "2026-10-23T10:00:00Z"))

        XCTAssertEqual(fractional.timeIntervalSince(wholeSecond), 0.123, accuracy: 0.001)
    }

    func testEquivalentFractionalTimestampsAcrossOffsetsParseToTheSameInstant() throws {
        let utc = try XCTUnwrap(ActorEnrichmentOverview.date(from: "2026-10-23T10:00:00.250Z"))
        let offset = try XCTUnwrap(ActorEnrichmentOverview.date(from: "2026-10-23T12:00:00.250+02:00"))
        let wholeSecondPrecision = try XCTUnwrap(ActorEnrichmentOverview.date(from: "2026-10-23T10:00:00Z"))

        XCTAssertEqual(utc, offset)
        XCTAssertEqual(utc.timeIntervalSince(wholeSecondPrecision), 0.25, accuracy: 0.001)
    }

    func testSortsActivityByInstantAcrossTimeZones() throws {
        let later = try update(id: "later", observedAt: "2026-10-23T09:30:00.100Z")
        let earlier = try update(id: "earlier", observedAt: "2026-10-23T11:00:00+02:00")

        XCTAssertEqual(ActorEnrichmentOverview.newestFirst([earlier, later]).map(\.id), ["later", "earlier"])
    }

    func testInvalidTimestampsSortAfterValidEventsAndRemainDeterministic() throws {
        let invalidZulu = try update(id: "invalid-z", observedAt: "not-a-date")
        let valid = try update(id: "valid", observedAt: "2026-10-23T10:00:00.123Z")
        let invalidAlpha = try update(id: "invalid-a", observedAt: "not-a-date")

        XCTAssertEqual(ActorEnrichmentOverview.newestFirst([invalidZulu, valid, invalidAlpha]).map(\.id), [
            "valid", "invalid-z", "invalid-a",
        ])
    }

    private func update(id: String, observedAt: String) throws -> ActorEnrichmentOverview.Update {
        let body: [String: Any] = [
            "id": id,
            "subjectId": "actor-1",
            "actorName": "Synthetic actor",
            "observedAt": observedAt,
            "captureIds": [],
            "kind": "updated",
            "metadata": [:],
        ]
        return try JSONDecoder().decode(ActorEnrichmentOverview.Update.self, from: JSONSerialization.data(withJSONObject: body))
    }
}
