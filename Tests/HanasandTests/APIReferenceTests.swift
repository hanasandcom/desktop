import Foundation
import XCTest
@testable import Hanasand

private struct APIReferenceStubTransport: APIReferenceTransport {
    let data: Data
    let status: Int
    var capturedRequest: ((URLRequest) -> Void)?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        capturedRequest?(request)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }
}

final class APIReferenceTests: XCTestCase {
    private let contract = #"""
    {
      "openapi": "3.1.0",
      "info": {"title": "Example API", "version": "1.2", "description": "A synthetic contract"},
      "servers": [{"url": "https://api.example.test/v1"}],
      "security": [{"Bearer": []}],
      "paths": {
        "/actors": {"parameters": [], "get": {"summary": "List actors", "operationId": "listActors", "responses": {"200": {"description": "OK", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Actor"}}}}}}},
        "/public": {"post": {"security": [], "requestBody": {"required": true, "content": {"application/json": {"schema": {"type": "object"}}}}, "responses": {"201": {"description": "Created"}}}}
      },
      "components": {"schemas": {"Actor": {"type": "object", "properties": {"id": {"type": "string"}}}}, "securitySchemes": {"Bearer": {"type": "http", "scheme": "bearer"}}}
    }
    """#

    func testUsesCanonicalPublicContractAndRejectsUnsafeWebsiteURLs() throws {
        XCTAssertEqual(try APIReferenceClient.openAPIURL("https://hanasand.com").absoluteString, "https://ti.hanasand.com/api/openapi/ti")
        XCTAssertEqual(try APIReferenceClient.openAPIURL("https://www.hanasand.com/").absoluteString, "https://ti.hanasand.com/api/openapi/ti")
        XCTAssertEqual(try APIReferenceClient.openAPIURL("https://custom.example/base/").absoluteString, "https://custom.example/base/api/openapi/ti")
        for value in ["http://custom.example", "https://user:secret@custom.example", "https://custom.example?token=secret", "https://custom.example/#fragment"] {
            XCTAssertThrowsError(try APIReferenceClient.openAPIURL(value))
        }
    }

    func testDecodesOperationsSchemasSecurityAndRequestBodies() throws {
        let document = try APIReferenceDocument.decode(Data(contract.utf8))
        XCTAssertEqual(document.info.title, "Example API")
        XCTAssertEqual(document.operations.map { $0.id }, ["GET /actors", "POST /public"])
        XCTAssertEqual(document.schemas["Actor"]?.objectValue?["type"], APIReferenceJSONValue.string("object"))
        XCTAssertEqual(document.security?.count, 1)
        XCTAssertEqual(document.operations.first?.operation.responses["200"]?.objectValue?["description"], APIReferenceJSONValue.string("OK"))
        XCTAssertNotNil(document.operations.last?.operation.requestBody)
        XCTAssertEqual(APIReferenceSecurity.label(operation: nil, document: document.security), "Bearer")
        XCTAssertEqual(APIReferenceSecurity.label(operation: [], document: document.security), "Public")
        XCTAssertEqual(APIReferenceSecurity.label(operation: [.object([:])], document: document.security), "Public")
        XCTAssertEqual(APIReferenceSecurity.label(operation: nil, document: nil), "Public (no security requirement declared)")
    }

    func testRejectsMalformedOrOversizedContractsAndNonOpenAPIResponses() {
        for value in ["{}", "not-json", #"{"openapi":"2.0","info":{"title":"old","version":"1"},"paths":{}}"#, #"{"openapi":"3.1.0","info":{"title":"missing version"},"paths":{}}"#, #"{"openapi":"3.1.0","info":{"title":"broken","version":"1"},"paths":{"bad":{}}}"#] {
            XCTAssertThrowsError(try APIReferenceDocument.decode(Data(value.utf8)))
        }
        XCTAssertThrowsError(try APIReferenceDocument.decode(Data(repeating: 32, count: APIReferenceClient.documentLimit + 1)))
    }

    func testClientSendsUnauthenticatedNoCookieRequestAndRejectsServiceErrors() async throws {
        var captured: URLRequest?
        let transport = APIReferenceStubTransport(data: Data(contract.utf8), status: 200) { captured = $0 }
        let loaded = try await APIReferenceClient(transport: transport).load(websiteBaseURL: "https://hanasand.com")
        XCTAssertEqual(loaded.document.info.title, "Example API")
        XCTAssertEqual(captured?.url?.absoluteString, "https://ti.hanasand.com/api/openapi/ti")
        XCTAssertEqual(captured?.httpMethod, "GET")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(captured?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(captured?.value(forHTTPHeaderField: "id"))
        XCTAssertFalse(captured?.httpShouldHandleCookies ?? true)

        do {
            _ = try await APIReferenceClient(transport: APIReferenceStubTransport(data: Data("{}".utf8), status: 503)).load(websiteBaseURL: "https://hanasand.com")
            XCTFail("Expected HTTP error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("503")) }
    }

    func testPinnedApplicationSnapshotHasExamplesForEachDocumentedOperation() {
        let snapshot = APIReferenceSnapshot.current
        XCTAssertEqual(snapshot.documentationSource, "a71de4414381d2dc11ae03d3a912dba96223e538")
        XCTAssertEqual(snapshot.applicationEndpoints.count, 36)
        XCTAssertEqual(snapshot.responseExamples.count, 48)
        XCTAssertEqual(Set(snapshot.applicationEndpoints.map(\.id)).count, snapshot.applicationEndpoints.count)
        XCTAssertTrue(snapshot.applicationEndpoints.allSatisfy { snapshot.responseExamples[$0.id] != nil })
        XCTAssertEqual(snapshot.responseExamples["GET /ti/enrichment"]?.status, 410)
    }

    @MainActor
    func testModelSearchMatchesMethodsPathsDescriptionsAndSchemas() async throws {
        let transport = APIReferenceStubTransport(data: Data(contract.utf8), status: 200)
        let model = APIReferenceModel(client: APIReferenceClient(transport: transport))
        await model.refresh(websiteBaseURL: "https://hanasand.com")
        XCTAssertTrue(model.errorMessage.isEmpty)
        model.query = "listActors"
        XCTAssertEqual(model.operationRows.map { $0.id }, ["GET /actors"])
        model.section = APIReferenceModel.Section.schemas
        model.query = "Actor"
        XCTAssertEqual(model.filteredSchemas.map { $0.0 }, ["Actor"])
    }
}
