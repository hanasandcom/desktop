import Foundation
import PDFKit

enum DocumentScannerPDF {
    static func data(for pages: [DocumentScanPage]) -> Data? {
        guard !pages.isEmpty else { return nil }
        let document = PDFDocument()
        for (index, scanPage) in pages.enumerated() {
            guard let pdfPage = PDFPage(image: scanPage.image) else { return nil }
            document.insert(pdfPage, at: index)
        }
        return document.dataRepresentation()
    }
}
