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

    func testBundledArticlesResolveOnlyKnownCoverAssets() throws {
        let catalog = try PublicArticleCatalog.bundled()

        XCTAssertEqual(catalog.article(for: "bot")?.coverAsset, .city)
        XCTAssertEqual(catalog.article(for: "cache")?.coverAsset, .art)
        XCTAssertEqual(catalog.article(for: "event")?.coverAsset, .project)
        XCTAssertEqual(catalog.article(for: "lsm")?.coverAsset, .abstract)
        XCTAssertEqual(catalog.article(for: "theme")?.coverAsset, .abstract)
        XCTAssertNil(catalog.article(for: "readme")?.coverAsset)

        for asset in [PublicArticleCoverAsset.city, .art, .project, .abstract] {
            XCTAssertNotNil(
                Bundle.module.url(
                    forResource: asset.resourceName,
                    withExtension: asset.fileExtension,
                    subdirectory: "images/assets"
                ),
                "Missing bundled cover resource for \(asset.rawValue)"
            )
        }
    }

    func testMissingOrUntrustedCoverPathsRemainAbsent() throws {
        let missingImage = Data(#"{"id":"plain","title":"Plain","created":"2024-01-01T00:00:00Z","modified":"2024-01-01T00:00:00Z","content":"Body","metadata":{}}"#.utf8)
        let unknownImage = Data(#"{"id":"unknown","title":"Unknown","created":"2024-01-01T00:00:00Z","modified":"2024-01-01T00:00:00Z","content":"Body","metadata":{"image":"https://example.com/cover.jpg"}}"#.utf8)
        let traversalImage = Data(#"{"id":"traversal","title":"Traversal","created":"2024-01-01T00:00:00Z","modified":"2024-01-01T00:00:00Z","content":"Body","metadata":{"image":"/images/assets/../../private.jpg"}}"#.utf8)

        XCTAssertNil(try JSONDecoder().decode(PublicArticle.self, from: missingImage).coverAsset)
        XCTAssertNil(try JSONDecoder().decode(PublicArticle.self, from: unknownImage).coverAsset)
        XCTAssertNil(try JSONDecoder().decode(PublicArticle.self, from: traversalImage).coverAsset)
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
