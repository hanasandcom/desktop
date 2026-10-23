import Foundation
import XCTest
@testable import Hanasand

final class TrafficRecentClientTests: XCTestCase {
    func testDomainAndRecordURLsUseTrafficAPIAndEncodedFilters() throws {
        let base = URL(string: "https://api.hanasand.com/api")!
        XCTAssertEqual(try TrafficRecentClient.domainsURL(apiBaseURL: base).path, "/api/traffic/domains")

        let records = try TrafficRecentClient.recordsURL(apiBaseURL: base, domain: "example.test:443", page: 2)
        let components = URLComponents(url: records, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(components.path, "/api/traffic/records")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "limit" })?.value, "50")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "page" })?.value, "2")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "domain" })?.value, "example.test:443")
    }

    func testRejectsInvalidPaginationAndUnsafeEndpoints() throws {
        let base = URL(string: "https://api.hanasand.com/api")!
        XCTAssertThrowsError(try TrafficRecentClient.recordsURL(apiBaseURL: base, domain: "example.test/path", page: 1))
        XCTAssertThrowsError(try TrafficRecentClient.recordsURL(apiBaseURL: base, domain: "", page: 0))
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
        let json = #"{"total":1,"result":[{"id":42,"user_agent":"Test client","domain":"example.test","path":"/health","method":"GET","referer":"","request_time":"12.5","status":"200","timestamp":"2026-10-23 09:14:12+00:00","country_iso":"NO"}]}"#.data(using: .utf8)!
        let page = try TrafficRecentClient.decodePage(json)
        XCTAssertEqual(page.total, 1)
        XCTAssertEqual(page.result.first?.id, "42")
        XCTAssertEqual(page.result.first?.path, "/health")
        XCTAssertEqual(page.result.first?.countryISO, "NO")
    }

    func testRejectsDuplicateOrMalformedRecordsAndDeduplicatesDomains() throws {
        let duplicate = #"{"total":2,"result":[{"id":"42","user_agent":"","domain":"example.test","path":"/","method":"GET","referer":"","request_time":1,"status":200,"timestamp":"2026-10-23T09:14:12Z","country_iso":null},{"id":"42","user_agent":"","domain":"example.test","path":"/","method":"GET","referer":"","request_time":1,"status":200,"timestamp":"2026-10-23T09:14:12Z","country_iso":null}]}"#.data(using: .utf8)!
        XCTAssertThrowsError(try TrafficRecentClient.decodePage(duplicate))

        let domains = #"{"domains":["example.test","example.test","hanasand.com"]}"#.data(using: .utf8)!
        XCTAssertEqual(try TrafficRecentClient.decodeDomains(domains), ["example.test", "hanasand.com"])
        XCTAssertThrowsError(try TrafficRecentClient.decodeDomains(#"{"domains":["bad/path"]}"#.data(using: .utf8)!))
    }
}
