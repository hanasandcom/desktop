import Foundation

struct NativePublicContactRequest: Encodable {
    let name: String
    let email: String
    let company: String
    let subject: String
    let message: String
    let source: String
}

struct NativePublicContactResponse: Decodable {
    let ticketID: String?
    let nextStep: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ticketID = "ticketId"
        case nextStep
        case error
    }
}

enum NativePublicInfoClientError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "Contact requests need a valid HTTPS API endpoint."
        case .invalidResponse:
            "The contact service returned an invalid response."
        case let .server(message):
            message
        }
    }
}

struct NativePublicInfoClient {
    private let endpoint: URL
    private let session: URLSession

    init(apiBaseURL: String, session: URLSession = .shared) throws {
        guard var components = URLComponents(string: apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              (scheme == "https" || ((host == "localhost" || host == "127.0.0.1") && scheme == "http")) else {
            throw NativePublicInfoClientError.invalidEndpoint
        }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [components.path, "commercial/contact-requests"].filter { !$0.isEmpty }.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        guard let endpoint = components.url else { throw NativePublicInfoClientError.invalidEndpoint }
        self.endpoint = endpoint
        self.session = session
    }

    func submit(_ payload: NativePublicContactRequest) async throws -> NativePublicContactResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw NativePublicInfoClientError.invalidResponse }
        let decoded = try? JSONDecoder().decode(NativePublicContactResponse.self, from: data)
        guard (200..<300).contains(response.statusCode), decoded?.error == nil else {
            throw NativePublicInfoClientError.server(decoded?.error ?? "Contact intake is temporarily unavailable.")
        }
        guard let decoded else { throw NativePublicInfoClientError.invalidResponse }
        return decoded
    }
}
