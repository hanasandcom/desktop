import Foundation
import XCTest
@testable import Hanasand

private struct DeveloperOnboardingStubTransport: APIReferenceTransport {
    let data: Data
    let status: Int

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }
}

private final class DeveloperOnboardingRetryTransport: APIReferenceTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let data: Data
    private let statuses: [Int]
    private var index = 0

    init(data: Data, statuses: [Int]) {
        self.data = data
        self.statuses = statuses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let status = nextStatus()
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }

    private func nextStatus() -> Int {
        lock.lock()
        let status = statuses[min(index, statuses.count - 1)]
        index += 1
        lock.unlock()
        return status
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return index
    }
}

final class DeveloperOnboardingTests: XCTestCase {
    private let contract = #"""
    {
      "openapi": "3.1.0",
      "info": {"title": "Example API", "version": "1.2"},
      "servers": [{"url": "https://api.example.test/api/v1"}],
      "security": [{"ApiKey": []}, {"SessionBearer": [], "SessionId": []}],
      "paths": {
        "/0-session-only": {"get": {"security": [{"SessionBearer": [], "SessionId": []}], "responses": {"200": {"description": "OK"}}}},
        "/actors": {"get": {"summary": "List actors", "security": [{"ApiKey": []}, {"SessionBearer": [], "SessionId": []}], "parameters": [{"$ref": "#/components/parameters/Page"}, {"$ref": "#/components/parameters/Limit"}], "responses": {"200": {"description": "OK"}}}},
        "/public-search": {"get": {"security": [], "responses": {"200": {"description": "OK"}}}}
      },
      "components": {"parameters": {"Page": {"name": "page", "in": "query", "schema": {"type": "integer"}}, "Limit": {"name": "limit", "in": "query", "schema": {"type": "integer"}}}, "securitySchemes": {"ApiKey": {"type": "apiKey", "in": "header", "name": "X-API-Key"}, "SessionBearer": {"type": "http", "scheme": "bearer"}, "SessionId": {"type": "apiKey", "in": "header", "name": "id"}}}
    }
    """#

    func testLoadsLiveContractAndBuildsAccurateOnboardingExamples() async throws {
        let client = DeveloperAPIReferenceClient(transport: DeveloperOnboardingStubTransport(data: Data(contract.utf8), status: 200))
        let details = try await client.load(websiteBaseURL: "https://hanasand.com")

        XCTAssertEqual(details.openAPIURL.absoluteString, "https://hanasand.com/api/openapi/ti")
        XCTAssertEqual(details.serverURL.absoluteString, "https://api.example.test/api/v1")
        XCTAssertEqual(details.apiKeyHeader, "X-API-Key")
        XCTAssertEqual(details.firstAPIKeyGETPath, "/actors")
        XCTAssertEqual(details.firstAPIKeyGETScope, "GET /api/v1/actors")
        XCTAssertTrue(details.supportsPageAndLimit)

        let typeGeneration = NativeDeveloperOnboardingContent.typeGenerationCommand(details: details)
        XCTAssertTrue(typeGeneration.contains(details.openAPIURL.absoluteString))
        XCTAssertTrue(typeGeneration.contains("openapi-typescript"))
        XCTAssertEqual(NativeDeveloperOnboardingContent.clientInstallCommand, "npm install openapi-fetch")

        let curlExample = try XCTUnwrap(NativeDeveloperOnboardingContent.apiKeyCurlExample(details: details))
        XCTAssertTrue(curlExample.contains("https://api.example.test/api/v1/actors?page=1&limit=20"))
        XCTAssertEqual(curlExample.components(separatedBy: "\n").last, "  -H 'X-API-Key: '\"$HANASAND_API_KEY\"")
        XCTAssertTrue(curlExample.contains("$HANASAND_API_KEY"), "The shell variable is passed for expansion at runtime.")
        XCTAssertFalse(curlExample.contains("actual-test-secret"), "The generated command must not contain a live key.")
        XCTAssertFalse(curlExample.contains("Authorization: Bearer"))
        XCTAssertFalse(curlExample.contains("YOUR_API_KEY"))

        let typedClient = NativeDeveloperOnboardingContent.typedClientExample(details: details)
        XCTAssertTrue(typedClient.contains("baseUrl: \"https://api.example.test/api/v1\""))
        XCTAssertTrue(typedClient.contains("\"X-API-Key\": process.env.HANASAND_API_KEY!"))
        XCTAssertTrue(typedClient.contains("api.GET(\"/actors\""))
        XCTAssertTrue(typedClient.contains("page: 1, limit: 20"))
        XCTAssertFalse(typedClient.contains("YOUR_API_KEY"))
        XCTAssertFalse(typedClient.contains("HANASAND_SESSION_BEARER"))
    }

    func testSelectsFirstGETWhoseSecurityRequirementCanBeSatisfiedByTheOrganizationKey() async throws {
        let client = DeveloperAPIReferenceClient(transport: DeveloperOnboardingStubTransport(data: Data(contract.utf8), status: 200))
        let details = try await client.load(websiteBaseURL: "https://hanasand.com")
        XCTAssertEqual(details.firstAPIKeyGETPath, "/actors")
    }

    func testContractLoadCanBeRetriedAfterTransientFailure() async throws {
        let transport = DeveloperOnboardingRetryTransport(data: Data(contract.utf8), statuses: [503, 200])
        let client = DeveloperAPIReferenceClient(transport: transport)
        do {
            _ = try await client.load(websiteBaseURL: "https://hanasand.com")
            XCTFail("Expected the first contract request to fail")
        } catch { XCTAssertTrue(error is DeveloperAPIReferenceError) }

        let details = try await client.load(websiteBaseURL: "https://hanasand.com")
        XCTAssertEqual(details.firstAPIKeyGETPath, "/actors")
        XCTAssertEqual(transport.requestCount, 2)
    }

    func testOmitsPaginationOptionsWhenContractDoesNotDeclareThem() async throws {
        let withoutPagination = contract.replacingOccurrences(of: ", \"parameters\": [{\"$ref\": \"#/components/parameters/Page\"}, {\"$ref\": \"#/components/parameters/Limit\"}]", with: "")
        let withoutParameters = withoutPagination.replacingOccurrences(of: "\"parameters\": {\"Page\": {\"name\": \"page\", \"in\": \"query\", \"schema\": {\"type\": \"integer\"}}, \"Limit\": {\"name\": \"limit\", \"in\": \"query\", \"schema\": {\"type\": \"integer\"}}}, ", with: "")
        let client = DeveloperAPIReferenceClient(transport: DeveloperOnboardingStubTransport(data: Data(withoutParameters.utf8), status: 200))
        let details = try await client.load(websiteBaseURL: "https://hanasand.com")
        XCTAssertFalse(details.supportsPageAndLimit)
        XCTAssertFalse(NativeDeveloperOnboardingContent.typedClientExample(details: details).contains("params: { query:"))
    }

    func testRejectsContractsWithInsecureServersOrNoAPIKeyAuthorizedGet() async {
        let insecure = contract.replacingOccurrences(of: "https://api.example.test/api/v1", with: "http://api.example.test/api/v1")
        let noAPIKeyGet = contract.replacingOccurrences(of: "{\"ApiKey\": []}, ", with: "")

        for value in [insecure, noAPIKeyGet] {
            let client = DeveloperAPIReferenceClient(transport: DeveloperOnboardingStubTransport(data: Data(value.utf8), status: 200))
            do {
                _ = try await client.load(websiteBaseURL: "https://hanasand.com")
                XCTFail("Expected an invalid contract to be rejected")
            } catch { XCTAssertTrue(error is DeveloperAPIReferenceError) }
        }
    }

    func testDoesNotUseRouteThatAlsoRequiresASession() async {
        let keyAndSessionRequired = contract.replacingOccurrences(
            of: "\"security\": [{\"ApiKey\": []}, {\"SessionBearer\": [], \"SessionId\": []}]",
            with: "\"security\": [{\"ApiKey\": [], \"SessionBearer\": [], \"SessionId\": []}]"
        )
        let client = DeveloperAPIReferenceClient(transport: DeveloperOnboardingStubTransport(data: Data(keyAndSessionRequired.utf8), status: 200))
        do {
            _ = try await client.load(websiteBaseURL: "https://hanasand.com")
            XCTFail("A route requiring a key and session should not be used in a key-only example")
        } catch { XCTAssertTrue(error is DeveloperAPIReferenceError) }
    }

    func testPaginationGuidanceDocumentsBoundsAndEndCondition() {
        XCTAssertTrue(NativeDeveloperOnboardingContent.paginationGuidance.contains("page=1"))
        XCTAssertTrue(NativeDeveloperOnboardingContent.paginationGuidance.contains("up to 100"))
        XCTAssertTrue(NativeDeveloperOnboardingContent.paginationGuidance.contains("default 50"))
        XCTAssertTrue(NativeDeveloperOnboardingContent.paginationGuidance.contains("pagination.totalPages"))
        XCTAssertTrue(NativeDeveloperOnboardingContent.paginationGuidance.contains("pagination.nextPage"))
        XCTAssertTrue(NativeDeveloperOnboardingContent.paginationGuidance.contains("null next page means you have reached the end"))
    }
}
