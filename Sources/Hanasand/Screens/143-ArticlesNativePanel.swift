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
            NativeGroupPanel(title: "Create article", subtitle: "Markdown article through the API") {
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

                HStack {
                    Text(model.articleDraftContent.isEmpty ? "Start with a markdown heading." : "\(model.articleDraftContent.count) chars")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                    Spacer()
                    ActionButton(title: "Create", icon: "plus") {
                        Task { await model.createNativeArticle() }
                    }
                    .disabled(model.isLoadingNativeDashboard)
                }
            }

            NativeGroupPanel(title: "Edit article", subtitle: model.selectedArticleID.isEmpty ? "Choose an article from the list." : model.selectedArticleID) {
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

                HStack {
                    Text(model.selectedArticleID.isEmpty ? "No article selected." : "\(model.articleEditContent.count) chars")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                    Spacer()
                    ActionButton(title: "Save", icon: "checkmark") {
                        Task { await model.updateSelectedArticle() }
                    }
                    .disabled(model.selectedArticleID.isEmpty || model.isLoadingNativeDashboard)
                }
            }
        }
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
            HStack {
                Text(model.articles.isEmpty ? "No articles loaded yet." : "Published articles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                Spacer()
                ActionButton(title: "Refresh", icon: "arrow.clockwise") {
                    Task { await model.loadNativeDashboardData() }
                }
            }

            HStack(spacing: 10) {
                TextField("Search titles or IDs", text: Binding(get: { search }, set: { search = $0; page = 0 }))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search article titles or IDs")
                ActionButton(title: sortByTitle ? "Sort: title" : "Sort: newest", icon: "arrow.up.arrow.down") {
                    sortByTitle.toggle(); page = 0
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
        if let content = article.content {
            self.content = content
            return
        }
        guard NativeRouteSelection.resolve(article.id, among: [article.id]) != nil,
              let id = article.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) else {
            error = "The article identifier is invalid."
            return
        }
        do {
            let loaded: DashboardArticle = try await model.requestJSON(
                model.settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("article/\(id)"),
                authenticated: false
            )
            guard loaded.id == article.id, let content = loaded.content else {
                error = "The article did not include readable content."
                return
            }
            self.content = content
        } catch {
            self.error = error.localizedDescription
        }
    }
}
