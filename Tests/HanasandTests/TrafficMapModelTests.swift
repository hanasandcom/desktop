import Foundation
import XCTest
@testable import Hanasand

final class TrafficMapModelTests: XCTestCase {
    func testSummarizesCountryCountsAndLatestTimestamp() throws {
        let records = try [
            record(id: 1, iso: "no", timestamp: "2026-10-23T10:00:00Z"),
            record(id: 2, iso: "NO", timestamp: "2026-10-23T10:03:00Z"),
            record(id: 3, iso: "US", timestamp: "2026-10-23T10:02:00Z"),
            record(id: 4, iso: nil, timestamp: "2026-10-23T10:04:00Z"),
            record(id: 5, iso: "X1", timestamp: "2026-10-23T10:05:00Z"),
        ]

        let countries = TrafficMapCountry.summarize(records)

        XCTAssertEqual(countries.map(\.iso), ["NO", "US"])
        XCTAssertEqual(countries.map(\.requestCount), [2, 1])
        XCTAssertEqual(countries.first?.lastSeen, ISO8601DateFormatter().date(from: "2026-10-23T10:03:00Z"))
    }

    func testCountryOrderingIsStableForEqualCounts() throws {
        let records = try [
            record(id: 1, iso: "US", timestamp: "2026-10-23T10:00:00Z"),
            record(id: 2, iso: "NO", timestamp: "2026-10-23T10:00:00Z"),
        ]

        XCTAssertEqual(TrafficMapCountry.summarize(records).map(\.iso), ["NO", "US"])
    }

    private func record(id: Int, iso: String?, timestamp: String) throws -> TrafficRecentRecord {
        let countryField = iso.map { "\"\($0)\"" } ?? "null"
        let record = """
        {"id":\(id),"user_agent":"test","domain":"example.test","path":"/","method":"GET","referer":"","request_time":1,"status":200,"timestamp":"\(timestamp)","country_iso":\(countryField)}
        """
        let pageJSON = "{" + "\"total\":1,\"result\":[\(record)]" + "}"
        let page = try TrafficRecentClient.decodePage(Data(pageJSON.utf8))
        return try XCTUnwrap(page.result.first)
    }
}
