import Foundation
import Combine

struct PublicStatusClient {
    typealias Sender = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    enum ClientError: LocalizedError {
        case invalidEndpoint
        case invalidResponse
        case httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint: return "The public status endpoint is invalid."
            case .invalidResponse: return "The public status service returned an invalid response."
            case .httpStatus(let status): return "The public status service returned HTTP \(status)."
            }
        }
    }

    static let endpoint = URL(string: "https://status.hanasand.com/api/status")!
    private let send: Sender

    init(send: @escaping Sender = { request in try await URLSession.shared.data(for: request) }) {
        self.send = send
    }

    func dashboard() async throws -> PublicStatusPayload {
        try await fetch(query: [URLQueryItem(name: "dashboard", value: "true")])
    }

    func incident(id: String) async throws -> PublicStatusPayload {
        try await fetch(query: [URLQueryItem(name: "incident", value: id)])
    }

    private func fetch(query: [URLQueryItem]) async throws -> PublicStatusPayload {
        guard var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false) else {
            throw ClientError.invalidEndpoint
        }
        components.queryItems = query
        guard let url = components.url else { throw ClientError.invalidEndpoint }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request)
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw ClientError.httpStatus(response.statusCode) }
        return try JSONDecoder().decode(PublicStatusPayload.self, from: data)
    }
}

@MainActor
final class PublicStatusViewModel: ObservableObject {
    @Published private(set) var payload: PublicStatusPayload?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var selectedIncident: PublicStatusIncident?
    @Published private(set) var isLoadingIncident = false
    @Published private(set) var incidentError: String?

    private let client: PublicStatusClient

    init(client: PublicStatusClient = PublicStatusClient()) {
        self.client = client
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            payload = try await client.dashboard()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectIncident(_ incident: PublicStatusIncident) async {
        selectedIncident = incident
        isLoadingIncident = true
        incidentError = nil
        defer { isLoadingIncident = false }
        do {
            let detail = try await client.incident(id: incident.id)
            selectedIncident = detail.incidents.first(where: { $0.id == incident.id || $0.aliases?.contains(incident.id) == true }) ?? detail.incidents.first ?? incident
        } catch {
            incidentError = error.localizedDescription
        }
    }

    func clearSelectedIncident() {
        selectedIncident = nil
        incidentError = nil
    }
}
