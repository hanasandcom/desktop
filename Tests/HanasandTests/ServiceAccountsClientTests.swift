import Foundation
import XCTest
@testable import Hanasand

final class ServiceAccountsClientTests: XCTestCase {
    private let base = URL(string: "https://api.hanasand.com/api")!
    private let access = ServiceAccountAccess(allowed: true, canEdit: true)

    func testReadUsesAuthenticatedNoStoreRequestsAndValidatesDirectory() async throws {
        var requests: [URLRequest] = []
        let client = try makeClient { request in
            requests.append(request)
            let body: String
            if request.url?.absoluteString.contains("internalPages=1") == true {
                body = #"{"allowed":true,"canEdit":true}"#
            } else {
                body = #"{"endpoints":[{"method":"GET","route":"/api/db","label":"Database"}],"accounts":[{"id":"svc_1234","name":"Monitor","description":"Read only","active":true,"created_at":"2026-10-01T00:00:00.000Z","keys":[{"id":"key_1","ownerId":"svc_1234","enabled":true,"keyPrefix":"123456abcdef","createdAt":"2026-10-01T00:00:00.000Z","lastUsedAt":null,"scopes":[{"method":"GET","route":"/api/db","label":"Database","enabled":true}]}]}]}"#
            }
            return (Data(body.utf8), self.response(for: request, status: 200))
        }
        let rights = try await client.loadAccess()
        XCTAssertTrue(rights.canEdit)
        let directory = try await client.loadDirectory()
        XCTAssertEqual(directory.accounts.first?.name, "Monitor")
        XCTAssertEqual(directory.accounts.first?.keys.first?.scopes.first?.route, "/api/db")
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET"])
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cache-Control") == "no-store" && $0.httpShouldHandleCookies == false })
        XCTAssertEqual(requests[0].url?.path, "/api/management/organizations")
        XCTAssertEqual(requests[0].url?.query, "internalPages=1")
        XCTAssertEqual(requests[1].url?.path, "/api/service-accounts")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "id"), "user_1")
    }

    func testCreateVerifiesOneTimeCredentialAndScopes() async throws {
        var captured: URLRequest?
        let endpoint = ServiceAccountEndpoint(method: "GET", route: "/api/db", label: "Database")
        let client = try makeClient { request in
            if request.httpMethod == "GET" {
                let directory = #"{"endpoints":[{"method":"GET","route":"/api/db","label":"Database"}],"accounts":[]}"#
                return (Data(directory.utf8), self.response(for: request, status: 200))
            }
            captured = request
            let secret = "hsk_123456abcdef_" + String(repeating: "a", count: 48)
            let body = #"{"apiKey":{"id":"key_2","ownerId":"svc_abcd","name":"Monitor","enabled":true,"keyPrefix":"123456abcdef","scopes":[{"method":"GET","route":"/api/db","label":"Database"}]},"secret":"\#(secret)"}"#
            return (Data(body.utf8), self.response(for: request, status: 201))
        }
        let receipt = try await client.create(access: access, name: " Monitor ", description: " read-only ", scopes: [endpoint])
        XCTAssertEqual(receipt.apiKey.ownerID, "svc_abcd")
        XCTAssertEqual(receipt.secret, "hsk_123456abcdef_" + String(repeating: "a", count: 48))
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.url?.path, "/api/service-accounts")
        let body = try XCTUnwrap(captured?.httpBody).jsonObject
        XCTAssertEqual(body["name"] as? String, "Monitor")
        XCTAssertEqual(body["description"] as? String, "read-only")
        XCTAssertEqual((body["scopes"] as? [[String: String]])?.first?["route"], "/api/db")
    }

    func testMutationsRejectImpersonationAndReadOnlyAccessBeforeNetwork() async throws {
        var requests = 0
        let client = try makeClient(impersonation: "acting-as") { _ in
            requests += 1
            return (Data(), self.response(for: URLRequest(url: self.base), status: 200))
        }
        do {
            _ = try await client.revoke(access: access, id: "svc_1")
            XCTFail("Expected impersonation guard")
        } catch let error as ServiceAccountsClientError { XCTAssertEqual(error, .readOnly) }
        XCTAssertEqual(requests, 0)
        let regular = try makeClient { _ in
            requests += 1
            return (Data(), self.response(for: URLRequest(url: self.base), status: 200))
        }
        do {
            _ = try await regular.revoke(access: ServiceAccountAccess(allowed: true, canEdit: false), id: "svc_1")
            XCTFail("Expected role guard")
        } catch let error as ServiceAccountsClientError { XCTAssertEqual(error, .readOnly) }
        XCTAssertEqual(requests, 0)
    }

    func testUnknownMutationReceiptIsNotReportedAsSuccess() async throws {
        let client = try makeClient { request in
            (Data(#"{"message":""}"#.utf8), self.response(for: request, status: 200))
        }
        do {
            _ = try await client.revoke(access: access, id: "svc_1")
            XCTFail("Expected unknown outcome")
        } catch let error as ServiceAccountsClientError { XCTAssertEqual(error, .unknownOutcome) }
    }

    func testRejectsInsecureBaseAndUnsafeRedirectResponse() async throws {
        XCTAssertThrowsError(try ServiceAccountsClient(baseURL: URL(string: "http://api.hanasand.com/api")!, userID: "user_1", token: "token", send: { _ in (Data(), HTTPURLResponse(url: self.base, statusCode: 200, httpVersion: nil, headerFields: nil)!) }))
        let client = try makeClient { request in
            (Data(#"{"allowed":true,"canEdit":true}"#.utf8), HTTPURLResponse(url: URL(string: "https://attacker.example/api")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        do { _ = try await client.loadAccess(); XCTFail("Expected origin validation") }
        catch let error as ServiceAccountsClientError { XCTAssertEqual(error, .invalidResponse) }
    }

    private func makeClient(impersonation: String = "", send: @escaping (URLRequest) async throws -> (Data, URLResponse)) throws -> ServiceAccountsClient {
        try ServiceAccountsClient(baseURL: base, userID: "user_1", token: "token", impersonationToken: impersonation, send: send)
    }

    private func response(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

private extension Data {
    var jsonObject: [String: Any] { (try! JSONSerialization.jsonObject(with: self)) as! [String: Any] }
}
