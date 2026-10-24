import XCTest
@testable import Hanasand

final class NativeBackupArchiveFilteringTests: XCTestCase {
    func testFiltersArchivesByServiceDateAndCaseInsensitiveFilename() {
        let files = [
            NativeBackupFile(service: "core", file: "core-2026-10-24.sql.gz", mtime: "2026-10-24T09:00:00Z", size: "1 KB", sizeBytes: 1024, verified: true, checksumSha256: nil, verifiedAt: nil, releaseCommit: nil),
            NativeBackupFile(service: "analytics", file: "analytics-2026-10-23.sql.gz", mtime: "2026-10-23T09:00:00Z", size: "2 KB", sizeBytes: 2048, verified: false, checksumSha256: nil, verifiedAt: nil, releaseCommit: nil),
            NativeBackupFile(service: "core", file: "core-older.sql.gz", mtime: nil, size: nil, sizeBytes: nil, verified: false, checksumSha256: nil, verifiedAt: nil, releaseCommit: nil),
        ]

        XCTAssertEqual(filterNativeBackupFiles(files, service: "core", date: "2026-10-24", search: "SQL").map(\.file), ["core-2026-10-24.sql.gz"])
        XCTAssertEqual(filterNativeBackupFiles(files, service: "", date: "2026-10-23", search: "").map(\.file), ["analytics-2026-10-23.sql.gz"])
        XCTAssertEqual(filterNativeBackupFiles(files, service: "missing", date: "", search: "").map(\.file), [])
        XCTAssertEqual(filterNativeBackupFiles(files, service: "", date: "", search: "  ").map(\.file), [])
        XCTAssertEqual(selectedNativeBackupFile(files, id: "core-core-2026-10-24.sql.gz", service: "core", date: "", search: "")?.file, "core-2026-10-24.sql.gz")
        XCTAssertNil(selectedNativeBackupFile(files, id: "core-core-2026-10-24.sql.gz", service: "analytics", date: "", search: ""), "A filtered-out archive must not prefill restore")
    }

    func testRestoreRouteDoesNotSilentlyReplaceUnavailableRequestedArchive() {
        let files = [
            NativeBackupFile(service: "core", file: "core-current.sql.gz", mtime: nil, size: nil, sizeBytes: nil, verified: true, checksumSha256: nil, verifiedAt: nil, releaseCommit: nil),
        ]

        XCTAssertEqual(preferredNativeRestoreFileID(files: files, requestedFile: "core-current.sql.gz", currentFileID: "", didChooseArchive: false), files[0].id)
        XCTAssertEqual(preferredNativeRestoreFileID(files: files, requestedFile: "core-removed.sql.gz", currentFileID: "", didChooseArchive: false), "")
        XCTAssertEqual(preferredNativeRestoreFileID(files: files, requestedFile: "core-removed.sql.gz", currentFileID: files[0].id, didChooseArchive: true), files[0].id)
    }
}
