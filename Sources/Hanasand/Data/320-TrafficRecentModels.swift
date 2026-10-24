import Foundation

struct TrafficRecentRecord: Decodable, Identifiable, Equatable {
    let id: String
    let userAgent: String
    let domain: String
    let path: String
    let method: String
    let referer: String
    let requestTime: Double
    let status: Int
    let timestamp: Date
    let countryISO: String?

    enum CodingKeys: String, CodingKey {
        case id, userAgent = "user_agent", domain, path, method, referer
        case requestTime = "request_time", status, timestamp, countryISO = "country_iso"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? values.decode(String.self, forKey: .id) {
            id = text
        } else {
            id = String(try values.decode(Int64.self, forKey: .id))
        }
        userAgent = try values.decode(String.self, forKey: .userAgent)
        domain = try values.decode(String.self, forKey: .domain)
        path = try values.decode(String.self, forKey: .path)
        method = try values.decode(String.self, forKey: .method)
        referer = try values.decode(String.self, forKey: .referer)
        if let value = try? values.decode(Double.self, forKey: .requestTime) {
            requestTime = value
        } else if let text = try? values.decode(String.self, forKey: .requestTime), let value = Double(text) {
            requestTime = value
        } else {
            throw TrafficRecentError.invalidResponse
        }
        if let value = try? values.decode(Int.self, forKey: .status) {
            status = value
        } else if let text = try? values.decode(String.self, forKey: .status), let value = Int(text) {
            status = value
        } else {
            throw TrafficRecentError.invalidResponse
        }
        timestamp = try values.decode(Date.self, forKey: .timestamp)
        let country = try values.decodeIfPresent(String.self, forKey: .countryISO)
        if let country, !country.isEmpty {
            guard country.range(of: "^[A-Za-z]{2}$", options: .regularExpression) != nil else {
                throw TrafficRecentError.invalidResponse
            }
            countryISO = country.uppercased()
        } else {
            countryISO = nil
        }
    }
}

struct TrafficRecentPage: Decodable, Equatable {
    let result: [TrafficRecentRecord]
    let total: Int
}

struct TrafficRecentDomains: Decodable, Equatable {
    let domains: [String]
}

enum TrafficRecentError: LocalizedError {
    case signIn
    case insecureEndpoint
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .signIn: "Sign in again to view recent traffic."
        case .insecureEndpoint: "Traffic requires a secure API address."
        case .invalidResponse: "Traffic returned an invalid response. Refresh to try again."
        case let .httpStatus(status) where status == 401: "Sign in again to view recent traffic."
        case let .httpStatus(status) where status == 403: "Traffic access is unavailable for this account."
        case let .httpStatus(status) where status == 429: "Traffic requests are limited. Wait before refreshing."
        case let .httpStatus(status): "Traffic is temporarily unavailable (\(status)). Refresh to try again."
        }
    }
}
