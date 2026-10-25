import Foundation

struct DeveloperAPIReferenceDetails: Equatable {
    let openAPIURL: URL
    let serverURL: URL
    let apiKeyHeader: String
    let firstAPIKeyGETPath: String
    let supportsPageAndLimit: Bool

    var firstAPIKeyGETScope: String {
        let serverPath = serverURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let routePath = firstAPIKeyGETPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = serverPath.isEmpty ? "/\(routePath)" : "/\(serverPath)/\(routePath)"
        return "GET \(path)"
    }
}

enum NativeDeveloperOnboardingContent {
    static let clientInstallCommand = "npm install openapi-fetch"
    static let paginationGuidance = "Use page=1, page=2, and so on. Set limit to the number of records per page, up to 100 (default 50). Responses include pagination.totalPages and pagination.nextPage. A null next page means you have reached the end."

    static func typeGenerationCommand(details: DeveloperAPIReferenceDetails) -> String {
        "npx openapi-typescript \(shellString(details.openAPIURL.absoluteString)) -o src/hanasand-api.d.ts"
    }

    static func apiKeyCurlExample(details: DeveloperAPIReferenceDetails) -> String? {
        guard let url = apiKeyRequestURL(details: details) else { return nil }
        let query = details.supportsPageAndLimit ? "?page=1&limit=20" : ""
        return [
            "curl \(shellString(url.absoluteString + query)) \\",
            "  -H \(shellString("\(details.apiKeyHeader): $HANASAND_API_KEY"))",
        ].joined(separator: "\n")
    }

    static func typedClientExample(details: DeveloperAPIReferenceDetails) -> String {
        let requestOptions = details.supportsPageAndLimit
            ? "\n  params: { query: { page: 1, limit: 20 } }\n"
            : ""
        let serverLiteral = javaScriptStringLiteral(details.serverURL.absoluteString)
        let headerLiteral = javaScriptStringLiteral(details.apiKeyHeader)
        let pathLiteral = javaScriptStringLiteral(details.firstAPIKeyGETPath)
        return """
        import createClient from 'openapi-fetch'
        import type { paths } from './hanasand-api'

        const api = createClient<paths>({
          baseUrl: \(serverLiteral),
          headers: {
            \(headerLiteral): process.env.HANASAND_API_KEY!
          }
        })

        const { data, error } = await api.GET(\(pathLiteral), {\(requestOptions)})
        if (error) throw new Error(error.error.message)
        """
    }

    private static func apiKeyRequestURL(details: DeveloperAPIReferenceDetails) -> URL? {
        guard var components = URLComponents(url: details.serverURL, resolvingAgainstBaseURL: false) else { return nil }
        let serverPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let routePath = details.firstAPIKeyGETPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = serverPath.isEmpty ? "/\(routePath)" : "/\(serverPath)/\(routePath)"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func javaScriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
        return encoded.replacingOccurrences(of: "\\/", with: "/")
    }

    private static func shellString(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
