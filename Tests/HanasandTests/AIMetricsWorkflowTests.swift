import XCTest
@testable import Hanasand

final class AIMetricsWorkflowTests: XCTestCase {
    func testSummaryAveragesClientLoadsAndAggregatesKnownLaneCapacity() throws {
        let first = try AIMetricsValidation.client([
            "name": "client-a", "ram": [["load": 0.2], ["load": 0.4]],
            "cpu": [["load": 0.1]], "gpu": [["load": 0.2]], "model": ["tps": 2.0],
            "lanes": [["activeRequests": 1, "availableRequests": 2, "maxRequests": 3]]
        ])
        let second = try AIMetricsValidation.client([
            "name": "client-b", "ram": [["load": 0.8]], "cpu": [["load": 0.5]],
            "gpu": [["load": 0.6]], "model": ["tps": 4.0],
            "lanes": [["activeRequests": 2, "availableRequests": 1, "maxRequests": 4]]
        ])

        let summary = AIMetricSummary(clients: [first, second])
        XCTAssertEqual(summary.ramLoad ?? -1, 0.55, accuracy: 0.0001)
        XCTAssertEqual(summary.cpuLoad ?? -1, 0.3, accuracy: 0.0001)
        XCTAssertEqual(summary.gpuLoad ?? -1, 0.4, accuracy: 0.0001)
        XCTAssertEqual(summary.throughput ?? -1, 3, accuracy: 0.0001)
        XCTAssertEqual(summary.activeRequests, 3)
        XCTAssertEqual(summary.availableRequests, 3)
        XCTAssertEqual(summary.maximumRequests, 7)
        XCTAssertEqual(summary.laneCount, 2)
    }

    func testSummaryKeepsPartialTelemetryUnavailable() throws {
        let first = try AIMetricsValidation.client(["name": "client-a", "ram": [["load": 0.2]], "lanes": []])
        let second = try AIMetricsValidation.client(["name": "client-b", "ram": [["load": NSNull()]]])

        let summary = AIMetricSummary(clients: [first, second])
        XCTAssertNil(summary.ramLoad, "Unknown readings must not be displayed as zero or averaged away")
        XCTAssertNil(summary.activeRequests)
        XCTAssertNil(summary.availableRequests)
        XCTAssertNil(summary.maximumRequests)
        XCTAssertNil(summary.laneCount)
    }

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
