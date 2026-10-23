import Foundation

struct AccountSubscriptionEnvelope: Decodable, Equatable {
    struct Subscription: Decodable, Equatable {
        let planId: String
        let status: String
        let currentPeriodStart: String?
        let currentPeriodEnd: String?
        let cancelAtPeriodEnd: Bool
    }

    struct Entitlement: Decodable, Equatable, Identifiable {
        let planId: String
        let features: [String]
        var id: String { planId + ":" + features.joined(separator: ",") }
    }

    struct Quota: Decodable, Equatable, Identifiable {
        let key: String
        let limit: Int?
        let used: Int?
        let remaining: Int?
        let resetsAt: String?
        var id: String { key }
    }

    let subscription: Subscription?
    let entitlements: [Entitlement]
    let quotas: [Quota]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subscription = try container.decodeIfPresent(Subscription.self, forKey: .subscription)
        entitlements = try container.decodeIfPresent([Entitlement].self, forKey: .entitlements) ?? []
        quotas = try container.decodeIfPresent([Quota].self, forKey: .quotas) ?? []
    }

    private enum CodingKeys: String, CodingKey { case subscription, entitlements, quotas }
}
