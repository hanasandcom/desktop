import Foundation
import XCTest
@testable import Hanasand

final class SecurityScannerClientTests: XCTestCase {
    func testClientRequiresOwnSelectedOrganizationAndRejectsImpersonation() throws {
        var settings = scannerSettings()
        settings.selectedOrganizationID = ""
        XCTAssertThrowsError(try SecurityScannerClient(settings: settings)) { XCTAssertEqual(($0 as? SecurityScannerClientError)?.localizedDescription, SecurityScannerClientError.selectOrganization.localizedDescription) }
        settings.selectedOrganizationID = "org-1"
        settings.impersonatingUserID = "other"
        XCTAssertThrowsError(try SecurityScannerClient(settings: settings)) { XCTAssertEqual(($0 as? SecurityScannerClientError)?.localizedDescription, SecurityScannerClientError.impersonationUnsupported.localizedDescription) }
        settings.impersonatingUserID = ""
        settings.selectedOrganizationUserID = "other"
        XCTAssertThrowsError(try SecurityScannerClient(settings: settings))
    }

    func testDashboardUsesAuthenticatedScopedNoCookieRequestAndDecodesEmptyState() async throws {
        var captured: URLRequest?
        let client = try SecurityScannerClient(settings: scannerSettings(), servicesPaused: false, send: { request in
            captured = request
            return (Data(#"{"assets":[],"engines":[],"runs":[],"assessments":[],"findings":[],"scannerError":"Scanner service paused","execution":{"enabled":false,"state":"paused","reason":"maintenance"}}"#.utf8), self.response(request, 200))
        })
        let dashboard = try await client.dashboard()
        XCTAssertTrue(dashboard.assets.isEmpty)
        XCTAssertEqual(dashboard.scannerError, "Scanner service paused")
        XCTAssertEqual(dashboard.execution?.enabled, false)
        XCTAssertEqual(captured?.url?.host, "scanner.hanasand.com")
        XCTAssertEqual(captured?.url?.path, "/api/v1/uvm/dashboard")
        XCTAssertEqual(URLComponents(url: captured!.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "organizationId" })?.value, "org-1")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "eirik")
        XCTAssertNil(captured?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(captured?.value(forHTTPHeaderField: "x-impersonation-token"))
    }

    func testPausedDashboardBlocksScannerWritesBeforeAnyTransportCall() async throws {
        var sent = 0
        let client = try SecurityScannerClient(settings: scannerSettings(), servicesPaused: true, send: { request in
            sent += 1
            return (Data(), self.response(request, 200))
        })
        do {
            _ = try await client.createAsset(hostname: "example.com")
            XCTFail("paused scanner must reject writes")
        } catch {
            XCTAssertEqual((error as? SecurityScannerClientError)?.localizedDescription, SecurityScannerClientError.servicesPaused.localizedDescription)
        }
        XCTAssertEqual(sent, 0, "paused write guard must run before membership or scanner requests")
        let dashboard = try JSONDecoder().decode(SecurityScannerDashboard.self, from: Data(#"{"scannerError":"Scanner services are stopped pending disk expansion.","execution":{"enabled":false,"state":"paused","reason":"pending_disk_expansion"}}"#.utf8))
        XCTAssertTrue(dashboard.servicesPaused)
    }

    func testClientDefaultsToFailClosedWithoutDashboardReadiness() async throws {
        var sent = 0
        let client = try SecurityScannerClient(settings: scannerSettings(), send: { request in
            sent += 1
            return (Data(), self.response(request, 200))
        })
        do {
            _ = try await client.createAsset(hostname: "example.com")
            XCTFail("missing readiness must reject writes")
        } catch {
            XCTAssertEqual((error as? SecurityScannerClientError)?.localizedDescription, SecurityScannerClientError.servicesPaused.localizedDescription)
        }
        XCTAssertEqual(sent, 0, "missing dashboard readiness must block before transport")
    }

    func testScannerReadinessFailsClosedAndBlocksWritesBeforeTransport() async throws {
        let decoder = JSONDecoder()
        let cases: [(String, Bool)] = [
            (#"{}"#, true),
            (#"{"execution":{"enabled":false,"state":"paused","reason":"maintenance"}}"#, true),
            (#"{"execution":{"enabled":true,"state":"enabled","reason":null}}"#, false),
            (#"{"execution":{"enabled":true,"state":"enabled","reason":null},"scannerError":"Scanner service is unavailable."}"#, true),
            (#"{"execution":{"enabled":true,"state":"enabled","reason":null},"scannerError":""}"#, true),
        ]
        for (payload, expectedPaused) in cases {
            XCTAssertEqual(try decoder.decode(SecurityScannerDashboard.self, from: Data(payload.utf8)).servicesPaused, expectedPaused)
        }

        var sent = 0
        for payload in [
            #"{}"#,
            #"{"execution":{"enabled":false,"state":"paused","reason":"maintenance"}}"#,
            #"{"execution":{"enabled":true,"state":"enabled","reason":null},"scannerError":"Scanner service is unavailable."}"#,
            #"{"execution":{"enabled":true,"state":"enabled","reason":null},"scannerError":""}"#,
        ] {
            let dashboard = try decoder.decode(SecurityScannerDashboard.self, from: Data(payload.utf8))
            let client = try SecurityScannerClient(settings: scannerSettings(), servicesPaused: dashboard.servicesPaused, send: { request in
                sent += 1
                return (Data(), self.response(request, 200))
            })
            do {
                _ = try await client.createAsset(hostname: "example.com")
                XCTFail("unready scanner must reject writes")
            } catch {
                XCTAssertEqual((error as? SecurityScannerClientError)?.localizedDescription, SecurityScannerClientError.servicesPaused.localizedDescription)
            }
        }
        XCTAssertEqual(sent, 0, "readiness guard must run before identity membership or scanner requests")

        let ready = try decoder.decode(SecurityScannerDashboard.self, from: Data(#"{"execution":{"enabled":true,"state":"enabled","reason":null}}"#.utf8))
        XCTAssertFalse(ready.servicesPaused)
    }

    func testCoveragePreservesAbsentNullAndLastCompleteRunWhileLatestRunIsPartial() throws {
        var payload: [String: Any] = [
            "assetId": "asset-1", "engine": "nmap", "state": "partial", "freshness": "stale",
            "lastRunId": "run-partial", "lastRunAt": "2026-10-24T10:00:00Z", "status": "partial",
            "authorizedAddresses": ["203.0.113.1", "203.0.113.2"],
            "requestedAddresses": ["203.0.113.1", "203.0.113.2"], "coverageKnown": true,
            "attemptedAddresses": 2, "completedAddresses": 1, "freshnessWindowHours": 24,
            "freshnessReason": "latest run was partial",
        ]

        func decodeCoverage() throws -> SecurityScannerCoverage {
            try JSONDecoder().decode(SecurityScannerCoverage.self, from: JSONSerialization.data(withJSONObject: payload))
        }
        func encodedCoverage(_ coverage: SecurityScannerCoverage) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(coverage)) as? [String: Any])
        }

        let olderServer = try decodeCoverage()
        XCTAssertEqual(olderServer.lastCompleteRun, .notReported)
        XCTAssertNil(olderServer.lastCompleteRunSummary)
        XCTAssertNil(olderServer.authorizationScopeWarning, "An unreported scope comparison must not invent a warning.")
        XCTAssertFalse(try encodedCoverage(olderServer).keys.contains("lastCompleteRun"))

        payload["scopeMatchesAuthorizedSnapshot"] = false
        let mismatchedScope = try decodeCoverage()
        XCTAssertEqual(mismatchedScope.authorizationScopeWarning, "Last run used a different authorized IP scope.")
        payload["scopeMatchesAuthorizedSnapshot"] = true
        XCTAssertNil(try decodeCoverage().authorizationScopeWarning)
        payload.removeValue(forKey: "scopeMatchesAuthorizedSnapshot")

        payload["lastCompleteRun"] = NSNull()
        let noSnapshot = try decodeCoverage()
        XCTAssertEqual(noSnapshot.lastCompleteRun, .noCompleteRun)
        XCTAssertEqual(noSnapshot.lastCompleteRunSummary, "No complete scan recorded")
        XCTAssertTrue(try encodedCoverage(noSnapshot)["lastCompleteRun"] is NSNull)

        payload["lastCompleteRun"] = [
            "runId": "run-complete", "at": "2026-10-20T08:30:00Z", "source": "scheduled",
            "profile": "tcp-top-1000", "requestedAddresses": ["203.0.113.1", "203.0.113.2"],
            "completedAddresses": 2, "completedAddressList": ["203.0.113.1", "203.0.113.2"],
            "scopeMatchesAuthorizedSnapshot": true,
        ] as [String: Any]
        let previousComplete = try decodeCoverage()
        XCTAssertEqual(previousComplete.state, "partial", "the previous complete snapshot must not replace current status")
        XCTAssertEqual(previousComplete.lastRunId, "run-partial")
        XCTAssertEqual(previousComplete.lastCompleteRunSummary, "Last complete: 2/2 addresses")
        XCTAssertEqual(previousComplete.lastCompleteRunAt, "2026-10-20T08:30:00Z")
        XCTAssertEqual(try JSONDecoder().decode(SecurityScannerCoverage.self, from: JSONEncoder().encode(previousComplete)), previousComplete)

        payload["state"] = "failed"
        let failedLatestRun = try decodeCoverage()
        XCTAssertEqual(failedLatestRun.state, "failed")
        XCTAssertEqual(failedLatestRun.lastCompleteRunSummary, previousComplete.lastCompleteRunSummary)
    }

    func testPausedScannerStillAllowsEditorToPauseExistingSchedule() async throws {
        var requests: [URLRequest] = []
        let client = try SecurityScannerClient(settings: scannerSettings(), servicesPaused: true, send: { request in
            requests.append(request)
            if request.url?.host == "identity.hanasand.com" {
                return (Data(#"{"organizations":[{"id":"org-1","name":"Hanasand","role":"editor","lifecycleStatus":"active"}]}"#.utf8), self.response(request, 200))
            }
            let asset = #"{"id":"asset-1","hostname":"example.com","verificationStatus":"verified","verificationRecordName":"","verificationRecordValue":"","verificationMethod":"dns_txt","verifiedAt":null,"scanAuthorizedAt":null,"authorizedAddresses":["203.0.113.1"],"scheduleEnabled":false,"schedulePlan":[{"engine":"nmap","profile":"tcp-top-1000"}],"scheduleEngine":"nmap","scheduleScanId":null,"scheduleProfile":"tcp-top-1000","zapApiDefinitionPath":null,"intervalMinutes":1440,"nextRunAt":null,"createdAt":"2026-10-23T10:00:00Z"}"#
            return (Data("{\"asset\":\(asset)}".utf8), self.response(request, 200))
        })
        let updated = try await client.setSchedule(
            asset: scannerAsset(scheduleEnabled: true), enabled: false, intervalMinutes: 1440, authorized: false,
            engines: [.init(engine: "nmap", scanId: nil, profile: "tcp-top-1000")]
        )

        XCTAssertFalse(updated.scheduleEnabled)
        XCTAssertEqual(requests.count, 2, "pausing a schedule must verify editor membership and send one schedule update")
        XCTAssertEqual(requests.last?.httpMethod, "PUT")
        XCTAssertEqual(requests.last?.url?.path, "/api/v1/uvm/assets/asset-1/schedule")
        let body = try XCTUnwrap(requests.last?.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(body["enabled"] as? Bool, false)
        XCTAssertEqual(body["authorized"] as? Bool, false)
        XCTAssertEqual((body["engines"] as? [[String: String]])?.first?["engine"], "nmap")
    }

    func testPausedScannerStillRejectsEnablingScheduleBeforeTransport() async throws {
        var sent = 0
        let client = try SecurityScannerClient(settings: scannerSettings(), servicesPaused: true, send: { request in
            sent += 1
            return (Data(), self.response(request, 200))
        })
        do {
            _ = try await client.setSchedule(
                asset: scannerAsset(), enabled: true, intervalMinutes: 1440, authorized: true,
                engines: [.init(engine: "nmap", scanId: nil, profile: "tcp-top-1000")]
            )
            XCTFail("a paused scanner must not enable recurring scans")
        } catch {
            XCTAssertEqual((error as? SecurityScannerClientError)?.localizedDescription, SecurityScannerClientError.servicesPaused.localizedDescription)
        }
        XCTAssertEqual(sent, 0, "new schedules remain blocked before membership or scanner requests")
    }

    func testHistoryFiltersAndLocalPagingMatchWebsiteSearchFields() throws {
        let runs = try (0..<23).map { index in
            try scannerRun(id: "run-\(index)", target: index == 4 ? "api.example.com" : "host-\(index).example.com",
                           engine: index.isMultiple(of: 2) ? "nmap" : "naabu", source: index == 3 ? "scheduled" : "manual")
        }
        let filtered = SecurityScannerHistoryFilter.runs(runs, query: " SCHEDULED ", engine: "all", status: "all")
        XCTAssertEqual(filtered.map(\.id), ["run-3"])
        XCTAssertEqual(SecurityScannerHistoryFilter.runs(runs, query: "api.example", engine: "all", status: "all").map(\.id), ["run-4"])
        XCTAssertEqual(SecurityScannerHistoryFilter.runs(runs, query: "", engine: "naabu", status: "failed").count, 0)
        XCTAssertEqual(SecurityScannerHistoryFilter.page(runs, index: 2, size: 10).map(\.id), ["run-20", "run-21", "run-22"])
        XCTAssertEqual(SecurityScannerHistoryFilter.page(runs, index: -1, size: 10).count, 10)
        XCTAssertEqual(SecurityScannerHistoryFilter.pageCount(total: 23, size: 10), 3)

        let assessments = try [
            scannerAssessment(id: "assessment-1", status: "succeeded", asset: "api.example.com"),
            scannerAssessment(id: "assessment-2", status: "failed", asset: "other.example.com"),
        ]
        XCTAssertEqual(SecurityScannerHistoryFilter.assessments(assessments, query: "api.example", status: "all").map(\.id), ["assessment-1"])
        XCTAssertEqual(SecurityScannerHistoryFilter.assessments(assessments, query: "", status: "failed").map(\.id), ["assessment-2"])
    }

    func testRunDecodingPreservesEngineSpecificObservationsFindingsAndCoverage() async throws {
        let fixture = #"{"id":"run-rich","scannerRunId":null,"requestId":"req-rich","assetId":"asset-1","target":"example.com","targetOrigin":"https://example.com","engine":"tlsx","profile":"tlsx-certificate-metadata-v1","source":"assessment","status":"succeeded","createdAt":"2026-10-23T10:00:00Z","startedAt":null,"finishedAt":null,"error":null,"engineVersion":"1.2","rawXmlSha256":null,"rawOutputSha256":"sha-output","reportHashes":{"json":"sha-report"},"attemptedAddresses":["203.0.113.5"],"completedAddresses":["203.0.113.5"],"coverage":{"known":true,"requestedAddresses":1,"attemptedAddresses":1,"completedAddresses":1,"completedAddressList":["203.0.113.5"],"missingAddresses":[],"unattemptedAddresses":[],"origin":"https://example.com","urlsVisited":3,"urlsDiscovered":2,"clientUrlsDiscovered":4,"traditionalSpiderComplete":true,"clientSpiderComplete":false,"totalAlerts":2,"acceptedAlerts":1,"acceptedInstances":1,"scopeFiltered":true,"truncationReasons":["time_limit"],"truncated":true,"complete":false},"observations":[{"id":"tls-1","address":"203.0.113.5","hostname":"example.com","port":443,"probeStatus":true,"tlsVersion":"TLS 1.3","cipher":"TLS_AES_128_GCM_SHA256","connectionMode":"direct","sni":"example.com","subjectCommonNames":["example.com"],"subjectAlternativeNames":["example.com","www.example.com"],"subjectOrganizations":[],"notBefore":"2026-01-01","notAfter":"2027-01-01","certificateSha256":"cert-sha","certificateSerial":"serial-1"}],"findings":[{"findingId":"nuclei-1","provider":"nuclei","title":"Example exposed endpoint","severity":"medium","assetAddress":"203.0.113.5","description":"Fixture description","evidence":"fixture evidence","templateId":"http/exposed","host":"https://example.com","matchedAt":"https://example.com/admin","tags":["exposure","panel"],"reference":["https://example.invalid/advisory"],"disposition":"finding"}]}"#
        let client = try SecurityScannerClient(settings: scannerSettings(), send: { request in (Data(fixture.utf8), self.response(request, 200)) })
        let run = try await client.run(id: "run-rich", engine: "tlsx")
        XCTAssertEqual(run.rawOutputSha256, "sha-output")
        XCTAssertEqual(run.reportHashes?["json"], "sha-report")
        XCTAssertEqual(run.attemptedAddresses, ["203.0.113.5"])
        XCTAssertEqual(run.coverage?.clientUrlsDiscovered, 4)
        XCTAssertEqual(run.coverage?.traditionalSpiderComplete, true)
        XCTAssertEqual(run.coverage?.clientSpiderComplete, false)
        XCTAssertEqual(run.observations?.first?.certificateSHA256, "cert-sha")
        XCTAssertEqual(run.observations?.first?.subjectAlternativeNames, ["example.com", "www.example.com"])
        XCTAssertEqual(run.findings?.first?.pluginID, nil)
        XCTAssertEqual(run.findings?.first?.matchedAt, "https://example.com/admin")
        XCTAssertEqual(run.findings?.first?.references, ["https://example.invalid/advisory"])
        XCTAssertEqual(run.findings?.first?.tags, ["exposure", "panel"])
    }

    func testUDPProfileIsSerializedForManualAndScheduledNmapScans() async throws {
        let asset = scannerAsset()
        var capturedBodies: [[String: Any]] = []
        let client = try SecurityScannerClient(settings: scannerSettings(), servicesPaused: false, send: { request in
            if request.url?.host == "identity.hanasand.com" {
                return (Data(#"{"organizations":[{"id":"org-1","name":"Hanasand","role":"editor","lifecycleStatus":"active"}]}"#.utf8), self.response(request, 200))
            }
            if let body = request.httpBody, let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any] { capturedBodies.append(decoded) }
            if request.url?.path.hasSuffix("/scans") == true {
                let receipt = ["run": ["id": "run-udp", "requestId": "request-udp", "assetId": asset.id, "target": asset.hostname,
                                        "engine": "nmap", "profile": "udp-top-100", "status": "queued", "createdAt": "2026-10-23T10:00:00Z"]]
                return (try JSONSerialization.data(withJSONObject: receipt), self.response(request, 202))
            }
            let receipt = ["asset": ["id": asset.id, "hostname": asset.hostname, "verificationStatus": "verified", "verificationRecordName": "",
                                      "verificationRecordValue": "", "verificationMethod": "dns_txt", "authorizedAddresses": ["203.0.113.1"],
                                      "scheduleEnabled": true, "schedulePlan": [["engine": "nmap", "profile": "udp-top-100"]],
                                      "scheduleEngine": "nmap", "scheduleProfile": "udp-top-100", "intervalMinutes": 1440,
                                      "createdAt": "2026-10-23T10:00:00Z"]] as [String: Any]
            return (try JSONSerialization.data(withJSONObject: receipt), self.response(request, 200))
        })
        let run = try await client.runScan(asset: asset, engine: .nmap, authorized: true, nmapProfile: .udpTop100)
        XCTAssertEqual(run.profile, "udp-top-100")
        _ = try await client.setSchedule(asset: asset, enabled: true, intervalMinutes: 1440, authorized: true,
                                         engines: [.init(engine: "nmap", scanId: nil, profile: SecurityScannerNmapProfile.udpTop100.rawValue)])
        XCTAssertEqual(capturedBodies.first?["profile"] as? String, "udp-top-100")
        XCTAssertEqual((capturedBodies.last?["engines"] as? [[String: String]])?.first?["profile"], "udp-top-100")
    }

    func testFindingSortSupportsSeverityAndFirstSeen() {
        let findings = [
            finding(id: "old-low", severity: "low", status: "open", firstSeen: "2026-01-01T00:00:00Z"),
            finding(id: "new-critical", severity: "critical", status: "open", firstSeen: "2026-03-01T00:00:00Z"),
            finding(id: "old-critical", severity: "critical", status: "open", firstSeen: "2026-02-01T00:00:00Z"),
            finding(id: "middle-critical", severity: "critical", status: "open", firstSeen: "2026-02-15T00:00:00Z")
        ]

        XCTAssertEqual(SecurityScannerFindingSort.severity.sorted(findings).map(\.id), ["old-critical", "middle-critical", "new-critical", "old-low"])
        XCTAssertEqual(SecurityScannerFindingSort.firstSeen.sorted(findings).map(\.id), ["old-low", "old-critical", "middle-critical", "new-critical"])
    }

    func testHistoryUsesRunsEnvelopeAndRunDetailUsesDirectRunContract() async throws {
        let run = #"{"id":"run-1","scannerRunId":null,"requestId":"request-1","assetId":"asset-1","target":"example.com","engine":"nmap","profile":"tcp-top-1000","status":"succeeded","createdAt":"2026-10-23T10:00:00Z","startedAt":null,"finishedAt":null,"error":null,"engineVersion":null,"rawXmlSha256":null,"coverage":null,"hosts":[{"address":"203.0.113.5","status":"up","timedOut":false,"ports":[{"port":443,"protocol":"tcp","state":"open","service":"https","product":"nginx","version":"1.2","extraInfo":null,"scriptResults":[{"id":"http-title","output":"Example","truncated":false}]}],"scriptResults":[]}],"findings":[]}"#
        let client = try SecurityScannerClient(settings: scannerSettings(), servicesPaused: false, send: { request in
            if request.url?.path == "/api/v1/uvm/runs" {
                return (Data("{\"runs\":[\(run)],\"nextCursor\":\"older\"}".utf8), self.response(request, 200))
            }
            return (Data(run.utf8), self.response(request, 200))
        })
        let page = try await client.runHistory(cursor: nil)
        XCTAssertEqual(page.items.map(\.id), ["run-1"])
        XCTAssertEqual(page.nextCursor, "older")
        let detail = try await client.run(id: "run-1", engine: "nmap")
        XCTAssertEqual(detail.hosts?.first?.ports.first?.protocolName, "tcp")
        XCTAssertEqual(detail.hosts?.first?.ports.first?.scriptResults?.first?.scriptID, "http-title")
    }

    func testCreateAssetRevalidatesActiveEditorMembershipAndSubmitsScopedRequest() async throws {
        var requests: [URLRequest] = []
        let client = try SecurityScannerClient(settings: scannerSettings(), servicesPaused: false, send: { request in
            requests.append(request)
            if request.url?.host == "identity.hanasand.com" {
                return (Data(#"{"organizations":[{"id":"org-1","name":"Hanasand","role":"editor","lifecycleStatus":"active"}]}"#.utf8), self.response(request, 200))
            }
            let asset = #"{"id":"asset-1","hostname":"example.com","verificationStatus":"pending","verificationRecordName":"_hanasand.example.com","verificationRecordValue":"verify-value","verificationMethod":"dns_txt","verifiedAt":null,"scanAuthorizedAt":null,"authorizedAddresses":[],"scheduleEnabled":false,"schedulePlan":[],"scheduleEngine":"nmap","scheduleScanId":null,"scheduleProfile":"tcp-top-1000","zapApiDefinitionPath":null,"intervalMinutes":60,"nextRunAt":null,"createdAt":"2026-10-23T10:00:00Z"}"#
            return (Data("{\"asset\":\(asset)}".utf8), self.response(request, 201))
        })
        let asset = try await client.createAsset(hostname: " Example.COM ")
        XCTAssertEqual(asset.hostname, "example.com")
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.url?.host, "identity.hanasand.com")
        XCTAssertEqual(requests.last?.httpMethod, "POST")
        XCTAssertEqual(URLComponents(url: requests.last!.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "organizationId" })?.value, "org-1")
        let bodyData = try XCTUnwrap(requests.last?.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["hostname"] as? String, "example.com")
        XCTAssertNil(body["actorId"])
    }

    func testViewerRoleCannotCreateAsset() async throws {
        var scannerWrites = 0
        let client = try SecurityScannerClient(settings: scannerSettings(), servicesPaused: false, send: { request in
            if request.url?.host == "identity.hanasand.com" {
                return (Data(#"{"organizations":[{"id":"org-1","name":"Hanasand","role":"viewer","lifecycleStatus":"active"}]}"#.utf8), self.response(request, 200))
            }
            scannerWrites += 1
            return (Data(), self.response(request, 201))
        })
        do { _ = try await client.createAsset(hostname: "example.com"); XCTFail("viewer must be read-only") }
        catch { XCTAssertEqual((error as? SecurityScannerClientError)?.localizedDescription, SecurityScannerClientError.permissionDenied.localizedDescription) }
        XCTAssertEqual(scannerWrites, 0)
    }

    func testScanCannotBeSubmittedWithoutExplicitAuthorization() async throws {
        let client = try SecurityScannerClient(settings: scannerSettings(), servicesPaused: false, send: { request in (Data(), self.response(request, 200)) })
        let asset = SecurityScannerAsset(id: "asset-1", hostname: "example.com", verificationStatus: "verified", verificationRecordName: "", verificationRecordValue: "", verificationMethod: "dns_txt", verifiedAt: nil, scanAuthorizedAt: nil, authorizedAddresses: ["203.0.113.1"], scheduleEnabled: false, schedulePlan: [], scheduleEngine: "nmap", scheduleScanId: nil, scheduleProfile: nil, zapApiDefinitionPath: nil, intervalMinutes: 60, nextRunAt: nil, createdAt: "2026-10-23T10:00:00Z")
        do { _ = try await client.runScan(asset: asset, engine: .nmap, authorized: false); XCTFail("authorization must be required") }
        catch { XCTAssertEqual((error as? SecurityScannerClientError)?.localizedDescription, SecurityScannerClientError.authorizationRequired.localizedDescription) }
    }

    func testEngineCatalogIncludesEverySupportedWebAndNetworkEngine() {
        XCTAssertEqual(SecurityScannerEngineID.allCases.map(\.rawValue), [
            "nmap", "naabu", "tenable-vm", "gvm", "zap", "testssl", "nuclei", "nikto", "sslyze",
            "wapiti", "whatweb", "httpx", "tlsx", "katana", "wafw00f",
        ])
        XCTAssertEqual(SecurityScannerEngineID.testssl.defaultProfile, "tls-default-v1")
        XCTAssertEqual(SecurityScannerEngineID.naabu.defaultProfile, "naabu-top-100")
        XCTAssertNil(SecurityScannerEngineID.nmap.defaultProfile)
    }

    func testRunScanUsesNativeEndpointForEachSupportedEngine() async throws {
        let asset = scannerAsset()
        for engine in SecurityScannerEngineID.allCases {
            var capturedPath: String?
            var capturedBody: [String: Any]?
            let client = try SecurityScannerClient(settings: scannerSettings(), servicesPaused: false, send: { request in
                if request.url?.host == "identity.hanasand.com" {
                    return (Data(#"{"organizations":[{"id":"org-1","name":"Hanasand","role":"editor","lifecycleStatus":"active"}]}"#.utf8), self.response(request, 200))
                }
                capturedPath = request.url?.path
                capturedBody = try request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let receipt = ["run": ["id": "run-1", "scannerRunId": NSNull(), "requestId": "request-1", "assetId": asset.id,
                                        "target": asset.hostname, "engine": engine.rawValue, "profile": engine.defaultProfile ?? "tcp-top-1000",
                                        "status": "queued", "createdAt": "2026-10-23T10:00:00Z"] as [String: Any]]
                return (try JSONSerialization.data(withJSONObject: receipt), self.response(request, 202))
            })

            let run = try await client.runScan(asset: asset, engine: engine, authorized: true, tenableScanID: "scan-1")
            XCTAssertEqual(run.engine, engine.rawValue)
            let expectedPath: String
            switch engine {
            case .nmap: expectedPath = "/api/v1/uvm/assets/asset-1/scans"
            case .tenableVM: expectedPath = "/api/v1/uvm/assets/asset-1/tenable-scans"
            case .gvm: expectedPath = "/api/v1/uvm/integrations/gvm/runs"
            default: expectedPath = "/api/v1/uvm/assets/asset-1/\(engine.rawValue)-scans"
            }
            XCTAssertEqual(capturedPath, expectedPath, "wrong route for \(engine.rawValue)")
            XCTAssertEqual(capturedBody?["authorized"] as? Bool, true)
            XCTAssertNotNil(capturedBody?["requestId"] as? String)
            if let profile = engine.defaultProfile { XCTAssertEqual(capturedBody?["profile"] as? String, profile) }
            if engine == .gvm { XCTAssertEqual(capturedBody?["organizationId"] as? String, "org-1") }
            if engine == .tenableVM { XCTAssertEqual(capturedBody?["scanId"] as? String, "scan-1") }
        }
    }

    func testSchedulePreservesEngineOrderAndIncludesSafeDefaultProfiles() async throws {
        let asset = scannerAsset()
        let client = try SecurityScannerClient(settings: scannerSettings(), servicesPaused: false, send: { request in
            if request.url?.host == "identity.hanasand.com" {
                return (Data(#"{"organizations":[{"id":"org-1","name":"Hanasand","role":"editor","lifecycleStatus":"active"}]}"#.utf8), self.response(request, 200))
            }
            let body = try XCTUnwrap(request.httpBody)
            let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let engines = try XCTUnwrap(decoded["engines"] as? [[String: String]])
            XCTAssertEqual(engines.map { $0["engine"] }, ["katana", "nmap", "testssl"])
            XCTAssertEqual(engines[0]["profile"], "katana-same-origin-crawl-v1")
            XCTAssertEqual(engines[2]["profile"], "tls-default-v1")
            let receipt = ["asset": ["id": asset.id, "hostname": asset.hostname, "verificationStatus": "verified",
                                      "verificationRecordName": "", "verificationRecordValue": "", "verificationMethod": "dns_txt",
                                      "verifiedAt": NSNull(), "scanAuthorizedAt": NSNull(), "authorizedAddresses": ["203.0.113.1"],
                                      "scheduleEnabled": true, "schedulePlan": [], "scheduleEngine": "katana", "scheduleScanId": NSNull(),
                                      "scheduleProfile": "katana-same-origin-crawl-v1", "zapApiDefinitionPath": NSNull(), "intervalMinutes": 60,
                                      "nextRunAt": NSNull(), "createdAt": "2026-10-23T10:00:00Z"] as [String: Any]]
            return (try JSONSerialization.data(withJSONObject: receipt), self.response(request, 200))
        })
        let selections = ["katana", "nmap", "testssl"].compactMap { raw -> SecurityScannerEngineSelection? in
            guard let engine = SecurityScannerEngineID(rawValue: raw) else { return nil }
            return SecurityScannerEngineSelection(engine: raw, scanId: nil, profile: engine == .nmap ? "tcp-top-1000" : engine.defaultProfile)
        }
        let updated = try await client.setSchedule(asset: asset, enabled: true, intervalMinutes: 60, authorized: true, engines: selections)
        XCTAssertTrue(updated.scheduleEnabled)
    }

    private func scannerSettings() -> HanasandDesktopSettings {
        var settings = HanasandDesktopSettings()
        settings.userID = "eirik"
        settings.authToken = "token-123"
        settings.selectedOrganizationID = "org-1"
        settings.selectedOrganizationUserID = "eirik"
        return settings
    }

    private func finding(id: String, severity: String, status: String, firstSeen: String?) -> SecurityScannerFinding {
        SecurityScannerFinding(
            id: id, assetId: "asset-1", asset: "example.com", address: nil, engine: "nmap", externalId: id,
            title: id, severity: severity, cvssScore: nil, cveIds: [], description: nil, solution: nil, evidence: nil,
            status: status, triageNote: nil, firstSeen: firstSeen, lastSeen: nil, updatedAt: "2026-03-02T00:00:00Z"
        )
    }

    private func scannerAsset(scheduleEnabled: Bool = false) -> SecurityScannerAsset {
        SecurityScannerAsset(id: "asset-1", hostname: "example.com", verificationStatus: "verified", verificationRecordName: "",
                             verificationRecordValue: "", verificationMethod: "dns_txt", verifiedAt: nil, scanAuthorizedAt: nil,
                             authorizedAddresses: ["203.0.113.1"], scheduleEnabled: scheduleEnabled,
                             schedulePlan: [.init(engine: "nmap", scanId: nil, profile: "tcp-top-1000")], scheduleEngine: "nmap",
                             scheduleScanId: nil, scheduleProfile: nil, zapApiDefinitionPath: nil, intervalMinutes: 60,
                             nextRunAt: nil, createdAt: "2026-10-23T10:00:00Z")
    }

    private func scannerRun(id: String, target: String, engine: String, source: String) throws -> SecurityScannerRun {
        let value: [String: Any] = [
            "id": id, "requestId": "request-\(id)", "assetId": "asset-1", "target": target,
            "engine": engine, "profile": "tcp-top-1000", "source": source, "status": "succeeded",
            "createdAt": "2026-10-23T10:00:00Z",
        ]
        return try JSONDecoder().decode(SecurityScannerRun.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func scannerAssessment(id: String, status: String, asset: String) throws -> SecurityScannerAssessment {
        let job: [String: Any] = [
            "id": "job-\(id)", "assetId": "asset-1", "asset": asset, "engine": "nmap", "profile": "tcp-top-1000",
            "stageIndex": 0, "stage": "inventory", "status": "succeeded", "attemptCount": 1,
            "createdAt": "2026-10-23T10:00:00Z",
        ]
        let value: [String: Any] = [
            "id": id, "requestId": "request-\(id)", "status": status, "source": "manual",
            "createdAt": "2026-10-23T10:00:00Z", "jobs": [job],
        ]
        return try JSONDecoder().decode(SecurityScannerAssessment.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func response(_ request: URLRequest, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    }
}
