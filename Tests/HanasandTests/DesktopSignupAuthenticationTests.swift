import Foundation
import XCTest
@testable import Hanasand

final class DesktopSignupAuthenticationTests: XCTestCase {
    private let baseURL = URL(string: "https://api.hanasand.test/api")!
    private let password = "Correct-Horse-Battery-19!"

    private func response(_ json: String, request: URLRequest, status: Int) -> (Data, URLResponse) {
        let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        return (Data(json.utf8), http)
    }

    func testSignupRequestsEmailVerificationWithWebsiteContract() async throws {
        var captured: URLRequest?
        let client = try AccountSignupClient(baseURL: baseURL) { request in
            captured = request
            return self.response(#"{"verificationRequired":true,"challengeId":"4bf1eb2f-1a9a-4a1b-b369-284e8ca6fd77","expiresIn":600}"#, request: request, status: 202)
        }

        let result = try await client.submit(name: " Ada Lovelace ", username: " Ada.Lovelace ", email: " ADA@example.test ", password: password)

        guard case let .verificationRequired(challengeID) = result else { return XCTFail("Expected email verification") }
        XCTAssertEqual(challengeID, "4bf1eb2f-1a9a-4a1b-b369-284e8ca6fd77")
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.hanasand.test/api/user")
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertFalse(captured?.httpShouldHandleCookies ?? true)
        let body = try XCTUnwrap(captured?.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(payload["id"], "ada.lovelace")
        XCTAssertEqual(payload["name"], "Ada Lovelace")
        XCTAssertEqual(payload["email"], "ada@example.test")
        XCTAssertEqual(payload["password"], password)
        XCTAssertNil(payload["challengeId"])
        XCTAssertNil(payload["code"])
    }

    func testVerifiedSignupCreatesDesktopSessionFromIdentityResponse() async throws {
        let challengeID = "4bf1eb2f-1a9a-4a1b-b369-284e8ca6fd77"
        var captured: URLRequest?
        let client = try AccountSignupClient(baseURL: baseURL) { request in
            captured = request
            return self.response(#"{"id":"ada","name":"Ada","token":"session-token","expires_at":"2030-01-01T00:00:00Z"}"#, request: request, status: 201)
        }

        let result = try await client.submit(name: "Ada", username: "ada", email: "ada@example.test", password: password, challengeID: challengeID, code: "012345")

        guard case let .authenticated(session) = result else { return XCTFail("Expected an authenticated session") }
        XCTAssertEqual(session.id, "ada")
        XCTAssertEqual(session.token, "session-token")
        XCTAssertEqual(session.expiresAt, "2030-01-01T00:00:00Z")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(captured?.httpBody)) as? [String: String])
        XCTAssertEqual(payload["challengeId"], challengeID)
        XCTAssertEqual(payload["code"], "012345")
    }

    func testSignupEnforcesWebsiteInputAndVerificationRulesBeforeSending() async throws {
        var sent = false
        let client = try AccountSignupClient(baseURL: baseURL) { request in
            sent = true
            return self.response("{}", request: request, status: 400)
        }

        XCTAssertFalse(AccountSignupClient.passwordMeetsRequirements("Short1!"))
        XCTAssertTrue(AccountSignupClient.passwordMeetsRequirements(password))
        do { _ = try await client.submit(name: "Ada", username: "ab", email: "ada@example.test", password: password); XCTFail("Expected username validation") }
        catch AccountSignupError.invalidUsername {}
        do { _ = try await client.submit(name: "Ada", username: "ada", email: "invalid", password: password); XCTFail("Expected email validation") }
        catch AccountSignupError.invalidEmail {}
        do { _ = try await client.submit(name: "Ada", username: "ada", email: "ada@example.test", password: password, challengeID: "bad", code: "123456"); XCTFail("Expected verification validation") }
        catch AccountSignupError.invalidVerification {}
        XCTAssertFalse(sent)
    }

    func testSignupReturnsServerValidationErrorsWithoutExposingRequestSecrets() async throws {
        let client = try AccountSignupClient(baseURL: baseURL) { request in
            self.response(#"{"error":"This username or email is already registered."}"#, request: request, status: 409)
        }
        do {
            _ = try await client.submit(name: "Ada", username: "ada", email: "ada@example.test", password: password)
            XCTFail("Expected conflict response")
        } catch {
            XCTAssertEqual(error.localizedDescription, "This username or email is already registered.")
            XCTAssertFalse(error.localizedDescription.contains(password))
        }
    }

    func testSignupRequiresHttpsAndRejectsIncompleteConfirmation() throws {
        XCTAssertThrowsError(try AccountSignupClient(baseURL: URL(string: "http://api.hanasand.test/api")!))
        XCTAssertThrowsError(try AccountSignupClient(baseURL: URL(string: "https://user@api.hanasand.test/api")!))
    }
}
