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

struct DashboardTrafficMetrics: Decodable {
    struct Metric: Decodable, Identifiable {
        var id: String { key }
        let key: String
        let count: Int
    }

    let totalRequests: Int
    let avgRequestTime: Double
    let errorRate: Double
    let topDomains: [Metric]

    enum CodingKeys: String, CodingKey {
        case totalRequests = "total_requests"
        case avgRequestTime = "avg_request_time"
        case errorRate = "error_rate"
        case topDomains = "top_domains"
    }
}

struct TrafficMetricSnapshot: Decodable, Equatable {
    struct Metric: Decodable, Identifiable, Equatable {
        let key: String
        let count: Int
        var id: String { key }
    }

    struct SlowMetric: Decodable, Identifiable, Equatable {
        let key: String
        let averageTime: Double
        var id: String { key }

        enum CodingKeys: String, CodingKey {
            case key
            case averageTime = "avg_time"
        }
    }

    let sampledAt: String?
    let totalRequests: Int
    let averageRequestTime: Double
    let errorRate: Double
    let topMethods: [Metric]
    let topStatusCodes: [Metric]
    let topDomains: [Metric]
    let topOperatingSystems: [Metric]
    let topBrowsers: [Metric]
    let requestsOverTime: [Metric]
    let topErrorPaths: [Metric]
    let topSlowPaths: [SlowMetric]
    let topPaths: [Metric]

    enum CodingKeys: String, CodingKey {
        case sampledAt = "sampled_at"
        case totalRequests = "total_requests"
        case averageRequestTime = "avg_request_time"
        case errorRate = "error_rate"
        case topMethods = "top_methods"
        case topStatusCodes = "top_status_codes"
        case topDomains = "top_domains"
        case topOperatingSystems = "top_os"
        case topBrowsers = "top_browsers"
        case requestsOverTime = "requests_over_time"
        case topErrorPaths = "top_error_paths"
        case topSlowPaths = "top_slow_paths"
        case topPaths = "top_paths"
    }

    static func decode(_ data: Data) throws -> TrafficMetricSnapshot {
        let value = try JSONDecoder().decode(TrafficMetricSnapshot.self, from: data)
        let groups = [value.topMethods, value.topStatusCodes, value.topDomains,
                      value.topOperatingSystems, value.topBrowsers, value.requestsOverTime,
                      value.topErrorPaths, value.topPaths]
        guard value.totalRequests >= 0,
              value.averageRequestTime.isFinite, value.averageRequestTime >= 0,
              value.errorRate.isFinite, (0...1).contains(value.errorRate),
              groups.allSatisfy({ $0.count <= 100 && $0.allSatisfy { !$0.key.isEmpty && $0.key.count <= 4096 && $0.count >= 0 } }),
              value.topSlowPaths.count <= 100,
              value.topSlowPaths.allSatisfy({ !$0.key.isEmpty && $0.key.count <= 4096 && $0.averageTime.isFinite && $0.averageTime >= 0 }),
              value.sampledAt.map({ Self.validDate($0) }) ?? true,
              value.requestsOverTime.allSatisfy({ Self.validDate($0.key) }) else {
            throw TrafficRecentError.invalidResponse
        }
        return value
    }

    private static func validDate(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 100 else { return false }
        var raw = value.replacingOccurrences(of: " ", with: "T", range: value.range(of: " "))
        if let suffix = raw.range(of: "[+-][0-9]{2}$", options: .regularExpression) {
            raw.replaceSubrange(suffix, with: String(raw[suffix]) + ":00")
        }
        guard raw.range(of: "(?:Z|[+-][0-9]{2}:[0-9]{2})$", options: [.regularExpression, .caseInsensitive]) != nil else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) != nil || {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: raw) != nil
        }()
    }
}
