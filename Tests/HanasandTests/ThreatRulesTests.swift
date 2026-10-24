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

    func testRuleDetailPreservesHistoricalVersionAndPagesAuditInSelectedOrganization() async throws {
        var captured: URLRequest?
        let audit = #"{"id":"audit-1","event_type":"event.rule.updated","actor_id":"owner","created_at":"2026-10-22T17:31:00.000Z","context":{"before":{"version":"1","enabled":true,"name":"Old name"},"after":{"version":"2","enabled":false,"name":"New name"},"action":"event.rule.updated"}}"#
        let historicalRule = #"{"id":"custom.example.v1","name":"Old name","explanation":"A representative organization rule.","severity":"medium","version":"2","enabled":true,"source":"owned","family":"Custom","hitCount":8,"definition":{"stage":"analyze","action":"drop","conditions":[{"path":"message","operator":"equals","value":"bad","caseSensitive":true}]}}"#
        let client = ThreatRulesClient(settings: settings) { request in
            captured = request
            return self.response(#"{"organizationId":"org-1","canEdit":false,"isHistorical":true,"rule":\#(historicalRule),"triggerCount":8,"audit":[\#(audit)],"nextOffset":100}"#, for: request)
        }

        let detail = try await client.loadRule(id: "custom.example.v2", organizationID: "org-1", offset: 50)

        XCTAssertEqual(captured?.url?.path, "/api/rules/custom.example.v2")
        let query = URLComponents(url: try XCTUnwrap(captured?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "organizationId" })?.value, "org-1")
        XCTAssertEqual(query?.first(where: { $0.name == "offset" })?.value, "50")
        XCTAssertEqual(detail.rule.version, "2")
        XCTAssertTrue(detail.isHistorical)
        XCTAssertFalse(detail.canEdit)
        XCTAssertEqual(detail.audit.first?.actor_id, "owner")
        XCTAssertEqual(detail.audit.first?.event_type, "event.rule.updated")
        XCTAssertEqual(detail.audit.first?.before["name"]?.stringValue, "Old name")
        XCTAssertEqual(detail.audit.first?.after["name"]?.stringValue, "New name")
        XCTAssertEqual(detail.audit.first?.action, "event.rule.updated")
        XCTAssertEqual(detail.nextOffset, 100)
    }

    func testCurrentRuleDetailUsesVersionFreeSlug() async throws {
        var captured: URLRequest?
        let client = ThreatRulesClient(settings: settings) { request in
            captured = request
            return self.response(#"{"organizationId":"org-1","canEdit":true,"isHistorical":false,"rule":\#(self.ruleJSON),"triggerCount":8,"audit":[],"nextOffset":null}"#, for: request)
        }

        let detail = try await client.loadRule(id: "custom.example", organizationID: "org-1")

        XCTAssertEqual(captured?.url?.path, "/api/rules/custom.example")
        XCTAssertFalse(detail.isHistorical)
        XCTAssertEqual(detail.rule.id, "custom.example.v1")
    }

    func testHistoricalRuleDetailRejectsMismatchedReturnedVersion() async {
        let client = ThreatRulesClient(settings: settings) { request in
            self.response(#"{"organizationId":"org-1","canEdit":true,"isHistorical":false,"rule":\#(self.ruleJSON),"triggerCount":8,"audit":[],"nextOffset":null}"#, for: request)
        }
        do {
            _ = try await client.loadRule(id: "custom.example.v9", organizationID: "org-1")
            XCTFail("Expected an unavailable historical snapshot to be rejected")
        } catch ThreatRulesError.organizationUnavailable {
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testRuleMetricsUseOrganizationScopedReadEndpoints() async throws {
        var requests: [URLRequest] = []
        let client = ThreatRulesClient(settings: settings) { request in
            requests.append(request)
            if request.url?.path.hasSuffix("/hits") == true {
                return self.response(#"{"organizationId":"org-1","triggerCount":12}"#, for: request)
            }
            return self.response(#"{"organizationId":"org-1","estimate":{"count":21,"bytes":8192,"checkedDate":"2026-10-22","generatedAt":"2026-10-22T12:00:00.000Z"}}"#, for: request)
        }

        let count = try await client.loadRuleHitCount(id: "custom.example.v1", organizationID: "org-1")
        let estimate = try await client.loadRuleStorageEstimate(id: "custom.example.v1", organizationID: "org-1")

        XCTAssertEqual(count, 12)
        XCTAssertEqual(estimate?.count, 21)
        XCTAssertEqual(estimate?.bytes, 8192)
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/rules/custom.example/hits", "/api/rules/custom.example/storage-estimate"])
        XCTAssertTrue(requests.allSatisfy { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "organizationId" && $0.value == "org-1" }) == true })
    }

    func testImportsJSONRulePackWithVerifiedOwnerScopeAndReceipt() async throws {
        var requests: [URLRequest] = []
        let client = ThreatRulesClient(settings: settings) { request in
            requests.append(request)
            if request.url?.path == "/api/organizations" {
                return self.response(#"{"organizations":[{"id":"org-1","name":"Example","role":"owner","lifecycleStatus":"active"}]}"#, for: request)
            }
            return self.response(#"{"imported":1,"pack":{"name":"Example pack","version":"1","sourceReference":"https://example.com/rules"}}"#, for: request)
        }
        let json = #"{"rules":[{"id":"login-failure","name":"Login failure","description":"Detects an unsuccessful login event.","conditions":[{"path":"event_type","operator":"equals","value":"authentication.failure"}]}]}"#

        let receipt = try await client.importRulePack(organizationID: "org-1", packName: "Example pack", packVersion: "1", sourceReference: "https://example.com/rules", json: json)

        XCTAssertEqual(receipt.imported, 1)
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
        let post = try XCTUnwrap(requests.last)
        XCTAssertEqual(post.url?.path, "/api/rules/packs")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(post.url), resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "organizationId" })?.value, "org-1")
        XCTAssertEqual(post.value(forHTTPHeaderField: "Authorization"), "Bearer token-abc")
        let body = try XCTUnwrap(post.httpBody?.jsonObject as? [String: Any])
        XCTAssertEqual(body["packName"] as? String, "Example pack")
        XCTAssertEqual(body["packVersion"] as? String, "1")
        XCTAssertEqual(body["sourceReference"] as? String, "https://example.com/rules")
        XCTAssertEqual((body["rules"] as? [[String: Any]])?.count, 1)
    }

    func testImportsSigmaPackAndPreservesYaml() async throws {
        var requests: [URLRequest] = []
        let client = ThreatRulesClient(settings: settings) { request in
            requests.append(request)
            if request.url?.path == "/api/organizations" {
                return self.response(#"{"organizations":[{"id":"org-1","name":"Example","role":"admin","lifecycleStatus":"active"}]}"#, for: request)
            }
            return self.response(#"{"imported":2,"pack":{"name":"Sigma pack","version":"2026.1","sourceReference":"https://example.com/sigma"}}"#, for: request)
        }
        let yaml = "title: Suspicious authentication event\ndetection:\n  selection:\n    event_type: authentication\n  condition: selection\n"

        let receipt = try await client.importSigmaPack(organizationID: "org-1", packName: "Sigma pack", packVersion: "2026.1", sourceReference: "https://example.com/sigma", yaml: yaml)

        XCTAssertEqual(receipt.imported, 2)
        let post = try XCTUnwrap(requests.last)
        XCTAssertEqual(post.url?.path, "/api/rules/sigma")
        XCTAssertEqual((post.httpBody?.jsonObject as? [String: Any])?["yaml"] as? String, yaml)
    }

    func testRulePackImportRejectsInvalidInputAndNonAdminBeforePost() async {
        var requests: [URLRequest] = []
        let client = ThreatRulesClient(settings: settings) { request in
            requests.append(request)
            return self.response(#"{"organizations":[{"id":"org-1","name":"Example","role":"editor","lifecycleStatus":"active"}]}"#, for: request)
        }

        do {
            _ = try await client.importRulePack(organizationID: "org-1", packName: "Example", packVersion: "1", sourceReference: "http://example.com/rules", json: "not-json")
            XCTFail("Expected role denial before import")
        } catch ThreatRulesError.permissionDenied {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(requests.map(\.httpMethod), ["GET"])

        var ownerRequests: [URLRequest] = []
        let ownerClient = ThreatRulesClient(settings: settings) { request in
            ownerRequests.append(request)
            if request.url?.path == "/api/organizations" {
                return self.response(#"{"organizations":[{"id":"org-1","name":"Example","role":"owner","lifecycleStatus":"active"}]}"#, for: request)
            }
            XCTFail("Invalid source URL must be rejected locally")
            return self.response("{}", for: request)
        }
        do {
            _ = try await ownerClient.importRulePack(organizationID: "org-1", packName: "Example", packVersion: "1", sourceReference: "http://example.com/rules", json: #"{"rules":[]}"#)
            XCTFail("Expected invalid source URL")
        } catch ThreatRulesError.invalidInput {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(ownerRequests.map(\.httpMethod), ["GET"])
    }

    func testRulePackImportSurfacesOrganizationPermissionErrorFromAPI() async {
        let client = ThreatRulesClient(settings: settings) { request in
            if request.url?.path == "/api/organizations" {
                return self.response(#"{"organizations":[{"id":"org-1","name":"Example","role":"owner","lifecycleStatus":"active"}]}"#, for: request)
            }
            return self.response(#"{"error":"Import is not allowed for this organization."}"#, for: request, status: 403)
        }
        let json = #"{"rules":[{"id":"login-failure","name":"Login failure","description":"Detects an unsuccessful login event.","conditions":[{"path":"event_type","operator":"equals","value":"authentication.failure"}]}]}"#

        do {
            _ = try await client.importRulePack(organizationID: "org-1", packName: "Example pack", packVersion: "1", sourceReference: "https://example.com/rules", json: json)
            XCTFail("Expected API permission denial")
        } catch let ThreatRulesError.requestFailed(status, message) {
            XCTAssertEqual(status, 403)
            XCTAssertEqual(message, "Import is not allowed for this organization.")
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testMalformedImportReceiptRequiresRefreshBeforeRetry() async {
        let client = ThreatRulesClient(settings: settings) { request in
            if request.url?.path == "/api/organizations" {
                return self.response(#"{"organizations":[{"id":"org-1","name":"Example","role":"owner","lifecycleStatus":"active"}]}"#, for: request)
            }
            return self.response(#"{"imported":1,"pack":{"name":"Different pack","version":"1","sourceReference":"https://example.com/rules"}}"#, for: request)
        }
        let json = #"{"rules":[{"id":"login-failure","name":"Login failure","description":"Detects an unsuccessful login event.","conditions":[{"path":"event_type","operator":"equals","value":"authentication.failure"}]}]}"#
        do {
            _ = try await client.importRulePack(organizationID: "org-1", packName: "Example pack", packVersion: "1", sourceReference: "https://example.com/rules", json: json)
            XCTFail("Expected an unconfirmed mutation")
        } catch ThreatRulesError.unconfirmedMutation {
        } catch { XCTFail("Unexpected error: \(error)") }
    }
}

private extension Data {
    var jsonObject: Any? { try? JSONSerialization.jsonObject(with: self, options: [.fragmentsAllowed]) }
}
