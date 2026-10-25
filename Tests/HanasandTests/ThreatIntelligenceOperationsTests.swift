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

    func testOperationalInventoryUsesGlobalOperatorEndpointAndReadOnlyProjection() async throws {
        var captured: URLRequest?
        let client = try ThreatIntelligenceOperationsClient(settings: makeSettings()) { request in
            captured = request
            return (
                self.responseData(#"{"schemaVersion":"ti.source_operations.v1","tenantId":"global","total":1,"rows":[{"id":"feed-1","name":"Synthetic feed","family":"advisory","type":"rss","lifecycleStatus":"active","executable":true,"operatingMode":{"accessMethod":"public_web","metadataOnly":false},"health":{"state":"healthy","lastAttemptAt":"2026-10-23T10:00:00Z","lastUsefulItemAt":"2026-10-23T09:00:00Z","consecutiveFailures":0},"coverage":{"captureCount":8,"customerMatchCount":2},"qualification":{"qualifies":true,"reasons":[],"productiveCheckCount":3}}],"summary":{"sourceCount":1},"safeOutput":{"sourceUrlsExposed":false,"rawCapturesExposed":false,"restrictedPayloadsExposed":false}}"#), self.response(for: request.url!)
            )
        }

        let result = try await client.loadOperationalSources(query: "feed", page: 1)

        XCTAssertEqual(result.rows.first?.name, "Synthetic feed")
        XCTAssertEqual(result.rows.first?.health?.state, "healthy")
        XCTAssertEqual(result.rows.first?.coverage?.captureCount, 8)
        XCTAssertEqual(captured?.httpMethod, "GET")
        XCTAssertEqual(URLComponents(url: captured!.url!, resolvingAgainstBaseURL: false)?.path, "/v1/intel/source-operations")
        let query = URLComponents(url: captured!.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertNil(query.first(where: { $0.name == "tenantId" }))
        XCTAssertEqual(query.first(where: { $0.name == "includeCandidates" })?.value, "true")
        assertAuthenticatedRead(captured)
    }

    func testCollectionRunsAndCapturesUseBoundedSafeReadEndpoints() async throws {
        var requests: [URLRequest] = []
        let client = try ThreatIntelligenceOperationsClient(settings: makeSettings()) { request in
            requests.append(request)
            let body: String
            if request.url?.path == "/v1/intel/collection-runs" {
                body = #"{"collectionRuns":[{"id":"run-1","sourceId":"feed-1","status":"completed","startedAt":"2026-10-23T10:00:00Z","captureCount":2}],"total":1}"#
            } else {
                body = #"{"captures":[{"id":"capture-1","sourceId":"feed-1","sourceName":"Synthetic feed","collectedAt":"2026-10-23T10:00:00Z","storageKind":"metadata_only","locatorRedacted":true,"metadata":{"title":"Synthetic event","actor":"Example group","domain":"example.test"},"bodyRedacted":true}],"total":1}"#
            }
            return (self.responseData(body), self.response(for: request.url!))
        }

        let runs = try await client.loadCollectionRuns(query: "feed", page: 1)
        let captures = try await client.loadCaptures(query: "feed", page: 1)

        XCTAssertEqual(runs.collectionRuns.first?.status, "completed")
        XCTAssertEqual(captures.captures.first?.metadata?.title, "Synthetic event")
        XCTAssertEqual(captures.captures.first?.locatorRedacted, true)
        XCTAssertEqual(requests.map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.path }, ["/v1/intel/collection-runs", "/v1/intel/captures"])
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
        requests.forEach { assertAuthenticatedRead($0) }
    }

    func testOperationalInventoryFailsClosedWhenServerDeniesOperatorRole() async throws {
        let client = try ThreatIntelligenceOperationsClient(settings: makeSettings()) { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (self.responseData(#"{"error":"source_operator_forbidden"}"#), response)
        }
        do {
            _ = try await client.loadOperationalSources(query: "", page: 1)
            XCTFail("Expected server role denial to fail the read rather than return an empty inventory.")
        } catch {
            XCTAssertEqual(error as? ThreatIntelligenceOperationsError, .requestFailed(403))
        }
    }

    func testSourceStatusWriteUsesWebsiteControlGateAndRequiresMatchingReceipt() async throws {
        var captured: URLRequest?
        let source = try operationalSource()
        let client = try ThreatIntelligenceOperationsClient(settings: makeSettings()) { request in
            captured = request
            return (self.responseData(#"{"ok":true,"status":200,"payload":{"source":{"id":"feed-1","status":"paused"}}}"#), self.response(for: request.url!))
        }

        try await client.updateSourceStatus(source: source, status: "paused")

        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.url?.absoluteString, "https://hanasand.com/api/ti/scraper/control")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "user-1")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: captured!.httpBody!) as? [String: String], [
            "action": "source_status", "sourceId": "feed-1", "tenantId": "default", "status": "paused",
        ])
    }

    func testManualRunWriteMatchesWebsitePayloadAndRequiresQueuedReceipt() async throws {
        var captured: URLRequest?
        let client = try ThreatIntelligenceOperationsClient(settings: makeSettings()) { request in
            captured = request
            return (self.responseData(#"{"ok":true,"status":201,"payload":{"run":{"id":"run-1","status":"queued"},"scheduler":{"queued":2}}}"#), self.response(for: request.url!))
        }

        try await client.queueCollectionQuery(source: operationalSource(), queries: ["example.test", "example.test", "another.test"])

        XCTAssertEqual(captured?.httpMethod, "POST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: captured!.httpBody!) as? [String: Any])
        XCTAssertEqual(body["action"] as? String, "run_query")
        XCTAssertEqual(body["sourceId"] as? String, "feed-1")
        XCTAssertEqual(body["query"] as? String, "example.test")
        XCTAssertEqual(body["targets"] as? [String], ["example.test", "another.test"])
    }

    func testMutationsFailClosedOnRoleDenialAndRequireRefreshAfterAmbiguousOutcome() async throws {
        let source = try operationalSource()
        let denied = try ThreatIntelligenceOperationsClient(settings: makeSettings()) { request in
            (self.responseData(#"{"error":"internal_access_required"}"#), HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        do {
            try await denied.updateSourceStatus(source: source, status: "paused")
            XCTFail("Expected fresh server-side authorization denial.")
        } catch { XCTAssertEqual(error as? ThreatIntelligenceOperationsError, .requestFailed(403)) }

        let uncertain = try ThreatIntelligenceOperationsClient(settings: makeSettings()) { request in
            (self.responseData(#"{"ok":false,"status":0}"#), HTTPURLResponse(url: request.url!, statusCode: 502, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        do {
            try await uncertain.queueCollectionQuery(source: source, queries: ["example.test"])
            XCTFail("Expected ambiguous mutation receipt to require a history refresh.")
        } catch { XCTAssertEqual(error as? ThreatIntelligenceOperationsError, .mutationOutcomeUnknown) }
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

    private func operationalSource() throws -> ThreatIntelligenceOperationalSourcePage.Source {
        try JSONDecoder().decode(ThreatIntelligenceOperationalSourcePage.Source.self, from: responseData(#"{"id":"feed-1","tenantId":"default","name":"Synthetic feed","family":"advisory","lifecycleStatus":"active","executable":true,"coverage":{"observedDomains":["example.test","another.test"]}}"#))
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
