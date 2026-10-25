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

struct MailSendPayload: Encodable {
    let mailboxUser: String?
    let to: String
    let cc: String?
    let bcc: String?
    let replyTo: String?
    let subject: String
    let textBody: String
    let attachments: [MailDraftAttachment.Payload]
}

enum MailReplyRecipientPolicy {
    static func replyAll(
        from: [MailOverviewEnvelope.MailAddress],
        to: [MailOverviewEnvelope.MailAddress],
        cc: [MailOverviewEnvelope.MailAddress],
        mailboxAddress: String?
    ) -> [MailOverviewEnvelope.MailAddress] {
        let ownAddress = (mailboxAddress ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var seen = Set<String>()
        return (from + to + cc).filter { address in
            let email = address.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !email.isEmpty, email != ownAddress, seen.insert(email).inserted else { return false }
            return true
        }
    }
}
