import XCTest
@testable import Hanasand

@MainActor
final class DesktopAIWorkspaceRouteTests: XCTestCase {
    func testRouteConversationIdentifierIsRestoredAsTheInitialNativeSelection() {
        let viewModel = DesktopAIWorkspaceViewModel()
        viewModel.configureRoute(conversationID: "chat-from-route", shareID: nil,
                                 shareFileID: nil, shareFilePath: nil,
                                 createShareConversation: false)

        XCTAssertEqual(viewModel.selectedConversationID, "chat-from-route")
        XCTAssertNil(viewModel.selectedConversation, "The route id is selected immediately; conversation content arrives from the workspace request.")
    }

    func testSelectingAConversationUpdatesTheNativeRouteSelectionState() {
        let viewModel = DesktopAIWorkspaceViewModel()
        viewModel.configureRoute(conversationID: "initial-chat", shareID: nil,
                                 shareFileID: nil, shareFilePath: nil,
                                 createShareConversation: false)

        viewModel.select("another-chat")

        XCTAssertEqual(viewModel.selectedConversationID, "another-chat")
        XCTAssertNil(viewModel.selectedConversation, "Selection can be restored before its workspace data is hydrated.")
    }
}
