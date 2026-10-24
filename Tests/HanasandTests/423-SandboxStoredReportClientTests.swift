import Foundation
import XCTest

@testable import Hanasand

final class SandboxStoredReportClientTests: XCTestCase {
    func testShareReportUsesRunAndTokenWithoutRequiringAccountCredentials() async throws {
        var captured: URLRequest?
        let client = try SandboxStoredReportClient { request in
            captured = request
            return (Data(Self.reportJSON.utf8), self.response(for: request.url!))
        }

        let report = try await client.load(runID: "run-9", reportToken: "share-token")

        XCTAssertEqual(captured?.url?.path, "/api/browser/runs/run-9/report")
        let query = URLComponents(url: captured!.url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "token" })?.value, "share-token")
        XCTAssertNil(captured?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(report.id, "run-9")
        XCTAssertEqual(report.exportData, Data(Self.reportJSON.utf8))
        XCTAssertEqual(report.target, "https://example.test")
        XCTAssertEqual(report.verdict, "suspicious")
        XCTAssertEqual(report.indicators, ["new domain"])
        XCTAssertEqual(report.recommendedActions, ["review redirect"])
        XCTAssertEqual(report.timeline.first?.detail, "https://example.test/login")
    }

    func testStoredResultHonorsSelectedRunAndAuthenticatedOwnerIdentity() async throws {
        var captured: URLRequest?
        let client = try SandboxStoredReportClient(userID: "user-7", authToken: "session-token") { request in
            captured = request
            return (Data(#"{"runId":"run-2","target":"https://example.test","finalUrl":"https://example.test/end","status":{"run":"completed"},"exportedAt":"2026-10-24T12:00:00Z","captures":[{"kind":"page","url":"https://example.test/end"}],"evidenceEvents":[{"type":"navigation","url":"https://example.test/end"}]}"#.utf8), self.response(for: request.url!))
        }

        let result = try await client.load(resultID: "01234567-89ab-cdef-0123-456789abcdef", selectedRunID: "run-2")

        XCTAssertEqual(captured?.url?.path, "/api/browser/results/01234567-89ab-cdef-0123-456789abcdef")
        XCTAssertEqual(URLComponents(url: captured!.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "run-2")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "user-7")
        XCTAssertNil(captured?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(captured?.httpShouldHandleCookies ?? true)
        XCTAssertEqual(result.id, "run-2")
        XCTAssertTrue(String(data: result.exportData, encoding: .utf8)?.contains("\"evidenceEvents\"") == true)
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(result.evidence.count, 2)
    }

    func testRejectsMissingCredentialsWithoutShareTokenAndMalformedRouteIDs() async throws {
        let client = try SandboxStoredReportClient { request in
            (Data(Self.reportJSON.utf8), self.response(for: request.url!))
        }
        do {
            _ = try await client.load(resultID: "01234567-89ab-cdef-0123-456789abcdef")
            XCTFail("A private result must require account credentials.")
        } catch {
            XCTAssertEqual(error as? SandboxStoredReportError, .signInRequired)
        }
        do {
            _ = try await client.load(runID: "run-9")
            XCTFail("A share report must include its token when no account is signed in.")
        } catch {
            XCTAssertEqual(error as? SandboxStoredReportError, .signInRequired)
        }
        do {
            _ = try await client.load(resultID: "not-a-uuid", selectedRunID: "run-2")
            XCTFail("Malformed result identifiers must be rejected before requesting.")
        } catch {
            XCTAssertEqual(error as? SandboxStoredReportError, .invalidRoute)
        }
    }

    func testRejectsInsecureAPIAndImpersonatedRequests() {
        XCTAssertThrowsError(try SandboxStoredReportClient(apiBaseURL: URL(string: "http://browsers.hanasand.com/api")!)) {
            XCTAssertEqual($0 as? SandboxStoredReportError, .invalidBaseURL)
        }
        XCTAssertThrowsError(try SandboxStoredReportClient(impersonationToken: "other-session")) {
            XCTAssertEqual($0 as? SandboxStoredReportError, .ownAccountRequired)
        }
    }

    func testNonSuccessAndForeignOriginResponsesFailClosed() async throws {
        let missing = try SandboxStoredReportClient { request in
            (Data(#"{"error":"not found"}"#.utf8), self.response(for: request.url!, status: 404))
        }
        do {
            _ = try await missing.load(runID: "run-9", reportToken: "share-token")
            XCTFail("Missing shared reports should surface a not found response.")
        } catch {
            XCTAssertEqual(error as? SandboxStoredReportError, .requestFailed(404))
        }

        let foreign = try SandboxStoredReportClient { request in
            (Data(Self.reportJSON.utf8), self.response(for: URL(string: "https://attacker.test/redirect")!))
        }
        do {
            _ = try await foreign.load(runID: "run-9", reportToken: "share-token")
            XCTFail("Responses from a different origin must be rejected.")
        } catch {
            XCTAssertEqual(error as? SandboxStoredReportError, .invalidResponse)
        }
    }

    private static let reportJSON = #"{"runId":"run-9","target":"https://example.test","finalUrl":"https://example.test","status":{"run":"completed"},"exportedAt":"2026-10-24T12:00:00Z","analystReport":{"verdict":"suspicious","markdown":"Report narrative","indicators":["new domain"],"recommendedActions":["review redirect"],"urlTimeline":[{"capturedAt":"12:00","url":"https://example.test/login"}],"providerReports":[{"tool":"reputation","status":"complete","verdict":"suspicious"}]},"analystSummary":{"narrative":"Summary"},"captures":[],"evidenceEvents":[]}"#

    private func response(for url: URL, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    }
}
