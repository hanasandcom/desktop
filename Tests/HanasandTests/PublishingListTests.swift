import XCTest
@testable import Hanasand

final class PublishingListTests: XCTestCase {
    func testArticleSearchMatchesAllTermsAcrossTitleAndIDAndResetsPageSlice() {
        let items = [
            DashboardArticle(id: "guide-search.md", size: nil, created: "2026-10-20T00:00:00Z", modified: nil, metadata: nil, title: "Search guide", content: nil),
            DashboardArticle(id: "search-api.md", size: nil, created: "2026-10-21T00:00:00Z", modified: nil, metadata: nil, title: "API guide", content: nil),
            DashboardArticle(id: "unrelated.md", size: nil, created: "2026-10-22T00:00:00Z", modified: nil, metadata: nil, title: "Unrelated", content: nil),
        ]

        let filtered = PublishingList.articles(items, matching: "  GUIDE   search ", order: .newest)

        XCTAssertEqual(filtered.map(\.id), ["search-api.md", "guide-search.md"])
        XCTAssertEqual(PublishingList.page(filtered, number: 0).map(\.id), ["search-api.md", "guide-search.md"])
        XCTAssertTrue(PublishingList.page(filtered, number: 1).isEmpty)
    }

    func testThoughtsSortByTitleOrLatestUpdateWithDeterministicTies() {
        let items = [
            DashboardThought(id: "3", title: "Zebra thought", createdAt: "2026-10-20T00:00:00Z", createdBy: "user-1", updatedAt: nil),
            DashboardThought(id: "2", title: "Apple thought", createdAt: "2026-10-21T00:00:00Z", createdBy: "user-2", updatedAt: nil),
            DashboardThought(id: "1", title: "Another apple", createdAt: "2026-10-21T00:00:00Z", createdBy: "user-1", updatedAt: nil),
        ]

        XCTAssertEqual(PublishingList.thoughts(items, matching: "", order: .title).map(\.id), ["1", "2", "3"])
        XCTAssertEqual(PublishingList.thoughts(items, matching: "user-1", order: .newest).map(\.id), ["1", "3"])
    }

    func testPageCountAndSlicesCoverEveryItemWithoutOverflow() {
        let items = Array(0..<41)

        XCTAssertEqual(PublishingList.pageCount(for: 0), 1)
        XCTAssertEqual(PublishingList.pageCount(for: 20), 1)
        XCTAssertEqual(PublishingList.pageCount(for: 21), 2)
        XCTAssertEqual(PublishingList.pageCount(for: 41), 3)
        XCTAssertEqual(PublishingList.page(items, number: 0), Array(0..<20))
        XCTAssertEqual(PublishingList.page(items, number: 1), Array(20..<40))
        XCTAssertEqual(PublishingList.page(items, number: 2), [40])
        XCTAssertEqual(PublishingList.page(items, number: 10), [])
    }
}
