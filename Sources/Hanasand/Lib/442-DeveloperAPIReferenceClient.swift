import Foundation

private final class DeveloperAPIReferenceRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum DeveloperAPIReferenceError: LocalizedError {
    case invalidURL
    case unavailable(Int)
    case invalidContract
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidURL: "The configured website URL is invalid."
        case .unavailable(let status): "The published API contract is unavailable (HTTP \(status))."
        case .invalidContract: "The published API contract does not contain the secure server and authentication details needed for onboarding."
        case .tooLarge: "The published API contract exceeded the supported size."
        }
    }
}

struct DeveloperAPIReferenceClient {
    private let transport: APIReferenceTransport

    init(transport: APIReferenceTransport? = nil) {
        if let transport {
            self.transport = transport
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            self.transport = URLSession(configuration: configuration, delegate: DeveloperAPIReferenceRedirectDelegate(), delegateQueue: nil)
        }
    }

    func load(websiteBaseURL: String) async throws -> DeveloperAPIReferenceDetails {
        let openAPIURL = try Self.openAPIURL(websiteBaseURL)
        var request = URLRequest(url: openAPIURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await transport.data(for: request)
        guard let response = response as? HTTPURLResponse, response.url == openAPIURL else { throw DeveloperAPIReferenceError.invalidContract }
        guard response.statusCode == 200 else { throw DeveloperAPIReferenceError.unavailable(response.statusCode) }
        guard data.count <= APIReferenceClient.documentLimit else { throw DeveloperAPIReferenceError.tooLarge }
        let document = try APIReferenceDocument.decode(data)
        guard let rawServer = document.servers?.first?.url,
              let serverURL = Self.validServerURL(rawServer),
              let operation = Self.firstSessionGET(in: document),
              operation.row.path.hasPrefix("/"),
              let header = Self.sessionIDHeader(in: document) else {
            throw DeveloperAPIReferenceError.invalidContract
        }
        return DeveloperAPIReferenceDetails(
            openAPIURL: openAPIURL,
            serverURL: serverURL,
            sessionIDHeader: header,
            firstSessionGETPath: operation.row.path,
            supportsPageAndLimit: operation.queryNames.contains("page") && operation.queryNames.contains("limit")
        )
    }

    static func openAPIURL(_ websiteBaseURL: String) throws -> URL {
        guard var components = URLComponents(string: websiteBaseURL),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw DeveloperAPIReferenceError.invalidURL
        }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = "\(basePath)/api/openapi/ti"
        guard let url = components.url else { throw DeveloperAPIReferenceError.invalidURL }
        return url
    }

    private static func validServerURL(_ value: String) -> URL? {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let url = components.url else { return nil }
        return url
    }

    private static func firstSessionGET(in document: APIReferenceDocument) -> (row: APIReferenceOperationRow, queryNames: Set<String>)? {
        let getRows = document.operations.filter { $0.method == "GET" }
        let selected = getRows.first { row in
            let requirements = row.operation.security ?? document.security ?? []
            return allowsSession(requirements)
        } ?? getRows.first
        guard let selected,
              let requirements = selected.operation.security ?? document.security,
              allowsSession(requirements) else { return nil }
        let queryNames = (selected.operation.parameters ?? []).compactMap { parameter -> String? in
            guard case .object(let values) = document.resolvingComponentReferences(in: parameter),
                  case .string("query")? = values["in"],
                  case .string(let name)? = values["name"] else { return nil }
            return name
        }
        return (selected, Set(queryNames))
    }

    private static func allowsSession(_ requirements: [APIReferenceJSONValue]) -> Bool {
        let sessionSchemes: Set<String> = ["SessionBearer", "SessionId"]
        return requirements.contains { requirement in
            guard case .object(let schemes) = requirement else { return false }
            return Set(schemes.keys) == sessionSchemes
        }
    }

    private static func sessionIDHeader(in document: APIReferenceDocument) -> String? {
        guard let components = document.components,
              case .object(let schemes)? = components["securitySchemes"],
              case .object(let bearer)? = schemes["SessionBearer"],
              case .string("http")? = bearer["type"],
              case .string("bearer")? = bearer["scheme"],
              case .object(let sessionID)? = schemes["SessionId"],
              case .string("apiKey")? = sessionID["type"],
              case .string("header")? = sessionID["in"],
              case .string(let name)? = sessionID["name"],
              !name.isEmpty,
              name.unicodeScalars.allSatisfy({ scalar in
                  let value = scalar.value
                  return (value >= 48 && value <= 57)
                      || (value >= 65 && value <= 90)
                      || (value >= 97 && value <= 122)
                      || "!#$%&'*+-.^_`|~".unicodeScalars.contains(scalar)
              }) else { return nil }
        return name
    }
}
