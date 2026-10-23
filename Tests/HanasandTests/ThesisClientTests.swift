import Foundation
import XCTest
@testable import Hanasand

final class ThesisClientTests: XCTestCase {
    private let base = URL(string: "https://api.hanasand.test/api")!
    private let access = ThesisAccess(member: true, canEdit: true)
    private let document = ThesisDocument(title: "Research", body: "# Findings", revision: 4)

    private func settings(impersonating: Bool = false) -> HanasandDesktopSettings {
        var value = HanasandDesktopSettings()
        value.apiBaseURL = base.absoluteString
        value.userID = "owner"
        value.authToken = "token"
        if impersonating { value.impersonationToken = "impersonation" }
        return value
    }

    private func response(_ body: String, request: URLRequest, status: Int = 200) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }

    func testAccessAndLoadUseAuthenticatedNoStoreAPIRequests() async throws {
        var paths: [String] = []
        let client = try ThesisClient(settings: settings()) { request in
            paths.append(request.url!.path)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "id"), "owner")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            XCTAssertFalse(request.httpShouldHandleCookies)
            return request.url!.path.hasSuffix("/access")
                ? self.response(#"{"member":true,"canEdit":true}"#, request: request)
                : self.response(##"{"title":"Research","body":"# Findings","revision":4}"##, request: request)
        }
        let loadedAccess = try await client.loadAccess()
        let loadedDocument = try await client.load()
        XCTAssertEqual(loadedAccess, access)
        XCTAssertEqual(loadedDocument, document)
        XCTAssertEqual(paths, ["/api/thesis/access", "/api/thesis"])
    }

    func testSaveSendsExpectedRevisionAndValidatesReceipt() async throws {
        var captured: URLRequest?
        let client = try ThesisClient(settings: settings()) { request in
            captured = request
            return self.response(#"{"title":"Updated","body":"New body","revision":5}"#, request: request)
        }
        let result = try await client.save(ThesisDocument(title: "Updated", body: "New body", revision: 4), access: access)
        XCTAssertEqual(result.revision, 5)
        XCTAssertEqual(captured?.httpMethod, "PUT")
        XCTAssertEqual(captured?.url?.path, "/api/thesis")
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(captured?.httpBody)) as? [String: Any])
        XCTAssertEqual(payload["revision"] as? Int, 4)
        XCTAssertEqual(payload["title"] as? String, "Updated")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testSaveFailsClosedForReadOnlyAndInvalidDocument() async throws {
        let client = try ThesisClient(settings: settings()) { request in
            self.response("{}", request: request)
        }
        do { _ = try await client.save(document, access: ThesisAccess(member: true, canEdit: false)); XCTFail("Expected read-only guard") }
        catch ThesisClientError.readOnly {}
        do { _ = try await client.save(ThesisDocument(title: "\n", body: "", revision: 1), access: access); XCTFail("Expected invalid title guard") }
        catch ThesisClientError.invalidDocument {}
        let impersonated = try ThesisClient(settings: settings(impersonating: true)) { request in self.response("{}", request: request) }
        do { _ = try await impersonated.save(document, access: access); XCTFail("Expected impersonation guard") }
        catch ThesisClientError.readOnly {}
    }

    func testConflictReturnsCurrentDocumentAndHistoryRoutesAreScoped() async throws {
        var paths: [String] = []
        let client = try ThesisClient(settings: settings()) { request in
            paths.append(request.url!.path + (request.url!.query.map { "?\($0)" } ?? ""))
            if request.url!.path.hasSuffix("/history/3") { return self.response(#"{"title":"Old","body":"Previous","revision":3}"#, request: request) }
            if request.url!.path.hasSuffix("/history") { return self.response(#"[{"revision":3,"title":"Old","saved_at":"2026-10-23T10:00:00Z","immediate":true}]"#, request: request) }
            return self.response(#"{"title":"Other","body":"Latest","revision":5}"#, request: request, status: 409)
        }
        do { _ = try await client.save(document, access: access); XCTFail("Expected revision conflict") }
        catch ThesisClientError.conflict(let current) { XCTAssertEqual(current.revision, 5) }
        let history = try await client.history(before: 4)
        XCTAssertEqual(history.first?.revision, 3)
        let oldVersion = try await client.version(3)
        XCTAssertEqual(oldVersion.title, "Old")
        XCTAssertEqual(paths, ["/api/thesis", "/api/thesis/history?before=4", "/api/thesis/history/3"])
    }

    func testRejectsInvalidCredentialsAndInsecureAPIURL() {
        var invalid = settings()
        invalid.authToken = "bad token"
        XCTAssertThrowsError(try ThesisClient(settings: invalid)) { XCTAssertEqual($0 as? ThesisClientError, .invalidIdentity) }
        invalid = settings(); invalid.apiBaseURL = "http://api.hanasand.test/api"
        XCTAssertThrowsError(try ThesisClient(settings: invalid)) { XCTAssertEqual($0 as? ThesisClientError, .invalidBaseURL) }
    }

    func testWorkspaceCodecRoundTripsUTF16SheetLengthsAndUnknownMetadata() throws {
        let original = "<!-- thesis-workspace:2 %5B%5D -->\n" // Deliberately malformed; preserved as ordinary Markdown.
        let decoded = ThesisWorkspaceCodec.sheets(title: "Research", body: original)
        XCTAssertEqual(decoded.count, 4)
        XCTAssertEqual(decoded[0].body, original)

        let sheets = [
            ThesisSheet(body: "Intro 🧭", metadata: ["id": "Overview", "name": "Overview", "title": "# Overview", "custom": ["keep": true]]),
            ThesisSheet(body: "| Task | Status |\n| --- | --- |\n| Read | Planned |\n", metadata: ["id": "Plan", "name": "Plan", "title": "# Plan"]),
        ]
        let body = ThesisWorkspaceCodec.write(sheets)
        let restored = ThesisWorkspaceCodec.sheets(title: "Ignored", body: body)
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored[0].body, "Intro 🧭")
        XCTAssertEqual((restored[0].metadata["custom"] as? [String: Bool])?["keep"], true)
        XCTAssertEqual(restored[1].body, sheets[1].body)
    }

    func testTableCodecFindsPlanAndTimetableTablesOutsideFencedCodeAndPreservesCells() throws {
        let body = """
        Intro 🧭

        ```md
        | fake | table |
        | --- | --- |
        ```

        | Task | Status |
        | --- | --- |
        | Read &#124; compare | Planned |
        <!-- thesis-table:{"widths":[210,120],"heights":[48,56]} -->

        | Week | Research | Total |
        | --- | --- | --- |
        | 2026-W01 | 4 | 4 |
        """
        let parsed = ThesisWorkspaceCodec.tables(in: body)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].kind, .plan)
        XCTAssertEqual(parsed[0].cells[1][0], "Read | compare")
        XCTAssertEqual(parsed[0].widths, [210, 120])
        XCTAssertEqual(parsed[1].kind, .timetable)

        let edited = ThesisWorkspaceCodec.replacing(parsed[0], in: body, with: [["Task", "Status"], ["A | B", "Completed"]])
        XCTAssertEqual(ThesisWorkspaceCodec.tables(in: edited)[0].cells[1], ["A | B", "Completed"])
        XCTAssertTrue(edited.contains("Intro 🧭"))
        XCTAssertTrue(edited.contains("```md\n| fake | table |"))
        XCTAssertEqual(ThesisWorkspaceCodec.tables(in: edited).count, 2)
    }

    func testTableInsertBuildsRequestedRowsAndRecognizablePlanTemplate() throws {
        let body = ThesisWorkspaceCodec.appendingTable(to: "Notes", headers: ["Task", "Hours", "Status"], rowCount: 3)
        let tables = ThesisWorkspaceCodec.tables(in: body)
        XCTAssertEqual(tables.count, 1)
        XCTAssertEqual(tables[0].kind, .plan)
        XCTAssertEqual(tables[0].cells.count, 3)
        XCTAssertEqual(tables[0].cells[0], ["Task", "Hours", "Status"])
        XCTAssertTrue(body.hasPrefix("Notes\n\n"))
    }

    func testWorkspaceCodecReadsLegacySheetMarkersAndLeavesCodeExamplesAlone() throws {
        let body = """
        Overview text

        ```md
        <!-- thesis-sheet:Plan title:%23%20Fake -->
        ```

        <!-- thesis-sheet:Plan title:%23%20Project%20Plan -->
        | Task | Status |
        | --- | --- |
        """
        let sheets = ThesisWorkspaceCodec.sheets(title: "Research", body: body)
        XCTAssertEqual(sheets.count, 4)
        XCTAssertEqual(sheets[0].body, "Overview text\n\n```md\n<!-- thesis-sheet:Plan title:%23%20Fake -->\n```")
        XCTAssertEqual(sheets[2].title, "# Project Plan")
        XCTAssertTrue(sheets[2].body.contains("| Task | Status |"))

        let tableBody = "| Value |\n| --- |\n| &amp;#124; |\n"
        XCTAssertEqual(ThesisWorkspaceCodec.tables(in: tableBody).first?.cells[1][0], "&#124;")
        let compactTable = "Task | Status\n--- | ---\nRead | Planned"
        XCTAssertEqual(ThesisWorkspaceCodec.tables(in: compactTable).first?.cells[1], ["Read", "Planned"])
    }
}
