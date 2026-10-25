import Foundation

enum PublishingListOrder {
    case newest
    case title
}

enum PublishingList {
    static let pageSize = 20

    static func articles(_ items: [DashboardArticle], matching query: String, order: PublishingListOrder) -> [DashboardArticle] {
        filterAndSort(items, matching: query, order: order,
                      id: \.id, title: \.title, timestamp: { $0.modified ?? $0.created }, extra: { _ in "" })
    }

    static func thoughts(_ items: [DashboardThought], matching query: String, order: PublishingListOrder) -> [DashboardThought] {
        filterAndSort(items, matching: query, order: order,
                      id: \.id, title: \.title, timestamp: { $0.updatedAt ?? $0.createdAt }, extra: { $0.createdBy ?? "" })
    }

    static func pageCount(for itemCount: Int) -> Int {
        max(1, (itemCount + pageSize - 1) / pageSize)
    }

    static func page<T>(_ items: [T], number: Int) -> [T] {
        let start = max(0, number) * pageSize
        guard start < items.count else { return [] }
        return Array(items[start..<min(start + pageSize, items.count)])
    }

    private static func filterAndSort<T>(
        _ items: [T], matching query: String, order: PublishingListOrder,
        id: (T) -> String, title: (T) -> String, timestamp: (T) -> String?, extra: (T) -> String
    ) -> [T] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let filtered = items.filter { item in
            let haystack = "\(id(item)) \(title(item)) \(extra(item))".lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }

        return filtered.sorted { lhs, rhs in
            switch order {
            case .title:
                let comparison = title(lhs).localizedStandardCompare(title(rhs))
                return comparison == .orderedSame ? id(lhs).localizedStandardCompare(id(rhs)) == .orderedAscending : comparison == .orderedAscending
            case .newest:
                let leftDate = timestamp(lhs).flatMap(Self.date)?.timeIntervalSince1970 ?? 0
                let rightDate = timestamp(rhs).flatMap(Self.date)?.timeIntervalSince1970 ?? 0
                if leftDate != rightDate { return leftDate > rightDate }
                return id(lhs).localizedStandardCompare(id(rhs)) == .orderedAscending
            }
        }
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
