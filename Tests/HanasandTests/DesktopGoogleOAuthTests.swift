import XCTest
@testable import Hanasand

final class DesktopGoogleOAuthTests: XCTestCase {
    func testBuildsGoogleAuthorizationURLWithMobilePKCEChallenge() throws {
        let challenge = String(repeating: "A", count: 43)
        let client = DesktopGoogleOAuthClient(websiteBaseURL: URL(string: "https://hanasand.com")!)

        let url = try client.authorizationURL(challenge: challenge)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(url.absoluteString, "https://hanasand.com/api/auth/social/google/start?mobile_challenge=\(challenge)")
        XCTAssertEqual(components.queryItems?.map(\.name), ["mobile_challenge"])
    }

    func testRejectsInsecureOrCredentialedAuthenticationEndpoints() throws {
        let challenge = String(repeating: "A", count: 43)
        for base in ["http://hanasand.com", "https://user:password@hanasand.com"] {
            let client = DesktopGoogleOAuthClient(websiteBaseURL: URL(string: base)!)
            XCTAssertThrowsError(try client.authorizationURL(challenge: challenge), "Accepted insecure base URL: \(base)") { error in
                XCTAssertEqual(error as? DesktopGoogleOAuthError, .insecureEndpoint)
            }
        }
    }

    func testRejectsNonGoogleAndMismatchedDeepLinkCallbacks() throws {
        let code = String(repeating: "A", count: 43)
        let invalidCallbacks = [
            "https://hanasand.com/api/auth/social/google/callback?code=\(code)",
            "hanasand://sso?code=\(code)",
            "hanasand://other?code=\(code)",
            "hanasand://social/callback?code=\(code)",
            "hanasand://social?code=\(code)&state=\(String(repeating: "B", count: 43))",
            "hanasand://social?code=short",
            "hanasand://social?code=\(code)#fragment",
        ]

        for value in invalidCallbacks {
            let callback = try XCTUnwrap(URL(string: value))
            XCTAssertNil(DesktopGoogleOAuthCallback.result(from: callback), "Accepted callback: \(value)")
        }
    }

    func testRecognizesProviderCancellationWithoutTreatingItAsSuccess() throws {
        let callback = try XCTUnwrap(URL(string: "hanasand://social?error=access_denied"))

        guard case .failure(.provider("access_denied"))? = DesktopGoogleOAuthCallback.result(from: callback) else {
            return XCTFail("Expected the provider cancellation to remain an error")
        }
    }

    func testRecognizesNativeAuthenticationSessionCancellation() {
        guard case .failure(.canceled) = DesktopGoogleOAuthCallback.sessionOutcome(callbackURL: nil, wasCancelled: true) else {
            return XCTFail("Expected cancellation of the native authentication session")
        }
    }

    func testExchangesPKCECodeAndDecodesDesktopSession() async throws {
        let code = String(repeating: "C", count: 43)
        let verifier = String(repeating: "V", count: 43)
        let client = DesktopGoogleOAuthClient(
            websiteBaseURL: URL(string: "https://hanasand.com")!,
            transport: { request in
                XCTAssertEqual(request.url?.absoluteString, "https://hanasand.com/api/auth/mobile/sso/exchange")
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                let payload = try XCTUnwrap(request.httpBody)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: String])
                XCTAssertEqual(object, ["code": code, "verifier": verifier])
                let data = Data(#"{"id":"eirik","token":"session-token"}"#.utf8)
                let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (data, response)
            }
        )

        let response = try await client.exchange(code: code, verifier: verifier)
        XCTAssertEqual(response.id, "eirik")
        XCTAssertEqual(response.token, "session-token")
    }

    func testProviderConfigurationIsReadThroughNativeJSONEndpoint() async throws {
        let client = DesktopGoogleOAuthClient(
            websiteBaseURL: URL(string: "https://hanasand.com")!,
            transport: { request in
                XCTAssertEqual(request.url?.absoluteString, "https://hanasand.com/api/auth/social/providers")
                XCTAssertEqual(request.httpMethod, "GET")
                let data = Data(#"{"providers":[{"provider":"google","configured":true}]}"#.utf8)
                let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (data, response)
            }
        )

        let configured = try await client.isConfigured()
        XCTAssertTrue(configured)
    }
}
