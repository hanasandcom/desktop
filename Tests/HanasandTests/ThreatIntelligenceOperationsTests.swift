import Foundation
import XCTest

@testable import Hanasand

final class ThreatIntelligenceOperationsTests: XCTestCase {
    func testProfilesUseAuthenticatedBoundedPublicPage() async throws {
        var captured: URLRequest?
        let client = try ThreatIntelligenceOperationsClient(settings: makeSettings()) { request in
            captured = request
            return (
                self.responseData(
                    #"{"data":[{"id":"actor-1","canonicalName":"Synthetic actor","actorType":"group","aliases":["Alias"],"confidence":0.8,"evidenceCount":4,"sourceIds":["source-1"],"reviewState":"needs_review","firstSeenAt":"2026-10-20T10:00:00Z","lastSeenAt":"2026-10-23T10:00:00Z"}],"pagination":{"page":2,"limit":50,"total":51,"totalPages":2,"nextPage":null}}"#
                ), self.response(for: request.url!)
            )
        }

        let result = try await client.loadProfiles(query: "Synthetic actor", page: 2)

        XCTAssertEqual(result.profiles.first?.name, "Synthetic actor")
        XCTAssertEqual(result.profiles.first?.sourceIDs, ["source-1"])
        XCTAssertEqual(result.total, 51)
        XCTAssertEqual(URLComponents(url: captured!.url!, resolvingAgainstBaseURL: false)?.path, "/api/v1/actors")
        XCTAssertEqual(
            URLComponents(url: captured!.url!, resolvingAgainstBaseURL: false)?.queryItems,
            [
                URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "page", value: "2"),
                URLQueryItem(name: "q", value: "Synthetic actor"),
            ])
        assertAuthenticatedRead(captured)
    }

    func testSourcesUseReadOnlyPublicProjectionAndDropUnsafeLocator() async throws {
        var captured: URLRequest?
        let client = try ThreatIntelligenceOperationsClient(settings: makeSettings()) { request in
            captured = request
            return (
                self.responseData(
                    #"{"data":[{"id":"source-1","name":"Synthetic feed","type":"advisory","status":"active","risk":"low","trustScore":0.9,"language":"en","tags":["public"],"url":"http://source.example.test/report","locatorRedacted":false,"operatingMode":{"accessMethod":"public_web","metadataOnly":false,"approvalState":"approved","policyVersion":"v1"},"collection":{"cadenceSeconds":3600,"freshnessTargetSeconds":7200,"lastSeenAt":"2026-10-23T10:00:00Z"}}],"pagination":{"page":1,"limit":50,"total":1,"totalPages":1,"nextPage":null}}"#
                ), self.response(for: request.url!)
            )
        }

        let result = try await client.loadSources(query: "feed", page: 1)

        XCTAssertEqual(result.sources.first?.name, "Synthetic feed")
        XCTAssertNil(result.sources.first?.url)
        XCTAssertEqual(result.sources.first?.collection.cadenceSeconds, 3600)
        XCTAssertEqual(captured?.httpMethod, "GET")
        XCTAssertEqual(URLComponents(url: captured!.url!, resolvingAgainstBaseURL: false)?.path, "/api/v1/sources")
        assertAuthenticatedRead(captured)
    }

    func testTimelinessUsesGlobalScopeAndParsesReadOnlySnapshot() async throws {
        var captured: URLRequest?
        let client = try ThreatIntelligenceOperationsClient(settings: makeSettings()) { request in
            captured = request
            return (
                self.responseData(
                    #"{"generatedAt":"2026-10-23T10:00:00Z","summary":{"recordCount":1,"unresolvedReferenceCount":1,"anomalyCount":0,"awaitingAlertCount":0,"awaitingDeliveryCount":0,"completeCount":0,"observedCoverage":1.0},"items":[{"id":"record-1","actorName":"Synthetic actor","sourceName":"Synthetic source","sourceFamily":"advisory","title":"Source-reported observation","summary":"Unverified source report.","status":"unresolved_reference","updatedAt":"2026-10-23T10:00:00Z","stages":{"observed":"2026-10-23T09:00:00Z","first_report":"2026-10-23T09:10:00Z"},"missingStages":["delivered"],"sources":[{"title":"Synthetic source","url":"https://example.test/report"}],"timestampAnomalies":[]}],"metrics":{"byStage":[{"name":"reportToDeliveredSeconds","sampleSize":5,"medianSeconds":60,"p95Seconds":120,"p99Seconds":150}],"bySourceFamily":[{"name":"advisory","recordCount":1,"metrics":{"reportToDeliveredSeconds":{"sampleSize":1,"medianSeconds":60,"p95Seconds":60,"p99Seconds":60}}}],"byActor":[]},"quality":{"fields":[{"name":"first_report","presentCount":1,"missingCount":0,"coverage":1.0}],"issues":[{"name":"timezone_missing","count":1}],"bySourceClass":[{"name":"advisory","recordCount":1,"missing":{"delivered":1},"issues":{"timezone_missing":1}}]},"page":{"total":1,"nextCursor":null}}"#
                ), self.response(for: request.url!)
            )
        }

        let result = try await client.loadTimeliness(status: "unresolved_reference", query: "actor")

        XCTAssertEqual(result.items.first?.actorName, "Synthetic actor")
        XCTAssertEqual(result.summary.recordCount, 1)
        XCTAssertEqual(result.metrics.byStage.first?.p95Seconds, 120)
        XCTAssertEqual(result.metrics.bySourceFamily.first?.metrics["reportToDeliveredSeconds"]?.medianSeconds, 60)
        XCTAssertEqual(result.quality.issues.first?.count, 1)
        XCTAssertEqual(result.items.first?.missingStages, ["delivered"])
        XCTAssertEqual(result.items.first?.sources.first?.url?.absoluteString, "https://example.test/report")
        XCTAssertEqual(URLComponents(url: captured!.url!, resolvingAgainstBaseURL: false)?.path, "/api/ti/timeliness")
        let query = URLComponents(url: captured!.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first(where: { $0.name == "scope" })?.value, "global")
        XCTAssertNil(query.first(where: { $0.name == "tenantId" }))
        XCTAssertEqual(captured?.httpMethod, "GET")
        assertAuthenticatedRead(captured)
    }

    func testRejectsImpersonationInsecureConfigurationAndRedirectedResponses() async throws {
        var settings = makeSettings()
        settings.impersonationToken = "impersonation"
        XCTAssertThrowsError(try ThreatIntelligenceOperationsClient(settings: settings))

        settings = makeSettings()
        settings.websiteBaseURL = "http://hanasand.test"
        XCTAssertThrowsError(try ThreatIntelligenceOperationsClient(settings: settings))

        let client = try ThreatIntelligenceOperationsClient(settings: makeSettings()) { request in
            (
                self.responseData(#"{"data":[],"pagination":{"page":1,"total":0,"nextPage":null}}"#),
                self.response(url: URL(string: "https://other.example.test/api/v1/actors")!)
            )
        }
        do {
            _ = try await client.loadProfiles(query: "", page: 1)
            XCTFail("Expected redirected response to be rejected.")
        } catch {
            XCTAssertTrue(error is ThreatIntelligenceOperationsError)
        }
    }

    func testRejectsOversizedAndInconsistentPages() async throws {
        let tooManyRows = (0..<51).map { "{\"id\":\"actor-\($0)\",\"canonicalName\":\"Actor\"}" }.joined(separator: ",")
        let tooManyClient = try ThreatIntelligenceOperationsClient(settings: makeSettings()) { request in
            (
                self.responseData("{\"data\":[\(tooManyRows)],\"pagination\":{\"page\":1,\"total\":51,\"nextPage\":2}}"),
                self.response(for: request.url!)
            )
        }
        do {
            _ = try await tooManyClient.loadProfiles(query: "", page: 1)
            XCTFail("Expected oversized page to be rejected.")
        } catch { XCTAssertTrue(error is ThreatIntelligenceOperationsError) }

        let hugePayload = String(repeating: "x", count: 2_000_001)
        let hugeClient = try ThreatIntelligenceOperationsClient(settings: makeSettings()) { request in
            (Data(hugePayload.utf8), self.response(for: request.url!))
        }
        do {
            _ = try await hugeClient.loadSources(query: "", page: 1)
            XCTFail("Expected oversized response to be rejected.")
        } catch { XCTAssertEqual(error as? ThreatIntelligenceOperationsError, .responseTooLarge) }
    }

    private func makeSettings() -> HanasandDesktopSettings {
        var settings = HanasandDesktopSettings()
        settings.websiteBaseURL = "https://hanasand.com"
        settings.userID = "user-1"
        settings.authToken = "test-token"
        return settings
    }

    private func responseData(_ body: String) -> Data { Data(body.utf8) }

    private func response(for requestURL: URL) -> HTTPURLResponse { response(url: requestURL) }

    private func response(url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
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
