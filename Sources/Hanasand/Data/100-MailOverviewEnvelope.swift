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

struct MailOverviewEnvelope: Decodable {
    let mailboxUser: String?; let mailboxAddress: String?; let accessibleAccounts: [Account]?; let mailboxes: [Mailbox]

    let selectedMailboxId: String?; var messages: [Message]; var selectedMessage: Message?; let filters: [Filter]?

    let recentRecipients: [RecentRecipient]?; let health: Health?; let settings: Settings?
    var nextCursor: String?
    let permissions: Actor?

    var canSend: Bool { permissions?.canSend != false }

    struct Actor: Decodable {
        let id: String?
        let canAccessAnyMailbox: Bool?
        let canSend: Bool?
    }

    enum CodingKeys: String, CodingKey {
        case mailboxUser, mailboxAddress, accessibleAccounts, mailboxes, selectedMailboxId, messages, selectedMessage
        case filters, recentRecipients, health, settings, nextCursor
        case permissions = "actor"
    }
}
