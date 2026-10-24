import Foundation
import XCTest

@testable import Hanasand

final class ActorEnrichmentClientTests: XCTestCase {
    func testOverviewMapsProfilesAndEvidenceUpdatesFromDistinctEndpoints() async throws {
        var requests: [URLRequest] = []
        let client = try ActorEnrichmentClient(settings: makeSettings()) { request in
            requests.append(request)
            let body: String
            if request.url?.path == "/v1/intel/actor-enrichment/overview" {
                body = #"{"profiles":[{"id":"actor-1","canonicalName":"Synthetic actor","aliases":["Example"],"confidence":0.83,"updatedAt":"2026-10-23T10:00:00Z","sourceIds":["feed-1"],"captureIds":["capture-1"],"evidenceCount":1}],"updates":[{"id":"delta-1","subjectType":"actor_profile","subjectId":"actor-1","actorName":"Synthetic actor","observedAt":"2026-10-23T10:00:00Z","sourceId":"feed-1","captureIds":["capture-1"],"kind":"enriched","metadata":{"characterization":{"malwareTools":["Example tool"]}}}],"status":{"worker":{"state":"active","lastRunAt":"2026-10-23T10:00:00Z","lastSuccessfulRunAt":"2026-10-23T10:00:00Z","currentFailure":null,"snapshotFresh":true},"latestRun":{"id":"enrich-1","status":"completed","actorCount":1,"sourceCount":1,"changedFieldCount":1,"evidenceCount":1,"failureCount":0,"finishedAt":"2026-10-23T10:00:00Z"},"queued":2,"productivity":{"profiles":1,"wordsAdded":12,"newFacts":1}}}"#
            } else {
                body = #"{"runs":[{"id":"enrich-1","status":"completed","startedAt":"2026-10-23T09:00:00Z","finishedAt":"2026-10-23T10:00:00Z","actorCount":1,"sourceCount":1,"changedFieldCount":1,"evidenceCount":1,"failureCount":0,"error":null}],"total":1,"nextCursor":null,"previousCursor":null}"#
            }
            return (Data(body.utf8), self.response(for: request.url!))
        }

        let overview = try await client.loadOverview(query: "Synthetic actor")
        let runs = try await client.loadRuns()

        XCTAssertEqual(overview.profiles.first?.name, "Synthetic actor")
        XCTAssertEqual(overview.profiles.first?.sourceIDs, ["feed-1"])
        XCTAssertEqual(overview.updates.first?.summary, "malwareTools")
        XCTAssertEqual(overview.status.queued, 2)
        XCTAssertEqual(overview.status.productivity?.newFacts, 1)
        XCTAssertEqual(runs.runs.first?.id, "enrich-1")
        XCTAssertEqual(requests.map { $0.url?.path }, ["/v1/intel/actor-enrichment/overview", "/v1/intel/actor-enrichment/status"])
        let overviewQuery = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(overviewQuery?.first(where: { $0.name == "tenantId" })?.value, "default")
        XCTAssertEqual(overviewQuery?.first(where: { $0.name == "q" })?.value, "Synthetic actor")
        requests.forEach { assertAuthenticatedRead($0) }
    }

    func testQueueRunRequiresAcceptedReceiptAndUsesAuthenticatedDefaultTenant() async throws {
        var captured: URLRequest?
        let client = try ActorEnrichmentClient(settings: makeSettings()) { request in
            captured = request
            return (Data(#"{"accepted":true,"status":"queued"}"#.utf8), self.response(for: request.url!, status: 202))
        }

        try await client.queueRun()

        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.url?.absoluteString, "https://ti.hanasand.com/v1/intel/actor-enrichment/runs")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "user-1")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: captured!.httpBody!) as? [String: String], ["tenantId": "default"])
    }

    func testQueueRunRejectsUnconfirmedReceiptAndOverviewQueryBounds() async throws {
        let rejected = try ActorEnrichmentClient(settings: makeSettings()) { request in
            (Data(#"{"accepted":false}"#.utf8), self.response(for: request.url!, status: 202))
        }
        do { try await rejected.queueRun(); XCTFail("An ambiguous receipt must fail closed.") }
        catch { XCTAssertEqual(error as? ThreatIntelligenceOperationsError, .mutationOutcomeUnknown) }

        let client = try ActorEnrichmentClient(settings: makeSettings()) { request in
            (Data("{}".utf8), self.response(for: request.url!))
        }
        do { _ = try await client.loadOverview(query: String(repeating: "x", count: 101)); XCTFail("Expected bounded query.") }
        catch { XCTAssertEqual(error as? ThreatIntelligenceOperationsError, .invalidRequest) }
    }

    private func makeSettings() -> HanasandDesktopSettings {
        var settings = HanasandDesktopSettings()
        settings.websiteBaseURL = "https://hanasand.com"
        settings.userID = "user-1"
        settings.authToken = "test-token"
        return settings
    }

    private func response(for url: URL, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    }

    private func assertAuthenticatedRead(_ request: URLRequest?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(request?.httpMethod, "GET", file: file, line: line)
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token", file: file, line: line)
        XCTAssertEqual(request?.value(forHTTPHeaderField: "id"), "user-1", file: file, line: line)
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Cache-Control"), "no-store", file: file, line: line)
        XCTAssertEqual(request?.httpShouldHandleCookies, false, file: file, line: line)
        XCTAssertEqual(request?.url?.host, "ti.hanasand.com", file: file, line: line)
    }
}
