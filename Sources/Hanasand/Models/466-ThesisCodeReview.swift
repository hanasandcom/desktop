import Foundation

enum ThesisCodeKind: String, Codable, CaseIterable, Identifiable {
    case frontend, api, database, source
    var id: String { rawValue }
}

struct ThesisCodeReviewEvent: Decodable, Equatable, Identifiable {
    let eventID: String
    let itemID: String
    let contentHash: String
    let reviewHash: String
    let approved: Bool
    let reviewer: String
    let reviewedAt: String

    var id: String { eventID }

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case itemID = "item_id"
        case contentHash = "content_hash"
        case reviewHash = "review_hash"
        case approved, reviewer
        case reviewedAt = "reviewed_at"
    }

    var hasValidReceipt: Bool {
        Self.isSHA256(contentHash) && Self.isSHA256(reviewHash)
            && UUID(uuidString: eventID) != nil && !itemID.isEmpty
            && !reviewer.isEmpty && Self.isISO8601(reviewedAt)
    }

    static func isSHA256(_ value: String) -> Bool {
        value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }

    private static func isISO8601(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) != nil
    }
}

struct ThesisCodeNode: Decodable, Equatable, Identifiable {
    let id: String
    let kind: ThesisCodeKind
    let title: String
    let file: String
    let line: Int?
    let sha256: String
    let reviewHash: String
    let dependencies: [String]
    let dependencyCount: Int
    let unresolved: [String]
    let content: String?
    let review: ThesisCodeReviewEvent?

    var reviewStatus: String {
        guard let review else { return "unreviewed" }
        if review.reviewHash != reviewHash { return "changed" }
        return review.approved ? "approved" : "unreviewed"
    }

    var isValid: Bool {
        !id.isEmpty && id.utf8.count <= 2_000 && !title.isEmpty && !file.isEmpty
            && ThesisCodeReviewEvent.isSHA256(sha256) && ThesisCodeReviewEvent.isSHA256(reviewHash)
            && dependencyCount >= 0 && dependencies.count <= 100_000 && unresolved.count <= 100_000
            && line.map { $0 > 0 } != false && content.map { $0.utf8.count <= 8_000_000 } != false
            && (review.map { $0.hasValidReceipt && $0.itemID == id } ?? true)
    }
}

struct ThesisCodeSync: Decodable, Equatable {
    let phase: String
    let checkedAt: String?
    let error: String?
    let warning: String?

    enum CodingKeys: String, CodingKey {
        case phase, error, warning
        case checkedAt = "checkedAt"
    }
}

struct ThesisCodeInventory: Decodable, Equatable {
    let version: Int
    let hash: String
    let nodes: [ThesisCodeNode]
    let release: String
    let revision: String?
    let sync: ThesisCodeSync?

    var cursor: String { "\(hash):\(revision ?? "")" }
    var syncReady: Bool { sync.map { $0.phase == "ready" && $0.error == nil } ?? true }

    func validated() throws -> ThesisCodeInventory {
        guard version > 0, !hash.isEmpty, hash.utf8.count <= 200, !release.isEmpty,
              nodes.count <= 100_000, nodes.allSatisfy(\.isValid),
              Set(nodes.map(\.id)).count == nodes.count else {
            throw ThesisCodeReviewError.invalidResponse
        }
        return self
    }
}

struct ThesisCodeSource: Decodable, Equatable {
    let item: ThesisCodeNode
    let history: [ThesisCodeReviewEvent]

    func validated(expectedID: String) throws -> ThesisCodeSource {
        guard item.id == expectedID, item.isValid, item.content != nil,
              history.count <= 50, history.allSatisfy({ $0.hasValidReceipt && $0.itemID == expectedID }) else {
            throw ThesisCodeReviewError.invalidResponse
        }
        return self
    }
}

struct ThesisCodeReviewReceipt: Decodable, Equatable {
    let event: ThesisCodeReviewEvent

    func validated(item: ThesisCodeNode, approved: Bool, eventID: String) throws -> ThesisCodeReviewReceipt {
        guard event.hasValidReceipt, event.eventID == eventID, event.itemID == item.id,
              event.contentHash == item.sha256, event.reviewHash == item.reviewHash,
              event.approved == approved else { throw ThesisCodeReviewError.invalidResponse }
        return self
    }
}

extension ThesisCodeReviewReceipt {
    init(from decoder: Decoder) throws {
        event = try ThesisCodeReviewEvent(from: decoder)
    }
}

enum ThesisCodeReviewError: LocalizedError, Equatable {
    case signInRequired
    case invalidEndpoint
    case invalidIdentity
    case readOnly
    case invalidInput
    case invalidResponse
    case responseTooLarge
    case requestFailed(Int, String?)

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to view source inventory."
        case .invalidEndpoint: "Source inventory requires a secure Website address."
        case .invalidIdentity: "The signed-in account could not be verified."
        case .readOnly: "Only Hanasand organization owners and editors can review source code."
        case .invalidInput: "Select a current source item before recording a review."
        case .invalidResponse: "The source review service returned an invalid response."
        case .responseTooLarge: "The source review response exceeded its size limit."
        case let .requestFailed(status, message): message ?? "Source review request failed (HTTP \(status))."
        }
    }
}
