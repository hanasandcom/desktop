import XCTest
@testable import Hanasand

@MainActor
final class NativeVMConsoleSessionTests: XCTestCase {
    func testBootOutputNeverEntersInteractiveTerminalAndBootErrorDoesNotCloseIt() throws {
        let session = makeSession()
        session.handleMessage(try event(["type": "ready", "username": "vm-17"]))
        session.handleMessage(try event(["type": "output", "data": "shell$ "]))
        session.handleMessage(try event(["type": "boot-output", "data": "kernel log only\n"]))
        let statusBeforeBootError = session.status

        session.handleMessage(try event(["type": "boot-error", "message": "ignored by the native client"] ))

        let terminalText = session.terminal.historyRows.flatMap(\.runs).map(\.text).joined()
        XCTAssertTrue(session.isConnected)
        XCTAssertEqual(session.status, statusBeforeBootError)
        XCTAssertTrue(terminalText.contains("shell$"))
        XCTAssertFalse(terminalText.contains("kernel log only"))
        XCTAssertEqual(session.bootLog.text, "kernel log only\n")
        XCTAssertEqual(session.bootLog.status, "Boot log is unavailable; the guest console remains separate.")
    }

    func testDisconnectClearsRetainedBootLog() throws {
        let session = makeSession()
        session.handleMessage(try event(["type": "boot-output", "data": "retained boot output"]))
        XCTAssertFalse(session.bootLog.text.isEmpty)

        session.disconnect()

        XCTAssertTrue(session.bootLog.text.isEmpty)
        XCTAssertEqual(session.bootLog.status, "Waiting for boot output.")
    }

    func testCredentialResetClearsRetainedBootLog() throws {
        let session = makeSession()
        session.handleMessage(try event(["type": "boot-output", "data": "retained boot output"]))

        session.updateCredentials(
            apiBaseURL: "https://new-api.example.test",
            userID: "user-2",
            token: "new-token",
            isImpersonating: false,
            provisioningFlow: true
        )

        XCTAssertTrue(session.bootLog.text.isEmpty)
        XCTAssertEqual(session.bootLog.status, "Waiting for boot output.")
    }

    private func makeSession() -> NativeVMConsoleSession {
        NativeVMConsoleSession(
            apiBaseURL: "https://api.example.test",
            vmName: "vm-17",
            userID: "user-1",
            token: "test-token",
            isImpersonating: false,
            provisioningFlow: true
        )
    }

    private func event(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }
}
