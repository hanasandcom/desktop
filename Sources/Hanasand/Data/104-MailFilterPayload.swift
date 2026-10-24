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

struct MailFilterPayload: Encodable {
    enum CriteriaField: String, CaseIterable, Encodable, Identifiable {
        case from
        case subject
        case body
        case senderDomain

        var id: String { rawValue }

        var title: String {
            switch self {
            case .from: "From"
            case .subject: "Subject"
            case .body: "Body"
            case .senderDomain: "Sender domain"
            }
        }
    }

    struct Criteria: Encodable {
        let field: CriteriaField
        let contains: String
    }

    struct Action: Encodable {
        let type: String
        let mailboxName: String
        let markRead: Bool
    }

    let mailboxUser: String?
    let name: String
    let enabled: Bool
    let criteria: Criteria
    let action: Action
}
