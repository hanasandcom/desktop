import XCTest
@testable import Hanasand

final class OrganizationWatchlistTests: XCTestCase {
    private func decodePage(_ json: String) throws -> OrganizationWatchlistPage {
        try JSONDecoder().decode(OrganizationWatchlistPage.self, from: Data(json.utf8))
    }

    private let pageJSON = #"""
    {"organization":{"id":"org-one","name":"Example Org","lifecycleStatus":"active"},"watchlistItems":[{"id":"item-1","organizationId":"org-one","kind":"domain","value":"example.org","notes":"Main domain","status":"active","updatedAt":"2026-01-01T00:00:00Z"}],"sharedWatchlistContract":{"organizationId":"org-one","capabilities":{"authoritativeProjectionSync":true,"projectionReconcile":true,"projectionReceiptSchemaVersion":"organization.watchlist_projection_receipt.v1"},"permissions":{"canRead":true,"canWrite":true,"canArchive":true,"canCleanup":false}}}
    """#

    func testDecodesOrgScopedItemsAndCapabilities() throws {
        let page = try decodePage(pageJSON)
        XCTAssertEqual(page.organization.id, "org-one")
        XCTAssertEqual(page.watchlistItems.first?.value, "example.org")
        XCTAssertTrue(page.projectionSupported)
        XCTAssertTrue(organizationWatchlistMayWrite(page: page, selectedOrganizationID: "org-one", isImpersonating: false))
        XCTAssertFalse(organizationWatchlistMayWrite(page: page, selectedOrganizationID: "other-org", isImpersonating: false))
        XCTAssertFalse(organizationWatchlistMayWrite(page: page, selectedOrganizationID: "org-one", isImpersonating: true))
    }

    func testRejectsCrossOrganizationItemsAndDuplicateIds() {
        let crossOrganization = pageJSON.replacingOccurrences(of: #""organizationId":"org-one","kind""#, with: #""organizationId":"other-org","kind""#)
        XCTAssertThrowsError(try decodePage(crossOrganization))
        let duplicate = pageJSON.replacingOccurrences(of: #"],"sharedWatchlistContract""#, with: #",{"id":"item-1","organizationId":"org-one","kind":"domain","value":"example.org","notes":"Main domain","status":"active","updatedAt":"2026-01-01T00:00:00Z"}],"sharedWatchlistContract""#)
        XCTAssertThrowsError(try decodePage(duplicate))
    }

    func testUnsupportedProjectionReceiptDoesNotEnableSupportedProjectionFeatures() throws {
        let page = try decodePage(pageJSON.replacingOccurrences(of: "organization.watchlist_projection_receipt.v1", with: "future.schema"))
        XCTAssertFalse(page.projectionSupported)
        XCTAssertTrue(page.sharedWatchlistContract.permissions.canWrite)
    }

    func testDecodesCleanupAndFreshCollectionReceipts() throws {
        let cleanup = try JSONDecoder().decode(OrganizationWatchlistCleanupReceipt.self, from: Data(#"{"cleanup":{"archivedCount":2,"skippedItemIds":["stale"]}}"#.utf8))
        XCTAssertEqual(cleanup.cleanup?.archivedCount, 2)
        XCTAssertEqual(cleanup.cleanup?.skippedItemIds, ["stale"])
        let collection = try JSONDecoder().decode(OrganizationCollectionRequestEnvelope.self, from: Data(#"{"collectionRequest":{"requestId":"request-1","status":"running","captureCount":3,"alertCount":1}}"#.utf8))
        XCTAssertEqual(collection.collectionRequest?.id, "request-1")
        XCTAssertEqual(collection.collectionRequest?.status, "running")
        XCTAssertEqual(collection.collectionRequest?.captureCount, 3)
    }
}
