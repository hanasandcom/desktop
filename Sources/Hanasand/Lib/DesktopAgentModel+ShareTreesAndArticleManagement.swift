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

    func articleWorkspaceClient(organizationID: String = "") throws -> ArticleWorkspaceClient {
        try ArticleWorkspaceClient(
            settings: settings,
            userID: userIDForRequests,
            authToken: authTokenForRequests,
            organizationID: organizationID
        )
    }

    func articleWorkspaceRequestContext(organizationID: String = "") -> ArticleWorkspaceRequestContext {
        ArticleWorkspaceRequestContext(
            settings: settings,
            userID: userIDForRequests,
            authToken: authTokenForRequests,
            organizationID: organizationID
        )
    }

    func isCurrentArticleWorkspaceRequest(_ context: ArticleWorkspaceRequestContext) -> Bool {
        context.matches(
            settings: settings,
            userID: userIDForRequests,
            authToken: authTokenForRequests,
            organizationID: selectedOrganizationID
        )
    }

    func recordArticleMutationFailure() {
        let title = articleMutationSafety.isBlocked ? "Article outcome needs review" : "Article not changed"
        append(meta: title, body: nativeDashboardStatus, kind: .error)
    }

    func beginArticleMutation(_ action: ArticleMutationAction, articleID: String, content: String?, organizationID: String) -> Bool {
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
            createdAt: Date(), organizationID: ArticleWorkspacePolicy.organizationID(organizationID), workspaceScopeKnown: true
        ))
        return true
    }

    func performArticleMutation(_ action: ArticleMutationAction, articleID: String, content: String? = nil,
                               original: DashboardArticle? = nil) async -> Bool {
        guard articleMutationSafety.canStartMutation else {
            nativeDashboardStatus = "An article change still needs review. Refresh its server state before editing again."
            return false
        }
        let organizationID = selectedOrganizationID
        let userID = userIDForRequests
        let token = authTokenForRequests
        let requestContext = articleWorkspaceRequestContext(organizationID: organizationID)
        let normalizedOrganizationID = ArticleWorkspacePolicy.organizationID(organizationID)
        var began = false
        do {
            let client = try articleWorkspaceClient(organizationID: organizationID)
            let access = try await client.loadAccess()
            guard requestContext.matches(settings: settings, userID: userIDForRequests,
                                         authToken: authTokenForRequests, organizationID: selectedOrganizationID),
                  organizationID == selectedOrganizationID, userID == userIDForRequests,
                  token == authTokenForRequests else { throw ArticleWorkspaceError.scopeChanged }
            guard access.canRead, access.canWrite else { throw ArticleWorkspaceError.readOnly }
            let normalizedID = try ArticleWorkspacePolicy.articleID(articleID)
            if action == .create {
                try await client.prepareCreate(normalizedID)
            } else {
                guard let original, original.id == normalizedID,
                      ArticleWorkspacePolicy.articleBelongs(original, to: normalizedOrganizationID) else {
                    throw ArticleWorkspaceError.scopeChanged
                }
                try await client.prepareExisting(original)
            }
            guard requestContext.matches(settings: settings, userID: userIDForRequests,
                                         authToken: authTokenForRequests, organizationID: selectedOrganizationID),
                  organizationID == selectedOrganizationID, userID == userIDForRequests,
                  token == authTokenForRequests else { throw ArticleWorkspaceError.scopeChanged }
            guard beginArticleMutation(action, articleID: normalizedID, content: content, organizationID: organizationID) else { return false }
            began = true
            _ = try await client.mutate(action, articleID: normalizedID, content: content, original: original, access: access)
            articleMutationSafety.clearAfterResolvedOutcome()
            guard requestContext.matches(settings: settings, userID: userIDForRequests,
                                         authToken: authTokenForRequests, organizationID: selectedOrganizationID) else {
                nativeDashboardStatus = "The article change was confirmed in \(requestContext.organizationID ?? "your personal") workspace. Switch back and refresh to review it."
                return true
            }
            return true
        } catch {
            if began, let articleError = error as? ArticleWorkspaceError, articleError.isDefiniteRejection {
                articleMutationSafety.clearAfterResolvedOutcome()
            } else if began, let requestError = error as? DashboardRequestError,
                      case .httpStatus(let status) = requestError,
                      ArticleMutationSafety.isDefiniteRejection(status: status) {
                articleMutationSafety.clearAfterResolvedOutcome()
            } else if began {
                articleMutationSafety.markUncertain()
            }
            guard requestContext.matches(settings: settings, userID: userIDForRequests,
                                         authToken: authTokenForRequests, organizationID: selectedOrganizationID) else {
                nativeDashboardStatus = "Account, API, or workspace changed during the article request. Refresh before continuing."
                return false
            }
            nativeDashboardStatus = began && articleMutationSafety.isBlocked
                ? "The article change could not be confirmed. Refresh and review the article in its original workspace before acting again."
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
        let selectedOrg = ArticleWorkspacePolicy.organizationID(selectedOrganizationID)
        guard settings.impersonationToken.isEmpty, settings.impersonatingUserID.isEmpty else {
            articleMutationSafety.markUncertain()
            nativeDashboardStatus = "Return to your own account before reviewing the pending article change."
            return
        }
        let requestContext = articleWorkspaceRequestContext(organizationID: selectedOrganizationID)
        if intent.workspaceScopeKnown, intent.organizationID != selectedOrg {
            articleMutationSafety.markUncertain()
            nativeDashboardStatus = "This pending article change belongs to a different workspace. Switch to that workspace before reviewing it."
            return
        }
        articleMutationSafety.markUncertain()
        isLoadingNativeDashboard = true
        defer { isLoadingNativeDashboard = false }
        do {
            let client = try articleWorkspaceClient(organizationID: selectedOrganizationID)
            let article: DashboardArticle
            if intent.workspaceScopeKnown {
                article = try await client.detail(intent.articleID)
            } else {
                article = try await client.detailForLegacyReview(intent.articleID)
            }
            guard isCurrentArticleWorkspaceRequest(requestContext),
                  selectedOrg == ArticleWorkspacePolicy.organizationID(selectedOrganizationID) else { return }
            if !intent.workspaceScopeKnown, !ArticleWorkspacePolicy.articleBelongs(article, to: selectedOrg) {
                nativeDashboardStatus = "This older pending change has no saved workspace. The article is in another workspace; switch there to review it."
                return
            }
            guard let body = article.content else {
                nativeDashboardStatus = "The server response did not include the full article. The pending change remains locked."
                return
            }
            articleMutationSafety.recordFreshReview(ArticleMutationReview(
                intentID: intent.id, fetchedAt: Date(), serverArticleExists: true,
                serverContent: body, serverTitle: article.title,
                serverContentDigest: ArticleMutationIntent.digest(body), organizationID: article.organizationID
            ))
            nativeDashboardStatus = "Fresh server article loaded from \(article.organizationID ?? "personal") for review. Compare it with the saved intent, then acknowledge to unlock article changes."
        } catch let error as DashboardRequestError {
            guard isCurrentArticleWorkspaceRequest(requestContext) else { return }
            if case .httpStatus(404) = error {
                if intent.workspaceScopeKnown {
                    articleMutationSafety.recordFreshReview(ArticleMutationReview(
                        intentID: intent.id, fetchedAt: Date(), serverArticleExists: false,
                        serverContent: nil, serverTitle: nil, serverContentDigest: nil, organizationID: intent.organizationID
                    ))
                    nativeDashboardStatus = "Fresh server read confirms the article is missing from its original workspace. Acknowledge only after reviewing the pending intent."
                } else {
                    nativeDashboardStatus = "This older pending update/delete has no saved workspace and the article is missing, so its original scope cannot be confirmed. The change remains locked."
                }
            } else {
                nativeDashboardStatus = "Could not refresh the article for review: \(error.localizedDescription)"
            }
        } catch let error as ArticleWorkspaceError {
            guard isCurrentArticleWorkspaceRequest(requestContext) else { return }
            if error.statusCode == 404, intent.workspaceScopeKnown {
                articleMutationSafety.recordFreshReview(ArticleMutationReview(
                    intentID: intent.id, fetchedAt: Date(), serverArticleExists: false,
                    serverContent: nil, serverTitle: nil, serverContentDigest: nil, organizationID: intent.organizationID
                ))
                nativeDashboardStatus = "Fresh server read confirms the article is missing from its original workspace. Acknowledge only after reviewing the pending intent."
            } else {
                nativeDashboardStatus = "Could not refresh the article for review: \(error.localizedDescription)"
            }
        } catch {
            guard isCurrentArticleWorkspaceRequest(requestContext) else { return }
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
        let baseID = explicitID.isEmpty ? ((heading ?? "desktop-article").slugifiedPath + ".md") : explicitID
        let id: String
        do { id = try ArticleWorkspacePolicy.articleID(baseID) }
        catch { nativeDashboardStatus = error.localizedDescription; return }
        let requestContext = articleWorkspaceRequestContext(organizationID: selectedOrganizationID)
        isLoadingNativeDashboard = true
        nativeDashboardStatus = "Creating article"
        defer { isLoadingNativeDashboard = false }

        if await performArticleMutation(.create, articleID: id, content: content) {
            guard isCurrentArticleWorkspaceRequest(requestContext) else { return }
            nativeDashboardStatus = "Created \(id)"
            articleDraftID = ""
            articleDraftContent = ""
            append(meta: "Article created", body: id, kind: .change)
            await loadNativeDashboardData()
        } else {
            recordArticleMutationFailure()
        }
    }

    func loadArticleIntoEditor(_ article: DashboardArticle) {
        guard ArticleWorkspacePolicy.articleBelongs(article, to: ArticleWorkspacePolicy.organizationID(selectedOrganizationID)) else {
            nativeDashboardStatus = "This article belongs to a different workspace. Refresh the selected workspace before editing it."
            return
        }
        selectedArticleID = article.id
        articleEditID = article.id
        articleEditContent = article.content ?? ""
        if article.content == nil {
            Task { await loadArticleContent(article) }
        }
    }

    func loadArticleContent(_ article: DashboardArticle) async {
        let organizationID = selectedOrganizationID
        let requestContext = articleWorkspaceRequestContext(organizationID: organizationID)
        do {
            let loaded = try await articleWorkspaceClient(organizationID: organizationID).detail(article.id)
            guard selectedArticleID == article.id, organizationID == selectedOrganizationID,
                  isCurrentArticleWorkspaceRequest(requestContext) else { return }
            articleEditID = loaded.id
            articleEditContent = loaded.content ?? articleEditContent
            if let index = articles.firstIndex(where: { $0.id == article.id }) {
                articles[index] = loaded
            }
            nativeDashboardStatus = "Loaded \(loaded.id)"
        } catch {
            if isCurrentArticleWorkspaceRequest(requestContext) {
                nativeDashboardStatus = error.localizedDescription
            }
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
        guard let original = articles.first(where: { $0.id == selectedArticleID }),
              (try? ArticleWorkspacePolicy.articleID(id)) == original.id else {
            nativeDashboardStatus = "Article IDs are immutable. Refresh and select the article you want to edit."
            return
        }

        let requestContext = articleWorkspaceRequestContext(organizationID: selectedOrganizationID)
        isLoadingNativeDashboard = true
        nativeDashboardStatus = "Saving article"
        defer { isLoadingNativeDashboard = false }

        if await performArticleMutation(.update, articleID: original.id, content: content, original: original) {
            guard isCurrentArticleWorkspaceRequest(requestContext) else { return }
            nativeDashboardStatus = "Saved \(id)"
            append(meta: "Article saved", body: id, kind: .change)
            await loadNativeDashboardData()
        } else {
            recordArticleMutationFailure()
        }
    }
}
