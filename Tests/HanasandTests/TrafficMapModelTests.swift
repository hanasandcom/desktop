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

    func testCountryCentroidsProjectAndCoverTheExpoDataset() {
        XCTAssertEqual(TrafficMapGeography.centroids.count, 250)
        XCTAssertEqual(TrafficMapGeography.centroids["NO"], TrafficMapCoordinate(latitude: 62, longitude: 10))
        let point = TrafficMapGeography.point(iso: "NO", size: CGSize(width: 1000, height: 500))
        XCTAssertEqual(point?.x ?? .nan, 527.7777777777778, accuracy: 1e-9)
        XCTAssertEqual(point?.y ?? .nan, 77.77777777777777, accuracy: 1e-9)
        XCTAssertNil(TrafficMapGeography.point(iso: "X1", size: CGSize(width: 1000, height: 500)))
        XCTAssertEqual(TrafficMapGeography.capitalNames["NO"], "Oslo")
        XCTAssertEqual(TrafficMapGeography.distanceFromNorwayKilometers(iso: "NO"), 0)
        XCTAssertNil(TrafficMapGeography.distanceFromNorwayKilometers(iso: "X1"))
    }

    func testBuildsSecureAuthenticatedLiveTrafficRequest() throws {
        let request = try TrafficMapLiveClient.request(
            apiBaseURL: URL(string: "https://example.test/api")!,
            userID: " user-1 ",
            authToken: " token-1 ",
            impersonationToken: "impersonation-1",
            domain: "example.test",
            after: "123"
        )

        XCTAssertEqual(request.url?.path, "/api/traffic/live")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems?.count, 2)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "id"), "user-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-impersonation-token"), "impersonation-1")
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    func testLiveTrafficRequestRejectsInsecureOrMalformedInput() {
        XCTAssertThrowsError(try TrafficMapLiveClient.requestURL(apiBaseURL: URL(string: "http://example.test/api")!, domain: "", after: nil))
        XCTAssertThrowsError(try TrafficMapLiveClient.requestURL(apiBaseURL: URL(string: "https://example.test/api")!, domain: "example.test/path", after: nil))
        XCTAssertThrowsError(try TrafficMapLiveClient.requestURL(apiBaseURL: URL(string: "https://example.test/api")!, domain: "", after: "9007199254740992"))
        XCTAssertThrowsError(try TrafficMapLiveClient.request(apiBaseURL: URL(string: "https://example.test/api")!, userID: "", authToken: "", domain: "", after: nil))
    }

    func testDecodesLiveCountryBatchAndSkipsOldCursor() throws {
        let data = Data("""
        [
          {"iso":"NO","count":3,"max_id":"105","timestamp":"2026-10-23 10:03:00+00"},
          {"iso":"US","count":1,"max_id":"100","timestamp":"2026-10-23T10:02:00Z"}
        ]
        """.utf8)

        let batches = try TrafficMapLiveClient.decodeBatch(data, after: "102")

        XCTAssertEqual(batches.map(\.iso), ["NO"])
        XCTAssertEqual(batches.first?.count, 3)
        XCTAssertEqual(batches.first?.maxID, "105")
    }

    func testRejectsMalformedLiveCountryBatch() {
        let data = Data("""
        [{"iso":"not-a-country","count":3,"max_id":"105","timestamp":"2026-10-23T10:03:00Z"}]
        """.utf8)

        XCTAssertThrowsError(try TrafficMapLiveClient.decodeBatch(data))
    }

    func testDecodesRetainedTrafficMetricsAndTopActivity() throws {
        let expandedData = Data("""
        {
          "sampled_at":"2026-10-23T10:05:00Z",
          "total_requests":1200,"avg_request_time":42.5,"error_rate":0.025,
          "top_methods":[{"key":"GET","count":1100}],
          "top_status_codes":[{"key":"200","count":1170}],
          "top_domains":[],"top_os":[],"top_browsers":[],
          "requests_over_time":[],"top_error_paths":[],"top_slow_paths":[],
          "top_paths":[{"key":"/api/status","count":240}]
        }
        """.utf8)

        let metrics = try TrafficMetricSnapshot.decode(expandedData)

        XCTAssertEqual(metrics.totalRequests, 1200)
        XCTAssertEqual(metrics.averageRequestTime, 42.5)
        XCTAssertEqual(metrics.errorRate, 0.025)
        XCTAssertEqual(metrics.topMethods.first?.key, "GET")
        XCTAssertEqual(metrics.topMethods.first?.count, 1100)
        XCTAssertEqual(metrics.topPaths.first?.key, "/api/status")
        XCTAssertEqual(metrics.topPaths.first?.count, 240)
        XCTAssertEqual(metrics.sampledAt, "2026-10-23T10:05:00Z")
    }

    func testRejectsInvalidRetainedTrafficMetrics() {
        let expandedData = Data("""
        {
          "sampled_at":"2026-10-23T10:05:00Z",
          "total_requests":10,"avg_request_time":-1,"error_rate":1.5,
          "top_methods":[],"top_status_codes":[],"top_domains":[],"top_os":[],
          "top_browsers":[],"requests_over_time":[],"top_error_paths":[],
          "top_slow_paths":[],"top_paths":[]
        }
        """.utf8)
        XCTAssertThrowsError(try TrafficMetricSnapshot.decode(expandedData))
    }

    func testLiveCountryTotalsIncludeBatchesAndExpireStaleDeltas() throws {
        let receivedAt = ISO8601DateFormatter().date(from: "2026-10-23T10:00:00Z")!
        let batch = TrafficMapLiveBatch(iso: "NO", count: 7, maxID: "100", timestamp: "2026-10-23T10:00:00Z")
        let initial = TrafficMapLiveAggregation.applying([batch], to: [:], receivedAt: receivedAt)
        XCTAssertEqual(initial["NO"]?.requestCount, 7)

        let records = try [record(id: 1, iso: "NO", timestamp: "2026-10-23T09:59:00Z")]
        let countries = TrafficMapCountry.summarize(records, liveDeltas: initial)
        XCTAssertEqual(countries.first?.requestCount, 8)
        XCTAssertEqual(countries.first?.lastSeen, receivedAt)

        let expired = TrafficMapLiveAggregation.applying([], to: initial, receivedAt: receivedAt.addingTimeInterval(TrafficMapLiveAggregation.expiry))
        XCTAssertTrue(expired.isEmpty)
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
