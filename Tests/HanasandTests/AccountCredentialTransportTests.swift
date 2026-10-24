import Foundation
import XCTest
@testable import Hanasand

private final class RedirectProbeURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var receivedRequests: [URLRequest] = []

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        receivedRequests = []
    }

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return receivedRequests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.receivedRequests.append(request)
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 307,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://redirect-target.example/collect"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class AccountCredentialTransportTests: XCTestCase {
    func testCredentialSessionDoesNotFollowPostRedirects() async throws {
        RedirectProbeURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectProbeURLProtocol.self]
        let session = AccountCredentialTransport.makeSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: URL(string: "https://identity.example/auth/login/alice")!)
        request.httpMethod = "POST"
        request.httpBody = Data("password=secret".utf8)

        let (_, response) = try await session.data(for: request)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 307)
        XCTAssertEqual(RedirectProbeURLProtocol.requests.count, 1)
        XCTAssertEqual(RedirectProbeURLProtocol.requests.first?.url?.host, "identity.example")
    }
}
