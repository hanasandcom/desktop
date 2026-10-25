import XCTest
@testable import Hanasand

final class GalleryAlbumPreviewRouteTests: XCTestCase {
    func testAlbumItemPreviewUsesRegisteredNativeRouteAndPreservesExactFileID() {
        let item = GalleryAlbumItem(id: "private/file-27", name: "Trip video", type: "video/mp4", owner: "owner", addedBy: "owner")
        let route = GalleryAlbumPreviewRoute(item: item)

        XCTAssertTrue(NativeDashboardDetail.hasNativePanel(for: GalleryAlbumPreviewRoute.path))
        XCTAssertEqual(GalleryAlbumPreviewRoute.path, "/cdn/files")
        XCTAssertEqual(route.detailID, item.id)
        XCTAssertEqual(route.label, "Trip video")
    }
}
