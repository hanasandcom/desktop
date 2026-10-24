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

extension MailNativePanel {

    func loadSelectedMessageReputation() async {
        guard let message = selectedMessage, let overview, let mailboxUser = overview.mailboxUser,
              message.hasHTMLBody || !(message.attachments ?? []).isEmpty else {
            messageReputation = nil
            messageReputationError = ""
            messageReputationPending = false
            approvedRemoteImageMessageID = nil
            inlineImageContents = [:]
            inlineImageTokensByCID = [:]
            return
        }
        let messageID = message.id
        messageReputation = nil
        messageReputationError = ""
        messageReputationPending = true
        approvedRemoteImageMessageID = nil
        inlineImageContents = [:]
        inlineImageTokensByCID = [:]
        do {
            let response = try await model.loadMailMessageReputation(
                messageID: messageID,
                mailboxUser: mailboxUser,
                html: message.htmlBody ?? "",
                attachmentIDs: Set((message.attachments ?? []).map(\.blobId))
            )
            guard !Task.isCancelled, selectedMessage?.id == messageID,
                  overview.mailboxUser == mailboxUser else { return }
            messageReputation = response
            messageReputationPending = false
            var imageContents: [String: MailInlineImageContent] = [:]
            var tokensByCID: [String: String] = [:]
            var totalImageBytes = 0
            for attachment in MailMessageSafety.eligibleInlineAttachments(message.attachments ?? [], reputations: response.attachments) {
                guard !Task.isCancelled, selectedMessage?.id == messageID,
                      overview.mailboxUser == mailboxUser else { return }
                do {
                    guard let image = try await model.loadMailInlineImage(attachment, mailboxUser: mailboxUser),
                          totalImageBytes + image.data.count <= MailMessageSafety.maximumInlineImageTotalBytes,
                          let cid = attachment.cid,
                          let token = String(imageContents.count).addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { continue }
                    imageContents[token] = image
                    tokensByCID[cid] = token
                    totalImageBytes += image.data.count
                } catch {
                    continue
                }
            }
            guard !Task.isCancelled, selectedMessage?.id == messageID,
                  overview.mailboxUser == mailboxUser else { return }
            inlineImageContents = imageContents
            inlineImageTokensByCID = tokensByCID
        } catch {
            guard !Task.isCancelled, selectedMessage?.id == messageID else { return }
            messageReputationError = "Safety status unavailable. External images and attachments remain blocked."
            messageReputationPending = false
        }
    }

    func messageReader(_ overview: MailOverviewEnvelope) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let message = selectedMessage {
                NativeGroupPanel(title: message.subjectLabel, subtitle: message.fromLabel) {
                    LazyVGrid(columns: mailToolbarActionColumns, alignment: .leading, spacing: 8) {
                        mailToolbarActionButton(title: message.isRead == true ? "Unread" : "Read", icon: message.isRead == true ? "envelope.badge" : "envelope.open") {
                            Task { await model.runMailAction(message.isRead == true ? "unread" : "read", message: message) }
                        }
                        mailToolbarActionButton(title: message.isFlagged == true ? "Unflag" : "Flag", icon: "flag") {
                            Task { await model.runMailAction(message.isFlagged == true ? "unflag" : "flag", message: message) }
                        }
                        mailToolbarActionButton(title: "Reply", icon: "arrowshape.turn.up.left") {
                            model.composeReplyToSelectedMail()
                        }
                        mailToolbarActionButton(title: "Reply all", icon: "arrowshape.turn.up.left.2") {
                            model.composeReplyAllToSelectedMail()
                        }
                        mailToolbarActionButton(title: "Forward", icon: "arrowshape.turn.up.right") {
                            model.composeForwardSelectedMail()
                        }
                        Menu {
                            ForEach(overview.mailboxes) { mailbox in
                                Button(mailbox.displayName) {
                                    Task { await model.runMailAction("move", message: message, targetMailboxId: mailbox.id, targetMailboxName: mailbox.displayName) }
                                }
                            }
                        } label: {
                            mailToolbarActionLabel(title: "Move", icon: "folder")
                        }
                        .buttonStyle(.borderless)
                        mailToolbarActionButton(title: "Archive", icon: "archivebox") {
                            Task { await model.runMailAction("archive", message: message) }
                        }
                        mailToolbarActionButton(title: message.isJunk == true ? "Not spam" : "Spam", icon: message.isJunk == true ? "checkmark.shield" : "exclamationmark.octagon") {
                            Task { await model.runMailAction(message.isJunk == true ? "ham" : "junk", message: message) }
                        }
                        if message.isDeleted == true {
                            mailToolbarActionButton(title: "Restore", icon: "arrow.uturn.backward") {
                                Task { await model.runMailAction("restore", message: message) }
                            }
                        }
                        mailToolbarActionButton(title: "Trash", icon: "trash", tone: .danger) {
                            Task { await model.runMailAction("trash", message: message) }
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("To  \(message.to.isEmpty ? "No recipient listed" : message.to.map(\.displayName).joined(separator: ", "))")
                        if let cc = message.cc, !cc.isEmpty {
                            Text("Cc  \(cc.map(\.displayName).joined(separator: ", "))")
                        }
                        Text("\(message.dateLabel)  ·  Thread \(message.threadId ?? message.id)")
                    }
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(theme.textTertiary)
                    .textSelection(.enabled)

                    if message.hasHTMLBody {
                        let remoteURLs = MailMessageSafety.remoteImageURLs(in: message.htmlBody ?? "")
                        let safeRemoteURLs = (messageReputation?.remoteUrls ?? [])
                            .filter { $0.reputation.isKnownClear }
                            .map(\.url)
                        if !remoteURLs.isEmpty {
                            HStack(spacing: 9) {
                                Image(systemName: messageReputationPending ? "hourglass" : "hand.raised.fill")
                                    .foregroundStyle(theme.accent)
                                if messageReputationPending {
                                    Text("Checking remote image safety…")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(theme.textSecondary)
                                } else if !messageReputationError.isEmpty {
                                    Text(messageReputationError)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(theme.textSecondary)
                                } else {
                                    Text(approvedRemoteImageMessageID == message.id
                                         ? "Safe remote images are loaded."
                                         : "Remote images are blocked by default. \(safeRemoteURLs.count) safe image\(safeRemoteURLs.count == 1 ? "" : "s") available.")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(theme.textSecondary)
                                    if !safeRemoteURLs.isEmpty {
                                        ActionButton(title: approvedRemoteImageMessageID == message.id ? "Hide remote images" : "Load safe remote images",
                                                     icon: approvedRemoteImageMessageID == message.id ? "eye.slash" : "eye") {
                                            approvedRemoteImageMessageID = approvedRemoteImageMessageID == message.id ? nil : message.id
                                        }
                                    }
                                    if approvedRemoteImageMessageID != message.id && !safeRemoteURLs.isEmpty {
                                        Text("Loading makes requests to external image hosts and may reveal your IP address.")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(theme.textTertiary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        MailSafeHTMLBodyView(
                            html: message.renderedHTML(inlineImageTokensByCID: inlineImageTokensByCID),
                            approvedRemoteURLs: approvedRemoteImageMessageID == message.id ? safeRemoteURLs : [],
                            inlineImageContents: inlineImageContents,
                            configuredWebsiteBaseURL: model.settings.websiteBaseURL,
                            onOpenURL: { model.openURL($0, label: "Mail link") }
                        )
                            .frame(minHeight: 380)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    } else {
                        ScrollView {
                            Text(message.bodyText.isEmpty ? "No plain text body returned." : message.bodyText)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(theme.textSecondary)
                                .textSelection(.enabled)
                                .lineSpacing(4)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(14)
                        }
                        .frame(minHeight: 315)
                        .background(theme.backgroundElevated.opacity(0.72))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    if let attachments = message.attachments, !attachments.isEmpty {
                        attachmentPanel(attachments, message: message)
                    }
                }
            } else {
                NativeGroupPanel(title: "No message selected", subtitle: "Select a message from the list") {
                    NativeEmptyState(title: "Mail ready", message: "Pick a message, use arrow keys to navigate, or press Command-Shift-N to compose.")
                }
            }
        }
    }

    func attachmentPanel(_ attachments: [MailOverviewEnvelope.Attachment], message: MailOverviewEnvelope.Message) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Attachments")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(theme.textTertiary)
                .textCase(.uppercase)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8)], spacing: 8) {
                ForEach(attachments) { attachment in
                    let reputation = messageReputation?.attachments.first { $0.blobId == attachment.blobId }?.reputation
                    let safeToOpen = reputation?.isKnownClear == true && !messageReputationPending
                    VStack(alignment: .leading, spacing: 5) {
                        Button {
                            Task { await model.downloadMailAttachment(attachment, from: message) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "paperclip")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(attachment.name)
                                        .font(.system(size: 12, weight: .bold))
                                        .lineLimit(1)
                                    Text("\(attachment.type ?? "file") · \(formatBytes(attachment.size ?? 0))")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(theme.textTertiary)
                                }
                                Spacer()
                            }
                            .foregroundStyle(theme.text)
                            .padding(10)
                            .background(theme.cardRaised)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(!safeToOpen)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(messageReputationPending ? "Checking VirusTotal…" : attachmentSafetyLabel(reputation))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(reputation?.status == "known" && (reputation?.flagged ?? 0) > 0 ? theme.danger : theme.textTertiary)
                            if safeToOpen, let report = reputation?.reportUrl,
                               let url = URL(string: report), url.scheme == "https", url.host == "www.virustotal.com",
                               url.user == nil, url.password == nil {
                                Button("VirusTotal report") { model.openURL(url.absoluteString, label: "Mail attachment report") }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(theme.accent)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }
            }
        }
    }

    func attachmentSafetyLabel(_ reputation: MailResourceReputation?) -> String {
        guard let reputation else { return "VirusTotal status unavailable; download blocked." }
        if reputation.status == "known", let flagged = reputation.flagged, flagged > 0 {
            return "Download blocked: \(flagged) of \(reputation.total.map { String($0) } ?? "?") scanners flagged this file."
        }
        if reputation.isKnownClear {
            return "VirusTotal: 0 / \(reputation.total.map { String($0) } ?? "?") scanners flagged."
        }
        if reputation.status == "unknown" { return "No VirusTotal report; download blocked." }
        return "VirusTotal status unavailable; download blocked."
    }
}

struct MailSafeHTMLBodyView: NSViewRepresentable {
    let html: String
    let approvedRemoteURLs: [String]
    let inlineImageContents: [String: MailInlineImageContent]
    let configuredWebsiteBaseURL: String
    let onOpenURL: (String) -> Void

    private var securedHTML: String {
        MailMessageSafety.frameHTML(html, approvedRemoteURLs: approvedRemoteURLs)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(context.coordinator.inlineImageHandler, forURLScheme: MailMessageSafety.inlineImageScheme)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        context.coordinator.load(securedHTML, in: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.configuredWebsiteBaseURL = configuredWebsiteBaseURL
        context.coordinator.onOpenURL = onOpenURL
        context.coordinator.inlineImageHandler.update(inlineImageContents)
        context.coordinator.load(securedHTML, in: view)
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        private var loadedHTML: String?
        let inlineImageHandler: MailInlineImageSchemeHandler
        var configuredWebsiteBaseURL: String
        var onOpenURL: (String) -> Void

        init(inlineImageContents: [String: MailInlineImageContent], configuredWebsiteBaseURL: String, onOpenURL: @escaping (String) -> Void) {
            inlineImageHandler = MailInlineImageSchemeHandler(inlineImageContents)
            self.configuredWebsiteBaseURL = configuredWebsiteBaseURL
            self.onOpenURL = onOpenURL
        }

        func load(_ html: String, in webView: WKWebView) {
            guard loadedHTML != html else { return }
            loadedHTML = html
            webView.loadHTMLString(html, baseURL: nil)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if BrowserWorkspaceModel.isHanasandOwnedURL(url.absoluteString, configuredWebsiteBaseURL: configuredWebsiteBaseURL) {
                onOpenURL(url.absoluteString)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(inlineImageContents: inlineImageContents, configuredWebsiteBaseURL: configuredWebsiteBaseURL, onOpenURL: onOpenURL)
    }
}

final class MailInlineImageSchemeHandler: NSObject, WKURLSchemeHandler {
    private let lock = NSLock()
    private var inlineImageContents: [String: MailInlineImageContent]

    init(_ inlineImageContents: [String: MailInlineImageContent]) {
        self.inlineImageContents = inlineImageContents
    }

    func update(_ contents: [String: MailInlineImageContent]) {
        lock.lock()
        inlineImageContents = contents
        lock.unlock()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              url.scheme == MailMessageSafety.inlineImageScheme,
              url.host == "inline", url.query == nil, url.fragment == nil,
              url.pathComponents.count == 2,
              let token = url.pathComponents.last else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        lock.lock()
        let image = inlineImageContents[token]
        lock.unlock()
        guard let image else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = URLResponse(url: url, mimeType: image.mimeType, expectedContentLength: image.data.count, textEncodingName: nil)
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(image.data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
