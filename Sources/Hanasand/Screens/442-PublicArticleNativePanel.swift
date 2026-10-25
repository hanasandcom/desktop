import SwiftUI
import AppKit

struct PublicArticleNativePanel: View {
    @Environment(\.desktopTheme) private var theme
    private static let bundledCatalog = try? PublicArticleCatalog.bundled()

    let articleID: String?
    let onBrowseArticles: () -> Void
    let onOpenArticle: (String) -> Void

    init(
        articleID: String? = nil,
        onBrowseArticles: @escaping () -> Void,
        onOpenArticle: @escaping (String) -> Void = { _ in }
    ) {
        self.articleID = articleID
        self.onBrowseArticles = onBrowseArticles
        self.onOpenArticle = onOpenArticle
    }

    private var article: PublicArticle? {
        guard let articleID, let catalog = Self.bundledCatalog else { return nil }
        return catalog.article(for: articleID)
    }

    private var publicArticles: [PublicArticle] {
        Self.bundledCatalog?.articles ?? []
    }

    var body: some View {
        Group {
            if articleID == nil {
                articleIndex
            } else if let article {
                articleContent(article)
            } else {
                NativeEmptyState(
                    title: "Article unavailable",
                    message: articleID == "featured" || articleID == "main"
                        ? "Choose an article from the article list."
                        : "This article could not be found."
                )
                Button("Browse articles", action: onBrowseArticles)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var articleIndex: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Articles", systemImage: "book.closed")
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(theme.text)
                    Text("Insights on internet security, performance, and reliability.")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.textSecondary)
                }

                if publicArticles.isEmpty {
                    NativeEmptyState(title: "No published articles", message: "There are no articles to show right now.")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                        ForEach(publicArticles) { article in
                            Button { onOpenArticle(PublicArticleCatalog.normalizedID(article.id)) } label: {
                                articleCard(article)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.vertical, 10)
        }
    }

    private func articleCard(_ article: PublicArticle) -> some View {
        NativeGroupPanel(
            title: article.title,
            subtitle: article.publishedDate.map { "Published \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Published date unavailable"
        ) {
            articleCover(article)

            if let description = article.descriptionText {
                Text(description)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text((article.metadata.wordCount ?? 0) > 100 ? "Read article" : "Brief note")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder private func articleCover(_ article: PublicArticle) -> some View {
        if let asset = article.coverAsset,
           let url = Bundle.module.url(
                forResource: asset.resourceName,
                withExtension: asset.fileExtension
           ),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 142)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.field)
                .overlay {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 24))
                        .foregroundStyle(theme.textTertiary)
                }
                .frame(height: 142)
                .accessibilityHidden(true)
        }
    }

    private func articleContent(_ article: PublicArticle) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                NativeGroupPanel(title: article.title, subtitle: "Published article") {
                    Button(action: onBrowseArticles) {
                        Label("Articles", systemImage: "arrow.left")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accent)

                    if let description = article.descriptionText {
                        Text(description)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { metadata(article) }
                        VStack(alignment: .leading, spacing: 8) { metadata(article) }
                    }
                }

                NativeGroupPanel(title: "Article", subtitle: "") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(PublicArticleMarkdown.blocks(from: article.markdownBody).enumerated()), id: \.offset) { _, block in
                            markdownBlock(block)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(action: onBrowseArticles) {
                    Label("Browse other articles", systemImage: "arrow.left")
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder private func metadata(_ article: PublicArticle) -> some View {
        if let date = article.publishedDate {
            Label("Published \(date.formatted(date: .abbreviated, time: .omitted))", systemImage: "calendar")
        }
        if let date = article.updatedDate {
            Label("Updated \(date.formatted(date: .abbreviated, time: .omitted))", systemImage: "clock")
        }
        if let minutes = article.metadata.estimatedMinutes, minutes > 0 {
            Label("\(minutes) min read", systemImage: "text.alignleft")
        }
    }

    @ViewBuilder private func markdownBlock(_ block: PublicArticleMarkdownBlock) -> some View {
        switch block {
        case let .heading(level, value):
            Text(richText(value))
                .font(.system(size: headingSize(level), weight: .semibold))
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case let .paragraph(value):
            Text(richText(value))
                .font(.system(size: 14))
                .foregroundStyle(theme.textSecondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case let .bullet(value):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Circle().fill(theme.accent).frame(width: 5, height: 5)
                Text(richText(value))
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.leading, 8)
        case let .orderedList(start, items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("\(orderedListNumber(start: start, offset: index)).")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.accent)
                            .frame(minWidth: 22, alignment: .trailing)
                        if let checked = item.checked {
                            Image(systemName: checked ? "checkmark.square.fill" : "square")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(checked ? theme.accent : theme.textTertiary)
                                .accessibilityHidden(true)
                        }
                        Text(richText(item.text))
                            .font(.system(size: 14))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(item.checked.map { "Task \($0 ? "completed" : "not completed"): \(item.text)" } ?? "\(orderedListNumber(start: start, offset: index)). \(item.text)")
                }
            }
            .padding(.leading, 8)
        case let .task(checked, value):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(checked ? theme.accent : theme.textTertiary)
                    .accessibilityHidden(true)
                Text(richText(value))
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.leading, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Task \(checked ? "completed" : "not completed"): \(value)")
        case let .table(headers, alignments, rows):
            PublicArticleMarkdownTable(headers: headers, alignments: alignments, rows: rows, theme: theme)
        case let .quote(value):
            Text(richText(value))
                .font(.system(size: 14, weight: .regular, design: .serif))
                .foregroundStyle(theme.textSecondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(theme.accent).frame(width: 3) }
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case let .code(value):
            Text(value)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(theme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(theme.field)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        case .divider:
            Divider()
        }
    }

    private func richText(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
    }

    private func orderedListNumber(start: Int, offset: Int) -> Int {
        let (number, overflow) = start.addingReportingOverflow(offset)
        return overflow ? Int.max : number
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 24
        case 2: 20
        case 3: 17
        default: 15
        }
    }
}

private struct PublicArticleMarkdownTable: View {
    let headers: [String]
    let alignments: [PublicArticleTableAlignment]
    let rows: [[String]]
    let theme: DesktopTheme

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 0), spacing: 0, alignment: .topLeading), count: headers.count)
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
            ForEach(headers.indices, id: \.self) { index in
                cell(headers[index], column: index, heading: true, row: -1)
            }
            ForEach(rows.indices, id: \.self) { rowIndex in
                ForEach(headers.indices, id: \.self) { columnIndex in
                    cell(rows[rowIndex][columnIndex], column: columnIndex, heading: false, row: rowIndex)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card)
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.divider, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain)
    }

    private func cell(_ value: String, column: Int, heading: Bool, row: Int) -> some View {
        let alignment = alignments[column]
        let textAlignment: TextAlignment
        let frameAlignment: Alignment
        switch alignment {
        case .leading:
            textAlignment = .leading
            frameAlignment = .leading
        case .center:
            textAlignment = .center
            frameAlignment = .center
        case .trailing:
            textAlignment = .trailing
            frameAlignment = .trailing
        }
        return Text(richText(value))
            .font(.system(size: heading ? 12 : 13, weight: heading ? .bold : .regular))
            .foregroundStyle(heading ? theme.text : theme.textSecondary)
            .multilineTextAlignment(textAlignment)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(heading ? theme.cardRaised : (row.isMultiple(of: 2) ? theme.card : theme.field.opacity(0.45)))
            .overlay(alignment: .trailing) { Rectangle().fill(theme.divider).frame(width: 0.5) }
            .overlay(alignment: .bottom) { Rectangle().fill(theme.divider).frame(height: 0.5) }
            .accessibilityLabel(heading ? value : "\(headers[column]): \(value)")
            .textSelection(.enabled)
    }

    private func richText(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
    }
}
