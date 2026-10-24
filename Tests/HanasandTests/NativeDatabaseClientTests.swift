import Foundation
import XCTest
@testable import Hanasand

final class NativeDatabaseClientTests: XCTestCase {
    func testBackupOperationLookupFollowsCurrentAndHistoricalOperationIDs() throws {
        let activeOperation = #"{"id":"op2","kind":"restore_drill","status":"running","stage":"restoring","startedAt":"2026-10-24T10:00:00Z"}"#
        let json = Self.backupDashboardJSON.replacingOccurrences(
            of: #""currentOperation":null"#,
            with: "\"currentOperation\":\(activeOperation)"
        )
        let dashboard = try JSONDecoder().decode(NativeBackupDashboard.self, from: Data(json.utf8))

        XCTAssertEqual(backupOperation(withID: "op2", in: dashboard)?.stage, "restoring")
        XCTAssertEqual(backupOperation(withID: "op1", in: dashboard)?.stage, "completed")
        XCTAssertNil(backupOperation(withID: "missing", in: dashboard))
        XCTAssertTrue(shouldRefreshBackupOperation(currentOperation: backupOperation(withID: "op2", in: dashboard), trackedOperation: nil))
        XCTAssertTrue(shouldRefreshBackupOperation(currentOperation: nil, trackedOperation: backupOperation(withID: "op2", in: dashboard)))
        XCTAssertFalse(shouldRefreshBackupOperation(currentOperation: nil, trackedOperation: backupOperation(withID: "op1", in: dashboard)))
    }

    func testAccessCheckUsesIdentityOriginAndAuthenticatedRequest() async throws {
        var settings = HanasandDesktopSettings()
        settings.userID = "user_1"
        settings.authToken = "token"
        var captured: URLRequest?
        let client = try NativeDatabaseClient(settings: settings) { request in
            captured = request
            return try Self.response(request, json: #"{"allowed":true,"canEdit":true}"#)
        }

        let access = try await client.loadAccess()

        XCTAssertTrue(access.allowed)
        XCTAssertTrue(access.canEdit)
        XCTAssertEqual(captured?.url?.absoluteString, "https://identity.hanasand.com/api/management/organizations?internalPages=1")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "user_1")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "User-Agent"), "hanasand_internal")
        XCTAssertEqual(captured?.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testBackupDashboardIsAuthenticatedAndRestoreUsesIsolatedTypedConfirmation() async throws {
        var settings = HanasandDesktopSettings()
        settings.userID = "user_1"
        settings.authToken = "token"
        var captured: URLRequest?
        let client = try NativeDatabaseClient(settings: settings) { request in
            captured = request
            if request.httpMethod == "GET" {
                return try Self.response(request, json: Self.backupDashboardJSON)
            }
            return try Self.response(request, json: Self.backupActionJSON)
        }
        let access = NativeDatabaseAccess(allowed: true, canEdit: true, scope: client.scope)
        let dashboard = try await client.loadBackupDashboard()
        XCTAssertEqual(captured?.url?.path, "/api/backup/dashboard")
        XCTAssertEqual(dashboard.backups.first?.operations.count, 1)
        XCTAssertEqual(dashboard.files.first?.verified, true)

        let file = try XCTUnwrap(dashboard.files.first)
        let result = try await client.runRestoreDrill(file, targetDatabase: "restore_drill_20261024", confirmation: "RESTORE restore_drill_20261024", access: access, dashboard: dashboard)
        XCTAssertEqual(result.operation.kind, "restore_drill")
        XCTAssertEqual(captured?.url?.path, "/api/backup/restore")
        let body = try XCTUnwrap(captured?.httpBody).flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] }
        XCTAssertEqual(body?["file"], "core-20261024.sql.gz")
        XCTAssertEqual(body?["targetDatabase"], "restore_drill_20261024")
        XCTAssertEqual(body?["confirmation"], "RESTORE restore_drill_20261024")
    }

    func testRestoreDrillRejectsLiveTargetMissingConfirmationAndStaleScopeBeforeSending() async throws {
        var settings = HanasandDesktopSettings()
        settings.userID = "user_1"
        settings.authToken = "token"
        var sent = false
        let client = try NativeDatabaseClient(settings: settings) { request in
            sent = true
            return try Self.response(request, json: Self.backupActionJSON)
        }
        let dashboard = try JSONDecoder().decode(NativeBackupDashboard.self, from: Data(Self.backupDashboardJSON.utf8))
        let file = try XCTUnwrap(dashboard.files.first)
        let access = NativeDatabaseAccess(allowed: true, canEdit: true, scope: client.scope)
        for (target, confirmation) in [("Core", "RESTORE Core"), ("restore_drill_20261024", ""), ("restore_drill_bad;drop", "RESTORE restore_drill_bad;drop")] {
            do {
                _ = try await client.runRestoreDrill(file, targetDatabase: target, confirmation: confirmation, access: access, dashboard: dashboard)
                XCTFail("Unsafe restore drill input must be rejected")
            } catch let error as NativeDatabaseClientError {
                guard case .invalidConfirmation = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
        do {
            _ = try await client.runRestoreDrill(file, targetDatabase: "restore_drill_20261024", confirmation: "RESTORE restore_drill_20261024", access: NativeDatabaseAccess(allowed: true, canEdit: true, scope: "stale"), dashboard: dashboard)
            XCTFail("Stale session access proof must be rejected")
        } catch let error as NativeDatabaseClientError {
            guard case .readOnly = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(sent)
    }

    func testLiveRestoreRequiresExactDatabaseConfirmationAndUsesTheLiveRestoreEndpoint() async throws {
        var settings = HanasandDesktopSettings()
        settings.userID = "user_1"
        settings.authToken = "token"
        var captured: URLRequest?
        let client = try NativeDatabaseClient(settings: settings) { request in
            captured = request
            return try Self.response(request, json: Self.liveRestoreActionJSON)
        }
        let dashboard = try JSONDecoder().decode(NativeBackupDashboard.self, from: Data(Self.backupDashboardJSON.utf8))
        let file = try XCTUnwrap(dashboard.files.first)
        let access = NativeDatabaseAccess(allowed: true, canEdit: true, scope: client.scope)
        do {
            _ = try await client.runLiveRestore(file, confirmation: "RESTORE Other", access: access, dashboard: dashboard)
            XCTFail("A confirmation for another database must be rejected")
        } catch let error as NativeDatabaseClientError {
            guard case .invalidConfirmation = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let result = try await client.runLiveRestore(file, confirmation: "RESTORE Core", access: access, dashboard: dashboard)
        XCTAssertEqual(result.operation.kind, "restore_live")
        XCTAssertEqual(captured?.url?.path, "/api/backup/restore-live")
        let body = try XCTUnwrap(captured?.httpBody).flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] }
        XCTAssertEqual(body?["file"], file.file)
        XCTAssertEqual(body?["confirmation"], "RESTORE Core")
    }

    func testBackupMutationTreatsMalformedSuccessAsUncertainAndRejectsRunningOperation() async throws {
        var settings = HanasandDesktopSettings()
        settings.userID = "user_1"
        settings.authToken = "token"
        let client = try NativeDatabaseClient(settings: settings) { request in
            try Self.response(request, json: "not-json")
        }
        let dashboard = try JSONDecoder().decode(NativeBackupDashboard.self, from: Data(Self.backupDashboardJSON.utf8))
        do {
            _ = try await client.runBackup(access: NativeDatabaseAccess(allowed: true, canEdit: true, scope: client.scope), dashboard: dashboard)
            XCTFail("Malformed operation response must block retry as uncertain")
        } catch let error as NativeDatabaseClientError {
            guard case .uncertainOutcome = error else { return XCTFail("Unexpected error: \(error)") }
        }

        let runningOperation = #""currentOperation":{"id":"op2","kind":"backup","status":"running","stage":"uploading","startedAt":"2026-10-24T10:00:00Z"}"#
        let runningJSON = Self.backupDashboardJSON.replacingOccurrences(of: #""currentOperation":null"#, with: runningOperation)
        let runningDashboard = try JSONDecoder().decode(NativeBackupDashboard.self, from: Data(runningJSON.utf8))
        do {
            _ = try await client.runBackup(access: NativeDatabaseAccess(allowed: true, canEdit: true, scope: client.scope), dashboard: runningDashboard)
            XCTFail("Existing server operation must block a second operation")
        } catch let error as NativeDatabaseClientError {
            guard case .invalidSelection = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testBrowseRequiresFreshInventoryAndUsesEncodedCursor() async throws {
        var settings = HanasandDesktopSettings()
        settings.userID = "user_1"
        settings.authToken = "token"
        var captured: URLRequest?
        let client = try NativeDatabaseClient(settings: settings) { request in
            captured = request
            return try Self.response(request, json: #"{"rows":[{"value":"ok"}],"fields":["value"],"nextCursor":null,"elapsedMs":1}"#)
        }
        let inventory = try Self.overview()

        let page = try await client.browse(inventory, instanceID: "main", databaseName: "Core", mode: "rows",
                                           schema: "public", table: "records", cursor: "opaque+/?")

        XCTAssertEqual(page.rows?.count, 1)
        let components = try XCTUnwrap(captured?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        XCTAssertEqual(components.path, "/api/db/browse")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "cursor" })?.value, "opaque+/?")
        var staleInventory = inventory
        staleInventory = try Self.overview(stale: true)
        do {
            _ = try await client.browse(staleInventory, instanceID: "main", databaseName: "Core", mode: "contents")
            XCTFail("Stale inventory must not be browsable")
        } catch let error as NativeDatabaseClientError {
            guard case .invalidSelection = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testSQLRequiresCurrentOwnerEditorAndOwnAccountAndPreservesAmbiguousOutcome() async throws {
        var settings = HanasandDesktopSettings()
        settings.userID = "user_1"
        settings.authToken = "token"
        var captured: URLRequest?
        let client = try NativeDatabaseClient(settings: settings) { request in
            captured = request
            return try Self.response(request, json: #"{"rows":[],"rowCount":0,"fields":[]}"#)
        }
        let writer = NativeDatabaseAccess(allowed: true, canEdit: true, scope: client.scope)
        _ = try await client.runReviewedSQL("SELECT 1", access: writer)
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.url?.path, "/api/db/query")
        XCTAssertEqual(try XCTUnwrap(captured?.httpBody).flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] }?["sql"], "SELECT 1")

        let reader = NativeDatabaseAccess(allowed: true, canEdit: false, scope: client.scope)
        do {
            _ = try await client.runReviewedSQL("DELETE FROM records", access: reader)
            XCTFail("Read-only account must not submit SQL")
        } catch let error as NativeDatabaseClientError {
            guard case .readOnly = error else { return XCTFail("Unexpected error: \(error)") }
        }

        var impersonated = settings
        impersonated.impersonatingUserID = "other_user"
        let impersonatedClient = try NativeDatabaseClient(settings: impersonated) { request in
            try Self.response(request, json: #"{"rows":[],"rowCount":0,"fields":[]}"#)
        }
        do {
            _ = try await impersonatedClient.runReviewedSQL("SELECT 1", access: NativeDatabaseAccess(allowed: true, canEdit: true, scope: impersonatedClient.scope))
            XCTFail("Impersonated sessions must not submit SQL")
        } catch let error as NativeDatabaseClientError {
            guard case .readOnly = error else { return XCTFail("Unexpected error: \(error)") }
        }

        let failingClient = try NativeDatabaseClient(settings: settings) { request in
            (Data("not-json".utf8), try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        do {
            _ = try await failingClient.runReviewedSQL("UPDATE records SET value = 1", access: NativeDatabaseAccess(allowed: true, canEdit: true, scope: failingClient.scope))
            XCTFail("Unparseable SQL response must be treated as uncertain")
        } catch let error as NativeDatabaseClientError {
            guard case .uncertainOutcome = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testCoreRowsRejectsUnsafeIdentifiersAndCrossSessionProof() async throws {
        var settings = HanasandDesktopSettings()
        settings.userID = "user_1"
        settings.authToken = "token"
        var sent = false
        let client = try NativeDatabaseClient(settings: settings) { request in
            sent = true
            return try Self.response(request, json: #"{"rows":[],"rowCount":0,"fields":[]}"#)
        }
        let access = NativeDatabaseAccess(allowed: true, canEdit: false, scope: client.scope)
        let unsafe = NativeDatabaseOverview.Table(schema: "public", name: "records; DROP TABLE x", sizeBytes: nil,
                                                  estimatedRows: nil, columns: [], lastWriteObservedAt: nil)
        do {
            _ = try await client.loadCoreRows(access: access, table: unsafe)
            XCTFail("Unsafe table name must be rejected")
        } catch let error as NativeDatabaseClientError {
            guard case .invalidSelection = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(sent)
        do {
            _ = try await client.loadCoreRows(access: NativeDatabaseAccess(allowed: true, canEdit: false, scope: "other session"), table: Self.table())
            XCTFail("Access proof must be bound to the current session")
        } catch let error as NativeDatabaseClientError {
            guard case .accessDenied = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testRedisBrowserAcceptsOnlyKeysFromTheLoadedContentsPage() async throws {
        var settings = HanasandDesktopSettings()
        settings.userID = "user_1"
        settings.authToken = "token"
        let client = try NativeDatabaseClient(settings: settings) { request in
            try Self.response(request, json: #"{"rows":[{"value":"ok"}],"fields":["value"],"nextCursor":null,"elapsedMs":1}"#)
        }
        let inventory = try Self.overview(engine: "Redis")
        do {
            _ = try await client.browse(inventory, instanceID: "main", databaseName: "Core", mode: "rows", table: "private:key")
            XCTFail("Unlisted Redis keys must not be previewed")
        } catch let error as NativeDatabaseClientError {
            guard case .invalidSelection = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let page = try await client.browse(inventory, instanceID: "main", databaseName: "Core", mode: "rows", table: "session:one", knownTableNames: ["session:one"])
        XCTAssertEqual(page.rows?.count, 1)
    }

    private static func response(_ request: URLRequest, status: Int = 200, json: String) throws -> (Data, URLResponse) {
        let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil))
        return (Data(json.utf8), response)
    }

    private static let backupDashboardJSON = #"{"backups":[{"id":"core","name":"Core database","database":"Core","status":"healthy","scheduleEnabled":true,"storageTarget":"s3://backups/core","currentOperation":null,"operations":[{"id":"op1","kind":"backup","trigger":"manual","status":"succeeded","stage":"completed","startedAt":"2026-10-24T09:00:00Z","finishedAt":"2026-10-24T09:01:00Z","durationMs":60000,"file":"core-20261024.sql.gz","checksumSha256":"abcd","sizeBytes":1024,"targetRemoved":null,"error":null}]}],"files":[{"service":"core","file":"core-20261024.sql.gz","mtime":"2026-10-24T09:00:00Z","size":"1 KB","sizeBytes":1024,"verified":true,"checksumSha256":"abcd","verifiedAt":"2026-10-24T09:02:00Z","releaseCommit":"deadbeef"}],"errors":[]}"#
    private static let backupActionJSON = #"{"message":"Restore drill passed.","operation":{"id":"op2","kind":"restore_drill","status":"succeeded","stage":"completed","startedAt":"2026-10-24T10:00:00Z","finishedAt":"2026-10-24T10:01:00Z","file":"core-20261024.sql.gz","targetDatabase":"restore_drill_20261024","targetRemoved":true,"sourceIntegrity":{"schemas":1,"tables":4,"estimatedRows":10},"restoredIntegrity":{"schemas":1,"tables":4,"estimatedRows":10},"error":null}}"#
    private static let liveRestoreActionJSON = #"{"message":"Database Core restored.","operation":{"id":"op3","kind":"restore_live","status":"succeeded","stage":"completed","startedAt":"2026-10-24T11:00:00Z","file":"core-20261024.sql.gz","targetDatabase":"Core","targetRemoved":true,"restoredIntegrity":{"schemas":1,"tables":4,"estimatedRows":10},"error":null}}"#

    private static func table() -> NativeDatabaseOverview.Table {
        NativeDatabaseOverview.Table(schema: "public", name: "records", sizeBytes: 10, estimatedRows: 1, columns: ["id"], lastWriteObservedAt: nil)
    }

    private static func overview(engine: String = "PostgreSQL", stale: Bool = false) throws -> NativeDatabaseOverview {
        let json = """
        {"status":"healthy","generatedAt":"2026-10-24T10:00:00Z","queries":[],"health":{"message":"OK"},"storage":{"sampledAt":"2026-10-24T10:00:00Z","stale":\(stale),"host":"db-host","disk":{"totalBytes":1000,"availableBytes":500,"dailyGrowthBytes":null,"daysUntilFull":null},"instances":[{"id":"main","engine":"\(engine)","status":"healthy","databases":[{"name":"Core","sizeBytes":100,"connections":1,"tables":[{"schema":"public","name":"records","sizeBytes":10,"estimatedRows":1,"columns":["id"],"lastWriteObservedAt":null}]}]}]}}
        """
        return try JSONDecoder().decode(NativeDatabaseOverview.self, from: Data(json.utf8))
    }
}
