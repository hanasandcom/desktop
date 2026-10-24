import Foundation

struct NativeDomainMonitorRow: Identifiable, Equatable {
    let domain: String
    let customer: String?
    let status: String?
    let monitoredSince: String?
    let lastSeenAt: String?
    let breachMentions: Int?
    let matchedTerms: [String]
    let sources: [String]?
    let requestsToday: Int?
    let requestsThisWeek: Int?
    let requestsThisMonth: Int?
    let requestsTotal: Int?

    var id: String { domain }
}

struct NativeDomainMonitorSnapshot: Equatable {
    struct ResourceState: Equatable {
        let title: String
        let detail: String
        let available: Bool
    }

    let rows: [NativeDomainMonitorRow]
    let trafficSummary: ResourceState
    let trafficMetrics: ResourceState
    let captures: ResourceState
    let sourceOperations: ResourceState

    var totalBreachMentions: Int { rows.compactMap(\.breachMentions).reduce(0, +) }
    var totalRequestsToday: Int { rows.compactMap(\.requestsToday).reduce(0, +) }
}

