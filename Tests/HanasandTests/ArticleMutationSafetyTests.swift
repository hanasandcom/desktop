import XCTest
@testable import Hanasand

final class ArticleMutationSafetyTests: XCTestCase {
    private func intent(_ action: ArticleMutationAction = .update, id: UUID = UUID()) -> ArticleMutationIntent {
        ArticleMutationIntent(id: id, action: action, articleID: "notes.md", content: "# Draft\ntext",
                             actorID: "user-1", apiBaseURL: "https://api.example.test", createdAt: Date(timeIntervalSince1970: 10))
    }

    func testUncertainIntentBlocksRepeatedMutationUntilFreshReviewIsAcknowledged() {
        var state = ArticleMutationSafety()
        let pending = intent()
        state.begin(pending)

        XCTAssertTrue(state.isBlocked)
        XCTAssertFalse(state.canStartMutation)
        XCTAssertFalse(state.mayAcknowledge)
        XCTAssertFalse(state.acknowledgeReviewedOutcome())
        XCTAssertTrue(state.isBlocked)

        state.recordFreshReview(ArticleMutationReview(
            intentID: pending.id, fetchedAt: Date(), serverArticleExists: true,
            serverContent: "# Draft\ntext", serverTitle: "Draft",
            serverContentDigest: ArticleMutationIntent.digest("# Draft\ntext")
        ))
        XCTAssertTrue(state.mayAcknowledge)
        XCTAssertEqual(state.review?.matches(pending), true)

        XCTAssertTrue(state.acknowledgeReviewedOutcome())
        XCTAssertFalse(state.isBlocked)
        XCTAssertTrue(state.canStartMutation)
        XCTAssertNil(state.review)
    }

    func testReviewForDifferentIntentCannotUnlockBarrier() {
        var state = ArticleMutationSafety()
        state.begin(intent())
        state.recordFreshReview(ArticleMutationReview(
            intentID: UUID(), fetchedAt: Date(), serverArticleExists: true,
            serverContent: "unrelated", serverTitle: "Other",
            serverContentDigest: ArticleMutationIntent.digest("unrelated")
        ))

        XCTAssertFalse(state.mayAcknowledge)
        XCTAssertFalse(state.acknowledgeReviewedOutcome())
        XCTAssertTrue(state.isBlocked)
    }

    func testPersistedIntentSurvivesButReviewMustBeFetchedAgain() throws {
        var state = ArticleMutationSafety()
        let pending = intent()
        state.begin(pending)
        state.recordFreshReview(ArticleMutationReview(
            intentID: pending.id, fetchedAt: Date(), serverArticleExists: false,
            serverContent: nil, serverTitle: nil, serverContentDigest: nil
        ))

        let restored = try JSONDecoder().decode(ArticleMutationSafety.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.intent, pending)
        XCTAssertNil(restored.review)
        XCTAssertFalse(restored.mayAcknowledge)
    }

    func testReceiptsRequireExpectedActionMarkerAndArticleID() {
        XCTAssertTrue(ArticleMutationSafety.isValidReceipt(#"{"created":true,"name":"notes.md"}"#, action: .create, articleID: "notes.md"))
        XCTAssertTrue(ArticleMutationSafety.isValidReceipt(#"{"updated":true,"id":"notes.md"}"#, action: .update, articleID: "notes.md"))
        XCTAssertTrue(ArticleMutationSafety.isValidReceipt(#"{"deleted":true,"id":"notes.md"}"#, action: .delete, articleID: "notes.md"))
        XCTAssertFalse(ArticleMutationSafety.isValidReceipt(#"{"updated":true,"id":"other.md"}"#, action: .update, articleID: "notes.md"))
        XCTAssertFalse(ArticleMutationSafety.isValidReceipt(#"{"ok":true}"#, action: .delete, articleID: "notes.md"))
        XCTAssertFalse(ArticleMutationSafety.isValidReceipt("not json", action: .create, articleID: "notes.md"))
    }

    func testOnlyUnambiguousClientRejectionsReleaseAutomatically() {
        XCTAssertTrue(ArticleMutationSafety.isDefiniteRejection(status: 400))
        XCTAssertTrue(ArticleMutationSafety.isDefiniteRejection(status: 409))
        XCTAssertFalse(ArticleMutationSafety.isDefiniteRejection(status: 408))
        XCTAssertFalse(ArticleMutationSafety.isDefiniteRejection(status: 500))
    }

    func testWorkspaceScopeMustMatchBeforeReviewCanUnlock() {
        var state = ArticleMutationSafety()
        let pending = ArticleMutationIntent(
            id: UUID(), action: .update, articleID: "notes.md", content: "draft",
            actorID: "user-1", apiBaseURL: "https://api.example.test", createdAt: Date(), organizationID: "org-1"
        )
        state.begin(pending)
        state.recordFreshReview(ArticleMutationReview(
            intentID: pending.id, fetchedAt: Date(), serverArticleExists: true,
            serverContent: "other workspace", serverTitle: "Other", serverContentDigest: nil, organizationID: "org-2"
        ))
        XCTAssertFalse(state.mayAcknowledge)
        XCTAssertTrue(state.isBlocked)

        state.recordFreshReview(ArticleMutationReview(
            intentID: pending.id, fetchedAt: Date(), serverArticleExists: true,
            serverContent: "same workspace", serverTitle: "Notes", serverContentDigest: nil, organizationID: "org-1"
        ))
        XCTAssertTrue(state.mayAcknowledge)
    }

    func testLegacyIntentDecodesAndDoesNotAssumeUnknownUpdateWorkspace() throws {
        let legacy = intent(.update)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        object.removeValue(forKey: "organizationID")
        object.removeValue(forKey: "workspaceScopeKnown")
        let data = try JSONSerialization.data(withJSONObject: ["intent": object])
        var restored = try JSONDecoder().decode(ArticleMutationSafety.self, from: data)
        let pending = try XCTUnwrap(restored.intent)

        XCTAssertEqual(pending.articleID, legacy.articleID)
        XCTAssertFalse(pending.workspaceScopeKnown)
        XCTAssertFalse(restored.mayAcknowledge)
        restored.recordFreshReview(ArticleMutationReview(
            intentID: pending.id, fetchedAt: Date(), serverArticleExists: true,
            serverContent: "found", serverTitle: "Notes", serverContentDigest: nil, organizationID: "org-1"
        ))
        XCTAssertEqual(restored.intent?.organizationID, "org-1")
        XCTAssertTrue(restored.mayAcknowledge)
    }
}
