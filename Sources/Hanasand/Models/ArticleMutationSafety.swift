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
    var mayAcknowledge: Bool { intent != nil && review?.intentID == intent?.id }

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
        guard newReview.intentID == intent?.id else { return }
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
