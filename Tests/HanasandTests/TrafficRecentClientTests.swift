import Foundation
import XCTest
@testable import Hanasand

final class TrafficRecentClientTests: XCTestCase {
    func testAutomaticRefreshOnlyRunsOnLatestPageWhenIdle() {
        XCTAssertTrue(TrafficRecentClient.shouldAutoRefresh(page: 1, isLoading: false))
        XCTAssertFalse(TrafficRecentClient.shouldAutoRefresh(page: 2, isLoading: false))
        XCTAssertFalse(TrafficRecentClient.shouldAutoRefresh(page: 1, isLoading: true))
    }

    func testDomainAndRecordURLsUseTrafficAPIAndEncodedFilters() throws {
        let base = URL(string: "https://api.hanasand.com/api")!
        XCTAssertEqual(try TrafficRecentClient.domainsURL(apiBaseURL: base).path, "/api/traffic/domains")

        let records = try TrafficRecentClient.recordsURL(apiBaseURL: base, domain: "example.test:443", page: 2)
        let components = URLComponents(url: records, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(components.path, "/api/traffic/records")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "limit" })?.value, "50")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "page" })?.value, "2")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "domain" })?.value, "example.test:443")

        let metrics = try TrafficRecentClient.metricsURL(apiBaseURL: base, domain: "example.test")
        let metricsComponents = URLComponents(url: metrics, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(metricsComponents.path, "/api/traffic/metrics")
        XCTAssertEqual(metricsComponents.queryItems?.first?.value, "example.test")
    }

    func testRejectsInvalidPaginationAndUnsafeEndpoints() throws {
        let base = URL(string: "https://api.hanasand.com/api")!
        XCTAssertThrowsError(try TrafficRecentClient.recordsURL(apiBaseURL: base, domain: "example.test/path", page: 1))
        XCTAssertThrowsError(try TrafficRecentClient.recordsURL(apiBaseURL: base, domain: "", page: 0))
        XCTAssertThrowsError(try TrafficRecentClient.metricsURL(apiBaseURL: base, domain: "example.test/path"))
        XCTAssertThrowsError(try TrafficRecentClient.recordsURL(apiBaseURL: URL(string: "http://api.hanasand.com/api")!, domain: "", page: 1))
    }

    func testAuthenticatedRequestOmitsCookiesAndCarriesCurrentIdentity() throws {
        let url = URL(string: "https://api.hanasand.com/api/traffic/domains")!
        let request = try TrafficRecentClient.request(url: url, userID: "user-7", authToken: "session-token", impersonationToken: "impersonation-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "id"), "user-7")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-impersonation-token"), "impersonation-token")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertThrowsError(try TrafficRecentClient.request(url: url, userID: "", authToken: "session-token"))
        XCTAssertThrowsError(try TrafficRecentClient.request(url: URL(string: "http://127.0.0.1/api/traffic/domains")!, userID: "user-7", authToken: "session-token"))
    }

    func testDecodesAndValidatesTrafficRecords() throws {
        let json = #"{"total":1,"result":[{"id":42,"user_agent":"Test client","domain":"example.test","path":"/health","method":"GET","referer":"","request_time":"12.5","status":"200","timestamp":"2026-10-23 09:14:12+00:00","country_iso":"no"}]}"#.data(using: .utf8)!
        let page = try TrafficRecentClient.decodePage(json)
        XCTAssertEqual(page.total, 1)
        XCTAssertEqual(page.result.first?.id, "42")
        XCTAssertEqual(page.result.first?.path, "/health")
        XCTAssertEqual(page.result.first?.countryISO, "NO")
    }

    func testAcceptsServerDefaultStatusZeroAsUnknown() throws {
        let json = #"{"total":1,"result":[{"id":42,"user_agent":"Test client","domain":"example.test","path":"/health","method":"GET","referer":"","request_time":1,"status":0,"timestamp":"2026-10-23T09:14:12Z","country_iso":null}]}"#.data(using: .utf8)!
        let page = try TrafficRecentClient.decodePage(json)
        XCTAssertEqual(page.result.first?.status, 0)
    }

    func testMapSnapshotDecoderAcceptsTheAuthorized200RecordPage() throws {
        let rows = (1...200).map { id in
            #"{"id":\#(id),"user_agent":"test","domain":"example.test","path":"/health","method":"GET","referer":"","request_time":1,"status":200,"timestamp":"2026-10-23T09:14:12Z","country_iso":"NO"}"#
        }.joined(separator: ",")
        let data = Data("{\"total\":200,\"result\":[\(rows)]}".utf8)

        XCTAssertEqual(try TrafficRecentClient.decodePage(data, limit: 200).result.count, 200)
        XCTAssertThrowsError(try TrafficRecentClient.decodePage(data))
    }

    func testRejectsDuplicateOrMalformedRecordsAndDeduplicatesDomains() throws {
        let duplicate = #"{"total":2,"result":[{"id":"42","user_agent":"","domain":"example.test","path":"/","method":"GET","referer":"","request_time":1,"status":200,"timestamp":"2026-10-23T09:14:12Z","country_iso":null},{"id":"42","user_agent":"","domain":"example.test","path":"/","method":"GET","referer":"","request_time":1,"status":200,"timestamp":"2026-10-23T09:14:12Z","country_iso":null}]}"#.data(using: .utf8)!
        XCTAssertThrowsError(try TrafficRecentClient.decodePage(duplicate))

        let domains = #"{"domains":["example.test","example.test","hanasand.com"]}"#.data(using: .utf8)!
        XCTAssertEqual(try TrafficRecentClient.decodeDomains(domains), ["example.test", "hanasand.com"])
        XCTAssertThrowsError(try TrafficRecentClient.decodeDomains(#"{"domains":["bad/path"]}"#.data(using: .utf8)!))
    }

    func testDecodesCompleteTrafficMetricContract() throws {
        let data = Data("""
        {
          "sampled_at":"2026-10-23T10:05:00Z",
          "total_requests":1200,
          "avg_request_time":42.5,
          "error_rate":0.025,
          "top_methods":[{"key":"GET","count":1100}],
          "top_status_codes":[{"key":"200","count":1170}],
          "top_domains":[{"key":"example.test","count":900}],
          "top_os":[{"key":"macOS","count":300}],
          "top_browsers":[{"key":"Safari","count":200}],
          "requests_over_time":[{"key":"2026-10-23T10:00:00Z","count":12}],
          "top_error_paths":[{"key":"/api/health","count":8}],
          "top_slow_paths":[{"key":"/api/report","avg_time":52.1}],
          "top_paths":[{"key":"/api/status","count":240}]
        }
        """.utf8)

        let metrics = try TrafficMetricSnapshot.decode(data)

        XCTAssertEqual(metrics.totalRequests, 1200)
        XCTAssertEqual(metrics.topOperatingSystems.first?.key, "macOS")
        XCTAssertEqual(metrics.requestsOverTime.first?.count, 12)
        XCTAssertEqual(metrics.topSlowPaths.first?.averageTime, 52.1)
        XCTAssertEqual(metrics.topErrorPaths.first?.key, "/api/health")
    }

    func testTrafficMetricsAcceptExpoNumericStringPayloads() throws {
        let data = Data("""
        {
          "sampled_at":"2026-10-23T10:05:00Z",
          "total_requests":"51",
          "avg_request_time":"18.5",
          "error_rate":"0.02",
          "top_methods":[{"key":"GET","count":"50"}],
          "top_status_codes":[{"key":"200","count":"50"}],
          "top_domains":[{"key":"synthetic.invalid","count":"51"}],
          "top_os":[],"top_browsers":[],
          "requests_over_time":[{"key":"2026-10-23T03:00:00Z","count":"26"}],
          "top_error_paths":[],"top_slow_paths":[],"top_paths":[]
        }
        """.utf8)

        let metrics = try TrafficMetricSnapshot.decode(data)
        XCTAssertEqual(metrics.totalRequests, 51)
        XCTAssertEqual(metrics.averageRequestTime, 18.5)
        XCTAssertEqual(metrics.errorRate, 0.02)
        XCTAssertEqual(metrics.topMethods.first?.count, 50)
    }

    func testRejectsInvalidTrafficMetricValuesAndTimestamps() {
        let data = Data("""
        {
          "sampled_at":"not a timestamp",
          "total_requests":10,
          "avg_request_time":-1,
          "error_rate":1.5,
          "top_methods":[],"top_status_codes":[],"top_domains":[],
          "top_os":[],"top_browsers":[],"requests_over_time":[],
          "top_error_paths":[],"top_slow_paths":[],"top_paths":[]
        }
        """.utf8)

        XCTAssertThrowsError(try TrafficMetricSnapshot.decode(data))
    }
}
