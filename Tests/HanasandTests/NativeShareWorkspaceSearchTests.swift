import XCTest
@testable import Hanasand

final class NativeShareWorkspaceSearchTests: XCTestCase {
    func testRejectsUnsafeRelativePathsAndDuplicateWorkspaceEntries() throws {
        for path in ["", "/etc/passwd", "../secret.txt", "src/../secret.txt", "src//main.swift", "src\\main.swift", "."] {
            XCTAssertFalse(NativeShareWorkspaceSearchSafety.isSafeRelativePath(path), "Expected unsafe path: \(path)")
        }
        XCTAssertTrue(NativeShareWorkspaceSearchSafety.isSafeRelativePath("src/main.swift"))

        XCTAssertThrowsError(try NativeShareWorkspaceSearch.search(
            files: [file("../outside.swift", content: "needle")], query: "needle"
        ))
        XCTAssertThrowsError(try NativeShareWorkspaceSearch.search(
            files: [file("src/a.swift", id: "same", content: "needle"), file("src/b.swift", id: "same", content: "needle")], query: "needle"
        ))
    }

    func testSearchesOnlySupportedTextExtensionsAndExtensionlessFiles() throws {
        let files = [
            file("src/main.SWIFT", content: "needle"),
            file("README", content: "needle"),
            file("assets/photo.png", content: "needle"),
            file("archive.tar.gz", content: "needle"),
            file(".gitignore", content: "needle"),
        ]

        let response = try NativeShareWorkspaceSearch.search(files: files, query: "needle")
        XCTAssertEqual(response.filesScanned, 2)
        XCTAssertEqual(response.groups.map(\.file.path), ["src/main.SWIFT", "README"])
        XCTAssertEqual(response.totalMatches, 2)
    }

    func testSupportsCaseSensitivityWholeWordRegexAndLineCoordinates() throws {
        let files = [file("src/main.swift", content: "Cat concatenate\ncat\n🙂 cat")]

        let insensitive = try NativeShareWorkspaceSearch.search(files: files, query: "cat")
        XCTAssertEqual(insensitive.totalMatches, 4)
        XCTAssertEqual(insensitive.groups[0].matches.map(\.line), [1, 1, 2, 3])

        var sensitiveOptions = NativeShareWorkspaceSearchOptions()
        sensitiveOptions.caseSensitive = true
        sensitiveOptions.wholeWord = true
        let sensitiveWholeWord = try NativeShareWorkspaceSearch.search(files: files, query: "cat", options: sensitiveOptions)
        XCTAssertEqual(sensitiveWholeWord.totalMatches, 2)
        XCTAssertEqual(sensitiveWholeWord.groups[0].matches.map(\.column), [1, 4])

        var regexOptions = NativeShareWorkspaceSearchOptions()
        regexOptions.regex = true
        regexOptions.caseSensitive = true
        let regex = try NativeShareWorkspaceSearch.search(files: files, query: "c.t", options: regexOptions)
        XCTAssertEqual(regex.totalMatches, 3)
        XCTAssertThrowsError(try NativeShareWorkspaceSearch.search(files: files, query: "[", options: regexOptions)) { error in
            XCTAssertEqual(error as? NativeShareWorkspaceSearchError, .invalidPattern)
        }
    }

    func testLongLinePreviewKeepsMatchAndContextWhenItAppearsAfterCharacterFiveHundred() throws {
        let line = String(repeating: "🙂", count: 600) + "needle" + String(repeating: "z", count: 600)
        let response = try NativeShareWorkspaceSearch.search(files: [file("large.txt", content: line)], query: "needle")
        let preview = try XCTUnwrap(response.groups.first?.matches.first?.preview)

        XCTAssertTrue(preview.contains("needle"))
        XCTAssertTrue(preview.contains("🙂"))
        XCTAssertTrue(preview.contains("z"))
        XCTAssertTrue(preview.hasPrefix("…"))
        XCTAssertTrue(preview.hasSuffix("…"))
        XCTAssertLessThanOrEqual(preview.count, NativeShareWorkspaceSearchLimits.previewCharacters + 2)
    }

    func testLongLinePreviewMarksOnlyTheClippedBoundary() throws {
        let line = "needle" + String(repeating: "x", count: 700) + "needle"
        let response = try NativeShareWorkspaceSearch.search(files: [file("large.txt", content: line)], query: "needle")
        let previews = try XCTUnwrap(response.groups.first?.matches.map(\.preview))

        XCTAssertEqual(previews.count, 2)
        XCTAssertTrue(previews[0].contains("needle"))
        XCTAssertFalse(previews[0].hasPrefix("…"))
        XCTAssertTrue(previews[0].hasSuffix("…"))
        XCTAssertTrue(previews[1].contains("needle"))
        XCTAssertTrue(previews[1].hasPrefix("…"))
        XCTAssertFalse(previews[1].hasSuffix("…"))
    }

    func testIncludeAndExcludeFiltersMatchWebsiteSubstringAndGlobRules() throws {
        let files = [
            file("src/ui/Button.swift", content: "needle"),
            file("src/core/Engine.swift", content: "needle"),
            file("vendor/src/Engine.swift", content: "needle"),
            file("README.md", content: "needle"),
        ]
        var options = NativeShareWorkspaceSearchOptions()
        options.include = "src/*,readme"
        options.exclude = "vendor,*.md"

        let response = try NativeShareWorkspaceSearch.search(files: files, query: "needle", options: options)
        XCTAssertEqual(response.groups.map(\.file.path), ["src/ui/Button.swift", "src/core/Engine.swift"])
        XCTAssertEqual(response.filesScanned, 2)
    }

    func testResultLimitIsBoundedAndReplacementRefusesPartialPlans() throws {
        let files = [file("a.swift", content: "x x x"), file("b.swift", content: "x")]
        let response = try NativeShareWorkspaceSearch.search(files: files, query: "x", maximumMatches: 2)
        XCTAssertEqual(response.totalMatches, 2)
        XCTAssertTrue(response.isTruncated)
        XCTAssertEqual(response.groups.flatMap(\.matches).count, 2)
        XCTAssertThrowsError(try NativeShareWorkspaceSearch.replacementPlans(files: files, query: "x", replacement: "y", maximumMatches: 2)) { error in
            XCTAssertEqual(error as? NativeShareWorkspaceSearchError, .tooManyMatches)
        }
    }

    func testReplacementPlansArePerFileAndSupportRegexCaptureExpansion() throws {
        let files = [
            file("src/a.swift", content: "let first = 12\nlet second = 34"),
            file("src/b.swift", content: "let third = 56"),
            file("README.md", content: "No match"),
        ]
        var options = NativeShareWorkspaceSearchOptions()
        options.regex = true
        options.caseSensitive = true

        let plans = try NativeShareWorkspaceSearch.replacementPlans(
            files: files, query: "let (\\w+) = (\\d+)", replacement: "const $1 = $2;", options: options
        )

        XCTAssertEqual(plans.map(\.path), ["src/a.swift", "src/b.swift"])
        XCTAssertEqual(plans.map(\.matchCount), [2, 1])
        XCTAssertEqual(plans[0].originalContent, "let first = 12\nlet second = 34")
        XCTAssertEqual(plans[0].replacementContent, "const first = 12;\nconst second = 34;")
        XCTAssertEqual(plans[1].replacementContent, "const third = 56;")
    }

    func testLiteralReplacementAndNoOpFiles() throws {
        let files = [file("a.txt", content: "cat cat"), file("b.txt", content: "dog")]
        let plans = try NativeShareWorkspaceSearch.replacementPlans(files: files, query: "cat", replacement: "$&! ")

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].matchCount, 2)
        XCTAssertEqual(plans[0].replacementContent, "cat!  cat! ")
    }

    private func file(_ path: String, id: String? = nil, content: String) -> NativeShareWorkspaceSearchFile {
        let fileID = id ?? path.replacingOccurrences(of: "/", with: "-")
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return NativeShareWorkspaceSearchFile(id: fileID, name: name, path: path, content: content)
    }
}
