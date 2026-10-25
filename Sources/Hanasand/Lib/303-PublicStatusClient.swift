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
        // The public status route defaults to the compact dashboard projection.
        // Desktop also exposes the website's full incident/history view.
        try await fetch(query: [URLQueryItem(name: "history", value: "true")])
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
    static let dashboardRefreshInterval: Duration = .seconds(3)
    static let incidentRefreshInterval: Duration = .seconds(30)

    @Published private(set) var payload: PublicStatusPayload?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var selectedIncident: PublicStatusIncident?
    @Published private(set) var isLoadingIncident = false
    @Published private(set) var incidentError: String?

    private let client: PublicStatusClient
    private let snapshotStore: PublicStatusSnapshotStore
    private let sleep: @Sendable (Duration) async throws -> Void
    private var activeScope: String?
    private var scopeGeneration = 0

    init(
        client: PublicStatusClient = PublicStatusClient(),
        snapshotStore: PublicStatusSnapshotStore = PublicStatusSnapshotStore(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.snapshotStore = snapshotStore
        self.sleep = sleep
        payload = snapshotStore.load()
    }

    func refresh() async {
        activateScope("dashboard")
        await refreshDashboard(in: scopeGeneration)
    }

    private func refreshDashboard(in generation: Int) async {
        guard activeScope == "dashboard", generation == scopeGeneration else { return }
        isLoading = true
        errorMessage = nil
        defer {
            if activeScope == "dashboard", generation == scopeGeneration { isLoading = false }
        }
        do {
            let freshPayload = try await client.dashboard()
            guard !Task.isCancelled, activeScope == "dashboard", generation == scopeGeneration else { return }
            payload = freshPayload
            snapshotStore.save(freshPayload)
        } catch {
            guard !Task.isCancelled, activeScope == "dashboard", generation == scopeGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadIncident(id: String) async {
        let requestedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedID.isEmpty else {
            incidentError = "This incident link is invalid."
            return
        }
        activateScope("incident:\(requestedID)")
        await refreshIncident(id: requestedID, in: scopeGeneration, initial: true)
    }

    private func refreshIncident(id requestedID: String, in generation: Int, initial: Bool = false) async {
        guard activeScope == "incident:\(requestedID)", generation == scopeGeneration else { return }
        isLoading = true
        isLoadingIncident = initial || isLoadingIncident
        errorMessage = nil
        incidentError = nil
        defer {
            if activeScope == "incident:\(requestedID)", generation == scopeGeneration {
                isLoading = false
                isLoadingIncident = false
            }
        }
        do {
            let detail = try await client.incident(id: requestedID)
            guard !Task.isCancelled, activeScope == "incident:\(requestedID)", generation == scopeGeneration else { return }
            if let updated = detail.incidents.first(where: {
                $0.id == requestedID || $0.aliases?.contains(requestedID) == true
            }) ?? detail.incidents.first {
                selectedIncident = updated
            } else if selectedIncident == nil {
                incidentError = "This incident is no longer available."
            }
        } catch {
            guard !Task.isCancelled, activeScope == "incident:\(requestedID)", generation == scopeGeneration else { return }
            errorMessage = error.localizedDescription
            incidentError = error.localizedDescription
        }
    }

    func selectIncident(_ incident: PublicStatusIncident) async {
        activateScope("incident:\(incident.id)")
        selectedIncident = incident
        isLoadingIncident = true
        incidentError = nil
        await refreshIncident(id: incident.id, in: scopeGeneration)
    }

    func pollWhileVisible() async {
        while !Task.isCancelled {
            let scope = activeScope ?? "dashboard"
            if scope.hasPrefix("incident:"), selectedIncident?.status.lowercased() == "resolved" { return }
            let interval: Duration = scope.hasPrefix("incident:") ? Self.incidentRefreshInterval : Self.dashboardRefreshInterval
            do {
                try await sleep(interval)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard activeScope == scope else { continue }
            if scope == "dashboard" {
                await refreshDashboard(in: scopeGeneration)
            } else if let id = scope.split(separator: ":", maxSplits: 1).last.map(String.init) {
                guard selectedIncident?.status.lowercased() != "resolved" else { return }
                await refreshIncident(id: id, in: scopeGeneration)
                guard selectedIncident?.status.lowercased() != "resolved" else { return }
            }
        }
    }

    func refreshCurrentScope() async {
        if let selectedIncident, selectedIncident.status.lowercased() != "resolved" {
            await refreshIncident(id: selectedIncident.id, in: scopeGeneration)
        } else {
            await refresh()
        }
    }

    private func activateScope(_ scope: String) {
        guard activeScope != scope else { return }
        activeScope = scope
        scopeGeneration &+= 1
    }

    func showDashboard() async {
        selectedIncident = nil
        incidentError = nil
        activateScope("dashboard")
        await refreshDashboard(in: scopeGeneration)
    }

    func clearSelectedIncident() async {
        await showDashboard()
    }
}
