import Foundation
import XCTest
@testable import Hanasand

final class ThreatRulesTests: XCTestCase {
    private var settings: HanasandDesktopSettings {
        var value = HanasandDesktopSettings()
        value.apiBaseURL = "https://api.hanasand.test/api"
        value.userID = "owner"
        value.authToken = "token-abc"
        value.selectedOrganizationID = "org-1"
        value.selectedOrganizationUserID = "owner"
        return value
    }

    private func response(_ json: String, for request: URLRequest, status: Int = 200) -> (Data, URLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }

    private let ruleJSON = #"{"id":"custom.example.v1","name":"Example rule","explanation":"A representative organization rule.","severity":"medium","version":"1","enabled":true,"source":"owned","family":"Custom","hitCount":8,"definition":{"stage":"analyze","action":"drop","conditions":[{"path":"message","operator":"equals","value":"bad","caseSensitive":true}]}}"#

    func testLoadsRulesOnlyForOwnerBoundActiveMembership() async throws {
        var requests: [URLRequest] = []
        let client = ThreatRulesClient(settings: settings) { request in
            requests.append(request)
            if request.url?.path == "/api/organizations" {
                return self.response(#"{"organizations":[{"id":"org-1","name":"Example","role":"editor","lifecycleStatus":"active"}]}"#, for: request)
            }
            return self.response(#"{"organizationId":"org-1","canManageRetention":true,"rules":[\#(self.ruleJSON)]}"#, for: request)
        }
        let page = try await client.loadRules(category: "analysis")
        XCTAssertEqual(page.organization.role, "editor")
        XCTAssertEqual(page.rules.first?.id, "custom.example.v1")
        XCTAssertTrue(page.canManageRetention)
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET"])
        XCTAssertEqual(requests[0].url?.host, "api.hanasand.test")
        XCTAssertEqual(requests[1].url?.path, "/api/rules")
        XCTAssertEqual(URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "organizationId" })?.value, "org-1")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer token-abc")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertFalse(requests[1].httpShouldHandleCookies)
    }

    func testRejectsStaleOrganizationBindingBeforeAnyRequest() async {
        var stale = settings
        stale.selectedOrganizationUserID = "different-user"
        var sent = false
        let client = ThreatRulesClient(settings: stale) { request in sent = true; return self.response("{}", for: request) }
        do {
            _ = try await client.loadRules(category: "match")
            XCTFail("Expected account-bound organization selection to be required")
        } catch ThreatRulesError.selectOrganization {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(sent)
    }

    func testTuningAccessUsesInternalRoleGateAndNeverNeedsSelectedHanasandOrg() async throws {
        var unrelated = settings
        unrelated.selectedOrganizationID = "org-other"
        var captured: URLRequest?
        let client = ThreatRulesClient(settings: unrelated) { request in
            captured = request
            return self.response(#"{"allowed":true,"canEdit":true}"#, for: request)
        }
        let access = try await client.tuningAccess()
        XCTAssertTrue(access.canWrite)
        XCTAssertEqual(captured?.url?.path, "/api/management/organizations")
        XCTAssertEqual(URLComponents(url: captured!.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "1")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "owner")
    }

    func testImpersonatedSessionCannotCreateOrganizationRule() async {
        var impersonating = settings
        impersonating.impersonationToken = "impersonation-token"
        var sent = false
        let client = ThreatRulesClient(settings: impersonating) { request in sent = true; return self.response("{}", for: request) }
        let definition: ThreatRuleJSON = .object(["stage": .string("match"), "action": .string("keep"), "conditions": .array([.object(["path": .string("event_type"), "operator": .string("equals"), "value": .string("login")])])])
        do {
            _ = try await client.saveRule(nil, category: "match", organizationID: "org-1", name: "Valid rule", explanation: "A valid description for this rule.", severity: "medium", enabled: true, definition: definition)
            XCTFail("Expected impersonation to deny rule mutation")
        } catch ThreatRulesError.permissionDenied {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(sent)
    }

    func testTuningPreviewSendsStoredLogsOnlyAndExplicitSample() async throws {
        var captured: URLRequest?
        let client = ThreatRulesClient(settings: settings) { request in
            captured = request
            return self.response(#"{"count":1,"scanned":12,"bytes":440,"events":[],"cursor":null}"#, for: request)
        }
        let access = TuningAccess(canWrite: false)
        let result = try await client.previewStored(conditions: [.init(path: "message", operation: "equals", value: "failed", caseSensitive: true)], action: "drop", access: access, from: nil, until: "2026-10-23T12:00:00Z")
        let body = try XCTUnwrap(captured?.httpBody).jsonObject as? [String: Any]
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(captured?.url?.path, "/api/rules/preview")
        XCTAssertEqual(body?["storedLogsOnly"] as? Bool, true)
        XCTAssertEqual(body?["sample"] as? Bool, true)
        XCTAssertEqual(body?["limit"] as? Int, 2000)
        XCTAssertEqual(URLComponents(url: captured!.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "organizationId" })?.value, ThreatRulesClient.tuningOrganizationID)
    }
}

private extension Data {
    var jsonObject: Any? { try? JSONSerialization.jsonObject(with: self, options: [.fragmentsAllowed]) }
}
