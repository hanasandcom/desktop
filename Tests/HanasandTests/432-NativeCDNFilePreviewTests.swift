import Foundation
import XCTest

@testable import Hanasand

final class NativeCDNFilePreviewTests: XCTestCase {
    func testLoadsRawCDNImageBytesFromAPIEndpointAndReadsSafeFilename() async throws {
        var captured: URLRequest?
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0x00])
        let client = try makeClient(userID: "user-7", token: "session-token") { request in
            captured = request
            return (bytes, self.response(for: request.url!, headers: [
                "Content-Type": "image/png",
                "Content-Disposition": "inline; filename=\"screen.png\"; filename*=UTF-8''screen%20shot.png",
            ]))
        }

        let preview = try await client.load(id: "file-9")

        XCTAssertEqual(captured?.url?.path, "/api/files/file-9")
        XCTAssertEqual(captured?.httpMethod, "GET")
        XCTAssertFalse(captured?.httpShouldHandleCookies ?? true)
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Cookie"), "id=user-7; access_token=session-token")
        XCTAssertEqual(preview.data, bytes)
        XCTAssertEqual(preview.mediaType, "image/png")
        XCTAssertEqual(preview.fileName, "screen shot.png")
        XCTAssertTrue(preview.isImage)
    }

    func testAnonymousPublicAttachmentUsesRawResponseAndProvidesTextPreviewWhenKnown() async throws {
        var captured: URLRequest?
        let client = try makeClient { request in
            captured = request
            return (Data("# Public note".utf8), self.response(for: request.url!, headers: [
                "Content-Type": "application/octet-stream",
                "Content-Disposition": "attachment; filename=\"readme.md\"",
            ]))
        }

        let preview = try await client.load(id: "public-file")

        XCTAssertNil(captured?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(preview.fileName, "readme.md")
        XCTAssertEqual(preview.textPreview, "# Public note")
        XCTAssertEqual(preview.disposition, "attachment; filename=\"readme.md\"")
    }

    func testLoadsAndValidatesNativePDFBytes() async throws {
        var captured: URLRequest?
        let fixture = Self.pdfFixture()
        let client = try makeClient(userID: "reader", token: "private-token") { request in
            captured = request
            return (fixture, self.response(for: request.url!, headers: [
                "Content-Type": "application/pdf; charset=binary",
                "Content-Disposition": "inline; filename=\"report.pdf\"",
            ]))
        }

        let preview = try await client.load(id: "private-pdf")

        XCTAssertTrue(captured?.value(forHTTPHeaderField: "Accept")?.contains("application/pdf") == true)
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Cookie"), "id=reader; access_token=private-token")
        XCTAssertEqual(preview.mediaType, "application/pdf")
        XCTAssertEqual(preview.fileName, "report.pdf")
        XCTAssertTrue(preview.isPDF)
        XCTAssertEqual(NativeCDNFilePreviewLimits.validatedPDFPageCount(in: preview.data), 1)
    }

    func testRejectsMalformedEmptyAndExcessivePagePDFs() throws {
        XCTAssertNil(NativeCDNFilePreviewLimits.validatedPDFPageCount(in: Data("%PDF-not-a-document".utf8)))
        XCTAssertNil(NativeCDNFilePreviewLimits.validatedPDFPageCount(in: Self.pdfFixture(pages: 0)))
        XCTAssertNil(NativeCDNFilePreviewLimits.validatedPDFPageCount(in: Self.pdfFixture(pages: NativeCDNFilePreviewLimits.pdfPages + 1)))
    }

    func testClientRejectsMislabeledPDFAndNonPDFBytes() async throws {
        let client = try makeClient { request in
            (Data("<html>not a PDF</html>".utf8), self.response(for: request.url!, headers: ["Content-Type": "application/pdf"]))
        }
        do {
            _ = try await client.load(id: "file-1")
            XCTFail("PDF MIME responses must contain a parseable PDF document.")
        } catch { XCTAssertEqual(error as? NativeCDNFilePreviewError, .invalidResponse) }
    }

    func testRejectsUnsafeIDsUnsupportedMimeAndOversizedFiles() async throws {
        let client = try makeClient { request in
            (Data([1]), self.response(for: request.url!, headers: ["Content-Type": "text/html"]))
        }
        do {
            _ = try await client.load(id: "../private")
            XCTFail("Unsafe file IDs must be rejected before the network request.")
        } catch { XCTAssertEqual(error as? NativeCDNFilePreviewError, .invalidIdentifier) }
        do {
            _ = try await client.load(id: "file-1")
            XCTFail("The file API returns safe attachment types, not executable HTML.")
        } catch { XCTAssertEqual(error as? NativeCDNFilePreviewError, .invalidResponse) }

        let large = try makeClient { request in
            (Data(repeating: 0, count: NativeCDNFilePreviewLimits.responseBytes + 1), self.response(for: request.url!, headers: ["Content-Type": "image/png"]))
        }
        do {
            _ = try await large.load(id: "file-1")
            XCTFail("Responses over the preview size limit must fail safely.")
        } catch { XCTAssertEqual(error as? NativeCDNFilePreviewError, .responseTooLarge) }
    }

    func testRejectsForeignOriginAndInsecureBase() async throws {
        let client = try makeClient { _ in
            (Data([1]), self.response(for: URL(string: "https://other.test/file")!, headers: ["Content-Type": "image/png"]))
        }
        do {
            _ = try await client.load(id: "file-1")
            XCTFail("Responses from another host must be rejected.")
        } catch { XCTAssertEqual(error as? NativeCDNFilePreviewError, .invalidResponse) }
        XCTAssertThrowsError(try NativeCDNFilePreviewClient(baseURL: URL(string: "http://cdn.hanasand.com/api")!)) {
            XCTAssertEqual($0 as? NativeCDNFilePreviewError, .invalidBaseURL)
        }
    }

    private func makeClient(userID: String = "", token: String = "", sender: @escaping NativeCDNFilePreviewClient.Sender) throws -> NativeCDNFilePreviewClient {
        try NativeCDNFilePreviewClient(baseURL: URL(string: "https://cdn.hanasand.com/api")!, userID: userID, token: token, sender: sender)
    }

    private func response(for url: URL, status: Int = 200, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    private static func pdfFixture(pages: Int = 1) -> Data {
        var content = "%PDF-1.4\n"
        var offsets = [Int]()
        let pageKids = pages > 0 ? (0..<pages).map { "\($0 + 3) 0 R" }.joined(separator: " ") : ""
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [\(pageKids)] /Count \(pages) >>",
        ] + (0..<pages).map { _ in
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << >> >>"
        }
        for (index, object) in objects.enumerated() {
            offsets.append(content.utf8.count)
            content += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xrefOffset = content.utf8.count
        content += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { content += String(format: "%010d 00000 n \n", offset) }
        content += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        return Data(content.utf8)
    }
}
