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

enum ArticleMutationAction: String, Codable {
    case create, update, delete
}

struct ArticleMutationIntent: Codable, Equatable, Identifiable {
    let id: UUID
    let action: ArticleMutationAction
    let articleID: String
    let content: String?
    let actorID: String
    let apiBaseURL: String
    let createdAt: Date
    var organizationID: String? = nil
    var workspaceScopeKnown: Bool = true

    init(id: UUID, action: ArticleMutationAction, articleID: String, content: String?, actorID: String,
         apiBaseURL: String, createdAt: Date, organizationID: String? = nil, workspaceScopeKnown: Bool = true) {
        self.id = id
        self.action = action
        self.articleID = articleID
        self.content = content
        self.actorID = actorID
        self.apiBaseURL = apiBaseURL
        self.createdAt = createdAt
        self.organizationID = organizationID
        self.workspaceScopeKnown = workspaceScopeKnown
    }

    private enum CodingKeys: String, CodingKey {
        case id, action, articleID, content, actorID, apiBaseURL, createdAt, organizationID, workspaceScopeKnown
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        action = try values.decode(ArticleMutationAction.self, forKey: .action)
        articleID = try values.decode(String.self, forKey: .articleID)
        content = try values.decodeIfPresent(String.self, forKey: .content)
        actorID = try values.decode(String.self, forKey: .actorID)
        apiBaseURL = try values.decode(String.self, forKey: .apiBaseURL)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        organizationID = try values.decodeIfPresent(String.self, forKey: .organizationID)
        // Older create intents were always sent to the personal lane. Older
        // updates/deletes could target any row because their list was unscoped.
        workspaceScopeKnown = try values.decodeIfPresent(Bool.self, forKey: .workspaceScopeKnown) ?? (action == .create)
    }

    var contentDigest: String? {
        guard let content else { return nil }
        return Self.digest(content)
    }

    static func digest(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct ArticleMutationReview: Equatable {
    let intentID: UUID
    let fetchedAt: Date
    let serverArticleExists: Bool
    let serverContent: String?
    let serverTitle: String?
    let serverContentDigest: String?
    var organizationID: String? = nil

    func matches(_ intent: ArticleMutationIntent) -> Bool? {
        guard intentID == intent.id, let submitted = intent.contentDigest,
              let serverContentDigest else { return nil }
        return submitted == serverContentDigest
    }
}

struct ArticleMutationSafety: Codable, Equatable {
    private(set) var intent: ArticleMutationIntent?
    private(set) var review: ArticleMutationReview?

    var isBlocked: Bool { intent != nil }
    var canStartMutation: Bool { intent == nil }
    var mayAcknowledge: Bool {
        guard let intent, intent.workspaceScopeKnown, let review else { return false }
        return review.intentID == intent.id && review.organizationID == intent.organizationID
    }

    static func isDefiniteRejection(status: Int) -> Bool {
        (400...499).contains(status) && status != 408
    }

    // Review state is intentionally memory-only: every app launch must fetch fresh server state.
    private enum CodingKeys: String, CodingKey { case intent }

    init(intent: ArticleMutationIntent? = nil) {
        self.intent = intent
        self.review = nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        intent = try container.decodeIfPresent(ArticleMutationIntent.self, forKey: .intent)
        review = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(intent, forKey: .intent)
    }

    mutating func begin(_ newIntent: ArticleMutationIntent) {
        intent = newIntent
        review = nil
    }

    mutating func markUncertain() {
        review = nil
    }

    mutating func recordFreshReview(_ newReview: ArticleMutationReview) {
        guard var current = intent, newReview.intentID == current.id else { return }
        if !current.workspaceScopeKnown {
            guard current.action != .create, newReview.serverArticleExists else { return }
            current.organizationID = newReview.organizationID
            current.workspaceScopeKnown = true
            intent = current
        }
        guard newReview.organizationID == current.organizationID else { return }
        review = newReview
    }

    mutating func acknowledgeReviewedOutcome() -> Bool {
        guard mayAcknowledge else { return false }
        intent = nil
        review = nil
        return true
    }

    mutating func clearAfterResolvedOutcome() {
        intent = nil
        review = nil
    }

    static func isValidReceipt(_ raw: String, action: ArticleMutationAction, articleID: String) -> Bool {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        switch action {
        case .create:
            return object["created"] as? Bool == true && object["name"] as? String == articleID
        case .update:
            return object["updated"] as? Bool == true && object["id"] as? String == articleID
        case .delete:
            return object["deleted"] as? Bool == true && object["id"] as? String == articleID
        }
    }
}
