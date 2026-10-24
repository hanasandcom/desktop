import AppKit
import ApplicationServices
import Combine
import CryptoKit
import Darwin
import Foundation
import Network
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct LoadTestingQuota: Decodable, Equatable {
    let plan: String
    let limit: Int
    let used: Int
    let remaining: Int
    let resetsAt: String?
}

enum LoadTestingLane: String, CaseIterable, Identifiable {
    case mine
    case recent

    var id: String { rawValue }
    var title: String { self == .mine ? "My tests" : "Recent tests" }
}

struct LoadTestingScenario: Identifiable {
    let id: String
    let title: String
    let description: String
    let timeout: Int
    let stages: [LoadTestStagePayload]

    static let all: [LoadTestingScenario] = [
        .init(id: "baseline", title: "Baseline", description: "One-user release check", timeout: 30, stages: [.init(duration: "30s", target: 1)]),
        .init(id: "ramp", title: "Ramp", description: "Gradually increase traffic", timeout: 45, stages: [.init(duration: "30s", target: 5), .init(duration: "1m", target: 20), .init(duration: "30s", target: 0)]),
        .init(id: "spike", title: "Spike", description: "Burst and recovery check", timeout: 60, stages: [.init(duration: "15s", target: 5), .init(duration: "20s", target: 40), .init(duration: "25s", target: 0)]),
    ]

    static let customID = "custom"
}

enum LoadTestingClientError: LocalizedError {
    case signIn
    case impersonation
    case invalidEndpoint
    case invalidTestID
    case invalidDraft(String)
    case http(Int, String, LoadTestingQuota?)
    case malformed(String, uncertain: Bool)
    case unavailable(uncertain: Bool)

    var isUncertain: Bool {
        switch self {
        case .malformed(_, let uncertain), .unavailable(let uncertain): return uncertain
        case .http(let code, _, _): return code >= 500
        default: return false
        }
    }

    var quota: LoadTestingQuota? {
        if case .http(_, _, let quota) = self { return quota }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .signIn: return "Sign in to review load tests."
        case .impersonation: return "Load generation is unavailable while impersonating. Switch back to your own account."
        case .invalidEndpoint: return "Use a secure API address without credentials, query parameters, or fragments."
        case .invalidTestID: return "Enter a valid test ID."
        case .invalidDraft(let message): return message
        case .http(let code, let message, _): return message.isEmpty ? "Load test request failed (HTTP \(code))." : message
        case .malformed(let message, _): return message
        case .unavailable(let uncertain):
            return uncertain ? "The request may have reached the server. Refresh history and review the result before trying again." : "Load tests are unavailable. Refresh to try again."
        }
    }
}

struct LoadTestingClient {
    typealias Sender = (URLRequest) async throws -> (Data, URLResponse)

    private let baseURL: URL
    private let userID: String
    private let token: String
    private let impersonationToken: String
    let canRead: Bool
    let canWrite: Bool
    private let send: Sender

    init(apiBaseURL: URL, userID: String, token: String, impersonationToken: String = "", impersonatingUserID: String = "", send: @escaping Sender = { try await URLSession.shared.data(for: $0) }) throws {
        guard let components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", components.host != nil,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { throw LoadTestingClientError.invalidEndpoint }
        self.baseURL = apiBaseURL
        self.userID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.impersonationToken = impersonationToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.canRead = !self.userID.isEmpty && !self.token.isEmpty
        self.canWrite = self.canRead && self.impersonationToken.isEmpty && impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        self.send = send
    }

    func history(_ lane: LoadTestingLane, limit: Int = 50) async throws -> [DashboardRecentTest] {
        guard canRead else { throw LoadTestingClientError.signIn }
        let envelopes: [LoadTestEnvelope] = try await request("tests/\(lane.rawValue)", queryItems: [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 50)))])
        let value = envelopes.map(\.test)
        guard value.count <= 50, Set(value.map(\.id)).count == value.count else { throw LoadTestingClientError.malformed("The test history is malformed.", uncertain: false) }
        return value
    }

    func quota() async throws -> LoadTestingQuota {
        guard canRead else { throw LoadTestingClientError.signIn }
        let value: LoadTestingQuota = try await request("tests/quota")
        guard ["free", "starter", "team", "volume"].contains(value.plan), value.limit >= 0, value.used >= 0, value.remaining >= 0 else {
            throw LoadTestingClientError.malformed("The server allowance is unavailable.", uncertain: false)
        }
        return value
    }

    func result(id: String) async throws -> DashboardRecentTest {
        guard canRead else { throw LoadTestingClientError.signIn }
        guard Self.validTestID(id) else { throw LoadTestingClientError.invalidTestID }
        let value: DashboardRecentTest = try await request("test/\(id)", as: LoadTestEnvelope.self).test
        guard value.id == id else { throw LoadTestingClientError.malformed("The returned result belongs to a different test.", uncertain: false) }
        return value
    }

    func create(url: String, scenario: LoadTestingScenario) async throws -> DashboardRecentTest {
        guard canWrite else { throw canRead ? LoadTestingClientError.impersonation : LoadTestingClientError.signIn }
        let target = try Self.validate(url: url)
        guard scenario.timeout >= 1, scenario.timeout <= 120, !scenario.stages.isEmpty, scenario.stages.count <= 8,
              scenario.stages.allSatisfy({ Self.validStage($0) }),
              scenario.stages.compactMap({ Self.durationSeconds($0.duration) }).reduce(0, +) <= 600 else {
            throw LoadTestingClientError.invalidDraft("Use a 1–120 second timeout and 1–8 traffic stages within 10 minutes. Each stage needs a positive duration and 0–100 users.")
        }
        let body = try JSONEncoder().encode(CreateLoadTestPayload(url: target, timeout: scenario.timeout, stages: scenario.stages))
        let value: DashboardRecentTest = try await request("test", method: "POST", body: body, as: LoadTestEnvelope.self).test
        guard Self.validTestID(value.id) else { throw LoadTestingClientError.malformed("The submission receipt is invalid. Refresh history before another request.", uncertain: true) }
        return value
    }

    func rerun(id: String) async throws {
        guard canWrite else { throw canRead ? LoadTestingClientError.impersonation : LoadTestingClientError.signIn }
        guard Self.validTestID(id) else { throw LoadTestingClientError.invalidTestID }
        let body = Data("{}".utf8)
        let value: RerunReceipt = try await request("test/\(id)/rerun", method: "POST", body: body)
        guard value.ok, value.status == "queued" else { throw LoadTestingClientError.malformed("The rerun receipt is unclear. Refresh history before another request.", uncertain: true) }
    }

    static func validTestID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_.:@-]{1,200}$", options: .regularExpression) != nil && value != "." && value != ".."
    }

    static func liveSocketURL(apiBaseURL: URL, testID: String) -> URL? {
        guard validTestID(testID),
              var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", components.host != nil,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = "ws/test/\(testID)"
        components.percentEncodedPath = "/" + ([basePath, suffix].filter { !$0.isEmpty }.joined(separator: "/"))
        components.scheme = "wss"
        return components.url
    }

    static func validStage(_ stage: LoadTestStagePayload) -> Bool {
        durationSeconds(stage.duration) != nil && stage.target >= 0 && stage.target <= 100
    }

    static func durationSeconds(_ duration: String) -> Int? {
        guard let match = duration.range(of: "^(\\d+)([smh])$", options: .regularExpression) else { return nil }
        let components = duration[match].dropLast()
        guard let amount = Int(components), amount > 0, let unit = duration.last else { return nil }
        let multiplier = unit == "s" ? 1 : unit == "m" ? 60 : 3600
        guard amount <= 600 / multiplier else { return nil }
        return amount * multiplier
    }

    static func validate(url rawValue: String) throws -> String {
        let candidate = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = candidate.lowercased()
        if candidate.contains("://") && !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            throw LoadTestingClientError.invalidDraft("Use an HTTP or HTTPS endpoint.")
        }
        if let colon = candidate.firstIndex(of: ":"), !lower.hasPrefix("http://"), !lower.hasPrefix("https://") {
            let prefix = candidate[..<colon]
            if !prefix.contains(".") && prefix.lowercased() != "localhost" {
                throw LoadTestingClientError.invalidDraft("Use an HTTP or HTTPS endpoint.")
            }
        }
        let normalized = candidate.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) == nil ? "https://\(candidate)" : candidate
        guard var components = URLComponents(string: normalized),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              normalized.utf8.count <= 2000 else { throw LoadTestingClientError.invalidDraft("Enter an HTTP or HTTPS endpoint without embedded credentials.") }
        components.fragment = nil
        return components.string ?? normalized
    }

    private func request<T: Decodable>(_ path: String, queryItems: [URLQueryItem] = [], method: String = "GET", body: Data? = nil, as responseType: T.Type = T.self) async throws -> T {
        let write = method != "GET"
        guard !write || canWrite else { throw LoadTestingClientError.impersonation }
        var components = URLComponents(url: baseURL.appendingAPIPath(path), resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url else { throw LoadTestingClientError.invalidEndpoint }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if !impersonationToken.isEmpty { request.setValue(impersonationToken, forHTTPHeaderField: "x-impersonation-token") }

        do {
            let (data, response) = try await send(request)
            guard let http = response as? HTTPURLResponse else { throw LoadTestingClientError.unavailable(uncertain: write) }
            guard data.count <= 2 * 1024 * 1024 else { throw LoadTestingClientError.malformed("The load-test response exceeded the 2 MiB limit.", uncertain: write) }
            guard (200..<300).contains(http.statusCode) else {
                let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let quota = (payload?["quota"] as? [String: Any]).flatMap { try? JSONDecoder().decode(LoadTestingQuota.self, from: JSONSerialization.data(withJSONObject: $0)) }
                throw LoadTestingClientError.http(http.statusCode, payload?["error"] as? String ?? "", quota)
            }
            do { return try JSONDecoder().decode(responseType, from: data) }
            catch { throw LoadTestingClientError.malformed("The server returned an invalid load-test response.", uncertain: write) }
        } catch let error as LoadTestingClientError {
            throw error
        } catch {
            throw LoadTestingClientError.unavailable(uncertain: write)
        }
    }

    private struct RerunReceipt: Decodable { let ok: Bool; let status: String }

    private struct LoadTestEnvelope: Decodable {
        let test: DashboardRecentTest

        private enum CodingKeys: String, CodingKey { case id, url, status }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let hasID = (try? container.decode(String.self, forKey: .id)) != nil || (try? container.decode(Int.self, forKey: .id)) != nil
            guard hasID,
                  let url = try? container.decode(String.self, forKey: .url), url.utf8.count <= 2000,
                  let status = try? container.decode(String.self, forKey: .status), !status.isEmpty, status.count <= 40 else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Required load-test result fields are missing."))
            }
            test = try DashboardRecentTest(from: decoder)
        }
    }
}
