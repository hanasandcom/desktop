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

struct MailResourceReputation: Decodable, Equatable {
    let provider: String
    let status: String
    let flagged: Int?
    let total: Int?
    let checkedAt: String?
    let reportUrl: String?

    var isKnownClear: Bool { provider == "virustotal" && status == "known" && flagged == 0 }
}

struct MailRemoteResourceReputation: Decodable, Equatable {
    let id: String
    let url: String
    let reputation: MailResourceReputation
}

struct MailAttachmentReputation: Decodable, Equatable {
    let blobId: String
    let name: String
    let size: Int
    let reputation: MailResourceReputation
}

struct MailMessageReputationEnvelope: Decodable, Equatable {
    let messageId: String
    let remoteUrls: [MailRemoteResourceReputation]
    let attachments: [MailAttachmentReputation]
}

enum MailMessageSafetyError: Error {
    case invalidRequest
    case mismatchedMessage
}

enum MailMessageSafety {
    static func makeRequestURL(baseURL: URL, mailboxUser: String, messageID: String) throws -> URL {
        let user = mailboxUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, user.count <= 256, !message.isEmpty, message.count <= 512,
              let encodedMessage = message.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) else {
            throw MailMessageSafetyError.invalidRequest
        }
        let route = baseURL.appendingAPIPath("mail/message")
        guard var components = URLComponents(url: route, resolvingAgainstBaseURL: false) else {
            throw MailMessageSafetyError.invalidRequest
        }
        components.percentEncodedPath += "/\(encodedMessage)/reputation"
        components.queryItems = [URLQueryItem(name: "mailboxUser", value: user)]
        guard let url = components.url, url.usesSecureHanasandTransport else {
            throw MailMessageSafetyError.invalidRequest
        }
        return url
    }

    static func validated(_ value: MailMessageReputationEnvelope, expectedMessageID: String,
                          html: String, attachmentIDs: Set<String>) throws -> MailMessageReputationEnvelope {
        guard value.messageId == expectedMessageID else { throw MailMessageSafetyError.mismatchedMessage }
        let messageImages = Set(remoteImageURLs(in: html))
        var seenURLs: Set<String> = []
        let remoteURLs = value.remoteUrls.filter { item in
            guard messageImages.contains(item.url), seenURLs.insert(item.url).inserted,
                  let canonical = canonicalRemoteURL(item.url), canonical == item.url,
                  sha256(canonical) == item.id, item.reputation.provider == "virustotal" else { return false }
            return true
        }
        var seenAttachments: Set<String> = []
        let attachments = value.attachments.filter { item in
            attachmentIDs.contains(item.blobId) && seenAttachments.insert(item.blobId).inserted
                && item.reputation.provider == "virustotal"
        }
        return MailMessageReputationEnvelope(messageId: value.messageId, remoteUrls: remoteURLs, attachments: attachments)
    }

    static func remoteImageURLs(in html: String) -> [String] {
        guard let imageTagRegex = try? NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive]),
              let sourceRegex = try? NSRegularExpression(pattern: #"\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#, options: [.caseInsensitive]) else { return [] }
        let source = html as NSString
        let matches = imageTagRegex.matches(in: html, range: NSRange(location: 0, length: source.length))
        var result: [String] = []
        var seen: Set<String> = []
        for match in matches {
            let tag = source.substring(with: match.range)
            let tagValue = tag as NSString
            guard let sourceMatch = sourceRegex.firstMatch(in: tag, range: NSRange(location: 0, length: tagValue.length)) else { continue }
            let raw = (1...3).compactMap { index -> String? in
                let range = sourceMatch.range(at: index)
                return range.location == NSNotFound ? nil : tagValue.substring(with: range)
            }.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let canonical = canonicalRemoteURL(raw), seen.insert(canonical).inserted else { continue }
            result.append(canonical)
            if result.count == 50 { break }
        }
        return result
    }

    static func canonicalRemoteURL(_ value: String) -> String? {
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil else { return nil }
        components.scheme = scheme
        components.host = host.lowercased()
        components.fragment = nil
        return components.url?.absoluteString
    }

    static func contentSecurityPolicy(approvedRemoteURLs: [String]) -> String {
        let remoteSources = approvedRemoteURLs.compactMap { value -> String? in
            guard canonicalRemoteURL(value) == value,
                  let url = URL(string: value), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = url.host, url.user == nil, url.password == nil,
                  let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath else { return nil }
            let port = url.port.map { ":\($0)" } ?? ""
            return "\(scheme)://\(host)\(port)\(path.isEmpty ? "/" : path)"
        }
        let imageSources = ( ["data:", "blob:"] + remoteSources).joined(separator: " ")
        return "default-src 'none'; img-src \(imageSources); style-src 'unsafe-inline'; font-src data:; frame-src 'none'; media-src 'none'; object-src 'none'; connect-src 'none'; base-uri 'none'; form-action 'none'"
    }

    static func frameHTML(_ html: String, approvedRemoteURLs: [String]) -> String {
        let policy = contentSecurityPolicy(approvedRemoteURLs: approvedRemoteURLs)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"
        guard let regex = try? NSRegularExpression(pattern: #"<head\b[^>]*>"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range, in: html) else { return meta + html }
        var framed = html
        framed.insert(contentsOf: meta, at: range.upperBound)
        return framed
    }

    static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension DesktopAgentModel {

    func loadMailMessageReputation(messageID: String, mailboxUser: String, html: String,
                                   attachmentIDs: Set<String>) async throws -> MailMessageReputationEnvelope {
        let url = try MailMessageSafety.makeRequestURL(baseURL: settings.apiBaseURL.normalizedBaseURL, mailboxUser: mailboxUser, messageID: messageID)
        let response: MailMessageReputationEnvelope = try await requestJSON(url, authenticated: true)
        return try MailMessageSafety.validated(response, expectedMessageID: messageID, html: html, attachmentIDs: attachmentIDs)
    }

    func refreshLocalStatus() async {
        currentTaskState = "Checking this Mac"
        guard server?.tlsCertificateSha256 != nil else {
            let message = "The local agent HTTPS listener is not running."
            status = AgentStatus.ready(ok: false, message: message)
            append(meta: "This Mac", body: message, kind: .error)
            recordRun(title: "This Mac error", detail: message, kind: .error)
            currentTaskState = "Idle"
            return
        }
        let loaded = AgentStatus.ready(message: "this Mac is reachable")
        status = loaded
        append(meta: "This Mac", body: "\(loaded.hostname) · \(loaded.platform) · \(Int(loaded.uptimeSeconds / 60)) min", kind: .command)
        recordRun(title: "This Mac", detail: loaded.message, kind: .command)
        currentTaskState = "Idle"
    }

    func loadMailOverview(silent: Bool = false) async {
        guard hasHanasandAuth else {
            mailSummary = "Setup needed."
            if silent {
                mailBackgroundIssue = mailSummary
            } else {
                append(meta: "Mail", body: mailSummary, kind: .error)
            }
            return
        }

        do {
            let overview: MailOverviewEnvelope = try await requestJSON(
                mailOverviewURL(),
                authenticated: true
            )
            mailOverview = overview
            selectedMailAccountUser = overview.mailboxUser ?? selectedMailAccountUser
            selectedMailboxID = overview.selectedMailboxId ?? selectedMailboxID
            selectedMailMessageID = overview.selectedMessage?.id ?? overview.messages.first?.id ?? selectedMailMessageID
            let availableMessageIDs = Set((overview.messages + mailSearchResults).map(\.id))
            selectedMailMessageIDs = selectedMailMessageIDs.intersection(availableMessageIDs)
            if let mailboxName = overview.mailboxes.first(where: { $0.id == selectedMailboxID })?.displayName, mailMoveTargetMailboxName.isEmpty {
                mailMoveTargetMailboxName = mailboxName
            }
            mailLastSuccessAt = Date()
            mailBackgroundIssue = ""
            mailSummary = "\(overview.messages.count) messages · \(overview.mailboxes.count) mailboxes"
            if !silent {
                append(meta: "Mail", body: mailSummary, kind: .command)
            }
        } catch {
            if silent {
                mailBackgroundIssue = error.localizedDescription
            } else {
                mailSummary = error.localizedDescription
                append(meta: "Mail", body: error.localizedDescription, kind: .error)
            }
        }
    }

    func selectMailbox(_ mailbox: MailOverviewEnvelope.Mailbox) async {
        resetMailSearch()
        selectedMailboxID = mailbox.id
        selectedMailMessageID = ""
        selectedMailMessageIDs = []
        mailMoveTargetMailboxName = mailbox.displayName
        await loadMailOverview()
    }

    func selectMailAccount(_ account: MailOverviewEnvelope.Account) async {
        resetMailSearch()
        selectedMailAccountUser = account.id
        selectedMailboxID = ""
        selectedMailMessageID = ""
        selectedMailMessageIDs = []
        mailOverview = nil
        mailSummary = "Loading \(account.address)"
        append(meta: "Mail account", body: account.address, kind: .command)
        await loadMailOverview()
    }

    func selectMailMessage(_ message: MailOverviewEnvelope.Message) async {
        selectedMailMessageID = message.id
        await loadMailOverview()
    }

    func toggleMailSelection(_ message: MailOverviewEnvelope.Message) {
        if selectedMailMessageIDs.contains(message.id) {
            selectedMailMessageIDs.remove(message.id)
        } else {
            selectedMailMessageIDs.insert(message.id)
        }
    }

    func selectAllVisibleMailMessages(_ messages: [MailOverviewEnvelope.Message]) {
        selectedMailMessageIDs = Set(messages.map(\.id))
        mailSummary = "Selected \(selectedMailMessageIDs.count) messages"
    }

    func clearMailSelection() {
        selectedMailMessageIDs = []
        mailSummary = "Cleared selection"
    }

    func runSelectedMailAction(_ action: String) async {
        guard let message = selectedMailMessage else { return }
        await runMailAction(action, message: message)
    }

    func toggleSelectedMailReadState() async {
        guard let message = selectedMailMessage else { return }
        await runMailAction(message.isRead == true ? "unread" : "read", message: message)
    }

    func toggleSelectedMailFlagState() async {
        guard let message = selectedMailMessage else { return }
        await runMailAction(message.isFlagged == true ? "unflag" : "flag", message: message)
    }

    func moveSelectedMail(to mailbox: MailOverviewEnvelope.Mailbox) async {
        let messages = selectedMailMessages
        guard !messages.isEmpty else {
            mailMoveTargetMailboxName = mailbox.displayName
            return
        }
        mailMoveTargetMailboxName = mailbox.displayName
        await runBulkMailAction("move", messages: messages, targetMailboxId: mailbox.id, targetMailboxName: mailbox.displayName)
    }

    func runBulkMailAction(_ action: String, messages: [MailOverviewEnvelope.Message]? = nil, targetMailboxId: String? = nil, targetMailboxName: String? = nil) async {
        let targets = messages ?? selectedMailMessages
        guard !targets.isEmpty else {
            mailSummary = "Select messages first."
            return
        }
        for message in targets {
            await runMailAction(action, message: message, targetMailboxId: targetMailboxId, targetMailboxName: targetMailboxName, reload: false)
        }
        selectedMailMessageIDs = []
        mailSummary = "\(action.capitalized) applied to \(targets.count) messages"
        await loadMailOverview()
    }

    var selectedMailMessages: [MailOverviewEnvelope.Message] {
        guard let overview = mailOverview else { return [] }
        var seen: Set<String> = []
        return (overview.messages + mailSearchResults).filter {
            selectedMailMessageIDs.contains($0.id) && seen.insert($0.id).inserted
        }
    }
}
