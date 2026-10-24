import Foundation
import PDFKit

struct NativeCDNFilePreview: Equatable {
    let id: String
    let fileName: String
    let mediaType: String
    let data: Data
    let disposition: String

    var isImage: Bool { mediaType.hasPrefix("image/") }
    var isVideo: Bool { mediaType.hasPrefix("video/") }
    var isPDF: Bool { mediaType == "application/pdf" }
    var textPreview: String? {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        guard ["txt", "md", "json", "csv", "xml", "yaml", "yml", "log", "swift", "ts", "tsx", "js", "css", "html", "sh", "py"].contains(ext),
              let text = String(data: data, encoding: .utf8), !text.contains("\0") else { return nil }
        return text
    }
}

enum NativeCDNFilePreviewLimits {
    static let responseBytes = 50 * 1024 * 1024
    static let identifierBytes = 200
    static let pdfPages = 1_000

    static func validatedPDFPageCount(in data: Data) -> Int? {
        guard data.starts(with: Data("%PDF-".utf8)),
              let document = PDFDocument(data: data),
              !document.isLocked,
              document.pageCount > 0,
              document.pageCount <= pdfPages else { return nil }
        return document.pageCount
    }
}

enum NativeCDNFilePreviewError: LocalizedError, Equatable {
    case signInRequired
    case invalidBaseURL
    case invalidIdentifier
    case invalidCredentials
    case invalidResponse
    case responseTooLarge
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to view this private file."
        case .invalidBaseURL: "Files require a valid HTTPS CDN address."
        case .invalidIdentifier: "This file link is missing a valid file identifier."
        case .invalidCredentials: "The current account credentials are invalid. Sign in again."
        case .invalidResponse: "The CDN returned an unsupported file response."
        case .responseTooLarge: "This file is too large to preview safely."
        case .requestFailed(401): "Sign in again to view this private file."
        case .requestFailed(404): "This file was not found or is private to another account."
        case .requestFailed: "This file is unavailable. Try again later."
        }
    }
}
