import Foundation
import XCTest
@testable import Hanasand

private final class OrganizationWorkspaceRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock()
        storedRequests.append(request)
        lock.unlock()
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }
}

final class OrganizationWorkspaceTests: XCTestCase {
    private var settings: HanasandDesktopSettings {
        var value = HanasandDesktopSettings()
        value.websiteBaseURL = "https://hanasand.test"
        value.userID = "owner"
        value.authToken = "token_abc-123"
        value.selectedOrganizationID = "org/a"
        value.selectedOrganizationUserID = "owner"
        return value
    }

    private func http(_ json: String, request: URLRequest, status: Int = 200) -> (Data, URLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }

    private let settingsJSON = #"{"organization":{"id":"org/a","name":"Example Org","slug":"example-org","lifecycleStatus":"active","role":"owner"},"settings":{"defaultWebhookPolicy":"active_destinations","alertVisibilityPolicy":"members","lifecycleStatus":"active","retentionDays":365,"auditSafeMetadata":{}},"permissions":{"canEdit":true,"editableFields":["name","slug","defaultWebhookPolicy","alertVisibilityPolicy","retentionDays","auditSafeMetadata"]},"lifecycleReadiness":{}}"#

    func testOrganizationDeepLinkReadsWebsiteQueryAliasesAndRequiresVerifiedMembership() {
        XCTAssertEqual(DashboardOrganizationRouteContext.requestedOrganizationID(from: ["org": " org-one "]), "org-one")
        XCTAssertEqual(DashboardOrganizationRouteContext.requestedOrganizationID(from: ["organizationId": "org-two"]), "org-two")
        XCTAssertEqual(DashboardOrganizationRouteContext.requestedOrganizationID(from: ["orgId": "org-three"]), "org-three")
        XCTAssertNil(DashboardOrganizationRouteContext.requestedOrganizationID(from: ["org": " ", "organizationId": ""]))

        XCTAssertTrue(DashboardOrganizationSwitchPolicy.canSwitch(
            organizationID: "org-one", organizationStatus: "active", membershipStatus: "active",
            isAuthenticated: true, isOwnAccount: true, isImpersonating: false
        ))
        XCTAssertFalse(DashboardOrganizationSwitchPolicy.canSwitch(
            organizationID: "org-one", organizationStatus: "active", membershipStatus: nil,
            isAuthenticated: true, isOwnAccount: true, isImpersonating: false
        ))
        XCTAssertFalse(DashboardOrganizationSwitchPolicy.canSwitch(
            organizationID: "org-one", organizationStatus: "active", membershipStatus: "active",
            isAuthenticated: true, isOwnAccount: true, isImpersonating: true
        ))
    }

    func testSettingsReadUsesSecureScopedNoStoreAuthenticatedRequest() async throws {
        var captured: URLRequest?
        let client = try OrganizationWorkspaceClient(settings: settings, organizationID: "org/a") { request in
            captured = request
            return self.http(self.settingsJSON, request: request)
        }
        let page = try await client.loadSettings()
        XCTAssertEqual(page.organization.id, "org/a")
        XCTAssertEqual(page.settings.name, "Example Org")
        XCTAssertEqual(captured?.url?.absoluteString, "https://hanasand.test/api/organizations/org%2Fa/settings")
        XCTAssertEqual(captured?.httpMethod, "GET")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer token_abc-123")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "owner")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertFalse(captured?.httpShouldHandleCookies ?? true)
    }

    func testRecordsLoadUsesOrganizationBoundEventAndCaseRoutes() async throws {
        let recorder = OrganizationWorkspaceRequestRecorder()
        let client = try OrganizationWorkspaceClient(settings: settings, organizationID: "org/a") { request in
            recorder.append(request)
            if request.url?.path.hasSuffix("/api/findings/alerts") == true {
                return self.http(#"{"organization":{"id":"org/a"},"visibilityDecision":{"allowed":true},"alerts":[],"total":0,"nextCursor":null}"#, request: request)
            }
            return self.http(#"{"organizationId":"org/a","items":[],"cases":[],"warnings":[]}"#, request: request)
        }
        let result = await client.loadRecords()
        let requests = recorder.requests
        XCTAssertEqual(result.events, [])
        XCTAssertEqual(result.cases, [])
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer token_abc-123" })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cache-Control") == "no-store" })
        let alerts = requests.first { $0.url?.path.hasSuffix("/api/findings/alerts") == true }!
        let alertQuery = URLComponents(url: alerts.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(alertQuery.first(where: { $0.name == "organizationId" })?.value, "org/a")
        XCTAssertEqual(alertQuery.first(where: { $0.name == "tenantId" })?.value, "org/a")
        let cases = requests.first { $0.url?.path.hasSuffix("/api/cases") == true }!
        XCTAssertEqual(URLComponents(url: cases.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "organizationId" })?.value, "org/a")
    }

    func testRecordFeedsRetainSuccessfulSourceWhenEventsFail() async throws {
        let client = try OrganizationWorkspaceClient(settings: settings, organizationID: "org/a") { request in
            if request.url?.path.hasSuffix("/api/findings/alerts") == true {
                return self.http(#"{"error":{"message":"Events are unavailable."}}"#, request: request, status: 503)
            }
            return self.http(#"{"organizationId":"org/a","items":[{"id":"case-1","title":"Open case","status":"open","organizationId":"org/a"}],"cases":[],"warnings":[]}"#, request: request)
        }

        let result = await client.loadRecords()
        XCTAssertNil(result.events)
        XCTAssertEqual(result.cases?.map(\.id), ["case-1"])
        XCTAssertTrue(result.warnings.contains(where: { $0.localizedCaseInsensitiveContains("events could not be loaded") }))
    }

    func testRecordFeedsRetainSuccessfulSourceWhenCasesFail() async throws {
        var eventSettings = settings
        eventSettings.selectedOrganizationID = "org-one"
        let client = try OrganizationWorkspaceClient(settings: eventSettings, organizationID: "org-one") { request in
            if request.url?.path.hasSuffix("/api/findings/alerts") == true {
                return self.http(#"{"organization":{"id":"org-one"},"visibilityDecision":{"allowed":true},"alerts":[{"id":"event-1","tenantId":"org-one","organizationId":"org-one","company":"Example Company","matchedTerm":{"value":"example.test"},"severity":"high","reviewState":"new","deliveryState":"pending","firstSeenAt":"2026-10-24T12:00:00Z","evidence":[]}],"total":1,"nextCursor":null}"#, request: request)
            }
            return self.http(#"{"error":{"message":"Cases are unavailable."}}"#, request: request, status: 503)
        }

        let result = await client.loadRecords()
        XCTAssertEqual(result.events?.map(\.id), ["event-1"])
        XCTAssertNil(result.cases)
        XCTAssertTrue(result.warnings.contains(where: { $0.localizedCaseInsensitiveContains("cases could not be loaded") }))
    }

    func testEventsScopeLoadsTermsVisibilityCorrelationsAndDeliverySummaryForSelectedOrganization() async throws {
        let recorder = OrganizationWorkspaceRequestRecorder()
        var eventSettings = settings
        eventSettings.selectedOrganizationID = "org-one"
        let client = try OrganizationWorkspaceClient(settings: eventSettings, organizationID: "org-one") { request in
            recorder.append(request)
            let path = request.url?.path ?? ""
            let body: String
            if path.hasSuffix("/api/findings/alerts") {
                body = #"{"organization":{"id":"org-one"},"visibilityDecision":{"allowed":true},"alerts":[{"id":"event-1","tenantId":"org-one","organizationId":"org-one","company":"Example Co","matchedTerm":{"value":"example.test"},"severity":"high","reviewState":"new","deliveryState":"failed","firstSeenAt":"2026-10-24T12:00:00Z","evidence":[]}],"total":1,"nextCursor":null}"#
            } else if path.hasSuffix("/api/cases") {
                body = #"{"organizationId":"org-one","cases":[{"id":"case-1","organizationId":"org-one","title":"Example case","status":"open","assignedOwner":"member-1","createdAt":"2026-10-24T11:00:00Z"}],"warnings":[]}"#
            } else if path.hasSuffix("/watchlists/alert-terms") {
                body = #"{"organization":{"id":"org-one"},"alertTermsExport":{"organizationId":"org-one","tenantId":"org-one","activeTerms":[{"organizationId":"org-one","watchlistItemId":"watch-1","kind":"domain","term":"example.test","matchReason":"domain match"}]}}"#
            } else if path.hasSuffix("/alert-case-visibility") {
                body = #"{"organization":{"id":"org-one"},"alertCaseVisibility":{"organizationId":"org-one","visibility":{"alertReadAllowed":true,"caseAssignmentAllowed":false},"caseWorkflow":{"casePathTemplate":"/cases/:id"}}}"#
            } else if path.hasSuffix("/webhooks") {
                body = #"{"organization":{"id":"org-one"},"destinations":[{"id":"dest-1","organizationId":"org-one","name":"Alerts","status":"active","endpointHash":"hash-1"}]}"#
            } else if path.hasSuffix("/deliveries") {
                body = #"{"deliveries":[{"id":"delivery-1","organizationId":"org-one","alertId":"event-1","caseId":"case-1","destinationId":"dest-1","status":"failed","attemptedAt":"2026-10-24T13:00:00Z","sanitizedPayloadPreview":{"context":{"matchReason":"matched domain evidence"}}}]}"#
            } else if path.hasSuffix("/watchlists") {
                body = #"{"organization":{"id":"org-one"},"watchlistItems":[{"id":"watch-1","organizationId":"org-one","value":"example.test","status":"active","webhookDestinationId":"dest-1"},{"id":"watch-2","organizationId":"org-one","value":"other.example","status":"paused","webhookEndpointHint":"hooks.example.test/opaque"}]}"#
            } else {
                body = #"{"members":[{"userId":"member-1","organizationId":"org-one","name":"Analyst One","status":"active"}]}"#
            }
            return self.http(body, request: request)
        }

        let result = await client.loadEventScope()

        XCTAssertEqual(result.eventRecords?.map(\.id), ["event-1"])
        XCTAssertEqual(result.caseRecords?.map(\.id), ["case-1"])
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(result.scope.termCount, 1)
        XCTAssertEqual(result.scope.eventCount, 1)
        XCTAssertEqual(result.scope.caseCount, 1)
        XCTAssertEqual(result.scope.destinationCount, 2)
        XCTAssertEqual(result.scope.failureCount, 1)
        XCTAssertTrue(result.scope.events?.first?.detail.contains("Term: example.test") == true)
        XCTAssertTrue(result.scope.events?.first?.detail.contains("Match: matched domain evidence") == true)
        XCTAssertTrue(result.scope.cases?.first?.detail.contains("Owner: Analyst One") == true)
        XCTAssertTrue(result.scope.cases?.first?.detail.contains("Match: matched domain evidence") == true)
        XCTAssertEqual(result.scope.visibility?.first(where: { $0.title == "Event visibility" })?.detail, "true")
        XCTAssertEqual(result.scope.failures?.first?.title, "Alerts delivery")
        let watchlistDestination = result.scope.destinations?.first(where: { $0.title == "other.example" })
        XCTAssertTrue(watchlistDestination?.detail.contains("Watchlist route") == true)
        XCTAssertEqual(watchlistDestination?.contextPath, "/organizations/watchlists")
        XCTAssertFalse(watchlistDestination?.detail.contains("hooks.example.test") ?? true)
        XCTAssertEqual(recorder.requests.count, 8)
        XCTAssertTrue(recorder.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer token_abc-123" })
        XCTAssertTrue(recorder.requests.allSatisfy { $0.value(forHTTPHeaderField: "Cache-Control") == "no-store" })
        let deliveries = recorder.requests.first { $0.url?.path.hasSuffix("/deliveries") == true }!
        XCTAssertEqual(URLComponents(url: deliveries.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "organizationId" })?.value, "org-one")
    }

    func testEventsScopeRejectsCrossOrganizationDataAndWarnsForUnavailableSources() async throws {
        let client = try OrganizationWorkspaceClient(settings: settings, organizationID: "org/a") { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/api/findings/alerts") {
                return self.http(#"{"organization":{"id":"org/a"},"visibilityDecision":{"allowed":true},"alerts":[],"total":0,"nextCursor":null}"#, request: request)
            }
            if path.hasSuffix("/api/cases") {
                return self.http(#"{"organizationId":"org/a","cases":[],"warnings":[]}"#, request: request)
            }
            if path.hasSuffix("/watchlists/alert-terms") {
                return self.http(#"{"organization":{"id":"org/other"},"alertTermsExport":{"organizationId":"org/other","activeTerms":[]}}"#, request: request)
            }
            if path.hasSuffix("/deliveries") {
                return self.http(#"{"deliveries":[{"id":"foreign-delivery","organizationId":"org/other","alertId":"foreign-event","status":"failed"}]}"#, request: request)
            }
            return self.http(#"{"error":{"message":"Source unavailable."}}"#, request: request, status: 503)
        }

        let result = await client.loadEventScope()

        XCTAssertEqual(result.eventRecords?.count, 0)
        XCTAssertEqual(result.caseRecords?.count, 0)
        XCTAssertNil(result.scope.terms)
        XCTAssertNil(result.scope.failures)
        XCTAssertTrue(result.warnings.contains(where: { $0.localizedCaseInsensitiveContains("watchlist terms") }))
        XCTAssertTrue(result.warnings.contains(where: { $0.localizedCaseInsensitiveContains("outside the selected organization") }))
        XCTAssertTrue(result.warnings.contains(where: { $0.localizedCaseInsensitiveContains("destinations could not be loaded") }))
        XCTAssertNil(result.scope.destinationCount)
    }

    func testActivityLoadIncludesOrganizationSourcesAndProducesNativeContextRows() async throws {
        let recorder = OrganizationWorkspaceRequestRecorder()
        let client = try OrganizationWorkspaceClient(settings: settings, organizationID: "org/a") { request in
            recorder.append(request)
            let path = request.url?.path ?? ""
            let body: String
            if path.hasSuffix("/members") {
                body = #"{"members":[{"userId":"member-1","organizationId":"org/a","name":"Person","email":"person@example.com","role":"reader","status":"active","joinedAt":"2026-10-22T12:00:00Z"}]}"#
            } else if path.hasSuffix("/invites") {
                body = #"{"invites":[{"id":"invite-1","organizationId":"org/a","email":"new@example.com","role":"reader","status":"pending","createdAt":"2026-10-23T12:00:00Z"}]}"#
            } else if path.hasSuffix("/watchlists") {
                body = #"{"watchlistItems":[{"id":"watch-1","organizationId":"org/a","value":"example.org","kind":"domain","status":"active","updatedAt":"2026-10-23T12:00:00Z"}]}"#
            } else if path.hasSuffix("/webhooks") {
                body = #"{"destinations":[{"id":"dest-1","orgId":"org/a","name":"Alerts","kind":"webhook","status":"active","endpointHint":"example.test/hook"}]}"#
            } else {
                body = #"{"deliveries":[{"id":"delivery-1","organizationId":"org/a","status":"delivered","alertId":"event-1","attemptedAt":"2026-10-24T12:00:00Z"}]}"#
            }
            return self.http(body, request: request)
        }
        let page = try await client.loadActivity()
        XCTAssertEqual(page.entries.count, 5)
        XCTAssertTrue(page.warnings.isEmpty)
        for kind in [OrganizationWorkspaceActivityKind.delivery, .member, .invite, .watchlist, .destination] {
            XCTAssertTrue(page.entries.contains(where: { $0.kind == kind }))
        }
        XCTAssertTrue(page.entries.first(where: { $0.kind == .member })?.detail.contains("active") == true)
        XCTAssertEqual(page.entries.first(where: { $0.kind == .watchlist })?.contextPath, "/watchlists")
        XCTAssertEqual(page.entries.first(where: { $0.kind == .destination })?.contextPath, "/integrations")
        XCTAssertEqual(recorder.requests.count, 5)
        XCTAssertTrue(recorder.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer token_abc-123" })
    }

    func testPartialActivityRefreshRetainsOnlyUnavailableSourceEntries() {
        let oldMember = summaryEntry("member-previous", kind: .member, status: "active")
        let oldWatchlist = summaryEntry("watchlist-previous", kind: .watchlist, status: "active")
        let previous = OrganizationWorkspaceActivityPage(entries: [oldMember, oldWatchlist], warnings: [])
        let refreshed = OrganizationWorkspaceActivityPage(entries: [
            summaryEntry("member-current", kind: .member, status: "active"),
            summaryEntry("watchlist-current", kind: .watchlist, status: "paused"),
        ], warnings: ["Could not load organization members activity."])

        let merged = refreshed.retainingUnavailableSources(from: previous)
        XCTAssertEqual(Set(merged.entries.map(\.id)), ["member-current", "member-previous", "watchlist-current"])
        XCTAssertEqual(merged.warnings, refreshed.warnings)
    }

    func testSettingsWriteRechecksServerPermissionAndValidatesReceipt() async throws {
        var requests: [URLRequest] = []
        let client = try OrganizationWorkspaceClient(settings: settings, organizationID: "org/a") { request in
            requests.append(request)
            if request.httpMethod == "GET" { return self.http(self.settingsJSON, request: request) }
            return self.http(#"{"organization":{"id":"org/a","name":"New Name","slug":"new-name","lifecycleStatus":"active","role":"owner"},"settings":{"defaultWebhookPolicy":"active_destinations","alertVisibilityPolicy":"members","lifecycleStatus":"active","retentionDays":90},"settingsMutationReceipt":{"schemaVersion":"organization.lifecycle_settings_mutation_receipt.v1","organizationId":"org/a","lifecycleStatus":"active","mutatedFields":["name","slug","retentionDays"]}}"#, request: request)
        }
        let draft = OrganizationWorkspaceSettings(name: "New Name", slug: "new-name", defaultWebhookPolicy: "active_destinations", alertVisibilityPolicy: "members", lifecycleStatus: "active", retentionDays: 90)
        let receipt = try await client.updateSettings(draft)
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "PUT"])
        XCTAssertEqual(receipt.organization?.id, "org/a")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer token_abc-123")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: requests[1].httpBody!) as? [String: Any])
        XCTAssertEqual(body["name"] as? String, "New Name")
        XCTAssertEqual(body["slug"] as? String, "new-name")
        XCTAssertEqual(body["defaultWebhookPolicy"] as? String, "active_destinations")
        XCTAssertEqual(body["alertVisibilityPolicy"] as? String, "members")
        XCTAssertEqual(body["lifecycleStatus"] as? String, "active")
        XCTAssertEqual(body["retentionDays"] as? Int, 90)
    }

    func testSettingsWriteStopsWhenFreshServerPermissionsDenyEdit() async throws {
        let denied = settingsJSON.replacingOccurrences(of: #""canEdit":true"#, with: #""canEdit":false"#)
        let client = try OrganizationWorkspaceClient(settings: settings, organizationID: "org/a") { request in
            self.http(denied, request: request)
        }
        let draft = OrganizationWorkspaceSettings(name: "New Name", slug: "new-name", defaultWebhookPolicy: "active_destinations", alertVisibilityPolicy: "members", lifecycleStatus: "active", retentionDays: 90)
        do {
            _ = try await client.updateSettings(draft)
            XCTFail("Expected permission denial")
        } catch OrganizationWorkspaceError.permissionChanged {}
    }

    func testClientRejectsCrossOrganizationAndImpersonatedWrites() async throws {
        XCTAssertThrowsError(try OrganizationWorkspaceClient(settings: settings, organizationID: "other"))
        var impersonating = settings
        impersonating.impersonationToken = "impersonation-token"
        let client = try OrganizationWorkspaceClient(settings: impersonating, organizationID: "org/a") { request in
            self.http(self.settingsJSON, request: request)
        }
        XCTAssertFalse(OrganizationWorkspacePolicy.canEdit(
            settings: try JSONDecoder().decode(OrganizationWorkspaceSettingsPage.self, from: Data(settingsJSON.utf8)),
            selectedOrganizationID: "org/a", signedInUserID: "owner", isAuthenticated: true, isImpersonating: true
        ))
        do {
            _ = try await client.updateSettings(.init(name: "New Name", slug: "new-name", defaultWebhookPolicy: "disabled", alertVisibilityPolicy: "owners", lifecycleStatus: "active", retentionDays: 90))
            XCTFail("Expected impersonation write denial")
        } catch OrganizationWorkspaceError.impersonationUnsupported {}
    }

    func testSettingsPolicyRejectsMalformedValues() {
        XCTAssertTrue(OrganizationWorkspacePolicy.valid(.init(name: "Example Org", slug: "example-org", defaultWebhookPolicy: "active_destinations", alertVisibilityPolicy: "members", lifecycleStatus: "active", retentionDays: 365)))
        XCTAssertFalse(OrganizationWorkspacePolicy.valid(.init(name: "x", slug: "../other", defaultWebhookPolicy: "*", alertVisibilityPolicy: "public", lifecycleStatus: "deleted", retentionDays: 0)))
    }

    func testOverviewSummarizesEventsCasesAndLatestActivity() {
        let events = [
            OrganizationWorkspaceRecord(id: "event-1", title: "Older event", status: "new", severity: "low",
                updatedAt: "2026-10-20T10:00:00Z", createdAt: "", organizationId: "org/a"),
            OrganizationWorkspaceRecord(id: "event-2", title: "Latest event", status: "new", severity: "high",
                updatedAt: "2026-10-23T10:00:00Z", createdAt: "", organizationId: "org/a"),
        ]
        let cases = [
            OrganizationWorkspaceRecord(id: "case-open", title: "Open", status: "investigating", severity: "high",
                updatedAt: "2026-10-22T10:00:00Z", createdAt: "", organizationId: "org/a"),
            OrganizationWorkspaceRecord(id: "case-closed", title: "Closed", status: "resolved", severity: "low",
                updatedAt: "2026-10-21T10:00:00Z", createdAt: "", organizationId: "org/a"),
        ]

        let overview = OrganizationWorkspaceOverview(events: events, cases: cases, activity: .summaryUnavailable,
            organizationID: "org/a", role: "owner", canViewInvites: true)

        XCTAssertEqual(overview.eventCount, 2)
        XCTAssertEqual(overview.caseCount, 2)
        XCTAssertEqual(overview.openCaseCount, 1)
        XCTAssertEqual(overview.latestActivity, "2026-10-23T10:00:00Z")
        XCTAssertNil(OrganizationWorkspaceOverview(events: [], cases: [], activity: .summaryUnavailable,
            organizationID: "org/a", role: nil, canViewInvites: false).latestActivity)
    }

    func testOverviewCountsOrganizationSummaryAndExposesNativeDestinations() {
        let activity = OrganizationWorkspaceActivityPage(entries: [
            summaryEntry("member-1", kind: .member, status: "active"),
            summaryEntry("member-2", kind: .member, status: "ACTIVE"),
            summaryEntry("member-3", kind: .member, status: "suspended"),
            summaryEntry("invite-1", kind: .invite, status: "pending"),
            summaryEntry("invite-2", kind: .invite, status: "accepted"),
            summaryEntry("watch-active", kind: .watchlist, status: "active"),
            summaryEntry("watch-paused", kind: .watchlist, status: "paused"),
        ], warnings: [])

        let overview = OrganizationWorkspaceOverview(events: [], cases: [], activity: activity,
            organizationID: "org/a", role: "admin", canViewInvites: true)

        XCTAssertEqual(overview.role, "admin")
        XCTAssertEqual(overview.activeMemberCount, 2)
        XCTAssertEqual(overview.pendingInviteCount, 1)
        XCTAssertEqual(overview.activeWatchlistCount, 1)
        XCTAssertEqual(overview.pausedWatchlistCount, 1)
        XCTAssertEqual(OrganizationWorkspaceSummaryDestination.allCases.map(\.path), ["/organizations/team", "/watchlists"])
    }

    func testOverviewKeepsZeroDistinctFromUnavailableAndHidesInviteCountWithoutPermission() {
        let empty = OrganizationWorkspaceActivityPage(entries: [], warnings: [])
        let overview = OrganizationWorkspaceOverview(events: [], cases: [], activity: empty,
            organizationID: "org/a", role: "reader", canViewInvites: false)

        XCTAssertEqual(overview.activeMemberCount, 0)
        XCTAssertNil(overview.pendingInviteCount)
        XCTAssertEqual(overview.activeWatchlistCount, 0)
        XCTAssertEqual(overview.pausedWatchlistCount, 0)

        let unavailable = OrganizationWorkspaceOverview(events: [], cases: [], activity: .summaryUnavailable,
            organizationID: "org/a", role: nil, canViewInvites: true)
        XCTAssertNil(unavailable.role)
        XCTAssertNil(unavailable.activeMemberCount)
        XCTAssertNil(unavailable.pendingInviteCount)
        XCTAssertNil(unavailable.activeWatchlistCount)
        XCTAssertNil(unavailable.pausedWatchlistCount)
    }

    func testOverviewDoesNotCountMismatchedOrganizationActivity() {
        let activity = OrganizationWorkspaceActivityPage(entries: [
            summaryEntry("foreign-member", kind: .member, status: "active", organizationID: "org/other"),
            summaryEntry("watch-active", kind: .watchlist, status: "active"),
        ], warnings: [])

        let overview = OrganizationWorkspaceOverview(events: [], cases: [], activity: activity,
            organizationID: "org/a", role: "owner", canViewInvites: true)

        XCTAssertNil(overview.activeMemberCount)
        XCTAssertEqual(overview.pendingInviteCount, 0)
        XCTAssertEqual(overview.activeWatchlistCount, 1)
        XCTAssertEqual(overview.pausedWatchlistCount, 0)
    }

    private func summaryEntry(_ id: String, kind: OrganizationWorkspaceActivityKind, status: String,
                              organizationID: String = "org/a") -> OrganizationWorkspaceActivityEntry {
        OrganizationWorkspaceActivityEntry(id: id, kind: kind, occurredAt: "", title: id, detail: status,
            status: status, subjectID: id, contextPath: "", contextQuery: ["organizationId": organizationID], metadata: [])
    }
}
