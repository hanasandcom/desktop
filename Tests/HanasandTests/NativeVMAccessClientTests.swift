import Foundation
import XCTest
@testable import Hanasand

final class NativeVMAccessClientTests: XCTestCase {
    private let base = URL(string: "https://api.example.test/api")!
    private var requests: [URLRequest] = []

    override func setUp() { requests = [] }

    func testConnectionReadUsesScopedAuthenticatedNoCookieRequestAndValidatesExactVM() async throws {
        let client = try makeClient(organization: "org-2") { request in
            self.requests.append(request)
            XCTAssertEqual(request.url?.path, "/api/vm/vm-17/connection")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "id"), "fixture-user")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-organization-id"), "org-2")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            XCTAssertFalse(request.httpShouldHandleCookies)
            let data = Data(#"{"vmName":"vm-17","vmIp":"192.0.2.17","username":"ubuntu","sshCommand":"ssh ubuntu@192.0.2.17 -p 443","certificateCount":2,"certificates":[{"privateKey":"must-not-be-retained"}]}"#.utf8)
            return (data, try Self.response(for: request, status: 200))
        }

        let connection = try await client.loadConnection(for: "vm-17")
        XCTAssertEqual(connection, NativeVMConnection(vmName: "vm-17", ipAddress: "192.0.2.17", username: "ubuntu",
                                                      sshCommand: "ssh ubuntu@192.0.2.17 -p 443", certificateCount: 2))
        XCTAssertEqual(requests.count, 1)
    }

    func testConnectionRejectsWrongVmAndMalformedSSHCommand() async throws {
        let wrongVM = try makeClient { request in
            (Data(#"{"vmName":"vm-18","vmIp":"192.0.2.18","username":"ubuntu","certificateCount":1}"#.utf8), try Self.response(for: request, status: 200))
        }
        do { _ = try await wrongVM.loadConnection(for: "vm-17"); XCTFail("Wrong-VM connection data must be rejected.") }
        catch { XCTAssertEqual(error as? NativeVMAccessError, .invalidResponse) }

        let unsafeCommand = try makeClient { request in
            (Data(#"{"vmName":"vm-17","vmIp":"192.0.2.17","username":"ubuntu","sshCommand":"ssh\nmalicious","certificateCount":1}"#.utf8), try Self.response(for: request, status: 200))
        }
        do { _ = try await unsafeCommand.loadConnection(for: "vm-17"); XCTFail("Control characters in an SSH command must be rejected.") }
        catch { XCTAssertEqual(error as? NativeVMAccessError, .invalidResponse) }
    }

    func testSudoPasswordRequiresCurrentPasswordAndReturnsOnlyValidatedSecret() async throws {
        let client = try makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/vm/vm-17/sudo-password")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(request.httpBody).flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] }
            XCTAssertEqual(body, ["currentPassword": "account-password"])
            return (Data(#"{"password":"temporary-sudo-secret"}"#.utf8), try Self.response(for: request, status: 200))
        }

        let password = try await client.revealSudoPassword(for: "vm-17", currentPassword: "account-password")
        XCTAssertEqual(password, "temporary-sudo-secret")
        do { _ = try await client.revealSudoPassword(for: "vm-17", currentPassword: ""); XCTFail("Empty password must be rejected locally.") }
        catch { XCTAssertEqual(error as? NativeVMAccessError, .invalidPassword) }
    }

    func testSudoUnavailableRequiresExactWebsiteCodeAndMessage() async throws {
        let exact = try makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/vm/vm-17/sudo-password")
            return (Data(#"{"code":"SUDO_PASSWORD_UNAVAILABLE","error":"Unavailable. Contact Support if the problem persists."}"#.utf8),
                    try Self.response(for: request, status: 503))
        }
        do {
            _ = try await exact.revealSudoPassword(for: "vm-17", currentPassword: "account-password")
            XCTFail("The Website-equivalent failure must be surfaced as a typed unavailable result.")
        } catch {
            XCTAssertEqual(error as? NativeVMAccessError, .sudoPasswordUnavailable)
        }

        let mismatches: [(Int, String)] = [
            (503, #"{"code":"TEMPORARY_FAILURE","error":"Unavailable. Contact Support if the problem persists."}"#),
            (503, #"{"code":"SUDO_PASSWORD_UNAVAILABLE","error":"Internal transport detail"}"#),
            (502, #"{"code":"SUDO_PASSWORD_UNAVAILABLE","error":"Unavailable. Contact Support if the problem persists."}"#)
        ]
        for (status, body) in mismatches {
            let client = try makeClient { request in
                (Data(body.utf8), try Self.response(for: request, status: status))
            }
            do {
                _ = try await client.revealSudoPassword(for: "vm-17", currentPassword: "account-password")
                XCTFail("A non-matching failure must not enable the Support handoff.")
            } catch {
                XCTAssertEqual(error as? NativeVMAccessError, .uncertainOutcome)
            }
        }
    }

    func testFailoverMutationUsesExpectedMethodsBodiesAndExactReceipts() async throws {
        let client = try makeClient { request in
            self.requests.append(request)
            switch (request.url?.path, request.httpMethod) {
            case ("/api/vm/vm-17/host-features", "PUT"):
                let patch = try XCTUnwrap(request.httpBody).flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Bool] }
                XCTAssertEqual(patch, ["failover_enabled": true])
                return (Data(#"{"name":"vm-17","primary_host":"ovhcloud","failover_host":"inspur","failover_premium":true,"failover_enabled":true}"#.utf8), try Self.response(for: request, status: 200))
            case ("/api/vm/vm-17/failover", "POST"):
                let body = try XCTUnwrap(request.httpBody).flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] }
                XCTAssertEqual(body, ["targetHost": "inspur", "requestId": "abcdef01-2345-6789-abcd-ef0123456789"])
                return (Data(#"{"vm":{"name":"vm-17","primary_host":"ovhcloud","failover_host":"inspur","failover_premium":true,"failover_enabled":true},"message":"Host switch queued."}"#.utf8), try Self.response(for: request, status: 202))
            default:
                XCTFail("Unexpected method/path: \(String(describing: request.httpMethod)) \(String(describing: request.url?.path))")
                throw NativeVMAccessError.invalidResponse
            }
        }

        let updated = try await client.updateFailover(for: "vm-17", enabled: true)
        XCTAssertEqual(updated.standbyHost, "inspur")
        XCTAssertTrue(updated.failoverEnabled)
        let requestID = try XCTUnwrap(UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789"))
        let receipt = try await client.runFailover(for: "vm-17", targetHost: "inspur", requestID: requestID)
        XCTAssertEqual(receipt.message, "Host switch queued.")
        XCTAssertEqual(receipt.hostOptions.primaryHost, "ovhcloud")
        XCTAssertEqual(requests.map(\.httpMethod), ["PUT", "POST"])
    }

    func testFailoverAmbiguousTransportOrReceiptIsNeverRetried() async throws {
        var requestCount = 0
        let failing = try makeClient { _ in
            requestCount += 1
            throw URLError(.timedOut)
        }
        let requestID = try XCTUnwrap(UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789"))
        do { _ = try await failing.runFailover(for: "vm-17", targetHost: "inspur", requestID: requestID); XCTFail("Timeout must be uncertain.") }
        catch { XCTAssertEqual(error as? NativeVMAccessError, .uncertainOutcome) }
        XCTAssertEqual(requestCount, 1)

        let serverFailure = try makeClient { request in
            requestCount += 1
            return (Data(#"{"error":"temporary failure"}"#.utf8), try Self.response(for: request, status: 500))
        }
        do { _ = try await serverFailure.runFailover(for: "vm-17", targetHost: "inspur", requestID: requestID); XCTFail("5xx after a mutation must be uncertain.") }
        catch { XCTAssertEqual(error as? NativeVMAccessError, .uncertainOutcome) }
        XCTAssertEqual(requestCount, 2)

        let nonQueuedReceipt = try makeClient { request in
            requestCount += 1
            return (Data(#"{"vm":{"name":"vm-17","primary_host":"ovhcloud","failover_host":"inspur","failover_premium":true,"failover_enabled":true},"message":"Moved."}"#.utf8), try Self.response(for: request, status: 200))
        }
        do { _ = try await nonQueuedReceipt.runFailover(for: "vm-17", targetHost: "inspur", requestID: requestID); XCTFail("A non-202 response must not be treated as queued.") }
        catch { XCTAssertEqual(error as? NativeVMAccessError, .uncertainOutcome) }
        XCTAssertEqual(requestCount, 3)

        let wrongReceipt = try makeClient { request in
            (Data(#"{"vm":{"name":"vm-18","primary_host":"ovhcloud","failover_host":"inspur","failover_premium":true,"failover_enabled":true},"message":"Host switch queued."}"#.utf8), try Self.response(for: request, status: 202))
        }
        do { _ = try await wrongReceipt.runFailover(for: "vm-17", targetHost: "inspur", requestID: requestID); XCTFail("Wrong-VM mutation receipt must be uncertain.") }
        catch { XCTAssertEqual(error as? NativeVMAccessError, .uncertainOutcome) }
    }

    func testFailoverCheckoutRequiresExactStripeHTTPSHost() async throws {
        let valid = try makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/billing/container-checkout")
            let body = try XCTUnwrap(request.httpBody).flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] }
            XCTAssertEqual(body, ["vmName": "vm-17", "feature": "failover"])
            return (Data(#"{"url":"https://checkout.stripe.com/c/pay/cs_live_fixture"}"#.utf8), try Self.response(for: request, status: 200))
        }
        let checkoutURL = try await valid.loadFailoverCheckoutURL(for: "vm-17")
        XCTAssertEqual(checkoutURL.host, "checkout.stripe.com")

        let untrusted = try makeClient { request in
            (Data(#"{"url":"https://checkout.stripe.com.evil.test/c/pay"}"#.utf8), try Self.response(for: request, status: 200))
        }
        do { _ = try await untrusted.loadFailoverCheckoutURL(for: "vm-17"); XCTFail("Untrusted checkout host must be rejected.") }
        catch { XCTAssertEqual(error as? NativeVMAccessError, .invalidResponse) }
    }

    func testImpersonationInvalidEndpointAndHTTPFailureAreRejected() async throws {
        XCTAssertThrowsError(try NativeVMAccessClient(apiBaseURL: base, userID: "fixture-user", token: "fixture-token", impersonationToken: "impersonation")) {
            XCTAssertEqual($0 as? NativeVMAccessError, .impersonationUnsupported)
        }
        XCTAssertThrowsError(try NativeVMAccessClient(apiBaseURL: URL(string: "http://api.example.test/api")!, userID: "fixture-user", token: "fixture-token")) {
            XCTAssertEqual($0 as? NativeVMAccessError, .invalidEndpoint)
        }
        let denied = try makeClient { request in
            (Data(#"{"error":"denied"}"#.utf8), try Self.response(for: request, status: 403))
        }
        do { _ = try await denied.loadConnection(for: "vm-17"); XCTFail("Forbidden access must be denied.") }
        catch { XCTAssertEqual(error as? NativeVMAccessError, .accessDenied) }
    }

    private func makeClient(organization: String? = nil, send: @escaping (URLRequest) async throws -> (Data, URLResponse)) throws -> NativeVMAccessClient {
        try NativeVMAccessClient(apiBaseURL: base, userID: "fixture-user", token: "fixture-token", organizationID: organization,
                                 send: { request in try await send(request) })
    }

    private static func response(for request: URLRequest, status: Int) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil))
    }
}
