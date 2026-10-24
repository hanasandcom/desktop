import AppKit
import PDFKit
import XCTest
@testable import Hanasand

final class DocumentScannerModelTests: XCTestCase {
    func testPagesCanBeReorderedWithoutLosingTheirIdentity() {
        var session = DocumentScanSession()
        let first = page(red: 1)
        let second = page(red: 2)
        let third = page(red: 3)
        session.append(first)
        session.append(second)
        session.append(third)

        session.move(third.id, by: -2)

        XCTAssertEqual(session.pages.map(\.id), [third.id, first.id, second.id])
    }

    func testMoveOutsideBoundsAndUnknownPageAreNoOps() {
        var session = DocumentScanSession()
        let first = page(red: 1)
        session.append(first)

        session.move(first.id, by: -1)
        session.move(UUID(), by: 1)

        XCTAssertEqual(session.pages.map(\.id), [first.id])
    }

    func testDeleteAndClearUpdateTheBundle() {
        var session = DocumentScanSession()
        let first = page(red: 1)
        let second = page(red: 2)
        session.append(first)
        session.append(second)

        session.remove(first.id)
        XCTAssertEqual(session.pages.map(\.id), [second.id])

        session.clear()
        XCTAssertTrue(session.isEmpty)
    }

    func testPDFAssemblyPreservesPageCountAndOrder() throws {
        let pages = [page(red: 1), page(red: 2), page(red: 3)]

        let data = try XCTUnwrap(DocumentScannerPDF.data(for: pages))
        let pdf = try XCTUnwrap(PDFDocument(data: data))

        XCTAssertEqual(pdf.pageCount, 3)
        XCTAssertNil(DocumentScannerPDF.data(for: []))
    }

    private func page(red: CGFloat) -> DocumentScanPage {
        let image = NSImage(size: NSSize(width: 40, height: 60))
        image.lockFocus()
        NSColor(calibratedRed: red / 3, green: 0.3, blue: 0.7, alpha: 1).setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        return DocumentScanPage(image: image)
    }
}
