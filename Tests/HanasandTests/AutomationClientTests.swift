import Foundation
import XCTest
@testable import Hanasand

final class AutomationClientTests: XCTestCase {
    func testPersonalCronAndHealthUseTheAuthenticatedAutomationContract() async throws {
        var captured: URLRequest?
        let client = try AutomationClient(settings: settings()) { request in
            captured = request
            return self.response(#"{"canManageSystem":true,"automations":[]}"#, request)
        }

        let personal = try await client.list(scope: "personal")
        XCTAssertTrue(personal.automations.isEmpty)
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.hanasand.test/api/automations?scope=personal")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "eirik")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertNil(captured?.value(forHTTPHeaderField: "Cookie"))

        _ = try await client.list()
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.hanasand.test/api/automations")
    }

    func testHealthDetailIncludesIssuesAndHistoryPagination() async throws {
        var captured: URLRequest?
        let client = try AutomationClient(settings: settings()) { request in
            captured = request
            return self.response(#"{"automation":{"id":"check-1","name":"Website","prompt":"available","actionType":"agent_prompt","monitoringType":"fetch","scheduleKind":"interval","intervalMinutes":5,"status":"active","uptime":99.5,"certificateStatus":"valid","history":[{"id":"run-1","status":"completed","warning":false,"started_at":"2026-10-23T10:00:00Z"}]},"runs":[{"id":"run-1","status":"completed","warning":false,"startedAt":"2026-10-23T10:00:00Z","caseNumber":"HA-1"}],"issues":[{"id":"issue-1","caseNumber":"HA-1","kind":"failure","summary":"Timed out","occurrences":2,"firstSeenAt":"2026-10-22T10:00:00Z","lastSeenAt":"2026-10-23T10:00:00Z","resolvedAt":null,"notifications":[]}],"total":51,"nextPage":2}"#, request)
        }

        let detail = try await client.detail(id: "check-1")
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.hanasand.test/api/automations/check-1?page=1")
        XCTAssertEqual(detail.automation.uptime, 99.5)
        XCTAssertEqual(detail.automation.history.first?.startedAt, "2026-10-23T10:00:00Z")
        XCTAssertEqual(detail.issues.first?.caseNumber, "HA-1")
        XCTAssertEqual(detail.nextPage, 2)

        _ = try await client.detail(id: "check-1", page: 2)
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.hanasand.test/api/automations/check-1?page=2")
    }

    func testMutationUsesExactRoutesAndRejectsImpersonationAndUnsafeIdentifiers() async throws {
        var requests: [URLRequest] = []
        let client = try AutomationClient(settings: settings()) { request in
            requests.append(request)
            let body = request.httpMethod == "POST" && request.url?.path.hasSuffix("/run") == true
                ? #"{"message":"queued"}"#
                : #"{"automation":{"id":"check-1","name":"Website","prompt":"available","actionType":"agent_prompt","monitoringType":"fetch","scheduleKind":"interval","status":"active"}}"#
            return self.response(body, request)
        }
        _ = try await client.setStatus("check-1", status: "paused")
        _ = try await client.delete("check-1")
        XCTAssertEqual(requests.map(\.httpMethod), ["PUT", "DELETE"])
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/automations/check-1", "/api/automations/check-1"])

        do { _ = try await client.delete("../check-1"); XCTFail("Unsafe path ids must be rejected") }
        catch AutomationClientError.invalidInput {}

        var impersonated = settings()
        impersonated.impersonationToken = "view-token"
        var sends = 0
        let readOnly = try AutomationClient(settings: impersonated) { request in
            sends += 1
            return self.response("{}", request)
        }
        do { _ = try await readOnly.run("check-1"); XCTFail("Impersonated accounts cannot start checks") }
        catch AutomationClientError.impersonationReadOnly {}
        XCTAssertEqual(sends, 0)
    }

    func testAutomationEditorEncodesJSONRuleAndSupportedActions() throws {
        let rule = DesktopAutomationJSONRule(path: "results.*.latency", operatorName: "gte", value: .number(80), aggregate: "max")
        let payload = DesktopAutomationPayload(
            name: "Latency", prompt: "Watch latency", targetUrl: "https://example.test/health",
            monitoringType: "json", scheduleKind: "interval", intervalMinutes: 5,
            status: "active", actionType: "agent_prompt", jsonRule: rule
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        let encodedRule = try XCTUnwrap(object["jsonRule"] as? [String: Any])
        XCTAssertEqual(encodedRule["path"] as? String, "results.*.latency")
        XCTAssertEqual(encodedRule["operator"] as? String, "gte")
        XCTAssertEqual(encodedRule["aggregate"] as? String, "max")
        XCTAssertEqual(encodedRule["value"] as? Double, 80)
        XCTAssertEqual(DesktopAutomationEditorRules.actions, ["agent_prompt", "system_alert", "echo", "mail_health_check"])
    }

    func testAutomationSavePreservesPushSourceAndFirstNotificationDestination() async throws {
        var captured: URLRequest?
        let client = try AutomationClient(settings: settings()) { request in
            captured = request
            return self.response(#"{"automation":{"id":"push-1","name":"Heartbeat","prompt":"Check in","actionType":"agent_prompt","targetUrl":"uptime.site","monitoringType":"push","scheduleKind":"interval","intervalMinutes":1,"status":"active"}}"#, request)
        }
        let payload = DesktopAutomationPayload(
            name: "Heartbeat", prompt: "Check in", targetUrl: "uptime.site", monitoringType: "push",
            scheduleKind: "interval", intervalMinutes: 1, status: "active", actionType: "agent_prompt",
            timeoutSeconds: 180, retryCount: 0, modelName: "https://discord.example/webhook",
            notificationDestinations: ["https://discord.example/webhook"]
        )

        _ = try await client.save(payload)
        let body = try XCTUnwrap(captured?.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["actionType"] as? String, "agent_prompt")
        XCTAssertEqual(object["monitoringType"] as? String, "push")
        XCTAssertEqual(object["targetUrl"] as? String, "uptime.site")
        XCTAssertEqual(object["intervalMinutes"] as? Int, 1)
        XCTAssertEqual(object["timeoutSeconds"] as? Int, 180)
        XCTAssertEqual(object["retryCount"] as? Int, 0)
        XCTAssertEqual(object["modelName"] as? String, "https://discord.example/webhook")
        XCTAssertEqual(object["notificationDestinations"] as? [String], ["https://discord.example/webhook"])
    }

    func testAutomationEditorParsesJSONScalarValuesWithoutLosingTypes() throws {
        XCTAssertEqual(DesktopAutomationEditorRules.value(from: "42"), .number(42))
        XCTAssertEqual(DesktopAutomationEditorRules.value(from: "true"), .bool(true))
        XCTAssertEqual(DesktopAutomationEditorRules.value(from: "false"), .bool(false))
        XCTAssertEqual(DesktopAutomationEditorRules.value(from: "degraded"), .string("degraded"))
        XCTAssertEqual(DesktopAutomationEditorRules.value(from: "\" 42 \""), .string(" 42 "))
        XCTAssertEqual(DesktopAutomationEditorRules.value(from: "null"), .string("null"))
        XCTAssertNil(DesktopAutomationEditorRules.value(from: "  "))
    }

    func testAutomationEditorRejectsUnsupportedDestinationClearing() {
        XCTAssertTrue(DesktopAutomationEditorRules.wouldClearExistingDestinations(
            existingModelName: "https://discord.example/webhook",
            existingDestinations: ["https://discord.example/webhook"],
            requestedDestinations: []
        ))
        XCTAssertTrue(DesktopAutomationEditorRules.wouldClearExistingDestinations(
            existingModelName: nil,
            existingDestinations: ["destination"],
            requestedDestinations: []
        ))
        XCTAssertFalse(DesktopAutomationEditorRules.wouldClearExistingDestinations(
            existingModelName: "https://discord.example/webhook",
            existingDestinations: ["https://discord.example/webhook"],
            requestedDestinations: ["https://discord.example/webhook"]
        ))
        XCTAssertFalse(DesktopAutomationEditorRules.wouldClearExistingDestinations(
            existingModelName: nil,
            existingDestinations: [],
            requestedDestinations: []
        ))
    }

    func testAmbiguousCreateFailureRequiresSuccessfulListReconciliation() {
        XCTAssertTrue(DesktopAutomationEditorRules.createMayHaveCommitted(AutomationClientError.invalidResponse))
        XCTAssertTrue(DesktopAutomationEditorRules.createMayHaveCommitted(AutomationClientError.requestFailed(503)))
        XCTAssertTrue(DesktopAutomationEditorRules.createMayHaveCommitted(AutomationClientError.requestFailed(408)))
        XCTAssertTrue(DesktopAutomationEditorRules.createMayHaveCommitted(URLError(.timedOut)))
        XCTAssertFalse(DesktopAutomationEditorRules.createMayHaveCommitted(AutomationClientError.requestFailed(400)))
        XCTAssertFalse(DesktopAutomationEditorRules.createMayHaveCommitted(AutomationClientError.invalidInput))

        XCTAssertFalse(DesktopAutomationEditorRules.canCreate(hasLoadedList: false, isLoading: false, outcomeUncertain: false, canMutate: true))
        XCTAssertFalse(DesktopAutomationEditorRules.canCreate(hasLoadedList: true, isLoading: true, outcomeUncertain: false, canMutate: true))
        XCTAssertFalse(DesktopAutomationEditorRules.canCreate(hasLoadedList: true, isLoading: false, outcomeUncertain: true, canMutate: true))
        XCTAssertFalse(DesktopAutomationEditorRules.canCreate(hasLoadedList: true, isLoading: false, outcomeUncertain: false, canMutate: false))
        XCTAssertTrue(DesktopAutomationEditorRules.canCreate(hasLoadedList: true, isLoading: false, outcomeUncertain: false, canMutate: true))
    }

    func testAutomationEditorValidatesJSONRuleAndSystemCapabilities() {
        func validate(path: String = "metrics.*.latency", op: String = "gt", value: DesktopAutomationRuleValue = .number(80), monitoring: String = "json",
                      aggregate: String? = "max", target: String = "https://example.test/metrics", canManage: Bool = false,
                      schedule: String = "interval", interval: Int? = nil, timeout: Int? = nil, expectedDown: Bool = false, upsideDown: Bool = false,
                      action: String = "agent_prompt") -> String? {
            let rule = DesktopAutomationJSONRule(path: path, operatorName: op, value: value, aggregate: aggregate)
            return DesktopAutomationEditorRules.validate(actionType: action, monitoringType: monitoring, targetURL: target, jsonRule: rule, canManageSystem: canManage, scheduleKind: schedule, intervalMinutes: interval, timeoutSeconds: timeout, expectedDown: expectedDown, upsideDown: upsideDown)
        }

        XCTAssertNil(validate())
        XCTAssertNotNil(validate(path: "metrics.__proto__.latency"))
        XCTAssertNotNil(validate(path: String(repeating: "a", count: 301)))
        XCTAssertNotNil(validate(op: "bad"))
        XCTAssertNotNil(validate(aggregate: "sum"))
        XCTAssertNotNil(validate(op: "eq", value: .null))
        XCTAssertNotNil(validate(value: .string("slow")))
        XCTAssertNil(validate(op: "eq", value: .string("slow")))
        XCTAssertNotNil(validate(target: "system:metrics"))
        XCTAssertNil(validate(target: "system:metrics", canManage: true))
        XCTAssertNotNil(validate(monitoring: "fetch", target: "system:metrics", canManage: true))
        XCTAssertNotNil(validate(canManage: false, action: "mail_health_check"))
        XCTAssertNil(validate(canManage: true, action: "mail_health_check"))
        XCTAssertNotNil(validate(action: "organization_report"))
        XCTAssertNil(validate(monitoring: "push", target: "uptime.site", interval: 1, timeout: 86_400))
        XCTAssertNotNil(validate(monitoring: "push", target: "uptime.site", interval: 2, timeout: 180))
        XCTAssertNotNil(validate(monitoring: "push", target: "system:metrics", canManage: true, interval: 1, timeout: 180))
        XCTAssertNotNil(validate(monitoring: "push", target: "uptime.site", interval: 1, timeout: 86_401))
        XCTAssertNotNil(validate(monitoring: "push", target: "uptime.site", interval: 1, timeout: 180, expectedDown: true))
        XCTAssertNotNil(validate(monitoring: "push", target: "uptime.site", interval: 1, timeout: 180, action: "system_alert"))
    }

    private func settings() -> HanasandDesktopSettings {
        var value = HanasandDesktopSettings()
        value.userID = "eirik"
        value.authToken = "token-123"
        value.apiBaseURL = "https://api.hanasand.test/api"
        return value
    }

    private func response(_ body: String, _ request: URLRequest) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }
}
