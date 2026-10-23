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

    func testDecodesRetainedTrafficMetricsAndTopActivity() throws {
        let data = Data("""
        {
          "sampled_at":"2026-10-23T10:05:00Z",
          "total_requests":1200,
          "avg_request_time":42.5,
          "error_rate":0.025,
          "top_methods":[{"key":"GET","count":1100}],
          "top_status_codes":[{"key":"200","count":1170}],
          "top_paths":[{"key":"/api/status","count":240}]
        }
        """.utf8)

        let metrics = try TrafficMapMetrics.decode(data)

        XCTAssertEqual(metrics.totalRequests, 1200)
        XCTAssertEqual(metrics.averageRequestTime, 42.5)
        XCTAssertEqual(metrics.errorRate, 0.025)
        XCTAssertEqual(metrics.topMethods.first, TrafficMapMetric(key: "GET", count: 1100))
        XCTAssertEqual(metrics.topPaths.first, TrafficMapMetric(key: "/api/status", count: 240))
        XCTAssertEqual(metrics.sampledAt, "2026-10-23T10:05:00Z")
    }

    func testRejectsInvalidRetainedTrafficMetrics() {
        let data = Data("""
        {"total_requests":10,"avg_request_time":-1,"error_rate":1.5,"top_methods":[],"top_status_codes":[],"top_paths":[]}
        """.utf8)

        XCTAssertThrowsError(try TrafficMapMetrics.decode(data))
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
