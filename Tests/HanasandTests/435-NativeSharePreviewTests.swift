import XCTest
import WebKit
@testable import Hanasand

final class NativeSharePreviewTests: XCTestCase {
    func testKnownWebFilesAndRuntimeContentCreateHTTPSAliasPreview() throws {
        let tree = try tree(#"[{"id":"root","name":"project","type":"folder","children":[{"id":"html","name":"index.html","type":"file"}]}]"#)
        let url = NativeSharePreview.target(alias: "demo-app", tree: tree, rootContent: nil, activeContent: nil)
        XCTAssertEqual(url?.absoluteString, "https://demo-app.hanasand.com/")

        let dotAlias = NativeSharePreview.target(alias: "demo.team-app", tree: tree, rootContent: nil, activeContent: nil)
        XCTAssertEqual(dotAlias?.host, "demo.team-app.hanasand.com")

        XCTAssertNotNil(NativeSharePreview.target(alias: "source-app", tree: [], rootContent: nil, activeContent: #"{"dependencies":{"vite":"5.0.0"}}"#))
    }

    func testNonHTTPWorkspaceAndUnsafeAliasesDoNotPreview() throws {
        let tree = try tree(#"[{"id":"root","name":"notes","type":"folder","children":[{"id":"note","name":"notes.md","type":"file"}]}]"#)
        XCTAssertNil(NativeSharePreview.target(alias: "notes", tree: tree, rootContent: "plain text", activeContent: nil))

        let webTree = try tree(#"[{"id":"root","name":"project","type":"folder","children":[{"id":"html","name":"index.html","type":"file"}]}]"#)
        for alias in ["", "../evil", "two labels", "bad_name", "-start", "end-", "a..b", "a/evil", "a@evil.test", String(repeating: "a", count: 241)] {
            XCTAssertNil(NativeSharePreview.target(alias: alias, tree: webTree, rootContent: nil, activeContent: nil), "Unexpected accepted alias: \(alias)")
        }
    }

    func testMainFrameNavigationStaysOnHTTPSPreviewOrigin() throws {
        let host = "demo-app.hanasand.com"
        XCTAssertTrue(NativeSharePreview.allowsMainFrameNavigation(to: URL(string: "https://\(host)/docs")!, previewHost: host))
        XCTAssertTrue(NativeSharePreview.allowsMainFrameNavigation(to: URL(string: "https://\(host):443/docs")!, previewHost: host))
        XCTAssertFalse(NativeSharePreview.allowsMainFrameNavigation(to: URL(string: "http://\(host)/")!, previewHost: host))
        XCTAssertFalse(NativeSharePreview.allowsMainFrameNavigation(to: URL(string: "https://other.hanasand.com/")!, previewHost: host))
        XCTAssertFalse(NativeSharePreview.allowsMainFrameNavigation(to: URL(string: "https://\(host):444/")!, previewHost: host))
        XCTAssertFalse(NativeSharePreview.allowsMainFrameNavigation(to: URL(string: "https://user@\(host)/")!, previewHost: host))
    }

    func testPreviewWebViewUsesNonpersistentWebsiteDataStore() {
        XCTAssertFalse(NativeSharePreviewWebView.configuration().websiteDataStore.isPersistent)
    }

    private func tree(_ json: String) throws -> [NativeShareWorkspaceTreeItem] {
        try JSONDecoder().decode([NativeShareWorkspaceTreeItem].self, from: Data(json.utf8))
    }
}
