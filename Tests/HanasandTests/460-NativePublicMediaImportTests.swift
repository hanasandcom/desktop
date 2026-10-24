import Foundation
import XCTest
@testable import Hanasand

final class NativePublicMediaImportTests: XCTestCase {
    func testUsesAuthenticatedFirstPartyProxyAndReturnsReviewedMedia() async throws {
        let payload = Data([1, 2, 3, 4])
        var captured: URLRequest?
        let client = try makeClient { request in
            captured = request
            return (payload, self.response(url: request.url!, status: 200, headers: ["Content-Type": "image/png; charset=binary"]))
        }
        let item = try await client.fetch("https://cdn.example.test/photo.png")
        XCTAssertEqual(item.data, payload)
        XCTAssertEqual(item.fileName, "photo.png")
        XCTAssertEqual(item.mediaType, "image/png")
        XCTAssertEqual(captured?.url?.host, "hanasand.test")
        XCTAssertEqual(captured?.url?.path, "/api/image")
        XCTAssertEqual(captured?.httpMethod, "GET")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Cookie"), "id=user-1; access_token=token-1")
        XCTAssertEqual(URLComponents(url: captured!.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value,
                       "https://cdn.example.test/photo.png")
    }

    func testRejectsCredentialsFragmentsAndOversizedURLsBeforeRequest() async throws {
        let client = try makeClient { _ in XCTFail("unexpected request"); throw NativePublicMediaImportError.invalidResponse }
        for value in ["https://name:password@example.test/a.png", "https://example.test/a.png#fragment"] {
            do { _ = try await client.fetch(value); XCTFail("expected invalid URL") }
            catch { XCTAssertEqual(error as? NativePublicMediaImportError, .invalidURL) }
        }
        do {
            _ = try await client.fetch("https://example.test/" + String(repeating: "a", count: NativePublicMediaImportLimits.maxURLBytes))
            XCTFail("expected URL size rejection")
        } catch { XCTAssertEqual(error as? NativePublicMediaImportError, .urlTooLong) }
    }

    func testRejectsUnsupportedMimeEmptyAndOversizedPayload() async throws {
        for (data, type, expected) in [
            (Data([1]), "application/octet-stream", NativePublicMediaImportError.unsupportedMediaType),
            (Data(), "image/png", NativePublicMediaImportError.emptyMedia),
            (Data(repeating: 0, count: NativePublicMediaImportLimits.maxBytes + 1), "video/mp4", NativePublicMediaImportError.tooLarge),
        ] {
            let client = try makeClient { request in
                (data, self.response(url: request.url!, status: 200, headers: ["Content-Type": type]))
            }
            do { _ = try await client.fetch("https://cdn.example.test/media") ; XCTFail("expected validation error") }
            catch { XCTAssertEqual(error as? NativePublicMediaImportError, expected) }
        }
    }

    func testMapsAuthenticationServiceAndProxyFailures() async throws {
        for (status, expected) in [(401, NativePublicMediaImportError.signInRequired),
                                   (503, NativePublicMediaImportError.serviceUnavailable),
                                   (413, NativePublicMediaImportError.tooLarge)] {
            let client = try makeClient { request in
                (Data("{\"error\":\"No\"}".utf8), self.response(url: request.url!, status: status, headers: ["Content-Type": "application/json"]))
            }
            do { _ = try await client.fetch("https://cdn.example.test/media.png"); XCTFail("expected proxy failure") }
            catch { XCTAssertEqual(error as? NativePublicMediaImportError, expected) }
        }
    }

    func testRejectsRedirectsAndCrossOriginFinalResponse() async throws {
        let redirectClient = try makeClient { request in
            (Data(), self.response(url: request.url!, status: 302, headers: ["Location": "https://attacker.test/collect"]))
        }
        do { _ = try await redirectClient.fetch("https://cdn.example.test/media.png"); XCTFail("expected redirect rejection") }
        catch { XCTAssertEqual(error as? NativePublicMediaImportError, .redirectBlocked) }

        let crossOriginClient = try makeClient { request in
            (Data([1]), self.response(url: URL(string: "https://attacker.test/api/image")!, status: 200, headers: ["Content-Type": "image/png"]))
        }
        do { _ = try await crossOriginClient.fetch("https://cdn.example.test/media.png"); XCTFail("expected origin rejection") }
        catch { XCTAssertEqual(error as? NativePublicMediaImportError, .invalidResponse) }
    }

    func testRequiresSecureOriginAndCredentials() throws {
        XCTAssertThrowsError(try NativePublicMediaImportClient(websiteBaseURL: "http://hanasand.test", userID: "u", token: "t")) {
            XCTAssertEqual($0 as? NativePublicMediaImportError, .invalidBaseURL)
        }
        XCTAssertThrowsError(try NativePublicMediaImportClient(websiteBaseURL: "https://hanasand.test", userID: "", token: "t")) {
            XCTAssertEqual($0 as? NativePublicMediaImportError, .signInRequired)
        }
        XCTAssertThrowsError(try NativePublicMediaImportClient(websiteBaseURL: "https://hanasand.test", userID: "user", token: "bad;cookie")) {
            XCTAssertEqual($0 as? NativePublicMediaImportError, .invalidCredentials)
        }
    }

    func testUploadStatusHasActionableRecovery() {
        XCTAssertEqual(NativePublicMediaImportError.uploadRecovery(status: 401), .uploadUnauthorized)
        XCTAssertEqual(NativePublicMediaImportError.uploadRecovery(status: 409), .pathConflict)
        XCTAssertEqual(NativePublicMediaImportError.uploadRecovery(status: 413), .tooLarge)
        XCTAssertEqual(NativePublicMediaImportError.uploadRecovery(status: 429), .uploadRateLimited)
        XCTAssertEqual(NativePublicMediaImportError.uploadRecovery(status: 507), .storageFull)
        XCTAssertEqual(NativePublicMediaImportError.uploadRecovery(status: 500), .requestFailed(500))
    }

    func testCDNUploadAuthenticationHeadersRequireValidAccountCredentials() {
        XCTAssertEqual(NativePublicMediaImportClient.cdnUploadAuthenticationHeaders(userID: " user-1 ", token: " token-1 "),
                       ["Authorization": "Bearer token-1", "id": "user-1"])
        XCTAssertNil(NativePublicMediaImportClient.cdnUploadAuthenticationHeaders(userID: "user", token: "token\r\nX-Evil: yes"))
        XCTAssertNil(NativePublicMediaImportClient.cdnUploadAuthenticationHeaders(userID: "", token: "token"))
    }

    private func makeClient(sender: @escaping NativePublicMediaImportClient.Sender) throws -> NativePublicMediaImportClient {
        try NativePublicMediaImportClient(websiteBaseURL: "https://hanasand.test/", userID: "user-1", token: "token-1", sender: sender)
    }

    private func response(url: URL, status: Int, headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }
}
