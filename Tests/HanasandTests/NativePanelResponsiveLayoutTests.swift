import XCTest
@testable import Hanasand

final class NativePanelResponsiveLayoutTests: XCTestCase {
    func testMailPanesFitThe639PointContentAreaAndKeepTheWideLayout() {
        let compactWidth: CGFloat = 639
        let panes = MailNativePanelLayout.compactPaneWidths(contentWidth: compactWidth)
        let measuredWidth = panes.mailboxes + panes.messages + panes.reader + MailNativePanelLayout.horizontalChromeWidth

        XCTAssertLessThanOrEqual(measuredWidth, compactWidth)
        XCTAssertGreaterThanOrEqual(panes.mailboxes, 120)
        XCTAssertGreaterThanOrEqual(panes.messages, 180)
        XCTAssertGreaterThanOrEqual(panes.reader, 220)
        XCTAssertEqual(measuredWidth, compactWidth, accuracy: 0.001)
        XCTAssertLessThan(compactWidth, MailNativePanelLayout.originalColumnsBreakpoint)

        let wideWidth: CGFloat = 1080
        XCTAssertGreaterThanOrEqual(wideWidth, MailNativePanelLayout.originalColumnsBreakpoint)
        XCTAssertEqual(MailNativePanelLayout.compactPaneWidths(contentWidth: wideWidth).mailboxes, 238)
    }

    func testSharesEditorAndListFitThe639PointContentAreaAndKeepWideWidths() {
        let compactWidth: CGFloat = 639
        let editorWidth = SharesNativePanelLayout.editorWidth(contentWidth: compactWidth)
        let listWidth = SharesNativePanelLayout.listWidth(contentWidth: compactWidth)

        XCTAssertLessThanOrEqual(editorWidth + 16 + listWidth, compactWidth)
        XCTAssertGreaterThanOrEqual(editorWidth, 240)
        XCTAssertGreaterThanOrEqual(listWidth, 260)
        XCTAssertEqual(editorWidth + 16 + listWidth, compactWidth, accuracy: 0.001)
        XCTAssertLessThan(compactWidth, SharesNativePanelLayout.originalColumnsBreakpoint)

        let wideWidth: CGFloat = 1080
        XCTAssertEqual(SharesNativePanelLayout.editorWidth(contentWidth: wideWidth), 380)
        XCTAssertEqual(SharesNativePanelLayout.listWidth(contentWidth: wideWidth), 684)
        XCTAssertGreaterThan(wideWidth, SharesNativePanelLayout.originalColumnsBreakpoint)
    }

    func testBothPanelsStackBelowTheirMinimumHorizontalBudgets() {
        XCTAssertLessThan(500, MailNativePanelLayout.stackedBreakpoint)
        XCTAssertLessThan(500, SharesNativePanelLayout.stackedBreakpoint)
    }

    func testMailQuickFilterGridKeepsLabelsReadableInTwoColumnMessagePanes() {
        let twoColumnMinimum = MailNativePanelLayout.quickFilterMinimumColumnWidth * 2 + 6

        XCTAssertGreaterThanOrEqual(MailNativePanelLayout.quickFilterMinimumColumnWidth, 160)
        XCTAssertLessThanOrEqual(twoColumnMinimum, 326)
    }

    func testVMCardMetricsAdaptToAvailableWidth() {
        XCTAssertEqual(NativeVMCardLayout.metricColumnCount(contentWidth: 248), 1)
        XCTAssertEqual(NativeVMCardLayout.metricColumnCount(contentWidth: 348), 1)
        XCTAssertEqual(NativeVMCardLayout.metricColumnCount(contentWidth: 428), 2)
        XCTAssertEqual(NativeVMCardLayout.metricColumnCount(contentWidth: 568), 3)
        XCTAssertEqual(NativeVMCardLayout.metricColumnCount(contentWidth: 0), 1)
        XCTAssertEqual(NativeVMCardLayout.metricColumnCount(contentWidth: .infinity), 1)
    }
}
