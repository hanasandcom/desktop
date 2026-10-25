import Foundation
import XCTest
@testable import Hanasand

final class ThreatIntelligencePublicSearchClientTests: XCTestCase {
    private let website = URL(string: "https://hanasand.com")!

    func testPublicSearchUsesCookieFreeUnauthenticatedGETAndProjectsOnlyPublicFields() async throws {
        var captured: URLRequest?
        let client = try ThreatIntelligencePublicSearchClient(websiteBaseURL: website) { request in
            captured = request
            return (Self.resultPayload, try Self.response(for: request, status: 200))
        }

        let result = try await client.search(" Example Actor ")

        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.host, "hanasand.com")
        XCTAssertEqual(request.url?.path, "/api/ti/search")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "q", value: "Example Actor"), URLQueryItem(name: "cached", value: "true")])
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "id"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(result.query, "Example Actor")
        XCTAssertEqual(result.summary, "Public reporting summary")
        XCTAssertEqual(result.sources.first?.name, "Public source")
        XCTAssertEqual(result.activity.first?.title, "Reported event")
        XCTAssertEqual(result.candidates.first?.name, "Example Actor")
        XCTAssertEqual(result.targets.first?.sector, "Finance")
    }

    func testPublicSearchRejectsBadQueriesRedirectsAndMismatchedResults() async throws {
        let client = try ThreatIntelligencePublicSearchClient(websiteBaseURL: website) { request in
            (Self.resultPayload, try Self.response(for: request, status: 200, url: URL(string: "https://attacker.example/api/ti/search")!))
        }
        do { _ = try await client.search("A"); XCTFail("Short queries must be rejected locally.") }
        catch { XCTAssertEqual(error as? ThreatIntelligencePublicSearchError, .invalidQuery) }
        do { _ = try await client.search("Example Actor"); XCTFail("A cross-origin response must be rejected.") }
        catch { XCTAssertEqual(error as? ThreatIntelligencePublicSearchError, .invalidResponse) }

        let mismatch = try ThreatIntelligencePublicSearchClient(websiteBaseURL: website) { request in
            (Data(#"{"query":"Different Actor","status":"ready"}"#.utf8), try Self.response(for: request, status: 200))
        }
        do { _ = try await mismatch.search("Example Actor"); XCTFail("A result for another query must be rejected.") }
        catch { XCTAssertEqual(error as? ThreatIntelligencePublicSearchError, .invalidResponse) }
    }

    private static let resultPayload = Data(#"{"query":"Example Actor","summary":"Public reporting summary","status":"ready","mode":"seeded","generatedAt":"2026-10-25T10:00:00Z","refreshAfterSeconds":0,"confidence":0.82,"aliases":["Example"],"notes":["Public note"],"adminOnly":"private fixture data","actorIdentity":{"catalogMatched":true,"activityEvidenceAvailable":false,"internalReviewer":"private","candidates":[{"canonicalName":"Example Actor","description":"Catalog match","sourceUrl":"https://reports.example.org/a","associatedNames":["Example"],"internalReviewer":"private"}]},"sources":[{"id":"source-1","name":"Public source","type":"report","provenance":"Public report","url":"https://reports.example.org/a","lastCollectedAt":"2026-10-24T00:00:00Z","privateKey":"private fixture data"}],"recentActivity":[{"title":"Reported event","detail":"Public detail","date":"2026-10-24","sourceIds":["source-1"],"reviewState":"unverified","corroborationState":"single_source","url":"https://reports.example.org/a","internalReviewNotes":"private"}],"ttps":[{"attackId":"T1001","name":"Obfuscation","tactic":"Command and Control","detail":"Public technique","sourceIds":["source-1"]}],"targets":[{"sector":"Finance","regions":["Europe"],"rationale":"Public evidence"}]}"#.utf8)

    private static func response(for request: URLRequest, status: Int, url: URL? = nil) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: url ?? XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil))
    }
}
