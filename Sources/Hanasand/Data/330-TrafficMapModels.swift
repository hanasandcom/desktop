import Foundation

struct TrafficMapMetric: Decodable, Equatable, Identifiable {
    let key: String
    let count: Int

    var id: String { key }
}

struct TrafficMapMetrics: Decodable, Equatable {
    let totalRequests: Int
    let averageRequestTime: Double
    let errorRate: Double
    let topMethods: [TrafficMapMetric]
    let topStatusCodes: [TrafficMapMetric]
    let topPaths: [TrafficMapMetric]
    let sampledAt: String?

    enum CodingKeys: String, CodingKey {
        case totalRequests = "total_requests"
        case averageRequestTime = "avg_request_time"
        case errorRate = "error_rate"
        case topMethods = "top_methods"
        case topStatusCodes = "top_status_codes"
        case topPaths = "top_paths"
        case sampledAt = "sampled_at"
    }

    static func decode(_ data: Data) throws -> TrafficMapMetrics {
        let value = try JSONDecoder().decode(TrafficMapMetrics.self, from: data)
        guard value.totalRequests >= 0,
              value.averageRequestTime.isFinite, value.averageRequestTime >= 0,
              value.errorRate.isFinite, (0...1).contains(value.errorRate),
              [value.topMethods, value.topStatusCodes, value.topPaths].allSatisfy({ metrics in
                  metrics.count <= 10 && metrics.allSatisfy { !$0.key.isEmpty && $0.key.count <= 2048 && $0.count >= 0 }
              }),
              value.sampledAt.map({ $0.count <= 64 }) ?? true else {
            throw TrafficRecentError.invalidResponse
        }
        return value
    }
}

struct TrafficMapCountry: Identifiable, Equatable {
    let iso: String
    let requestCount: Int
    let lastSeen: Date

    var id: String { iso }
    var name: String { Locale.current.localizedString(forRegionCode: iso) ?? iso }

    private init(iso: String, requestCount: Int, lastSeen: Date) {
        self.iso = iso
        self.requestCount = requestCount
        self.lastSeen = lastSeen
    }

    static func summarize(_ records: [TrafficRecentRecord]) -> [TrafficMapCountry] {
        var counts: [String: Int] = [:]
        var latest: [String: Date] = [:]

        for record in records {
            guard let iso = record.countryISO?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                  iso.count == 2, iso.allSatisfy(\.isASCII), iso.allSatisfy(\.isLetter) else { continue }
            counts[iso, default: 0] += 1
            if latest[iso].map({ record.timestamp > $0 }) ?? true {
                latest[iso] = record.timestamp
            }
        }

        return counts.compactMap { iso, count in
            guard let lastSeen = latest[iso] else { return nil }
            return TrafficMapCountry(iso: iso, requestCount: count, lastSeen: lastSeen)
        }
        .sorted { lhs, rhs in
            lhs.requestCount == rhs.requestCount ? lhs.iso < rhs.iso : lhs.requestCount > rhs.requestCount
        }
    }
}
