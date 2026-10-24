import Foundation
import XCTest
@testable import Hanasand

final class PublicArticleNativePanelTests: XCTestCase {
    func testPublishedDraftsResolveToFallbackAndFinishedArticlesStayPublished() throws {
        let catalog = try PublicArticleCatalog.bundled()

        let bot = try XCTUnwrap(catalog.article(for: "bot"))
        XCTAssertEqual(bot.id, "bot")
        XCTAssertEqual(bot.title, "How to create a scalable Discord bot for your community")
        XCTAssertTrue(bot.content.contains("Start with the smallest workflow"))
        XCTAssertFalse(bot.content.localizedCaseInsensitiveContains("Coming soon"))
        XCTAssertEqual(bot.metadata.estimatedMinutes, 1)

        let lsm = try XCTUnwrap(catalog.article(for: "lsm.md"))
        XCTAssertEqual(lsm.title, "Library Safety Manager")
        XCTAssertTrue(lsm.content.contains("Sorry, the full thesis is finished"))
    }

    func testPublishedContentWinsWhenItIsNotAnUnfinishedDraft() throws {
        let catalog = try PublicArticleCatalog.bundled()

        let readme = try XCTUnwrap(catalog.article(for: "readme.md"))
        XCTAssertTrue(readme.content.contains("software engineer and security-minded developer"))
        XCTAssertEqual(readme.metadata.wordCount, 322)
    }

    func testPublicArticleIndexIncludesPublishedItemsWithResolvedFallbackCopy() throws {
        let catalog = try PublicArticleCatalog.bundled()
        let articles = catalog.articles

        XCTAssertEqual(articles.count, 6)
        XCTAssertEqual(articles.map { PublicArticleCatalog.normalizedID($0.id) }, ["bot", "cache", "event", "lsm", "readme", "theme"])
        XCTAssertTrue(articles.first(where: { $0.id == "bot" })?.content.contains("Start with the smallest workflow") == true)
        XCTAssertTrue(articles.first(where: { $0.id == "readme.md" })?.content.contains("software engineer and security-minded developer") == true)
    }

    func testUnsafeOrUnknownArticleIDsDoNotResolveToContent() throws {
        let catalog = try PublicArticleCatalog.bundled()

        XCTAssertNil(catalog.article(for: "featured"))
        XCTAssertNil(catalog.article(for: "main"))
        XCTAssertNil(catalog.article(for: "unknown-article"))
        XCTAssertNil(catalog.article(for: "../readme"))
        XCTAssertEqual(catalog.article(for: "  cache.md  ")?.id, "cache")
    }

    func testReaderRemovesTheLeadingTitleAndPreservesMetadataDates() throws {
        let catalog = try PublicArticleCatalog.bundled()
        let article = try XCTUnwrap(catalog.article(for: "bot"))

        XCTAssertFalse(article.markdownBody.hasPrefix("# "))
        XCTAssertTrue(article.markdownBody.hasPrefix("Start with"))
        XCTAssertNotNil(article.publishedDate)
        XCTAssertNotNil(article.updatedDate)
        XCTAssertNotNil(article.descriptionText)
    }

    func testMarkdownParserBuildsNativeReadableBlocks() {
        let blocks = PublicArticleMarkdown.blocks(from: """
        ## Setup

        **Keep this simple.**

        - first item
        - [second item](https://example.com)

        > A useful note

        ```sh
        echo ready
        ```

        ---
        """)

        XCTAssertEqual(blocks, [
            .heading(level: 2, text: "Setup"),
            .paragraph("**Keep this simple.**"),
            .bullet("first item"),
            .bullet("[second item](https://example.com)"),
            .quote("A useful note"),
            .code("echo ready"),
            .divider,
        ])
    }
}
