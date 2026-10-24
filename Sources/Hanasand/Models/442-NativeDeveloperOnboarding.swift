import Foundation

struct DeveloperAPIReferenceDetails: Equatable {
    let openAPIURL: URL
    let serverURL: URL
    let sessionIDHeader: String
    let firstSessionGETPath: String
    let supportsPageAndLimit: Bool

    var eventIntakeURL: URL? {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/mill"
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

enum NativeDeveloperOnboardingContent {
    static let clientInstallCommand = "npm install openapi-fetch"
    static let paginationGuidance = "Use page=1, page=2, and so on. Set limit to the number of records per page, up to 100 (default 50). Responses include pagination.totalPages and pagination.nextPage. A null next page means you have reached the end."

    static func typeGenerationCommand(details: DeveloperAPIReferenceDetails) -> String {
        "npx openapi-typescript \(shellString(details.openAPIURL.absoluteString)) -o src/hanasand-api.d.ts"
    }

    static func eventIntakeCommand(details: DeveloperAPIReferenceDetails) -> String? {
        guard let url = details.eventIntakeURL else { return nil }
        return [
            "curl \(shellString(url.absoluteString)) \\",
            "  -H 'Authorization: Bearer $HANASAND_API_KEY' \\",
            "  -H 'Content-Type: application/json' \\",
            "  --data \"$HANASAND_EVENT_JSON\"",
        ].joined(separator: "\n")
    }

    static func typedClientExample(details: DeveloperAPIReferenceDetails) -> String {
        let requestOptions = details.supportsPageAndLimit
            ? "\n  params: { query: { page: 1, limit: 20 } }\n"
            : ""
        let serverLiteral = javaScriptStringLiteral(details.serverURL.absoluteString)
        let headerLiteral = javaScriptStringLiteral(details.sessionIDHeader)
        let pathLiteral = javaScriptStringLiteral(details.firstSessionGETPath)
        return """
        import createClient from 'openapi-fetch'
        import type { paths } from './hanasand-api'

        const api = createClient<paths>({
          baseUrl: \(serverLiteral),
          headers: {
            Authorization: `Bearer ${process.env.HANASAND_SESSION_BEARER!}`,
            \(headerLiteral): process.env.HANASAND_SESSION_ID!
          }
        })

        const { data, error } = await api.GET(\(pathLiteral), {\(requestOptions)})
        if (error) throw new Error(error.error.message)
        """
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
