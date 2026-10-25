import Combine
import Foundation

private final class AccountSubscriptionRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum AccountSubscriptionSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: AccountSubscriptionRedirectDelegate(), delegateQueue: nil)
    }()
}

enum AccountSubscriptionClientError: LocalizedError {
    case signInRequired
    case invalidBaseURL
    case invalidWebsiteURL
    case invalidResponse
    case requestFailed(Int)
    case impersonationUnsupported
    case invalidPortalURL
    case invalidPlan
    case planAlreadyActive
    case checkoutUncertainOutcome
    case invalidCheckoutURL

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to view subscription information."
        case .invalidBaseURL: "Subscription information requires a valid HTTPS API address."
        case .invalidWebsiteURL: "Plan checkout requires a valid HTTPS website address."
        case .invalidResponse: "The subscription service returned an invalid response."
        case let .requestFailed(status): "Subscription request failed (HTTP \(status))."
        case .impersonationUnsupported: "Return to your own account to manage billing."
        case .invalidPortalURL: "The billing service returned an invalid management link."
        case .invalidPlan: "Choose one of the available Hanasand plans."
        case .planAlreadyActive: "This plan is already active. Refresh subscription details."
        case .checkoutUncertainOutcome: "Checkout status is unclear. Check billing before starting another checkout."
        case .invalidCheckoutURL: "The billing service returned an invalid checkout link."
        }
    }
}

struct AccountSubscriptionClient {
    let endpoint: URL
    private let websiteBaseURL: URL?
    let userID: String
    let token: String
    let impersonationToken: String
    var send: (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await AccountSubscriptionSession.shared.data(for: request)
    }

    init(baseURL: URL, websiteBaseURL: URL? = nil, userID: String, token: String, impersonationToken: String = "", send: ((URLRequest) async throws -> (Data, URLResponse))? = nil) throws {
        let cleanUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUserID.isEmpty, !cleanToken.isEmpty else {
            throw AccountSubscriptionClientError.signInRequired
        }
        guard baseURL.scheme?.lowercased() == "https", baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil,
              cleanUserID.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              cleanToken.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else {
            throw AccountSubscriptionClientError.invalidBaseURL
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        guard components?.query == nil, components?.fragment == nil else { throw AccountSubscriptionClientError.invalidBaseURL }
        let path = components?.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.percentEncodedPath = "/" + [path, "billing/subscription"].filter { !$0.isEmpty }.joined(separator: "/")
        guard let endpoint = components?.url, endpoint.scheme == "https", endpoint.host == baseURL.host else {
            throw AccountSubscriptionClientError.invalidBaseURL
        }
        if let websiteBaseURL, !Self.validWebsiteBase(websiteBaseURL) {
            throw AccountSubscriptionClientError.invalidWebsiteURL
        }
        self.endpoint = endpoint
        self.websiteBaseURL = websiteBaseURL
        self.userID = cleanUserID
        self.token = cleanToken
        self.impersonationToken = impersonationToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if let send { self.send = send }
    }

    func load() async throws -> AccountSubscriptionEnvelope {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")
        if !impersonationToken.isEmpty {
            request.setValue(impersonationToken, forHTTPHeaderField: "x-impersonation-token")
        }
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw AccountSubscriptionClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw AccountSubscriptionClientError.requestFailed(http.statusCode) }
        do { return try JSONDecoder().decode(AccountSubscriptionEnvelope.self, from: data) }
        catch { throw AccountSubscriptionClientError.invalidResponse }
    }

    func createBillingPortalURL() async throws -> URL {
        guard impersonationToken.isEmpty else { throw AccountSubscriptionClientError.impersonationUnsupported }
        var request = URLRequest(url: endpoint.deletingLastPathComponent().appendingPathComponent("portal"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw AccountSubscriptionClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw AccountSubscriptionClientError.requestFailed(http.statusCode) }
        guard let payload = try? JSONDecoder().decode(BillingPortalEnvelope.self, from: data),
              let url = URL(string: payload.url),
              url.scheme?.lowercased() == "https", url.host?.lowercased() == "billing.stripe.com",
              url.user == nil, url.password == nil, url.port == nil else {
            throw AccountSubscriptionClientError.invalidPortalURL
        }
        return url
    }

    /// Starts a plan checkout through the website's authenticated session route.
    /// URLSession's redirect delegate rejects automatic redirects, so the only
    /// destination handed to the app is the explicitly validated Stripe URL.
    func createPlanCheckoutURL(for planID: String) async throws -> URL {
        guard impersonationToken.isEmpty else { throw AccountSubscriptionClientError.impersonationUnsupported }
        guard CommercialAccessPlans.all.contains(where: { $0.id == planID }) else {
            throw AccountSubscriptionClientError.invalidPlan
        }
        guard let websiteBaseURL, Self.validWebsiteBase(websiteBaseURL),
              var components = URLComponents(url: websiteBaseURL, resolvingAgainstBaseURL: false) else {
            throw AccountSubscriptionClientError.invalidWebsiteURL
        }
        components.path = "/api/billing/checkout"
        components.queryItems = [URLQueryItem(name: "plan", value: planID)]
        guard let url = components.url, Self.sameOrigin(url, websiteBaseURL) else {
            throw AccountSubscriptionClientError.invalidWebsiteURL
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("id=\(userID); access_token=\(token)", forHTTPHeaderField: "Cookie")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await send(request)
        } catch {
            // The website route can create a Stripe session before the client
            // loses its response. Never retry this mutation automatically.
            throw AccountSubscriptionClientError.checkoutUncertainOutcome
        }
        guard let http = response as? HTTPURLResponse,
              let responseURL = http.url, Self.sameOrigin(responseURL, websiteBaseURL),
              responseURL.path == "/api/billing/checkout" else {
            throw AccountSubscriptionClientError.checkoutUncertainOutcome
        }
        if (300..<400).contains(http.statusCode) {
            guard let rawLocation = http.value(forHTTPHeaderField: "Location"),
                  let checkoutURL = URL(string: rawLocation, relativeTo: responseURL)?.absoluteURL else {
                throw AccountSubscriptionClientError.invalidCheckoutURL
            }
            if Self.sameOrigin(checkoutURL, websiteBaseURL), checkoutURL.path == "/login" {
                throw AccountSubscriptionClientError.signInRequired
            }
            guard Self.validCheckoutURL(checkoutURL) else { throw AccountSubscriptionClientError.invalidCheckoutURL }
            return checkoutURL
        }
        if http.statusCode == 409 { throw AccountSubscriptionClientError.planAlreadyActive }
        if http.statusCode == 408 || http.statusCode >= 500 {
            throw AccountSubscriptionClientError.checkoutUncertainOutcome
        }
        _ = data
        throw AccountSubscriptionClientError.requestFailed(http.statusCode)
    }

    private static func validWebsiteBase(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https",
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return false }
        let path = url.path
        return path.isEmpty || path == "/"
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == "https"
            && lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && lhs.port == rhs.port
            && lhs.user == nil && lhs.password == nil
    }

    private static func validCheckoutURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "checkout.stripe.com"
            && url.user == nil && url.password == nil
            && url.port == nil && url.fragment == nil
    }

    private struct BillingPortalEnvelope: Decodable { let url: String }
}

@MainActor
final class NativePlanCheckoutCoordinator: ObservableObject {
    @Published private(set) var openingPlanID: String?
    @Published private(set) var status = ""

    private var requestID = UUID()
    private var task: Task<Void, Never>?

    func buy(planID: String, model: DesktopAgentModel, source: String) {
        guard openingPlanID == nil else { return }
        guard model.settings.impersonationToken.isEmpty else {
            status = AccountSubscriptionClientError.impersonationUnsupported.localizedDescription
            return
        }
        guard model.hasHanasandAuth else {
            model.openNativeDashboard(path: "/login", label: "Sign in", query: ["path": "/subscription"])
            return
        }

        let currentRequestID = UUID()
        requestID = currentRequestID
        let requestedScope = scope(for: model)
        openingPlanID = planID
        status = ""
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.requestID == currentRequestID {
                    self.openingPlanID = nil
                    self.task = nil
                }
            }
            do {
                guard let apiBaseURL = URL(string: model.settings.apiBaseURL),
                      let websiteBaseURL = URL(string: model.settings.websiteBaseURL) else {
                    throw AccountSubscriptionClientError.invalidBaseURL
                }
                let client = try AccountSubscriptionClient(
                    baseURL: apiBaseURL,
                    websiteBaseURL: websiteBaseURL,
                    userID: model.userIDForRequests,
                    token: model.authTokenForRequests
                )
                let checkoutURL = try await client.createPlanCheckoutURL(for: planID)
                guard !Task.isCancelled, self.requestID == currentRequestID,
                      self.scope(for: model) == requestedScope else { return }
                let didOpen = model.openStripeInAppBrowser(
                    url: checkoutURL.absoluteString,
                    title: "checkout",
                    source: source
                )
                self.status = didOpen
                    ? "Secure Stripe checkout opened in the built-in browser."
                    : "Could not open secure Stripe checkout in the built-in browser."
            } catch {
                guard !Task.isCancelled, self.requestID == currentRequestID,
                      self.scope(for: model) == requestedScope else { return }
                self.status = error.localizedDescription
            }
        }
    }

    func clearStatus() { status = "" }
    func setStatus(_ message: String) { status = message }

    func cancel() {
        requestID = UUID()
        task?.cancel()
        task = nil
        openingPlanID = nil
    }

    private func scope(for model: DesktopAgentModel) -> String {
        [model.settings.apiBaseURL, model.settings.websiteBaseURL, model.userIDForRequests,
         String(model.authTokenForRequests.hashValue), model.settings.impersonatingUserID,
         String(model.settings.impersonationToken.hashValue)].joined(separator: "|")
    }
}
