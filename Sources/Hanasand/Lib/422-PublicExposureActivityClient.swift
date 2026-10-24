import Foundation
import Combine

private final class PublicExposureActivityRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum PublicExposureActivitySession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: PublicExposureActivityRedirectBlocker(), delegateQueue: nil)
    }()
}

struct PublicExposureActivityClient {
    typealias Sender = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    enum ClientError: LocalizedError {
        case invalidEndpoint
        case invalidResponse
        case httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint: return "The public activity endpoint is invalid."
            case .invalidResponse: return "The public activity service returned an invalid response."
            case .httpStatus(let status): return "The public activity service returned HTTP \(status)."
            }
        }
    }

    static let endpoint = URL(string: "https://hanasand.com/api/public/exposure-queue")!
    private let send: Sender

    init(send: @escaping Sender = { request in try await PublicExposureActivitySession.shared.data(for: request) }) {
        self.send = send
    }

    func load(filters: PublicExposureActivityFilters, offset: Int = 0, limit: Int = 50) async throws -> PublicExposureActivityPage {
        guard var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false) else {
            throw ClientError.invalidEndpoint
        }
        components.queryItems = filters.queryItems(limit: limit, offset: offset)
        guard let url = components.url, url.scheme == "https", url.host == "hanasand.com" else {
            throw ClientError.invalidEndpoint
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await send(request)
        guard data.count <= 4 * 1024 * 1024,
              let http = response as? HTTPURLResponse,
              response.url?.scheme == "https", response.url?.host == "hanasand.com" else {
            throw ClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else { throw ClientError.httpStatus(http.statusCode) }
        do { return try JSONDecoder().decode(PublicExposureActivityPage.self, from: data) }
        catch { throw ClientError.invalidResponse }
    }
}

@MainActor
final class PublicExposureActivityViewModel: ObservableObject {
    @Published private(set) var page: PublicExposureActivityPage?
    @Published private(set) var items: [PublicExposureActivityPage.Item] = []
    @Published private(set) var nextOffset: Int?
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var errorMessage: String?

    private let client: PublicExposureActivityClient
    private var generation = UUID()

    init(client: PublicExposureActivityClient = PublicExposureActivityClient()) { self.client = client }

    func refresh(filters: PublicExposureActivityFilters) async {
        let requestID = UUID(); generation = requestID
        isLoading = true; errorMessage = nil
        defer { if generation == requestID { isLoading = false } }
        do {
            let result = try await client.load(filters: filters)
            guard generation == requestID, !Task.isCancelled else { return }
            page = result; items = result.items; nextOffset = result.nextOffset
        } catch {
            guard generation == requestID else { return }
            errorMessage = "Activity could not refresh. \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    func loadMore(filters: PublicExposureActivityFilters) async {
        guard !isLoadingMore, let offset = nextOffset else { return }
        let requestID = generation; isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let result = try await client.load(filters: filters, offset: offset)
            guard generation == requestID, !Task.isCancelled else { return }
            page = result
            items = PublicExposureActivityPage.Item.merge(items, result.items, appending: true)
            nextOffset = result.nextOffset
            errorMessage = nil
        } catch {
            guard generation == requestID else { return }
            errorMessage = "More activity could not load. \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }
}
