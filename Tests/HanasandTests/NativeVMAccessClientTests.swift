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

    func testFailoverMutationUsesExpectedMethodsBodiesAndExactReceipts() async throws {
        let client = try makeClient { request in
            self.requests.append(request)
            switch (request.url?.path, request.httpMethod) {
            case ("/api/vm/vm-17/host-features", "PUT"):
                let patch = try XCTUnwrap(request.httpBody).flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Bool] }
                XCTAssertEqual(patch, ["failover_enabled": true])
                return (Data(#"{"name":"vm-17","primary_host":"ovhcloud","failover_host":"inspur","failover_premium":true,"failover_enabled":true}"#.utf8), try Self.response(for: request, status: 200))
            case ("/api/vm/vm-17/failover", "POST"):
                XCTAssertNil(request.httpBody)
                return (Data(#"{"vm":{"name":"vm-17","primary_host":"inspur","failover_host":"ovhcloud","failover_premium":true,"failover_enabled":true},"message":"Moved to inspur."}"#.utf8), try Self.response(for: request, status: 200))
            default:
                XCTFail("Unexpected method/path: \(String(describing: request.httpMethod)) \(String(describing: request.url?.path))")
                throw NativeVMAccessError.invalidResponse
            }
        }

        let updated = try await client.updateFailover(for: "vm-17", enabled: true)
        XCTAssertEqual(updated.standbyHost, "inspur")
        XCTAssertTrue(updated.failoverEnabled)
        let receipt = try await client.runFailover(for: "vm-17")
        XCTAssertEqual(receipt.message, "Moved to inspur.")
        XCTAssertEqual(receipt.hostOptions.primaryHost, "inspur")
        XCTAssertEqual(requests.map(\.httpMethod), ["PUT", "POST"])
    }

    func testFailoverAmbiguousTransportOrReceiptIsNeverRetried() async throws {
        var requestCount = 0
        let failing = try makeClient { _ in
            requestCount += 1
            throw URLError(.timedOut)
        }
        do { _ = try await failing.updateFailover(for: "vm-17", enabled: true); XCTFail("Timeout must be uncertain.") }
        catch { XCTAssertEqual(error as? NativeVMAccessError, .uncertainOutcome) }
        XCTAssertEqual(requestCount, 1)

        let wrongReceipt = try makeClient { request in
            (Data(#"{"name":"vm-18","failover_premium":true,"failover_enabled":true}"#.utf8), try Self.response(for: request, status: 200))
        }
        do { _ = try await wrongReceipt.updateFailover(for: "vm-17", enabled: true); XCTFail("Wrong-VM mutation receipt must be uncertain.") }
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
