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
        "/actors": {"parameters": [], "get": {"summary": "List actors", "operationId": "listActors", "parameters": [{"$ref": "#/components/parameters/Query"}], "responses": {"200": {"description": "OK", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Actor"}}}}, "404": {"$ref": "#/components/responses/NotFound"}}}},
        "/public": {"post": {"security": [], "requestBody": {"required": true, "content": {"application/json": {"schema": {"type": "object"}}}}, "responses": {"201": {"description": "Created"}}}}
      },
      "components": {"parameters": {"Query": {"name": "q", "in": "query", "schema": {"type": "string"}}}, "responses": {"NotFound": {"description": "Actor not found", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Error"}}}}}, "schemas": {"Actor": {"type": "object", "properties": {"id": {"type": "string"}}}, "Error": {"type": "object", "properties": {"actor": {"$ref": "#/components/schemas/Actor"}}}, "Node": {"type": "object", "properties": {"next": {"$ref": "#/components/schemas/Node"}}}}, "securitySchemes": {"Bearer": {"type": "http", "scheme": "bearer"}}}
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

    func testShowsHumanReadableAccessAndExactKeyScope() throws {
        let document = try APIReferenceDocument.decode(Data(contract.utf8))
        let actor = try XCTUnwrap(document.operations.first)
        XCTAssertEqual(APIReferenceSecurity.accessLabel(operation: actor.operation.security, document: document.security), "Bearer")

        let keyOrSession: [APIReferenceJSONValue] = [
            .object(["ApiKey": .array([])]),
            .object(["SessionBearer": .array([]), "SessionId": .array([])])
        ]
        XCTAssertEqual(APIReferenceSecurity.accessLabel(operation: keyOrSession, document: nil), "API key or session")
        XCTAssertEqual(APIReferenceSecurity.apiKeyScope(method: actor.method, path: actor.path, operation: keyOrSession, document: nil, serverURL: document.servers?.first?.url), "GET /v1/actors")

        let publicOperation = try XCTUnwrap(document.operations.last)
        XCTAssertEqual(APIReferenceSecurity.accessLabel(operation: publicOperation.operation.security, document: document.security), "Anonymous")
        XCTAssertNil(APIReferenceSecurity.apiKeyScope(method: publicOperation.method, path: publicOperation.path, operation: publicOperation.operation.security, document: document.security, serverURL: document.servers?.first?.url))
        XCTAssertEqual(APIReferenceSecurity.accessLabel(operation: [.object([:]), .object(["ApiKey": .array([])])], document: nil), "Anonymous")

        let actorWithoutExplicitSecurity = APIReferenceSecurity.apiKeyScope(method: "GET", path: "/actors", operation: nil, document: nil, serverURL: "https://api.example.test/api/v1/")
        XCTAssertEqual(actorWithoutExplicitSecurity, "GET /api/v1/actors")
        XCTAssertNil(APIReferenceSecurity.apiKeyScope(method: "GET", path: "/actors", operation: [], document: nil, serverURL: "https://api.example.test/api/v1"))
    }

    func testCommonErrorSummaryIncludesOnlyKnownResponsesPresentInTheContract() throws {
        let responseDocument = #"""
        {"openapi":"3.1.0","info":{"title":"Example API","version":"1"},"paths":{},"components":{"responses":{"BadRequest":{"description":"The request is invalid."},"Unavailable":{"$ref":"#/components/responses/BadRequest"},"NotFound":{"description":"Not included in the common summary."}}}}
        """#
        let document = try APIReferenceDocument.decode(Data(responseDocument.utf8))

        XCTAssertEqual(document.commonErrorResponses.map(\.name), ["BadRequest", "Unavailable"])
        let resolved = document.resolvingComponentReferences(in: try XCTUnwrap(document.commonErrorResponses.last?.value))
        XCTAssertEqual(resolved.objectValue?["description"], .string("The request is invalid."))
    }

    func testResolvesNestedComponentReferencesInOperationDetails() throws {
        let document = try APIReferenceDocument.decode(Data(contract.utf8))
        let operation = try XCTUnwrap(document.operations.first?.operation)

        let parameters = document.resolvingComponentReferences(in: .array(try XCTUnwrap(operation.parameters)))
        guard case .array(let parameterRows) = parameters,
              case .object(let parameter) = parameterRows.first else {
            return XCTFail("Expected the referenced query parameter to be expanded")
        }
        XCTAssertEqual(parameter["name"], .string("q"))
        XCTAssertEqual(parameter["in"], .string("query"))

        let response = try XCTUnwrap(operation.responses["404"])
        let expandedResponse = document.resolvingComponentReferences(in: response)
        XCTAssertEqual(expandedResponse.objectValue?["description"], .string("Actor not found"))
        let content = expandedResponse.objectValue?["content"]?.objectValue?["application/json"]?.objectValue
        let schema = content?["schema"]?.objectValue
        XCTAssertEqual(schema?["properties"]?.objectValue?["actor"]?.objectValue?["type"], .string("object"))
    }

    func testLeavesUnsupportedAndCyclicReferencesVisible() throws {
        let document = try APIReferenceDocument.decode(Data(contract.utf8))
        let external = APIReferenceJSONValue.object(["$ref": .string("https://example.test/schema.json")])
        XCTAssertEqual(document.resolvingComponentReferences(in: external), external)

        let recursive = APIReferenceJSONValue.object(["$ref": .string("#/components/schemas/Node")])
        let expanded = document.resolvingComponentReferences(in: recursive)
        let next = expanded.objectValue?["properties"]?.objectValue?["next"]?.objectValue
        XCTAssertEqual(next?["$ref"], .string("#/components/schemas/Node"))
    }

    func testJSONPagingUsesMobileSizedPagesAndPreservesUnicodeBoundaries() {
        let ascii = String(repeating: "x", count: APIReferenceJSONPages.pageSize * 2 + 1)
        let pages = APIReferenceJSONPages.split(ascii)
        XCTAssertEqual(pages.map { $0.utf16.count }, [8_000, 8_000, 1])
        XCTAssertEqual(pages.joined(), ascii)

        let unicode = String(repeating: "a", count: APIReferenceJSONPages.pageSize - 1) + "😀" + "tail"
        let unicodePages = APIReferenceJSONPages.split(unicode)
        XCTAssertEqual(unicodePages.count, 2)
        XCTAssertEqual(unicodePages.first?.utf16.count, APIReferenceJSONPages.pageSize - 1)
        XCTAssertEqual(unicodePages.joined(), unicode)
        XCTAssertTrue(unicodePages[1].hasPrefix("😀"))
        XCTAssertEqual(APIReferenceJSONPages.split("").count, 1)
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
        model.query = "id"
        XCTAssertEqual(model.filteredSchemas.map { $0.0 }, ["Actor"])
    }

    @MainActor
    func testResultPagingMatchesMobileBatchBehaviorAndResetsOnSearchAndSectionChanges() async throws {
        let transport = APIReferenceStubTransport(data: Data(contract.utf8), status: 200)
        let model = APIReferenceModel(client: APIReferenceClient(transport: transport))
        await model.refresh(websiteBaseURL: "https://hanasand.com")

        model.selectSection(.applicationAPI)
        XCTAssertEqual(model.visibleEntryTotal, 36)
        XCTAssertEqual(model.visibleEntryCount, APIReferenceModel.entryPageSize)
        model.showMoreEntries()
        XCTAssertEqual(model.visibleEntryCount, 36)

        model.setQuery("billing")
        XCTAssertEqual(model.visibleEntryCount, APIReferenceModel.entryPageSize)
        XCTAssertEqual(model.visibleEntryTotal, 2)

        model.setQuery("")
        model.showMoreEntries()
        XCTAssertEqual(model.visibleEntryCount, 36)
        model.selectSection(.schemas)
        XCTAssertEqual(model.visibleEntryCount, APIReferenceModel.entryPageSize)
        XCTAssertEqual(model.visibleEntryTotal, 3)
    }

    @MainActor
    func testOpenAPIJSONRouteCanInitializeRawJSONSection() {
        let model = APIReferenceModel(section: .json)
        XCTAssertEqual(model.section, .json)
    }
}
