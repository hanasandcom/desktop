import Foundation
import XCTest
@testable import Hanasand

final class NativeVMWorkspaceClientTests: XCTestCase {
    func testDetailsRequestKeepsBasePathAndAddsScopedAuthentication() async throws {
        let client = try NativeVMWorkspaceClient(
            apiBaseURL: "https://api.example.test/api",
            userID: "user-1",
            token: "token-value",
            organizationID: "org-2",
            send: { request in
                XCTAssertEqual(request.url?.path, "/api/vm/details/vm-17")
                XCTAssertEqual(request.value(forHTTPHeaderField: "id"), "user-1")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-value")
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-organization-id"), "org-2")
                let data = Data(#"{"name":"vm-17","status":"Running","profiles":["default"],"limits_cpu":"4"}"#.utf8)
                return (data, try Self.response(for: request, status: 200))
            }
        )

        let details = try await client.loadDetails(for: "vm-17")
        XCTAssertEqual(details?.name, "vm-17")
        XCTAssertEqual(details?.profiles, ["default"])
        XCTAssertTrue(details?.fields.contains(where: { $0.0 == "Status" && $0.1 == "Running" }) == true)
    }

    func testMetricsRejectRowsForAnotherVM() async throws {
        let client = try NativeVMWorkspaceClient(
            apiBaseURL: "https://api.example.test/api/",
            userID: "user-1",
            token: "token-value",
            send: { request in
                XCTAssertEqual(request.url?.path, "/api/vm/metrics/vm-17")
                let data = Data(#"[{"name":"vm-18","cpu_usage_percent":12,"power_state":"running"}]"#.utf8)
                return (data, try Self.response(for: request, status: 200))
            }
        )

        do {
            _ = try await client.loadMetrics(for: "vm-17")
            XCTFail("A metrics response for a different VM must be rejected.")
        } catch let error as NativeVMWorkspaceClientError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testManagementReadReturnsCurrentAuthorizationAndServices() async throws {
        let client = try NativeVMWorkspaceClient(
            apiBaseURL: "https://api.example.test/api",
            userID: "user-1",
            token: "token-value",
            send: { request in
                XCTAssertEqual(request.url?.path, "/api/vm/vm-17/public-services")
                let data = Data(#"{"canManage":true,"services":[{"name":"site","type":"http","port":8080,"hostname":"site.example.test"}]}"#.utf8)
                return (data, try Self.response(for: request, status: 200))
            }
        )

        let access = try await client.loadManagement(for: "vm-17")
        XCTAssertTrue(access.canManage)
        XCTAssertEqual(access.services.first?.0, "site")
        XCTAssertEqual(access.services.first?.1, "http · port 8080 · site.example.test")
    }

    func testVMNameAndEndpointValidation() throws {
        XCTAssertThrowsError(try NativeVMWorkspaceClient(apiBaseURL: "http://api.example.test/api", userID: "u", token: "t"))
        XCTAssertThrowsError(try NativeVMWorkspaceClient(apiBaseURL: "https://user:pass@api.example.test/api", userID: "u", token: "t"))
        XCTAssertNil(nativeVMActionPath(vmName: "node/other", action: "start", isImpersonating: false))
        XCTAssertNil(nativeVMActionPath(vmName: "node-1", action: "delete", isImpersonating: false))
        XCTAssertNil(nativeVMActionPath(vmName: "node-1", action: "start", isImpersonating: true))
        XCTAssertEqual(nativeVMActionPath(vmName: "node-1", action: "restart", isImpersonating: false), "vm/node-1/restart")
    }

    private static func response(for request: URLRequest, status: Int) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil))
    }
}
