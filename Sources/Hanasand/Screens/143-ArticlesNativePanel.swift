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

struct ArticlesNativePanel: View {
    @EnvironmentObject var model: DesktopAgentModel
    @Environment(\.desktopTheme) var theme
    @State var deletingArticle: DashboardArticle?
    @State private var search = ""
    @State private var sortByTitle = false
    @State private var page = 0
    @State private var previewArticle: DashboardArticle?

    private var filteredArticles: [DashboardArticle] {
        PublishingList.articles(model.articles, matching: search, order: sortByTitle ? .title : .newest)
    }
    private var pageCount: Int { PublishingList.pageCount(for: filteredArticles.count) }
    private var currentPage: Int { min(page, pageCount - 1) }

    let columns = [
        GridItem(.adaptive(minimum: 270), spacing: 12, alignment: .top),
    ]

    var body: some View {
        GeometryReader { geometry in
            Group {
                if geometry.size.width >= 780 {
                    HStack(alignment: .top, spacing: 16) {
                        editorColumn
                            .frame(width: min(410, max(320, geometry.size.width * 0.4)))
                        articleColumn
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        editorColumn.frame(maxWidth: .infinity, alignment: .topLeading)
                        articleColumn.frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .alert("Delete article?", isPresented: Binding(
            get: { deletingArticle != nil },
            set: { if !$0 { deletingArticle = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                deletingArticle = nil
            }
            Button("Delete", role: .destructive) {
                if let deletingArticle {
                    Task { await model.deleteSelectedArticle(deletingArticle) }
                }
                deletingArticle = nil
            }
        } message: {
            Text(deletingArticle?.title ?? "This article will be removed.")
        }
        .sheet(item: $previewArticle) { article in
            NativeArticlePreviewSheet(article: article)
                .environmentObject(model)
                .frame(minWidth: 520, minHeight: 420)
        }
    }

    private var editorColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let intent = model.articleMutationSafety.intent {
                mutationReviewPanel(intent)
            }
            NativeGroupPanel(title: "Create article", subtitle: "Markdown article · \(workspaceLabel)") {
                TextField("article-id.md or heading slug", text: $model.articleDraftID)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(theme.text)
                    .padding(12)
                    .background(theme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                TextEditor(text: $model.articleDraftContent)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.text)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 220)
                    .background(theme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                statusActionRow(
                    status: model.articleDraftContent.isEmpty ? "Start with a markdown heading." : "\(model.articleDraftContent.count) chars",
                    title: "Create",
                    icon: "plus",
                    disabled: model.isLoadingNativeDashboard || model.articleMutationSafety.isBlocked
                ) {
                        Task { await model.createNativeArticle() }
                }
            }

            NativeGroupPanel(title: "Edit article", subtitle: model.selectedArticleID.isEmpty ? "Choose an article from the list · \(workspaceLabel)." : "\(model.selectedArticleID) · \(workspaceLabel)") {
                TextField("Article id", text: $model.articleEditID)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.text)
                    .padding(12)
                    .background(theme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                TextEditor(text: $model.articleEditContent)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.text)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 280)
                    .background(theme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                statusActionRow(
                    status: model.selectedArticleID.isEmpty ? "No article selected." : "\(model.articleEditContent.count) chars",
                    title: "Save",
                    icon: "checkmark",
                    disabled: model.selectedArticleID.isEmpty || model.isLoadingNativeDashboard || model.articleMutationSafety.isBlocked
                ) {
                        Task { await model.updateSelectedArticle() }
                }
            }
        }
    }

    private var workspaceLabel: String {
        let organizationID = ArticleWorkspacePolicy.organizationID(model.selectedOrganizationID)
        guard let organizationID else { return "Personal workspace" }
        return model.selectedOrganizationName ?? organizationID
    }

    private func statusActionRow(
        status: String,
        title: String,
        icon: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                statusLabel(status)
                Spacer()
                ActionButton(title: title, icon: icon, action: action)
                    .disabled(disabled)
            }
            VStack(alignment: .leading, spacing: 8) {
                statusLabel(status)
                ActionButton(title: title, icon: icon, action: action)
                    .disabled(disabled)
            }
        }
    }

    private func statusLabel(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func mutationReviewPanel(_ intent: ArticleMutationIntent) -> some View {
        let scope = intent.workspaceScopeKnown ? (intent.organizationID ?? "Personal workspace") : "Workspace not recorded"
        return NativeGroupPanel(title: "Article change needs review", subtitle: "\(intent.action.rawValue.capitalized) · \(intent.articleID) · \(scope)") {
            Text("The request may have reached the server, but Desktop did not receive a verifiable receipt. The service has no idempotency key or revision check, so repeating a request can conflict, overwrite, or remove newer content. Refresh and review the server state before unlocking article changes.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            statusActionRow(
                status: "Submitted \(intent.createdAt.formatted(date: .abbreviated, time: .shortened))",
                title: "Refresh server article",
                icon: "arrow.clockwise",
                disabled: model.isLoadingNativeDashboard
            ) {
                Task { await model.reviewUncertainArticleMutation() }
            }

            if let review = model.articleMutationSafety.review, review.intentID == intent.id {
                VStack(alignment: .leading, spacing: 8) {
                    Text(review.serverArticleExists ? "Fresh server version · \(review.serverTitle ?? intent.articleID)" : "Fresh server read · article not found")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.text)
                    if review.serverArticleExists, let serverContent = review.serverContent {
                        if intent.content != nil, let matches = review.matches(intent) {
                            Label(matches ? "Server content matches submitted text" : "Server content differs from submitted text",
                                  systemImage: matches ? "checkmark.circle" : "exclamationmark.triangle")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(matches ? .green : .orange)
                        }
                        Text("Server content")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(theme.textTertiary)
                        ScrollView {
                            Text(serverContent)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(theme.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 160)
                        .padding(9)
                        .background(theme.field)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    if let submitted = intent.content {
                        DisclosureGroup("Submitted text") {
                            ScrollView {
                                Text(submitted)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(theme.text)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 140)
                        }
                        .font(.system(size: 11, weight: .semibold))
                    }
                    Text("Reviewed at \(review.fetchedAt.formatted(date: .abbreviated, time: .shortened)). Acknowledging clears the barrier; it does not claim whether the original request committed.")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                    ActionButton(title: "Acknowledge and unlock", icon: "checkmark.shield") {
                        model.acknowledgeReviewedArticleMutation()
                    }
                    .disabled(!model.articleMutationSafety.mayAcknowledge)
                    .accessibilityLabel("Acknowledge reviewed state and unlock article changes")
                }
                .padding(10)
                .background(theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.orange.opacity(0.45), lineWidth: 1))
    }

    private var articleColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Label("\(model.articles.count) articles", systemImage: "text.alignleft")
                Text("·")
                Text("Source: Git")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.textSecondary)
            statusActionRow(
                status: model.articles.isEmpty ? "No articles loaded yet." : "Published articles",
                title: "Refresh",
                icon: "arrow.clockwise",
                disabled: model.isLoadingNativeDashboard
            ) {
                Task { await model.loadNativeDashboardData() }
            }

            Label(workspaceLabel, systemImage: "building.2")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    searchField
                    sortButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    searchField
                    sortButton
                }
            }
            Text("\(filteredArticles.count) of \(model.articles.count) articles · page \(currentPage + 1) of \(pageCount)")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)

            if filteredArticles.isEmpty {
                NativeEmptyState(title: model.articles.isEmpty ? "No articles loaded" : "No matching articles",
                                 message: model.articles.isEmpty ? "Create an article or refresh the API-backed article list." : "Try another title or ID search.")
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(PublishingList.page(filteredArticles, number: currentPage)) { article in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(article.title)
                                .font(.system(size: 15, weight: .black))
                                .foregroundStyle(theme.text)
                                .lineLimit(2)
                            Text(article.metadata?.description ?? article.id)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(3)
                            HStack(spacing: 8) {
                                Label(article.readingLabel, systemImage: "book")
                                Label(article.publishedLabel, systemImage: "clock")
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                            HStack(spacing: 8) {
                                Button("Open") {
                                    previewArticle = article
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(theme.accent)
                                Menu {
                                    Button("Edit") {
                                        model.loadArticleIntoEditor(article)
                                    }
                                    Button("Delete", role: .destructive) {
                                        deletingArticle = article
                                    }
                                    .disabled(model.articleMutationSafety.isBlocked)
                                } label: {
                                    Label("More", systemImage: "ellipsis")
                                }
                                .menuStyle(.borderlessButton)
                                .accessibilityLabel("More actions for \(article.title)")
                            }
                            HStack(spacing: 5) {
                                Text("ID")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(theme.textTertiary)
                                Text(article.id)
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(theme.textTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(13)
                        .background(theme.card)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(theme.divider, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                HStack {
                    ActionButton(title: "Previous", icon: "chevron.left") { page = max(0, currentPage - 1) }
                        .disabled(currentPage == 0)
                    Spacer()
                    ActionButton(title: "Next", icon: "chevron.right") { page = min(pageCount - 1, currentPage + 1) }
                        .disabled(currentPage >= pageCount - 1)
                }
            }
        }
    }

    private var searchField: some View {
        TextField("Search titles or IDs", text: Binding(get: { search }, set: { search = $0; page = 0 }))
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Search article titles or IDs")
    }

    private var sortButton: some View {
        ActionButton(title: sortByTitle ? "Sort: title" : "Sort: newest", icon: "arrow.up.arrow.down") {
            sortByTitle.toggle(); page = 0
        }
    }
}

private struct NativeArticlePreviewSheet: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    let article: DashboardArticle
    @State private var content: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(article.title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(theme.text)
                        .textSelection(.enabled)
                    Text("\(article.readingLabel) · Updated \(article.publishedLabel)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.escape)
            }

            if let error {
                NativeNotice(message: error, title: "Article unavailable")
            } else if let content {
                ScrollView {
                    Text((try? AttributedString(markdown: content)) ?? AttributedString(content))
                        .font(.system(size: 14))
                        .foregroundStyle(theme.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .background(theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                ProgressView("Loading article…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .task(id: article.id) { await load() }
    }

    @Environment(\.dismiss) private var dismiss

    @MainActor private func load() async {
        let context = model.articleWorkspaceRequestContext(organizationID: article.organizationID ?? "")
        guard model.isCurrentArticleWorkspaceRequest(context), model.articleWorkspaceRowsContext == context else {
            error = "Refresh the selected publishing workspace before opening this article."
            return
        }
        if let content = article.content {
            self.content = content
            return
        }
        guard (try? ArticleWorkspacePolicy.articleID(article.id)) == article.id else {
            error = "The article identifier is invalid."
            return
        }
        do {
            let loaded = try await model.articleWorkspaceClient(organizationID: article.organizationID ?? "").detail(article.id)
            guard model.isCurrentArticleWorkspaceRequest(context),
                  loaded.id == article.id, loaded.organizationID == article.organizationID,
                  let content = loaded.content else {
                error = "The article did not include readable content."
                return
            }
            self.content = content
        } catch {
            if model.isCurrentArticleWorkspaceRequest(context) {
                self.error = error.localizedDescription
            }
        }
    }
}
