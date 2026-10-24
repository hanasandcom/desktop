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

extension DesktopAgentModel {

    func beginArticleMutation(_ action: ArticleMutationAction, articleID: String, content: String?) -> Bool {
        guard articleMutationSafety.canStartMutation else {
            nativeDashboardStatus = "An article change still needs review. Refresh its server state before editing again."
            return false
        }
        guard hasHanasandAuth else {
            nativeDashboardStatus = "Hanasand session is not ready. Log in again if this persists."
            return false
        }
        articleMutationSafety.begin(ArticleMutationIntent(
            id: UUID(), action: action, articleID: articleID, content: content,
            actorID: userIDForRequests, apiBaseURL: settings.apiBaseURL.normalizedBaseURL.absoluteString,
            createdAt: Date()
        ))
        return true
    }

    func performArticleMutation(_ action: ArticleMutationAction, articleID: String, content: String? = nil) async -> Bool {
        guard beginArticleMutation(action, articleID: articleID, content: content) else { return false }
        let method: String
        switch action {
        case .create: method = "POST"
        case .update: method = "PUT"
        case .delete: method = "DELETE"
        }
        let body = content.flatMap { try? JSONEncoder().encode(["content": $0]) }
        do {
            let receipt = try await requestPrettyText(
                settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("article/\(articleID)"),
                method: method, body: body, authenticated: true
            )
            guard ArticleMutationSafety.isValidReceipt(receipt, action: action, articleID: articleID) else {
                articleMutationSafety.markUncertain()
                nativeDashboardStatus = "The article request returned without a verifiable receipt. Refresh and review the server article before acting again."
                return false
            }
            articleMutationSafety.clearAfterResolvedOutcome()
            return true
        } catch {
            if let requestError = error as? DashboardRequestError,
               case .httpStatus(let status) = requestError,
               ArticleMutationSafety.isDefiniteRejection(status: status) {
                articleMutationSafety.clearAfterResolvedOutcome()
            } else {
                articleMutationSafety.markUncertain()
            }
            nativeDashboardStatus = articleMutationSafety.isBlocked
                ? "The article change could not be confirmed. Refresh and review the server article before acting again."
                : error.localizedDescription
            return false
        }
    }

    func reviewUncertainArticleMutation() async {
        guard let intent = articleMutationSafety.intent else { return }
        guard intent.actorID == userIDForRequests,
              intent.apiBaseURL == settings.apiBaseURL.normalizedBaseURL.absoluteString else {
            articleMutationSafety.markUncertain()
            nativeDashboardStatus = "The saved article change belongs to a different account or API. Switch to that account and refresh it before review."
            return
        }
        articleMutationSafety.markUncertain()
        isLoadingNativeDashboard = true
        defer { isLoadingNativeDashboard = false }
        do {
            let article: DashboardArticle = try await requestJSON(
                settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("article/\(intent.articleID)"),
                authenticated: false
            )
            guard article.id == intent.articleID, let body = article.content else {
                nativeDashboardStatus = "The server response did not include the full article. The pending change remains locked."
                return
            }
            articleMutationSafety.recordFreshReview(ArticleMutationReview(
                intentID: intent.id, fetchedAt: Date(), serverArticleExists: true,
                serverContent: body, serverTitle: article.title,
                serverContentDigest: ArticleMutationIntent.digest(body)
            ))
            nativeDashboardStatus = "Fresh server article loaded for review. Compare it with the saved intent, then acknowledge to unlock article changes."
        } catch let error as DashboardRequestError {
            if case .httpStatus(404) = error {
                articleMutationSafety.recordFreshReview(ArticleMutationReview(
                    intentID: intent.id, fetchedAt: Date(), serverArticleExists: false,
                    serverContent: nil, serverTitle: nil, serverContentDigest: nil
                ))
                nativeDashboardStatus = "Fresh server read confirms the article is currently missing. Acknowledge only after reviewing the pending intent."
            } else {
                nativeDashboardStatus = "Could not refresh the article for review: \(error.localizedDescription)"
            }
        } catch {
            nativeDashboardStatus = "Could not refresh the article for review: \(error.localizedDescription)"
        }
    }

    func acknowledgeReviewedArticleMutation() {
        guard articleMutationSafety.acknowledgeReviewedOutcome() else {
            nativeDashboardStatus = "Refresh the full server article before acknowledging this change."
            return
        }
        nativeDashboardStatus = "Reviewed server state acknowledged. Article changes are unlocked; any new save will be a separate request."
    }

    func loadNativeShareTree(_ share: DashboardShare) async {
        isLoadingNativeDashboard = true
        nativeDashboardStatus = "Loading share tree"
        defer { isLoadingNativeDashboard = false }

        do {
            let tree: [DashboardShareTreeItem] = try await requestJSON(
                settings.cdnBaseURL.normalizedBaseURL.appendingAPIPath("share/tree/\(share.id)"),
                authenticated: true
            )
            shareTrees[share.id] = tree
            nativeDashboardStatus = tree.isEmpty ? "No tree entries returned." : "Loaded \(tree.count) tree entries."
        } catch {
            nativeDashboardStatus = error.localizedDescription
        }
    }

    func deleteNativeShare(_ share: DashboardShare) async {
        isLoadingNativeDashboard = true
        nativeDashboardStatus = "Deleting share"
        defer { isLoadingNativeDashboard = false }

        do {
            _ = try await requestPrettyText(
                settings.cdnBaseURL.normalizedBaseURL.appendingAPIPath("share/\(share.id)"),
                method: "DELETE",
                authenticated: true
            )
            if selectedShareID == share.id {
                selectedShareID = ""
                shareEditName = ""
                shareEditPath = ""
                shareEditContent = ""
            }
            nativeDashboardStatus = "Deleted share."
            append(meta: "Share deleted", body: share.id, kind: .change)
            await loadNativeDashboardData()
        } catch {
            nativeDashboardStatus = error.localizedDescription
        }
    }

    func createNativeArticle() async {
        let content = articleDraftContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            nativeDashboardStatus = "Write article markdown first."
            return
        }

        let explicitID = articleDraftID.trimmingCharacters(in: .whitespacesAndNewlines)
        let heading = content.split(separator: "\n").first { $0.hasPrefix("# ") }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines) }
        let baseID = explicitID.isEmpty ? (heading ?? "desktop-article") : explicitID
        let id = baseID.slugifiedPath + (baseID.hasSuffix(".md") ? "" : ".md")
        isLoadingNativeDashboard = true
        nativeDashboardStatus = "Creating article"
        defer { isLoadingNativeDashboard = false }

        if await performArticleMutation(.create, articleID: id, content: content) {
            nativeDashboardStatus = "Created \(id)"
            articleDraftID = ""
            articleDraftContent = ""
            append(meta: "Article created", body: id, kind: .change)
            await loadNativeDashboardData()
        } else {
            append(meta: "Article outcome needs review", body: nativeDashboardStatus, kind: .error)
        }
    }

    func loadArticleIntoEditor(_ article: DashboardArticle) {
        selectedArticleID = article.id
        articleEditID = article.id
        articleEditContent = article.content ?? ""
        if article.content == nil {
            Task { await loadArticleContent(article) }
        }
    }

    func loadArticleContent(_ article: DashboardArticle) async {
        do {
            let loaded: DashboardArticle = try await requestJSON(
                settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("article/\(article.id)"),
                authenticated: false
            )
            guard selectedArticleID == article.id else { return }
            articleEditID = loaded.id
            articleEditContent = loaded.content ?? articleEditContent
            if let index = articles.firstIndex(where: { $0.id == article.id }) {
                articles[index] = loaded
            }
            nativeDashboardStatus = "Loaded \(loaded.id)"
        } catch {
            nativeDashboardStatus = error.localizedDescription
        }
    }

    func updateSelectedArticle() async {
        let id = (articleEditID.isEmpty ? selectedArticleID : articleEditID).trimmingCharacters(in: .whitespacesAndNewlines)
        let content = articleEditContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            nativeDashboardStatus = "Select an article first."
            return
        }
        guard !content.isEmpty else {
            nativeDashboardStatus = "Article content cannot be empty."
            return
        }

        isLoadingNativeDashboard = true
        nativeDashboardStatus = "Saving article"
        defer { isLoadingNativeDashboard = false }

        if await performArticleMutation(.update, articleID: id, content: content) {
            nativeDashboardStatus = "Saved \(id)"
            append(meta: "Article saved", body: id, kind: .change)
            await loadNativeDashboardData()
        } else {
            append(meta: "Article outcome needs review", body: nativeDashboardStatus, kind: .error)
        }
    }
}
