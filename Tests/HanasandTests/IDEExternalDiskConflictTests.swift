import Foundation
import XCTest
@testable import Hanasand

final class IDEExternalDiskConflictTests: XCTestCase {
    @MainActor
    func testManualSaveAndSamePathSaveDiskPreserveNewerExternalContents() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        try fixture.replaceDisk(with: "external version")

        XCTAssertFalse(model.saveCurrent())
        model.exportCurrent(to: fixture.url)

        XCTAssertEqual(try String(contentsOf: fixture.url, encoding: .utf8), "external version")
        XCTAssertEqual(model.editorText, "local draft")
        XCTAssertTrue(model.isDirty)
        let recoveredDrafts = try XCTUnwrap(UserDefaults.standard.data(forKey: model.draftKey))
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: recoveredDrafts)["disk-file"], "local draft")
        XCTAssertTrue(model.status.contains("Reload it"))
    }

    @MainActor
    func testAutosavePreservesNewerExternalContentsAndConflictStatus() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        try fixture.replaceDisk(with: "external version")

        model.autosaveCurrent()
        try await Task.sleep(nanoseconds: 5_200_000_000)

        XCTAssertEqual(try String(contentsOf: fixture.url, encoding: .utf8), "external version")
        XCTAssertEqual(model.editorText, "local draft")
        XCTAssertEqual(model.autosaveState, "Disk changed externally")
        XCTAssertTrue(model.status.contains("Reload it"))
    }

    @MainActor
    func testExplicitOverwriteReplacesExternalContentsAndRefreshesDiskBaseline() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        try fixture.replaceDisk(with: "external version")
        XCTAssertTrue(model.selectedDiskFileChangedExternally)

        model.overwriteCurrentDiskFile()

        XCTAssertEqual(try String(contentsOf: fixture.url, encoding: .utf8), "local draft")
        XCTAssertFalse(model.selectedDiskFileChangedExternally)
        XCTAssertEqual(model.savedSnapshots["disk-file"], "local draft")
        XCTAssertEqual(model.status, "example.swift saved locally")
    }

    @MainActor
    func testReloadRecoversExternalContentsWithoutWritingTheDraft() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        try fixture.replaceDisk(with: "external version")

        model.reloadCurrentFromDisk()

        XCTAssertEqual(model.editorText, "external version")
        XCTAssertEqual(try String(contentsOf: fixture.url, encoding: .utf8), "external version")
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(model.selectedDiskFileChangedExternally)
    }

    @MainActor
    func testDeletedDiskFileBlocksSaveButCanBeExplicitlyRecreated() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        try FileManager.default.removeItem(at: fixture.url)

        XCTAssertTrue(model.selectedDiskFileChangedExternally)
        XCTAssertFalse(model.saveCurrent())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.path))

        model.overwriteCurrentDiskFile()

        XCTAssertEqual(try String(contentsOf: fixture.url, encoding: .utf8), "local draft")
        XCTAssertFalse(model.selectedDiskFileChangedExternally)
    }
}

private struct Fixture {
    let url: URL
    let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
    let priorDrafts: Any?

    init() throws {
        priorDrafts = UserDefaults.standard.object(forKey: "hanasand.desktop.ide.drafts")
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ide-conflict-\(UUID().uuidString).swift")
        try Data("original".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: url.path)
    }

    @MainActor
    func makeModel() -> IDEWorkspaceModel {
        let model = IDEWorkspaceModel()
        let file = IDEShareFile(
            id: "disk-file",
            title: "example.swift",
            path: url.path,
            language: "Swift",
            icon: "swift",
            seed: "original",
            diskPath: url.path,
            diskModifiedAt: originalDate
        )
        model.files = [file]
        model.selectedFileID = file.id
        model.openFileIDs = [file.id]
        model.editorText = "local draft"
        model.drafts[file.id] = model.editorText
        model.savedSnapshots[file.id] = "original"
        model.autoformatEnabled = false
        return model
    }

    func replaceDisk(with contents: String) throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: originalDate.addingTimeInterval(10)],
            ofItemAtPath: url.path
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: url)
        if let priorDrafts {
            UserDefaults.standard.set(priorDrafts, forKey: "hanasand.desktop.ide.drafts")
        } else {
            UserDefaults.standard.removeObject(forKey: "hanasand.desktop.ide.drafts")
        }
    }
}
