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

struct DashboardThought: Codable, Identifiable {
    let id: String
    let title: String
    let createdAt: String?
    let createdBy: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case createdAt = "created_at"
        case createdBy = "created_by"
        case updatedAt = "updated_at"
    }

    var updatedLabel: String {
        formatDateText(updatedAt, fallback: formatDateText(createdAt, fallback: "No timestamp"))
    }

    var markdownBody: String { title }

    var displayTitle: String {
        title.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? title
    }

    var markdownRemainder: String {
        title.components(separatedBy: .newlines).dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
