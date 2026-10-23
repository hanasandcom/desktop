import Foundation

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
