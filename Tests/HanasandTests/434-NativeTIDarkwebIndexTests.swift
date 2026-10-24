import Foundation
import XCTest

@testable import Hanasand

final class NativeTIDarkwebIndexTests: XCTestCase {
    func testFilterQueryIncludesOnlyNonemptySupportedFilters() {
        let filters = NativeTIDarkwebFilters(
            query: "  Acme & Sons ",
            category: "ransomware_claim",
            legalTriage: "approved",
            network: "tor",
            reviewState: "ready"
        )

        let items = filters.queryItems(limit: 50)
        XCTAssertEqual(items.map(\.name), ["limit", "q", "category", "legalTriage", "network", "reviewState"])
        XCTAssertEqual(items.map(\.value), ["50", "Acme & Sons", "ransomware_claim", "approved", "tor", "ready"])
        XCTAssertEqual(NativeTIDarkwebFilters().queryItems().map(\.name), ["limit"])
    }

    func testStatusAndSearchModelsDecodeWebsiteContracts() throws {
        let status = try JSONDecoder().decode(NativeTIDarkwebStatusResponse.self, from: Data(#"{"darkwebIndex":{"indexedRecordCount":12,"monitoredSourceCount":4,"metadataOnly":true,"generatedAt":"2026-10-24T10:00:00Z","latestRecordAt":"2026-10-23T10:00:00Z","counts":{"byNetwork":{"tor":5},"byLegalTriage":{"approved":12},"byLiveness":{"fresh":9},"byReviewState":{"ready":12}},"noLeakSerialization":{"passed":true}}}"#.utf8))
        XCTAssertEqual(status.index?.indexedRecordCount, 12)
        XCTAssertEqual(status.index?.counts?.byNetwork?["tor"], 5)
        XCTAssertEqual(status.index?.noLeakSerialization?.passed, true)

        let search = try JSONDecoder().decode(NativeTIDarkwebSearchResponse.self, from: Data(#"{"generatedAt":"2026-10-24T10:00:00Z","count":1,"nextCursor":"next-page","canonicalIdentity":{"type":"actor","canonicalName":"Example actor","aliases":["Example"],"canonicalPath":"/ti/example","restrictedEvidenceState":"no_approved_restricted_evidence","restrictedRecordCount":0},"rows":[{"id":"record-1","network":"tor","title":"Example exposure","safeSummary":"Metadata-only claim","category":"ransomware_claim","legalTriage":"approved","liveness":"fresh","firstSeen":"2026-10-20T00:00:00Z","lastSeen":"2026-10-23T00:00:00Z","reviewState":"ready","actorHints":["Example group"],"victimHints":["Example company"],"datasetHints":["customer records"],"sectorHints":["technology"],"countryHints":["NO"],"safeLocatorHash":"sha256:abc"}],"noLeakSerialization":{"passed":true}}"#.utf8))
        XCTAssertEqual(search.records.count, 1)
        XCTAssertEqual(search.records.first?.safeLocatorHash, "sha256:abc")
        XCTAssertEqual(search.canonicalIdentity?.canonicalName, "Example actor")
        XCTAssertEqual(search.nextCursor, "next-page")
    }

    func testClientUsesPublicWebsiteProxyWithoutCookiesOrCredentials() async throws {
        let recorder = DarkwebRequestRecorder()
        let client = NativeTIDarkwebIndexClient(websiteBaseURL: "https://hanasand.com") { request in
            recorder.append(request)
            return (Data(#"{"count":0,"rows":[],"nextCursor":null}"#.utf8), Self.response(for: request.url!))
        }

        let filters = NativeTIDarkwebFilters(query: "Acme & Sons", category: "ransomware_claim", legalTriage: "approved", network: "tor", reviewState: "ready")
        let result = try await client.search(filters: filters)

        XCTAssertTrue(result.records.isEmpty)
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "hanasand.com")
        XCTAssertEqual(request.url?.path, "/api/ti/darkweb/search")
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "limit" })?.value, "50")
        XCTAssertEqual(query?.first(where: { $0.name == "q" })?.value, "Acme & Sons")
        XCTAssertEqual(query?.first(where: { $0.name == "category" })?.value, "ransomware_claim")
        XCTAssertEqual(query?.first(where: { $0.name == "legalTriage" })?.value, "approved")
        XCTAssertEqual(query?.first(where: { $0.name == "network" })?.value, "tor")
        XCTAssertEqual(query?.first(where: { $0.name == "reviewState" })?.value, "ready")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "id"))
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    func testClientReadsStatusAndRejectsRedirectOrBadEndpoint() async throws {
        let recorder = DarkwebRequestRecorder()
        let client = NativeTIDarkwebIndexClient(websiteBaseURL: "https://hanasand.com") { request in
            recorder.append(request)
            return (Data(#"{"status":{"indexedRecordCount":2}}"#.utf8), Self.response(for: request.url!))
        }
        let status = try await client.loadStatus()
        XCTAssertEqual(status.index?.indexedRecordCount, 2)
        XCTAssertEqual(recorder.requests.first?.url?.path, "/api/ti/darkweb/status")

        let redirected = NativeTIDarkwebIndexClient(websiteBaseURL: "https://hanasand.com") { request in
            (Data("{}".utf8), Self.response(for: URL(string: "https://other.example/api/ti/darkweb/status")!))
        }
        do {
            _ = try await redirected.loadStatus()
            XCTFail("A cross-origin final response must be rejected.")
        } catch {
            XCTAssertEqual(error as? NativeTIDarkwebIndexClient.ClientError, .invalidResponse)
        }

        let insecure = NativeTIDarkwebIndexClient(websiteBaseURL: "http://hanasand.com") { request in
            (Data("{}".utf8), Self.response(for: request.url!))
        }
        do {
            _ = try await insecure.loadStatus()
            XCTFail("The client must reject insecure endpoints.")
        } catch {
            XCTAssertEqual(error as? NativeTIDarkwebIndexClient.ClientError, .invalidEndpoint)
        }
    }

    func testSearchRejectsOversizedFiltersAndReportsHTTPStatus() async throws {
        let client = NativeTIDarkwebIndexClient(websiteBaseURL: "https://hanasand.com") { request in
            (Data(#"{"error":"unavailable"}"#.utf8), Self.response(for: request.url!, status: 503))
        }
        do {
            _ = try await client.search(filters: NativeTIDarkwebFilters(query: String(repeating: "x", count: 257)))
            XCTFail("Overlong query must be rejected before the request.")
        } catch {
            XCTAssertEqual(error as? NativeTIDarkwebIndexClient.ClientError, .invalidRequest)
        }
        do {
            _ = try await client.loadStatus()
            XCTFail("Non-success responses must surface as failures.")
        } catch {
            XCTAssertEqual(error as? NativeTIDarkwebIndexClient.ClientError, .httpStatus(503))
        }
    }

    private static func response(for url: URL, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    }
}

private final class DarkwebRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func append(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        storage.append(request)
    }
}
