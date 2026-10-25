import Foundation
import XCTest
@testable import Hanasand

private actor PublicStatusFixtureTransport {
    private var responses: [(Data, Int)]
    private var capturedRequests: [URLRequest] = []

    init(responses: [(Data, Int)]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        capturedRequests.append(request)
        let next = responses.isEmpty ? (Data("{}".utf8), 200) : responses.removeFirst()
        return (next.0, HTTPURLResponse(url: request.url!, statusCode: next.1, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }

    func requests() -> [URLRequest] { capturedRequests }
}

private final class PublicStatusSnapshotFixture {
    var data: Data?

    var store: PublicStatusSnapshotStore {
        PublicStatusSnapshotStore(readData: { self.data }, writeData: { self.data = $0 })
    }
}

final class PublicStatusTests: XCTestCase {
    private let dashboardJSON = Data(#"""
    {
      "overall":"degraded","monitoring":"live","generated_at":"2026-10-23T10:00:00Z",
      "last_verified_at":"2026-10-23T09:59:00Z","history_available":true,
      "history_generated_at":"2026-10-23T09:58:00Z",
      "checks":[{"service":"Infrastructure","check_name":"Browser Web","status":"down","latency_ms":250.7,"message":"Timed out","checked_at":"2026-10-23T09:58:00Z","uptime_30d":"99.4","uptime_90d":"98.6"}],
      "incidents":[{"id":"incident-42","service":"Infrastructure","check_name":"Browser Web","title":"Browser Web interruption","impact":"Outage","status":"investigating","started_at":"2026-10-23T09:00:00Z","resolved_at":null,"summary":"Requests are timing out.","cause":"Under investigation.","updates":[]}],
      "history":[{"service":"Infrastructure","check_name":"Browser Web","date":"2026-10-23","status":"down","incident_ids":["incident-42"],"samples":24,"healthy_samples":20,"degraded_samples":1,"failed_samples":3}]
    }
    """#.utf8)

    private let detailJSON = Data(#"""
    {"overall":"unknown","generated_at":"2026-10-23T10:00:00Z","checks":[],"history":[],"incidents":[{"id":"incident-42","service":"Infrastructure","check_name":"Browser Web","title":"Browser Web interruption","impact":"Outage","status":"investigating","started_at":"2026-10-23T09:00:00Z","resolved_at":null,"summary":"Requests are timing out.","cause":"Under investigation.","updates":[{"at":"2026-10-23T09:30:00Z","status":"investigating","message":"The team is checking the upstream service."}]}]}
    """#.utf8)

    func testDashboardDecodesCurrentChecksIncidentsAndDailyHistoryWithoutAuth() async throws {
        let transport = PublicStatusFixtureTransport(responses: [(dashboardJSON, 200)])
        let client = PublicStatusClient(send: { request in try await transport.send(request) })

        let payload = try await client.dashboard()

        XCTAssertEqual(payload.overall, "degraded")
        XCTAssertEqual(payload.checks.first?.checkName, "Browser Web")
        XCTAssertEqual(payload.checks.first?.status, "down")
        XCTAssertEqual(payload.checks.first?.latencyMilliseconds, 250.7)
        XCTAssertEqual(payload.checks.first?.uptime30Days, "99.4")
        XCTAssertEqual(payload.checks.first?.uptime90Days, "98.6")
        XCTAssertEqual(payload.checks.first?.displayService, "Infrastructure")
        XCTAssertEqual(payload.incidents.first?.id, "incident-42")
        XCTAssertEqual(payload.history.first?.failedSamples, 3)
        let requests = await transport.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.host, "status.hanasand.com")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "history", value: "true")])
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testDashboardKeepsEstablishedChecksAndDropsIdentifierBearingOrNewServices() async throws {
        let fixture = Data(#"""
        {
          "overall":"degraded","checks":[
            {"service":"docker","check_name":"Discord Bot","status":"up","latency_ms":0.0},
            {"service":"docker","check_name":"Ti Web","status":"up","latency_ms":0.0},
            {"service":"docker","check_name":"Browser Worker Flatten 2ee166a healthcheck","status":"down","latency_ms":0.0},
            {"service":"docker","check_name":"Browser Worker","status":"down","latency_ms":0.0},
            {"service":"browser-worker","check_name":"Browser Worker","status":"down","latency_ms":0.0}
          ],
          "incidents":[{"id":"worker-incident","service":"docker","check_name":"Browser Worker","title":"Browser Worker failed","impact":"Outage","status":"investigating","started_at":"2026-10-23T10:00:00Z","summary":"The worker failed.","updates":[]}],
          "history":[{"service":"docker","check_name":"Browser Worker","date":"2026-10-23","status":"down","incident_ids":[]}]
        }
        """#.utf8)
        let client = PublicStatusClient(send: { request in
            (fixture, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })

        let payload = try await client.dashboard()

        XCTAssertEqual(payload.checks.map(\.checkName), ["Discord Bot", "Ti Web"])
        XCTAssertEqual(payload.checks.first?.displayService, "Infrastructure")
        XCTAssertEqual(payload.overall, "up")
        XCTAssertTrue(payload.incidents.isEmpty)
        XCTAssertTrue(payload.history.isEmpty)
    }

    func testIdentifierBearingMessagesAndIncidentTextAreNeverShown() async throws {
        let fixture = Data(#"""
        {
          "overall":"up","monitoring":"live","checks":[
            {"service":"docker","check_name":"Discord Bot","status":"up","message":"Worker 2ee166a completed."},
            {"service":"docker","check_name":"Browser Web","status":"up","message":"Requests are responding."}
          ],
          "incidents":[
            {"id":"incident-2ee166a","service":"infrastructure","check_name":"Browser Web","title":"Browser issue","impact":"Degraded","status":"resolved","started_at":"2026-10-23T09:00:00Z","summary":"Worker 2ee166a recovered.","updates":[]},
            {"id":"incident-2","service":"infrastructure","check_name":"Browser Web","title":"Browser issue","impact":"Degraded","status":"resolved","started_at":"2026-10-23T09:00:00Z","summary":"Requests have recovered.","updates":[]}
          ],
          "history":[{"service":"infrastructure","check_name":"Browser Web","date":"2026-10-23","status":"up","incident_ids":["incident-2ee166a"],"samples":24}]
        }
        """#.utf8)
        let client = PublicStatusClient(send: { request in
            (fixture, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })

        let payload = try await client.dashboard()

        XCTAssertEqual(payload.checks.map(\.checkName), ["Browser Web"])
        XCTAssertEqual(payload.incidents.map(\.summary), ["Requests have recovered."])
        XCTAssertEqual(payload.history.count, 1)
    }

    func testIncidentSelectionFetchesDetailAndUsesEncodedIncidentQuery() async throws {
        let transport = PublicStatusFixtureTransport(responses: [(detailJSON, 200)])
        let client = PublicStatusClient(send: { request in try await transport.send(request) })
        let dashboardFixture = dashboardJSON
        let summaryPayload = try await PublicStatusClient(send: { _ in (dashboardFixture, HTTPURLResponse(url: PublicStatusClient.endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!) }).dashboard()
        let summary = try XCTUnwrap(summaryPayload.incidents.first)
        let model = await MainActor.run { PublicStatusViewModel(client: client) }

        await model.selectIncident(summary)

        let selected = await model.selectedIncident
        XCTAssertEqual(selected?.updates.first?.message, "The team is checking the upstream service.")
        let requests = await transport.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "incident", value: "incident-42")])
    }

    func testIncidentDeepLinkLoadsRequestedIncidentDirectly() async throws {
        let transport = PublicStatusFixtureTransport(responses: [(detailJSON, 200)])
        let model = await MainActor.run {
            PublicStatusViewModel(client: PublicStatusClient(send: { request in try await transport.send(request) }))
        }

        await model.loadIncident(id: "incident-42")

        let selected = await model.selectedIncident
        XCTAssertEqual(selected?.id, "incident-42")
        XCTAssertEqual(selected?.updates.first?.message, "The team is checking the upstream service.")
        let requests = await transport.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "incident", value: "incident-42")])
    }

    func testReturningFromIncidentDetailReloadsFullHistorySnapshot() async throws {
        let fullHistory = Data(#"{"overall":"up","monitoring":"live","checks":[],"history":[{"service":"infrastructure","check_name":"Browser Web","date":"2026-10-23","status":"up","incident_ids":[]}],"incidents":[{"id":"incident-42","service":"infrastructure","check_name":"Browser Web","title":"Browser Web interruption","impact":"Outage","status":"resolved","started_at":"2026-10-23T09:00:00Z","resolved_at":"2026-10-23T09:30:00Z","summary":"Requests recovered.","updates":[]},{"id":"incident-41","service":"infrastructure","check_name":"Browser Web","title":"Earlier interruption","impact":"Outage","status":"resolved","started_at":"2026-10-22T09:00:00Z","resolved_at":"2026-10-22T09:30:00Z","summary":"Earlier recovery.","updates":[]}] }"#.utf8)
        let transport = PublicStatusFixtureTransport(responses: [(detailJSON, 200), (fullHistory, 200)])
        let model = await MainActor.run {
            PublicStatusViewModel(client: PublicStatusClient(send: { request in try await transport.send(request) }))
        }

        await model.loadIncident(id: "incident-42")
        await model.clearSelectedIncident()

        let selected = await model.selectedIncident
        let payload = await model.payload
        XCTAssertNil(selected)
        XCTAssertEqual(payload?.incidents.map(\.id), ["incident-42", "incident-41"])
        XCTAssertEqual(payload?.history.count, 1)
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(requests[1].url), resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "history", value: "true")])
    }

    func testEmptyPayloadAndRefreshErrorRemainDistinguishable() async throws {
        let empty = Data(#"{"overall":"unknown","generated_at":"","checks":[],"incidents":[],"history":[],"history_available":false}"#.utf8)
        let emptyTransport = PublicStatusFixtureTransport(responses: [(empty, 200)])
        let emptyModel = await MainActor.run { PublicStatusViewModel(client: PublicStatusClient(send: { request in try await emptyTransport.send(request) })) }
        await emptyModel.refresh()
        let emptyPayload = await emptyModel.payload
        let emptyError = await emptyModel.errorMessage
        XCTAssertEqual(emptyPayload?.checks.count, 0)
        XCTAssertNil(emptyError)

        let failedTransport = PublicStatusFixtureTransport(responses: [(Data("{}".utf8), 503)])
        let failedStorage = PublicStatusSnapshotFixture()
        let failedModel = await MainActor.run {
            PublicStatusViewModel(
                client: PublicStatusClient(send: { request in try await failedTransport.send(request) }),
                snapshotStore: failedStorage.store
            )
        }
        await failedModel.refresh()
        let failedPayload = await failedModel.payload
        let failedError = await failedModel.errorMessage
        let isLoading = await failedModel.isLoading
        XCTAssertNil(failedPayload)
        XCTAssertEqual(failedError, "The public status service returned HTTP 503.")
        XCTAssertFalse(isLoading)
    }

    func testVerifiedDashboardSnapshotPersistsAndRestoresBeforeOfflineRefresh() async throws {
        let storage = PublicStatusSnapshotFixture()
        let successfulModel = await MainActor.run {
            PublicStatusViewModel(
                client: PublicStatusClient(send: { request in
                    (self.dashboardJSON, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }),
                snapshotStore: storage.store
            )
        }

        await successfulModel.refresh()
        let savedData = try XCTUnwrap(storage.data)
        XCTAssertLessThanOrEqual(savedData.count, PublicStatusSnapshotStore.maximumSnapshotBytes)
        let expected = await successfulModel.payload
        XCTAssertEqual(expected?.lastVerifiedAt, "2026-10-23T09:59:00Z")

        let offlineModel = await MainActor.run {
            PublicStatusViewModel(
                client: PublicStatusClient(send: { _ in throw URLError(.notConnectedToInternet) }),
                snapshotStore: storage.store
            )
        }
        let restoredBeforeRefresh = await offlineModel.payload
        XCTAssertEqual(restoredBeforeRefresh, expected)

        await offlineModel.refresh()

        let retained = await offlineModel.payload
        let error = await offlineModel.errorMessage
        XCTAssertEqual(retained?.lastVerifiedAt, "2026-10-23T09:59:00Z")
        XCTAssertEqual(retained?.checks.first?.checkName, "Browser Web")
        XCTAssertNotNil(error)
        XCTAssertEqual(storage.data, savedData)
    }

    func testSnapshotStoreRejectsCorruptAndIdentifierBearingSnapshots() throws {
        let storage = PublicStatusSnapshotFixture()
        let store = storage.store

        storage.data = Data("not-json".utf8)
        XCTAssertNil(store.load())
        XCTAssertNil(storage.data)

        storage.data = Data(#"{"overall":"up","monitoring":"live","last_verified_at":"2026-10-23T09:59:00Z","checks":[{"service":"docker","check_name":"Browser Worker Flatten 2ee166a healthcheck","status":"down"}],"incidents":[],"history":[]}"#.utf8)
        XCTAssertNil(store.load())
        XCTAssertNil(storage.data)

        storage.data = Data(repeating: 0x20, count: PublicStatusSnapshotStore.maximumSnapshotBytes + 1)
        XCTAssertNil(store.load())
        XCTAssertNil(storage.data)
    }

    func testIncidentDetailNeverReplacesFullDashboardSnapshot() async throws {
        let storage = PublicStatusSnapshotFixture()
        let dashboardModel = await MainActor.run {
            PublicStatusViewModel(
                client: PublicStatusClient(send: { request in
                    (self.dashboardJSON, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }),
                snapshotStore: storage.store
            )
        }
        await dashboardModel.refresh()
        let savedFullDashboard = try XCTUnwrap(storage.data)
        let incidentModel = await MainActor.run {
            PublicStatusViewModel(
                client: PublicStatusClient(send: { request in
                    (self.detailJSON, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }),
                snapshotStore: storage.store
            )
        }

        await incidentModel.loadIncident(id: "incident-42")

        let payload = await incidentModel.payload
        let selected = await incidentModel.selectedIncident
        XCTAssertEqual(payload?.checks.first?.checkName, "Browser Web")
        XCTAssertEqual(payload, try JSONDecoder().decode(PublicStatusPayload.self, from: dashboardJSON))
        XCTAssertEqual(selected?.updates.first?.message, "The team is checking the upstream service.")
        XCTAssertEqual(storage.data, savedFullDashboard)
    }

    func testFreshVerifiedSnapshotReplacesOlderCache() async throws {
        let storage = PublicStatusSnapshotFixture()
        let store = storage.store
        let oldPayload = try JSONDecoder().decode(PublicStatusPayload.self, from: dashboardJSON)
        store.save(oldPayload)
        let freshFixture = Data(#"{"overall":"up","monitoring":"live","generated_at":"2026-10-24T11:00:00Z","last_verified_at":"2026-10-24T10:59:00Z","checks":[{"service":"docker","check_name":"Discord Bot","status":"up","checked_at":"2026-10-24T10:59:00Z"}],"incidents":[],"history":[]}"#.utf8)
        let model = await MainActor.run {
            PublicStatusViewModel(
                client: PublicStatusClient(send: { request in
                    (freshFixture, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }),
                snapshotStore: store
            )
        }

        await model.refresh()

        let payload = await model.payload
        let restored = try XCTUnwrap(store.load())
        XCTAssertEqual(payload?.lastVerifiedAt, "2026-10-24T10:59:00Z")
        XCTAssertEqual(restored.checks.map(\.checkName), ["Discord Bot"])
        XCTAssertEqual(restored.lastVerifiedAt, payload?.lastVerifiedAt)
    }

    func testRefreshExposesLoadingStateUntilResponseArrives() async throws {
        let fixture = dashboardJSON
        let model = await MainActor.run {
            PublicStatusViewModel(client: PublicStatusClient(send: { _ in
                try await Task.sleep(for: .milliseconds(100))
                return (fixture, HTTPURLResponse(url: PublicStatusClient.endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }))
        }

        let refresh = await MainActor.run { Task { await model.refresh() } }
        try await Task.sleep(for: .milliseconds(10))
        let loading = await model.isLoading
        XCTAssertTrue(loading)
        await refresh.value
        let finishedLoading = await model.isLoading
        XCTAssertFalse(finishedLoading)
    }

    func testStatusHasARecognizedLoopbackScreenshotCommand() {
        let request = #"POST /command HTTP/1.1"#
        let body = Data(#"{"command":"open_dashboard_status"}"#.utf8)

        XCTAssertEqual(LoopbackAgentServer.commandName(from: request, body: body), "open_dashboard_status")
    }

    func testDateFormattingHandlesFractionalStatusTimestamps() {
        let formatted = formatDateText("2026-10-23T19:51:19.658Z", fallback: "unverified")

        XCTAssertNotEqual(formatted, "2026-10-23T19:51:19.658Z")
        XCTAssertNotEqual(formatted, "unverified")
    }

    func testPublicStatusTimelineCoversTheLatest90UTCDateKeys() throws {
        let formatter = ISO8601DateFormatter()
        let now = try XCTUnwrap(formatter.date(from: "2026-10-25T23:59:00Z"))

        let dates = PublicStatusTimeline.dateKeys(now: now)

        XCTAssertEqual(dates.count, 90)
        XCTAssertEqual(dates.first, "2026-07-28")
        XCTAssertEqual(dates.last, "2026-10-25")
    }

    func testPublicStatusTimelineAssociatesOnlyVisibleMatchingIncidents() throws {
        let fixture = Data(#"""
        {
          "overall":"degraded","monitoring":"live",
          "checks":[{"service":"infrastructure","check_name":"Browser Web","status":"down","uptime_90d":"98.6"}],
          "incidents":[
            {"id":"incident-42","aliases":["legacy-42"],"service":"infrastructure","check_name":"Browser Web","title":"Browser Web interruption","impact":"Degraded","status":"resolved","started_at":"2026-07-28T09:00:00Z","summary":"Requests recovered.","updates":[]},
            {"id":"unsafe-incident","service":"infrastructure","check_name":"Browser Web","title":"Browser Worker 2ee166a failed","impact":"Outage","status":"resolved","started_at":"2026-07-29T09:00:00Z","summary":"Worker 2ee166a recovered.","updates":[]}
          ],
          "history":[
            {"service":"infrastructure","check_name":"Browser Web","date":"2026-07-28","status":"down","incident_ids":["legacy-42"],"samples":24,"healthy_samples":20,"degraded_samples":1,"failed_samples":3},
            {"service":"infrastructure","check_name":"Browser Web","date":"2026-07-29","status":"down","incident_ids":["unsafe-incident"],"samples":24,"healthy_samples":20,"degraded_samples":1,"failed_samples":3},
            {"service":"infrastructure","check_name":"Browser Web","date":"2026-07-30","status":"down","incident_ids":["not-in-visible-feed"],"samples":24,"healthy_samples":0,"degraded_samples":0,"failed_samples":24},
            {"service":"infrastructure","check_name":"Browser Web","date":"2026-07-31","status":"down","incident_ids":["incident-42"]},
            {"service":"website","check_name":"Browser Web","date":"2026-07-28","status":"up","incident_ids":["incident-42"]}
          ]
        }
        """#.utf8)
        let payload = try JSONDecoder().decode(PublicStatusPayload.self, from: fixture)
        let check = try XCTUnwrap(payload.checks.first)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-25T23:59:00Z"))
        let days = PublicStatusTimeline.days(for: check, in: payload, now: now)
        let byDate = Dictionary(uniqueKeysWithValues: days.map { ($0.date, $0) })

        XCTAssertEqual(payload.incidents.map(\.id), ["incident-42"])
        XCTAssertEqual(byDate["2026-07-28"]?.incident?.id, "incident-42")
        XCTAssertEqual(byDate["2026-07-28"]?.displayStatus, "degraded")
        XCTAssertEqual(byDate["2026-07-28"]?.samples, 24)
        XCTAssertEqual(try XCTUnwrap(byDate["2026-07-28"]?.healthyFraction), 20.0 / 24.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(byDate["2026-07-28"]?.healthyAndDegradedFraction), 21.0 / 24.0, accuracy: 0.0001)
        XCTAssertNil(byDate["2026-07-29"]?.incident)
        XCTAssertNil(byDate["2026-07-30"]?.incident)
        XCTAssertEqual(byDate["2026-07-31"]?.incident?.id, "incident-42")
        XCTAssertNil(byDate["2026-07-27"])
        XCTAssertEqual(byDate["2026-07-28"]?.id, "2026-07-28")
    }
}
