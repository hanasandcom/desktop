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
                    #"{"data":[{"id":"actor-1","canonicalName":"Synthetic actor","normalizedName":"synthetic actor","actorType":"group","aliases":["Alias"],"confidence":0.8,"evidenceCount":4,"sourceIds":["source-1"],"captureIds":["capture-1"],"reviewState":"needs_review","firstSeenAt":"2026-10-20T10:00:00Z","lastSeenAt":"2026-10-23T10:00:00Z","updatedAt":"2026-10-23T11:00:00Z"}],"pagination":{"page":2,"limit":50,"total":51,"totalPages":2,"nextPage":null}}"#
                ), self.response(for: request.url!)
            )
        }

        let result = try await client.loadProfiles(query: "Synthetic actor", page: 2)

        XCTAssertEqual(result.profiles.first?.name, "Synthetic actor")
        XCTAssertEqual(result.profiles.first?.normalizedName, "synthetic actor")
        XCTAssertEqual(result.profiles.first?.sourceIDs, ["source-1"])
        XCTAssertEqual(result.profiles.first?.captureIDs, ["capture-1"])
        XCTAssertEqual(result.profiles.first?.updatedAt, "2026-10-23T11:00:00Z")
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

    func testTimelinessTenantScopeUsesWebsiteProxyAndActiveTenantQuery() async throws {
        var captured: URLRequest?
        let client = try ThreatIntelligenceOperationsClient(settings: makeSettings()) { request in
            captured = request
            return (self.responseData(#"{"generatedAt":"2026-10-23T10:00:00Z","summary":{},"items":[],"metrics":{},"quality":{},"page":{"total":0,"nextCursor":null}}"#), self.response(for: request.url!))
        }

        _ = try await client.loadTimeliness(scope: .tenant("org-1"), status: "unresolved_reference", query: "actor", cursor: "next-1")

        XCTAssertEqual(captured?.url?.host, "hanasand.com")
        XCTAssertEqual(captured?.url?.path, "/api/ti/timeliness")
        XCTAssertEqual(URLComponents(url: captured!.url!, resolvingAgainstBaseURL: false)?.queryItems, [
            URLQueryItem(name: "scope", value: "tenant"), URLQueryItem(name: "tenantId", value: "org-1"),
            URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "status", value: "unresolved_reference"),
            URLQueryItem(name: "q", value: "actor"), URLQueryItem(name: "cursor", value: "next-1"),
        ])
        assertAuthenticatedRead(captured, expectedHost: "hanasand.com")
    }

    func testFirstReportEvidencePostsWebsiteContractAndRequiresMatchingReceipt() async throws {
        var captured: URLRequest?
        let evidence = ThreatIntelligenceFirstReportEvidence(
            recordID: "record-1", role: "publisher", timestamp: "2026-10-23T09:10:00Z",
            referenceURL: "https://example.test", evidencePath: "article.time[datetime]", referenceTitle: "Published report")
        let client = try ThreatIntelligenceOperationsClient(settings: makeSettings()) { request in
            captured = request
            return (self.responseData(#"{"created":true,"reference":{"role":"publisher","timestamp":"2026-10-23T09:10:00Z","evidencePath":"article.time[datetime]","referenceUrl":"https://example.test/","referenceTitle":"Published report","recordedBy":"user-1","recordedAt":"2026-10-23T09:11:00Z"},"item":{"id":"record-1","actorName":"Synthetic actor","sourceName":"Synthetic source","sourceFamily":"advisory","title":"Report","summary":"","status":"unresolved_reference","updatedAt":"2026-10-23T09:11:00Z","stages":{},"missingStages":[],"sources":[],"reportReferences":[{"role":"publisher","timestamp":"2026-10-23T09:10:00Z","evidencePath":"article.time[datetime]","referenceUrl":"https://example.test/","referenceTitle":"Published report","recordedBy":"user-1","recordedAt":"2026-10-23T09:11:00Z"}],"timestampAnomalies":[]}}"#), self.response(for: request.url!))
        }

        let receipt = try await client.recordFirstReportEvidence(scope: .tenant("org-1"), evidence: evidence)

        XCTAssertTrue(receipt.created)
        XCTAssertEqual(receipt.item.id, "record-1")
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.url?.host, "hanasand.com")
        XCTAssertEqual(captured?.url?.path, "/api/ti/timeliness")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        assertAuthenticatedHeaders(captured)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: captured!.httpBody!) as? [String: String])
        XCTAssertEqual(body, [
            "recordId": "record-1", "role": "publisher", "timestamp": "2026-10-23T09:10:00Z",
            "referenceUrl": "https://example.test/", "evidencePath": "article.time[datetime]", "referenceTitle": "Published report",
        ])
        XCTAssertEqual(URLComponents(url: captured!.url!, resolvingAgainstBaseURL: false)?.queryItems, [
            URLQueryItem(name: "scope", value: "tenant"), URLQueryItem(name: "tenantId", value: "org-1"),
        ])
    }

    func testFirstReportEvidenceRejectsInvalidInputBeforeSendingAndReconcilesAmbiguousReceipt() async throws {
        var sendCount = 0
        let invalidClient = try ThreatIntelligenceOperationsClient(settings: makeSettings()) { request in
            sendCount += 1
            return (self.responseData("{}"), self.response(for: request.url!))
        }
        let invalid = ThreatIntelligenceFirstReportEvidence(
            recordID: "record-1", role: "publisher", timestamp: "2026-10-23T09:10:00", referenceURL: "http://192.168.1.1/report",
            evidencePath: "article.time[datetime]", referenceTitle: "")
        do {
            _ = try await invalidClient.recordFirstReportEvidence(scope: .tenant("org-1"), evidence: invalid)
            XCTFail("Expected private URL and missing timezone to be rejected.")
        } catch { XCTAssertEqual(error as? ThreatIntelligenceOperationsError, .invalidRequest) }
        XCTAssertEqual(sendCount, 0)

        let evidence = ThreatIntelligenceFirstReportEvidence(
            recordID: "record-1", role: "publisher", timestamp: "2026-10-23T09:10:00Z", referenceURL: "https://example.test/report",
            evidencePath: "article.time[datetime]", referenceTitle: "")
        let uncertainClient = try ThreatIntelligenceOperationsClient(settings: makeSettings()) { request in
            (self.responseData("{}"), HTTPURLResponse(url: request.url!, statusCode: 502, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        do {
            _ = try await uncertainClient.recordFirstReportEvidence(scope: .global, evidence: evidence)
            XCTFail("Expected an ambiguous server outcome to require reconciliation.")
        } catch { XCTAssertEqual(error as? ThreatIntelligenceOperationsError, .mutationOutcomeUnknown) }
    }

    func testProfilesSupportEmptyResultsAndSurfacePermissionDenial() async throws {
        let empty = try ThreatIntelligenceOperationsClient(settings: makeSettings()) { request in
            (self.responseData(#"{"data":[],"pagination":{"page":1,"limit":50,"total":0,"nextPage":null}}"#), self.response(for: request.url!))
        }
        let result = try await empty.loadProfiles(query: "No matching actor", page: 1)
        XCTAssertTrue(result.profiles.isEmpty)
        XCTAssertEqual(result.total, 0)
        XCTAssertNil(result.nextPage)

        let denied = try ThreatIntelligenceOperationsClient(settings: makeSettings()) { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (self.responseData(#"{"error":"forbidden"}"#), response)
        }
        do {
            _ = try await denied.loadProfiles(query: "", page: 1)
            XCTFail("Expected the server's profile permission denial to be preserved.")
        } catch {
            XCTAssertEqual(error as? ThreatIntelligenceOperationsError, .requestFailed(403))
        }
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

    func testOperationalSourceLookupUsesExactSourceIDParameter() async throws {
        var captured: URLRequest?
        let client = try ThreatIntelligenceOperationsClient(settings: makeSettings()) { request in
            captured = request
            return (self.responseData(#"{"schemaVersion":"ti.source_operations.v1","tenantId":"global","total":1,"rows":[{"id":"feed-1","collection":{"cadenceSeconds":1800},"nextRunAt":"2026-10-23T11:00:00Z"}]}"#), self.response(for: request.url!))
        }

        let result = try await client.loadOperationalSources(query: "", page: 1, sourceID: "feed-1")

        XCTAssertEqual(result.rows.map(\.id), ["feed-1"])
        let queryItems = URLComponents(url: captured!.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(queryItems.first(where: { $0.name == "sourceId" })?.value, "feed-1")
        XCTAssertNil(queryItems.first(where: { $0.name == "q" }))
        XCTAssertEqual(result.rows.first?.collection?.cadenceSeconds, 1800)
        XCTAssertEqual(result.rows.first?.nextRunAt, "2026-10-23T11:00:00Z")
    }

    func testOperationalSourceFiltersAndWebsiteRouteContextReachNativeQuery() async throws {
        var captured: URLRequest?
        let client = try ThreatIntelligenceOperationsClient(settings: makeSettings()) { request in
            captured = request
            return (self.responseData(#"{"schemaVersion":"ti.source_operations.v1","tenantId":"global","total":0,"rows":[],"summary":{},"safeOutput":{"sourceUrlsExposed":false,"rawCapturesExposed":false,"restrictedPayloadsExposed":false}}"#), self.response(for: request.url!))
        }
        let routeQuery = [
            "scope": "global", "available": "true", "q": "bot feed", "page": "3",
            "family": "rss", "lifecycle": "candidate",
            "access": "public_rss", "health": "not observed", "output": "yes", "matches": "no",
            "sort": "useful", "dir": "desc",
        ]
        let filters = ThreatIntelligenceOperationsRouteContext.sourceFilters(routeQuery)
        XCTAssertEqual(filters.family, "rss")
        XCTAssertEqual(filters.lifecycle, "candidate")
        XCTAssertEqual(filters.sort, "useful")
        XCTAssertEqual(filters.direction, "desc")
        let searchQuery = ThreatIntelligenceOperationsRouteContext.sourceSearchQuery(routeQuery, fallback: "detail-id")
        let page = ThreatIntelligenceOperationsRouteContext.sourcePage(routeQuery["page"])
        XCTAssertEqual(searchQuery, "bot feed")
        XCTAssertEqual(page, 3)

        _ = try await client.loadOperationalSources(query: searchQuery, page: page, filters: filters)

        let query = URLComponents(url: captured!.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first(where: { $0.name == "q" })?.value, "bot feed")
        XCTAssertEqual(query.first(where: { $0.name == "page" })?.value, "3")
        XCTAssertEqual(query.first(where: { $0.name == "includeCandidates" })?.value, "true")
        XCTAssertEqual(query.first(where: { $0.name == "family" })?.value, "rss")
        XCTAssertEqual(query.first(where: { $0.name == "lifecycle" })?.value, "candidate")
        XCTAssertEqual(query.first(where: { $0.name == "access" })?.value, "public_rss")
        XCTAssertEqual(query.first(where: { $0.name == "health" })?.value, "not observed")
        XCTAssertEqual(query.first(where: { $0.name == "output" })?.value, "yes")
        XCTAssertEqual(query.first(where: { $0.name == "matches" })?.value, "no")
        XCTAssertEqual(query.first(where: { $0.name == "sort" })?.value, "useful")
        XCTAssertEqual(query.first(where: { $0.name == "dir" })?.value, "desc")
        assertAuthenticatedRead(captured)
    }

    func testOperationalSourceFilterRouteRejectsUnsupportedWebsiteValues() {
        let filters = ThreatIntelligenceOperationsRouteContext.sourceFilters([
            "family": "unexpected", "lifecycle": "retired", "sort": "id", "dir": "sideways",
        ])
        XCTAssertEqual(filters.family, "")
        XCTAssertEqual(filters.lifecycle, "")
        XCTAssertEqual(filters.sort, "source")
        XCTAssertEqual(filters.direction, "asc")
        XCTAssertEqual(ThreatIntelligenceOperationsRouteContext.sourcePage("3x"), 1)
        XCTAssertEqual(ThreatIntelligenceOperationsRouteContext.sourcePage("0"), 1)
        XCTAssertEqual(ThreatIntelligenceOperationsRouteContext.sourcePage("20001"), 1)
        XCTAssertEqual(ThreatIntelligenceOperationsRouteContext.sourcePage("20000"), 20_000)
        XCTAssertEqual(ThreatIntelligenceOperationsRouteContext.sourceSearchQuery([:], fallback: "source-id"), "source-id")
    }

    func testCollectionRunsAndCapturesUseBoundedSafeReadEndpoints() async throws {
        var requests: [URLRequest] = []
        let client = try ThreatIntelligenceOperationsClient(settings: makeSettings()) { request in
            requests.append(request)
            let body: String
            if request.url?.path == "/v1/intel/collection-runs" {
                body = #"{"collectionRuns":[{"id":"run-1","sourceId":"feed-1","sourceName":"Synthetic feed","sourceFamily":"advisory","status":"completed","startedAt":"2026-10-23T10:00:00Z","finishedAt":"2026-10-23T10:01:00Z","nextRunAt":"2026-10-24T10:00:00Z","rows":12,"captures":3,"screenshots":1,"trigger":"automated"},{"id":"run-2","sourceIds":["feed-2"],"status":"processing","createdAt":"2026-10-23T11:00:00Z","captureCount":2,"metadata":{"trigger":"manual"}},{"id":"run-3","sourceId":"feed-3","status":"dead_letter","startedAt":"2026-10-23T12:00:00Z","updatedAt":"2026-10-23T12:05:00Z","rowCount":5,"captureCount":4,"screenshotCount":2}],"total":3}"#
            } else {
                body = #"{"captures":[{"id":"capture-1","sourceId":"feed-1","sourceName":"Synthetic feed","collectedAt":"2026-10-23T10:00:00Z","storageKind":"metadata_only","locatorRedacted":true,"metadata":{"title":"Synthetic event","actor":"Example group","domain":"example.test"},"bodyRedacted":true}],"total":1}"#
            }
            return (self.responseData(body), self.response(for: request.url!))
        }

        let runs = try await client.loadCollectionRuns(query: "feed", page: 1)
        let captures = try await client.loadCaptures(query: "feed", page: 1)

        XCTAssertEqual(runs.collectionRuns.first?.status, "completed")
        XCTAssertEqual(runs.collectionRuns.first?.sourceName, "Synthetic feed")
        XCTAssertEqual(runs.collectionRuns.first?.sourceFamily, "advisory")
        XCTAssertEqual(runs.collectionRuns.first?.trigger, "automated")
        XCTAssertEqual(runs.collectionRuns.first?.finishedAt, "2026-10-23T10:01:00Z")
        XCTAssertEqual(runs.collectionRuns.first?.nextRunAt, "2026-10-24T10:00:00Z")
        XCTAssertEqual(runs.collectionRuns.first?.captureTotal, 3)
        XCTAssertEqual(runs.collectionRuns.first?.screenshots, 1)
        XCTAssertEqual(runs.collectionRuns.first?.rowTotal, 12)
        XCTAssertEqual(runs.collectionRuns[1].sourceId, "feed-2")
        XCTAssertEqual(runs.collectionRuns[1].startedAt, "2026-10-23T11:00:00Z")
        XCTAssertEqual(runs.collectionRuns[1].status, "running")
        XCTAssertEqual(runs.collectionRuns[1].trigger, "manual")
        let mappedSource = try JSONDecoder().decode(
            ThreatIntelligenceOperationalSourcePage.Source.self,
            from: responseData(#"{"id":"feed-2","name":"Mapped feed","family":"advisory"}"#))
        XCTAssertEqual(runs.sourceName(for: runs.collectionRuns[1], sources: [mappedSource]), "Mapped feed")
        XCTAssertEqual(runs.sourceFamily(for: runs.collectionRuns[1], sources: [mappedSource]), "advisory")
        XCTAssertEqual(runs.collectionRuns[2].status, "failed")
        XCTAssertEqual(runs.collectionRuns[2].finishedAt, "2026-10-23T12:05:00Z")
        XCTAssertEqual(runs.collectionRuns[2].screenshots, 2)
        XCTAssertEqual(runs.collectionRuns[2].rowTotal, 5)
        XCTAssertEqual(runs.summary.active, 1)
        XCTAssertEqual(runs.summary.completed, 1)
        XCTAssertEqual(runs.summary.failed, 1)
        XCTAssertEqual(runs.summary.captures, 9)
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

    func testFocusedSourceScheduleParsesCadenceBackoffAndRejectsMalformedNextCheck() throws {
        let source = try JSONDecoder().decode(
            ThreatIntelligenceOperationalSourcePage.Source.self,
            from: responseData(#"{"id":"feed-1","lifecycleStatus":"active","collection":{"cadenceSeconds":3600},"nextRunAt":"not-a-date","health":{"lastAttemptAt":"2026-10-23T10:00:00Z","backoffUntil":"2026-10-23T12:30:00Z"}}"#))

        XCTAssertEqual(source.collection?.cadenceSeconds, 3600)
        XCTAssertEqual(source.cadenceDescription, "1 hr")
        XCTAssertNil(source.nextRunAt)
        XCTAssertEqual(source.displayedBackoffUntil, "2026-10-23T12:30:00Z")
        XCTAssertEqual(source.displayedNextCheckAt, "2026-10-23T12:30:00Z")

        let delayed = try JSONDecoder().decode(
            ThreatIntelligenceOperationalSourcePage.Source.self,
            from: responseData(#"{"id":"feed-1","nextRunAt":"2026-10-23T11:00:00Z","health":{"backoffUntil":"2026-10-23T12:30:00Z"}}"#))
        XCTAssertEqual(delayed.displayedNextCheckAt, "2026-10-23T12:30:00Z")

        let roundedCadence = try JSONDecoder().decode(
            ThreatIntelligenceOperationalSourcePage.Source.self,
            from: responseData(#"{"id":"feed-3","collection":{"cadenceSeconds":5400}}"#))
        XCTAssertEqual(roundedCadence.cadenceDescription, "2 hr")

        let invalid = try JSONDecoder().decode(
            ThreatIntelligenceOperationalSourcePage.Source.self,
            from: responseData(#"{"id":"feed-2","collection":{"cadenceSeconds":-30}}"#))
        XCTAssertNil(invalid.collection?.cadenceSeconds)
        XCTAssertEqual(invalid.cadenceDescription, "Not reported")
        XCTAssertNil(invalid.displayedNextCheckAt)
    }

    func testFocusedSourceHistoryUsesNarrowingQueryAndExactSourceFiltering() async throws {
        var capturedPaths: [URL] = []
        let client = try ThreatIntelligenceOperationsClient(settings: makeSettings()) { request in
            capturedPaths.append(request.url!)
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "page" })?.value
            let body: String
            if request.url?.path == "/v1/intel/collection-runs" {
                body = page == "2"
                    ? #"{"collectionRuns":[{"id":"run-page-2","sourceId":"feed-1","startedAt":"2026-10-24T12:00:00Z"}],"total":51}"#
                    : #"{"collectionRuns":[{"id":"run-exact","sourceId":"feed-1","startedAt":"2026-10-23T12:00:00Z"},{"id":"run-prefix","sourceId":"feed-10","startedAt":"2026-10-23T13:00:00Z"},{"id":"run-array","sourceIds":["feed-1","feed-2"],"createdAt":"2026-10-23T11:00:00Z"}],"total":51,"nextCursor":"cursor-2"}"#
            } else {
                body = page == "2"
                    ? #"{"captures":[{"id":"capture-page-2","sourceId":"feed-1","collectedAt":"2026-10-24T12:00:00Z"}],"total":51}"#
                    : #"{"captures":[{"id":"capture-exact","sourceId":"feed-1","collectedAt":"2026-10-23T12:00:00Z","normalizedEvidence":{"excerpt":"Safe report excerpt","text":"Detailed normalized report text"},"metadata":{"screenshotId":"hash-1","screenshotTakenAt":"2026-10-23T12:01:00Z"}},{"id":"capture-prefix","sourceId":"feed-10","collectedAt":"2026-10-23T13:00:00Z"}],"total":51,"nextCursor":"cursor-2"}"#
            }
            return (self.responseData(body), self.response(for: request.url!))
        }

        let runs = try await client.loadRecentRuns(sourceID: "feed-1")
        let captures = try await client.loadRecentCaptures(sourceID: "feed-1")

        XCTAssertEqual(Set(runs.map(\.id)), ["run-exact", "run-array", "run-page-2"])
        XCTAssertTrue(runs.allSatisfy { $0.exactlyBelongs(to: "feed-1") })
        XCTAssertEqual(Set(captures.map(\.id)), ["capture-exact", "capture-page-2"])
        XCTAssertTrue(captures.allSatisfy { $0.exactlyBelongs(to: "feed-1") })
        let captureWithExcerpt = try XCTUnwrap(captures.first(where: { $0.id == "capture-exact" }))
        XCTAssertEqual(captureWithExcerpt.safeExcerpt, "Safe report excerpt")
        XCTAssertEqual(captureWithExcerpt.screenshotLabel, "hash-1")
        XCTAssertEqual(capturedPaths.count, 4)
        for url in capturedPaths {
            let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(queryItems.first(where: { $0.name == "q" })?.value, "feed-1")
        }
    }

    func testFocusedSourceRunAndCaptureFailuresRemainIndependent() async throws {
        let client = try ThreatIntelligenceOperationsClient(settings: makeSettings()) { request in
            if request.url?.path == "/v1/intel/collection-runs" {
                return (self.responseData(#"{"error":"unavailable"}"#), self.response(url: request.url!, status: 503))
            }
            return (self.responseData(#"{"captures":[{"id":"capture-1","sourceId":"feed-1"}],"total":1}"#), self.response(for: request.url!))
        }

        async let runRequest = client.loadRecentRuns(sourceID: "feed-1")
        async let captureRequest = client.loadRecentCaptures(sourceID: "feed-1")
        let runs: [ThreatIntelligenceCollectionRunPage.Run]? = try? await runRequest
        let captures: [ThreatIntelligenceCapturePage.Capture]? = try? await captureRequest
        XCTAssertNil(runs, "Run history should be unavailable in this fixture.")
        XCTAssertEqual(captures?.map(\.id), ["capture-1"], "Capture history should load independently.")
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
        assertAuthenticatedRead(captured, expectedHost: "hanasand.com")
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

    private func response(url: URL, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    }

    private func assertAuthenticatedRead(_ request: URLRequest?, expectedHost: String = "ti.hanasand.com", file: StaticString = #filePath, line: UInt = #line) {
        assertAuthenticatedHeaders(request, file: file, line: line)
        XCTAssertEqual(request?.httpMethod, "GET", file: file, line: line)
        XCTAssertEqual(request?.url?.host, expectedHost, file: file, line: line)
    }

    private func assertAuthenticatedHeaders(_ request: URLRequest?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token", file: file, line: line)
        XCTAssertEqual(request?.value(forHTTPHeaderField: "id"), "user-1", file: file, line: line)
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Cache-Control"), "no-store", file: file, line: line)
        XCTAssertEqual(request?.httpShouldHandleCookies, false, file: file, line: line)
    }
}
