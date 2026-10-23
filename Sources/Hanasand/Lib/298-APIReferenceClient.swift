import Combine
import Foundation

protocol APIReferenceTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: APIReferenceTransport {}

private final class APIReferenceRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct APIReferenceLoadedDocument {
    let document: APIReferenceDocument
    let rawJSON: String
}

struct APIReferenceClient {
    static let documentLimit = 2 * 1024 * 1024
    private let transport: APIReferenceTransport

    init(transport: APIReferenceTransport? = nil) {
        if let transport {
            self.transport = transport
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            self.transport = URLSession(configuration: configuration, delegate: APIReferenceRedirectDelegate(), delegateQueue: nil)
        }
    }

    func load(websiteBaseURL: String) async throws -> APIReferenceLoadedDocument {
        let url = try Self.openAPIURL(websiteBaseURL)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await transport.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIReferenceError.invalidDocument }
        guard response.statusCode == 200 else { throw APIReferenceError.unavailable(response.statusCode) }
        guard data.count <= Self.documentLimit else { throw APIReferenceError.tooLarge }
        let document = try APIReferenceDocument.decode(data)
        guard let rawJSON = String(data: data, encoding: .utf8) else { throw APIReferenceError.invalidDocument }
        return APIReferenceLoadedDocument(document: document, rawJSON: rawJSON)
    }

    static func openAPIURL(_ websiteBaseURL: String) throws -> URL {
        guard var components = URLComponents(string: websiteBaseURL), components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              let host = components.host, !host.isEmpty else { throw APIReferenceError.invalidURL }
        if ["hanasand.com", "www.hanasand.com"].contains(host.lowercased()), components.port == nil {
            return URL(string: "https://ti.hanasand.com/api/openapi/ti")!
        }
        components.path = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path += "/api/openapi/ti"
        guard let url = components.url else { throw APIReferenceError.invalidURL }
        return url
    }
}

@MainActor
final class APIReferenceModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case publicAPI = "Public API"
        case applicationAPI = "Application API"
        case schemas = "Schemas"
        case json = "OpenAPI JSON"
        var id: String { rawValue }
    }

    @Published private(set) var document: APIReferenceDocument?
    @Published private(set) var rawJSON = ""
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage = ""
    @Published var query = ""
    @Published var section: Section = .publicAPI
    @Published var expandedRows: Set<String> = []
    @Published var expandedSchemas: Set<String> = []

    private let client: APIReferenceClient
    private var requestGeneration = 0

    init(client: APIReferenceClient = APIReferenceClient()) { self.client = client }

    var operationRows: [APIReferenceOperationRow] {
        let rows: [APIReferenceOperationRow]
        if section == .applicationAPI {
            rows = APIReferenceSnapshot.current.applicationEndpoints.map { endpoint in
                APIReferenceOperationRow(method: endpoint.method, path: endpoint.path,
                    operation: APIReferenceDocument.Operation(summary: endpoint.summary, description: nil, operationId: nil,
                        security: nil, parameters: nil, requestBody: nil, responses: [:]))
            }
        } else {
            rows = document?.operations ?? []
        }
        return rows.filter { $0.matches(query) }
    }

    var filteredSchemas: [(String, APIReferenceJSONValue)] {
        (document?.schemas ?? [:]).filter { name, value in
            query.isEmpty || "\(name) \(value.prettyJSON)".localizedCaseInsensitiveContains(query.trimmingCharacters(in: .whitespacesAndNewlines))
        }.sorted { $0.key < $1.key }
    }

    func refresh(websiteBaseURL: String) async {
        requestGeneration += 1
        let generation = requestGeneration
        isLoading = true
        errorMessage = ""
        do {
            let loaded = try await client.load(websiteBaseURL: websiteBaseURL)
            guard generation == requestGeneration, !Task.isCancelled else { return }
            document = loaded.document
            rawJSON = loaded.rawJSON
        } catch {
            guard generation == requestGeneration, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
        if generation == requestGeneration { isLoading = false }
    }

    func invalidate() {
        requestGeneration += 1
        isLoading = false
    }

    func toggleOperation(_ id: String) {
        if expandedRows.contains(id) { expandedRows.remove(id) } else { expandedRows.insert(id) }
    }

    func toggleSchema(_ name: String) {
        if expandedSchemas.contains(name) { expandedSchemas.remove(name) } else { expandedSchemas.insert(name) }
    }
}
