import XCTest
@testable import Hanasand

final class MailQuickFilterTests: XCTestCase {
    func testAllMatchesEveryMessageState() {
        for isRead: Bool? in [true, false, nil] {
            for isFlagged: Bool? in [true, false, nil] {
                for hasAttachment in [true, false] {
                    XCTAssertTrue(MailQuickFilter.all.matches(isRead: isRead, isFlagged: isFlagged, hasAttachment: hasAttachment))
                }
            }
        }
    }

    func testUnreadStarredAndAttachmentFiltersUseServerSummaryState() {
        XCTAssertTrue(MailQuickFilter.unread.matches(isRead: false, isFlagged: false, hasAttachment: false))
        XCTAssertTrue(MailQuickFilter.unread.matches(isRead: nil, isFlagged: false, hasAttachment: false))
        XCTAssertFalse(MailQuickFilter.unread.matches(isRead: true, isFlagged: true, hasAttachment: true))

        XCTAssertTrue(MailQuickFilter.starred.matches(isRead: true, isFlagged: true, hasAttachment: false))
        XCTAssertFalse(MailQuickFilter.starred.matches(isRead: false, isFlagged: nil, hasAttachment: true))

        XCTAssertTrue(MailQuickFilter.attachments.matches(isRead: true, isFlagged: false, hasAttachment: true))
        XCTAssertFalse(MailQuickFilter.attachments.matches(isRead: false, isFlagged: true, hasAttachment: false))
    }

    func testFilterOrderAndLabelsMatchWebsiteMailList() {
        XCTAssertEqual(MailQuickFilter.allCases.map(\.rawValue), ["all", "unread", "starred", "attachments"])
        XCTAssertEqual(MailQuickFilter.allCases.map(\.title), ["All", "Unread", "Starred", "Attachments"])
    }
}
