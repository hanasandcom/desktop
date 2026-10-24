import XCTest
@testable import Hanasand

final class NativeVMConsoleTests: XCTestCase {
    func testConsoleRequiresExplicitReviewAndOwnAccountAuthentication() {
        XCTAssertFalse(nativeVMConsoleMayOpen(hasAuth: true, isImpersonating: false, reviewed: false, userID: "user-1", token: "secret"))
        XCTAssertTrue(nativeVMConsoleMayOpen(hasAuth: true, isImpersonating: false, reviewed: true, userID: "user-1", token: "secret"))
        XCTAssertFalse(nativeVMConsoleMayOpen(hasAuth: true, isImpersonating: true, reviewed: true, userID: "user-1", token: "secret"))
        XCTAssertFalse(nativeVMConsoleMayOpen(hasAuth: false, isImpersonating: false, reviewed: true, userID: "user-1", token: "secret"))
        XCTAssertFalse(nativeVMConsoleMayOpen(hasAuth: true, isImpersonating: false, reviewed: true, userID: " ", token: "secret"))
    }

    func testNestedVMConsoleURLKeepsBasePathAndEncodesNameAsOneSegment() throws {
        let url = try XCTUnwrap(nativeVMConsoleWebSocketURL(apiBaseURL: "https://api.example.test/api", vmName: "vm-17"))
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.path, "/api/ws/vm/vm-17/console")
    }

    func testConsoleRouteRejectsCompositeVMName() {
        XCTAssertNil(nativeVMConsoleWebSocketURL(apiBaseURL: "https://api.example.test/api", vmName: "cluster-1/node-2"))
    }
}
