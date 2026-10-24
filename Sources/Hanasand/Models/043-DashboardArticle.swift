import AppKit
import ApplicationServices
import Combine
import CryptoKit
import Darwin
import Foundation
import Network
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct DashboardArticle: Codable, Identifiable {
    struct Metadata: Codable {
        let image: String?
        let description: String?
        let wordCount: Int?
        let estimatedMinutes: Int?
    }

    let id: String
    let size: Int?
    let created: String?
    let modified: String?
    let metadata: Metadata?
    let title: String
    let content: String?
    let organizationID: String?

    enum CodingKeys: String, CodingKey {
        case id, size, created, modified, metadata, title, content
        case organizationID = "organization_id"
    }

    init(id: String, size: Int?, created: String?, modified: String?, metadata: Metadata?, title: String,
         content: String?, organizationID: String? = nil) {
        self.id = id
        self.size = size
        self.created = created
        self.modified = modified
        self.metadata = metadata
        self.title = title
        self.content = content
        self.organizationID = organizationID
    }

    var publishedLabel: String {
        formatDateText(modified, fallback: formatDateText(created, fallback: "No timestamp"))
    }

    var readingLabel: String {
        guard let minutes = metadata?.estimatedMinutes else { return "No estimate" }
        return "\(minutes) min read"
    }
}
