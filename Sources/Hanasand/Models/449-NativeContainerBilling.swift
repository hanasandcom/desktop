import Foundation

struct NativeContainerPurchase: Equatable, Identifiable {
    let name: String
    let failoverPremium: Bool

    var id: String { name }
}

struct NativeContainerPurchasePlan: Equatable, Identifiable {
    let id: String
    let name: String
    let priceNok: Int
    let currency: String
    let interval: String
}

struct NativeContainerBillingSnapshot: Equatable {
    let plans: [NativeContainerPurchasePlan]
    let containers: [NativeContainerPurchase]
}
