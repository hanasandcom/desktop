import XCTest
@testable import Hanasand

final class NativeUploadPreviewTests: XCTestCase {
    func testClassifiesSupportedImageAndVideoTypes() {
        XCTAssertEqual(NativeUploadPreviewKind(fileExtension: "png"), .image)
        XCTAssertEqual(NativeUploadPreviewKind(fileExtension: ".jpeg"), .image)
        XCTAssertEqual(NativeUploadPreviewKind(fileExtension: "mp4"), .video)
        XCTAssertEqual(NativeUploadPreviewKind(fileExtension: "mov"), .video)
    }

    func testOtherAllowedFilesUseTheNonPreviewFallback() {
        XCTAssertEqual(NativeUploadPreviewKind(fileExtension: "pdf"), .other)
        XCTAssertEqual(NativeUploadPreviewKind(fileExtension: "json"), .other)
        XCTAssertEqual(NativeUploadPreviewKind(fileExtension: "unknown-extension"), .other)
        XCTAssertFalse(NativeUploadPreviewKind(fileExtension: "pdf").canPreview(fileSize: 100))
    }

    func testPreviewUsesExistingUploadSizeLimit() {
        let image = NativeUploadPreviewKind(fileExtension: "png")

        XCTAssertTrue(image.canPreview(fileSize: 1))
        XCTAssertTrue(image.canPreview(fileSize: NativePublicMediaImportLimits.maxBytes))
        XCTAssertFalse(image.canPreview(fileSize: 0))
        XCTAssertFalse(image.canPreview(fileSize: NativePublicMediaImportLimits.maxBytes + 1))
    }
}
