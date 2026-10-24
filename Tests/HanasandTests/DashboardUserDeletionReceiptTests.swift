import Foundation
import XCTest

@testable import Hanasand

final class DashboardUserDeletionReceiptTests: XCTestCase {
    func testAcceptsOnlyAConfirmedFutureScheduleForTheRequestedUser() throws {
        let scheduled = ISO8601DateFormatter().string(from: Date().addingTimeInterval(30 * 24 * 60 * 60))
        let data = Data("""
        {"pending_deletion":true,"user":{"id":"target","deletion_scheduled_at":"\(scheduled)"}}
        """.utf8)
        let receipt = try JSONDecoder().decode(DashboardUserDeletionReceipt.self, from: data)

        XCTAssertTrue(receipt.confirmsDeletion(of: "target"))
        XCTAssertFalse(receipt.confirmsDeletion(of: "another-user"))
    }

    func testRejectsUnconfirmedMissingInvalidAndExpiredReceipts() throws {
        let expired = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        let fixtures = [
            "{\"pending_deletion\":false,\"user\":{\"id\":\"target\",\"deletion_scheduled_at\":\"\(expired)\"}}",
            "{\"pending_deletion\":true,\"user\":{\"id\":\"target\"}}",
            "{\"pending_deletion\":true,\"user\":{\"id\":\"target\",\"deletion_scheduled_at\":\"not-a-date\"}}",
            "{\"pending_deletion\":true,\"user\":{\"id\":\"different-user\",\"deletion_scheduled_at\":\"\(expired)\"}}"
        ]

        for fixture in fixtures {
            let receipt = try JSONDecoder().decode(DashboardUserDeletionReceipt.self, from: Data(fixture.utf8))
            XCTAssertFalse(receipt.confirmsDeletion(of: "target"))
        }
    }
}
