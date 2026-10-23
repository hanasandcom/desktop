import Foundation

enum IntegrationKind: String, Codable, CaseIterable, Identifiable {
    case discord
    case webhook
    var id: String { rawValue }
    var title: String { self == .discord ? "Discord" : "Webhook" }
}

struct IntegrationDestination: Decodable, Identifiable, Equatable {
    let id: String
    let orgId: String
    let name: String
    let kind: IntegrationKind
    let status: String
    let endpointHint: String?
    let lastTestedAt: String?
    let lastTestStatus: String?
}

struct IntegrationPermission: Decodable {
    let canManage: Bool?
    let canUpdate: Bool?
    let canDisable: Bool?
    let canTest: Bool?
}

struct IntegrationAccessRow: Decodable {
    let destinationId: String?
    let access: IntegrationPermission?
}

struct IntegrationBlocker: Decodable, Identifiable {
    var id: String { "\(code ?? "blocker"): \(message)" }
    let code: String?
    let blocking: Bool?
    let message: String
}

struct IntegrationLatestTest: Decodable {
    let requestId: String?
    let deliveryId: String?
    let status: String?
    let dryRun: Bool?
    let live: Bool?
    let responseStatus: Int?
    let error: String?
    let attemptedAt: String?
    let source: String?
}

struct IntegrationTestRow: Decodable {
    let destinationId: String?
    let access: IntegrationPermission?
    let status: String?
    let latestTest: IntegrationLatestTest?
    let blockers: [IntegrationBlocker]?
}

struct IntegrationAdminProof: Decodable {
    let access: IntegrationPermission?
}

struct IntegrationPage: Decodable {
    let destinations: [IntegrationDestination]
    let destinationLifecycle: [IntegrationAccessRow]
    let destinationTests: [IntegrationTestRow]
    let destinationAdminProof: IntegrationAdminProof
}

struct IntegrationDraft {
    var id: String?
    var name: String
    var kind: IntegrationKind
    var endpointURL: String
}
