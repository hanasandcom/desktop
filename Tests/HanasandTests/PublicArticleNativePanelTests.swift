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
                    withExtension: asset.fileExtension
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

    func testMarkdownParserPreservesOrderedListsAndTheirStartingNumber() {
        let blocks = PublicArticleMarkdown.blocks(from: """
        Follow these steps:

        3. Review the saved version.

        4) Confirm the changes.
        5. Save the article.

        Then return to the list.
        """)

        XCTAssertEqual(blocks, [
            .paragraph("Follow these steps:"),
            .orderedList(start: 3, items: [
                PublicArticleMarkdownListItem(text: "Review the saved version.", checked: nil),
                PublicArticleMarkdownListItem(text: "Confirm the changes.", checked: nil),
                PublicArticleMarkdownListItem(text: "Save the article.", checked: nil),
            ]),
            .paragraph("Then return to the list."),
        ])
    }

    func testMarkdownParserReadsGFMTableAlignmentEmptyAndEscapedCells() {
        let blocks = PublicArticleMarkdown.blocks(from: #"""
        | Name | Center | Right | Empty |
        | :--- | :---: | ---: | --- |
        | A \| B | middle | 7 | |
        | short | | 9 |
        """#)

        XCTAssertEqual(blocks, [
            .table(
                headers: ["Name", "Center", "Right", "Empty"],
                alignments: [.leading, .center, .trailing, .leading],
                rows: [["A \\| B", "middle", "7", ""], ["short", "", "9", ""]]
            ),
        ])
    }

    func testMarkdownParserNormalizesShortAndLongGFMTableRowsAndStopsAtMalformedRow() {
        let blocks = PublicArticleMarkdown.blocks(from: """
        Name | Count | Note
        :--- | ---: | :---:
        Ada | 2
        Grace | 3 | compiler | ignored
        this line is not a table row

        - ordinary list item
        """)

        XCTAssertEqual(blocks, [
            .table(
                headers: ["Name", "Count", "Note"],
                alignments: [.leading, .trailing, .center],
                rows: [["Ada", "2", ""], ["Grace", "3", "compiler"]]
            ),
            .paragraph("this line is not a table row"),
            .bullet("ordinary list item"),
        ])
    }

    func testMarkdownParserKeepsPipesInsideInlineCodeInTheSameCell() {
        let blocks = PublicArticleMarkdown.blocks(from: """
        Expression | Meaning
        :--- | :---:
        `a | b` | the pipe is code, not a cell boundary
        """)

        XCTAssertEqual(blocks, [
            .table(
                headers: ["Expression", "Meaning"],
                alignments: [.leading, .center],
                rows: [["`a | b`", "the pipe is code, not a cell boundary"]]
            ),
        ])
    }

    func testMarkdownParserLeavesMalformedGFMSeparatorAsParagraphText() {
        let blocks = PublicArticleMarkdown.blocks(from: """
        Name | Count
        :-- | nope
        """)

        XCTAssertEqual(blocks, [.paragraph("Name | Count :-- | nope")])

        let escapedPipeOnly = PublicArticleMarkdown.blocks(from: #"""
        A \| B
        ---
        """#)
        XCTAssertEqual(escapedPipeOnly, [.paragraph("A \\| B"), .divider])
    }

    func testMarkdownParserDistinguishesCheckedTaskListsFromOrdinaryBullets() {
        let blocks = PublicArticleMarkdown.blocks(from: """
        - [x] Completed setup
        - [ ] Pending review
        - [X] Uppercase marker
        - [x]not a task marker
        - ordinary bullet
        2. [ ] Numbered pending task
        3. [x] Numbered completed task
        """)

        XCTAssertEqual(blocks, [
            .task(checked: true, text: "Completed setup"),
            .task(checked: false, text: "Pending review"),
            .task(checked: true, text: "Uppercase marker"),
            .bullet("[x]not a task marker"),
            .bullet("ordinary bullet"),
            .orderedList(start: 2, items: [
                PublicArticleMarkdownListItem(text: "Numbered pending task", checked: false),
                PublicArticleMarkdownListItem(text: "Numbered completed task", checked: true),
            ]),
        ])
    }
}
