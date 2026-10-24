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
        let underscoredAlias = NativeSharePreview.target(alias: "demo_team", tree: tree, rootContent: nil, activeContent: nil)
        XCTAssertEqual(underscoredAlias?.host, "demo_team.hanasand.com")

        XCTAssertNotNil(NativeSharePreview.target(alias: "source-app", tree: [], rootContent: nil, activeContent: #"{"dependencies":{"vite":"5.0.0"}}"#))
    }

    func testActiveContentFallsBackToRootContentOnlyWhenEmpty() throws {
        let tree = try tree(#"[{"id":"root","name":"notes","type":"folder","children":[{"id":"note","name":"notes.md","type":"file"}]}]"#)
        XCTAssertNotNil(NativeSharePreview.target(alias: "root-port", tree: tree, rootContent: "EXPOSE 8080", activeContent: ""))
        XCTAssertNil(NativeSharePreview.target(alias: "active-note", tree: tree, rootContent: "PORT=8080", activeContent: "ordinary notes"))
    }

    func testPortDetectionMatchesWebsitePatterns() throws {
        let portPatterns = ["EXPOSE 8080", "PORT=3000", "PORT: 3000", "listen(8080)", "ListenAndServe(\":8080\")"]
        for content in portPatterns {
            XCTAssertNotNil(NativeSharePreview.target(alias: "port-app", tree: [], rootContent: content, activeContent: nil),
                            "Expected website port pattern to enable preview: \(content)")
        }
        XCTAssertNil(NativeSharePreview.target(alias: "long-port", tree: [], rootContent: "PORT=123456", activeContent: nil))
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

    func testSubframesAreAllowedButPopupsAndOffOriginMainFrameNavigationAreBlocked() {
        let host = "demo-app.hanasand.com"
        let external = URL(string: "https://external.example/")!
        XCTAssertTrue(NativeSharePreview.allowsNavigation(isMainFrame: false, hasTargetFrame: true, to: external, previewHost: host))
        XCTAssertFalse(NativeSharePreview.allowsNavigation(isMainFrame: false, hasTargetFrame: false, to: external, previewHost: host))
        XCTAssertFalse(NativeSharePreview.allowsNavigation(isMainFrame: true, hasTargetFrame: true, to: external, previewHost: host))
        XCTAssertTrue(NativeSharePreview.allowsResponse(isForMainFrame: false, to: external, previewHost: host))
        XCTAssertFalse(NativeSharePreview.allowsResponse(isForMainFrame: true, to: external, previewHost: host))
    }

    func testPreviewWebViewUsesNonpersistentWebsiteDataStore() {
        XCTAssertFalse(NativeSharePreviewWebView.configuration().websiteDataStore.isPersistent)
    }

    private func tree(_ json: String) throws -> [NativeShareWorkspaceTreeItem] {
        try JSONDecoder().decode([NativeShareWorkspaceTreeItem].self, from: Data(json.utf8))
    }
}
