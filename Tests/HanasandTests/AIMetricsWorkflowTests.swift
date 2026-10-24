import XCTest
@testable import Hanasand

final class AIMetricsWorkflowTests: XCTestCase {
    func testPromptBoundsHistoryAndExactExplicitTargetWireShape() throws {
        let prior = [AIMetricPromptMessage(role: "assistant", content: "prior")]
        let messages = try AIMetricsValidation.prompt("  test this model  ", history: prior)
        XCTAssertEqual(messages.last?.content, "test this model")
        let request = try AIMetricsValidation.promptRequest(clientName: "selected-client", conversationID: "stable-id", messages: messages)
        XCTAssertEqual(request["type"] as? String, "prompt_request")
        XCTAssertEqual(request["clientName"] as? String, "selected-client")
        XCTAssertEqual(request["conversationId"] as? String, "stable-id")
        XCTAssertEqual(request["maxTokens"] as? Int, 512)
        XCTAssertEqual(request["temperature"] as? Double, 0.7)
        XCTAssertEqual((request["messages"] as? [[String: String]])?.last?["content"], "test this model")
        XCTAssertThrowsError(try AIMetricsValidation.prompt(String(repeating: "x", count: 8_001), history: []))
        XCTAssertThrowsError(try AIMetricsValidation.prompt("x", history: (0..<40).map { _ in AIMetricPromptMessage(role: "user", content: "x") }))
        XCTAssertThrowsError(try AIMetricsValidation.prompt("x", history: [AIMetricPromptMessage(role: "system", content: "not allowed")]))
        XCTAssertThrowsError(try AIMetricsValidation.promptRequest(clientName: "", conversationID: "stable-id", messages: messages))
    }

    func testUncertainSendRequiresBothFreshManualHTTPReviewAndLiveSnapshot() {
        var gate = AIMetricReviewGate()
        XCTAssertFalse(gate.requiresReview)
        gate.markUncertain()
        XCTAssertTrue(gate.requiresReview)
        gate.markManualHTTPReview(succeeded: true)
        XCTAssertTrue(gate.requiresReview, "HTTP refresh alone cannot clear an uncertain sent prompt")
        gate.markFreshLiveSnapshot()
        XCTAssertFalse(gate.requiresReview)
        gate.markUncertain()
        gate.markFreshLiveSnapshot()
        XCTAssertTrue(gate.requiresReview, "a socket snapshot alone cannot clear the gate")
        gate.markManualHTTPReview(succeeded: false)
        XCTAssertTrue(gate.requiresReview, "failed refresh cannot clear the gate")
        gate.markManualHTTPReview(succeeded: true)
        XCTAssertFalse(gate.requiresReview)
    }

    func testPromptTestingRequiresOwnAccountAndExplicitLiveTarget() throws {
        let client = try AIMetricsValidation.client(["name": "model-a", "model": ["status": "connected"]])
        var settings = HanasandDesktopSettings()
        XCTAssertTrue(AIMetricsValidation.canTestPrompt(settings: settings, selectedClient: "model-a", liveClients: [client], hasFreshSnapshot: true, requiresReview: false))
        XCTAssertFalse(AIMetricsValidation.canTestPrompt(settings: settings, selectedClient: "model-b", liveClients: [client], hasFreshSnapshot: true, requiresReview: false))
        XCTAssertFalse(AIMetricsValidation.canTestPrompt(settings: settings, selectedClient: "model-a", liveClients: [client], hasFreshSnapshot: false, requiresReview: false))
        XCTAssertFalse(AIMetricsValidation.canTestPrompt(settings: settings, selectedClient: "model-a", liveClients: [client], hasFreshSnapshot: true, requiresReview: true))
        settings.impersonatingUserID = "other-user"
        XCTAssertFalse(AIMetricsValidation.canTestPrompt(settings: settings, selectedClient: "model-a", liveClients: [client], hasFreshSnapshot: true, requiresReview: false))
        settings.impersonatingUserID = ""; settings.impersonationToken = "impersonation-token"
        XCTAssertFalse(AIMetricsValidation.canTestPrompt(settings: settings, selectedClient: "model-a", liveClients: [client], hasFreshSnapshot: true, requiresReview: false))
    }

    func testScopeResetClearsUncertainStateWhenAccountChanges() {
        var gate = AIMetricReviewGate(); gate.markUncertain()
        gate.resetScope()
        XCTAssertFalse(gate.requiresReview)
    }

    @MainActor
    func testSocketDeadlineCancelsStalledReceiveAndCompletesCleanup() async {
        final class StalledSocket {
            var isCancelled = false
            func cancel() { isCancelled = true }
        }
        let socket = StalledSocket()
        var watchdog: Task<Void, Never>?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            watchdog = AIMetricSocketDeadline.schedule(after: .milliseconds(20)) {
                socket.cancel()
                continuation.resume()
            }
        }
        await watchdog?.value
        XCTAssertTrue(socket.isCancelled, "A stalled receive must be interrupted by its timeout callback")

        var firedAfterCancellation = false
        let cancelled = AIMetricSocketDeadline.schedule(after: .milliseconds(20)) { firedAfterCancellation = true }
        cancelled.cancel()
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(firedAfterCancellation, "completed/cancelled deadlines must not fire later")
    }
}
