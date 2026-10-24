import CryptoKit
import Foundation

@MainActor
final class MailSendIdempotencyStore {
    static let shared = MailSendIdempotencyStore()

    private struct DraftState {
        var keyByPayloadFingerprint: [Data: String] = [:]
    }

    private var draftsByMailbox: [String: DraftState] = [:]
    private var sendingMailboxes: Set<String> = []

    func beginNewDraft(mailbox: String) {
        guard !sendingMailboxes.contains(mailbox) else { return }
        draftsByMailbox[mailbox] = DraftState()
    }

    func idempotencyKey(mailbox: String, payload: Data) -> String {
        let fingerprint = Data(SHA256.hash(data: payload))
        var draft = draftsByMailbox[mailbox] ?? DraftState()
        if let key = draft.keyByPayloadFingerprint[fingerprint] {
            return key
        }
        let key = UUID().uuidString.lowercased()
        draft.keyByPayloadFingerprint[fingerprint] = key
        draftsByMailbox[mailbox] = draft
        return key
    }

    func beginSend(mailbox: String) -> Bool {
        guard sendingMailboxes.insert(mailbox).inserted else { return false }
        return true
    }

    func finishSend(mailbox: String) {
        sendingMailboxes.remove(mailbox)
    }

    func isSending(mailbox: String) -> Bool {
        sendingMailboxes.contains(mailbox)
    }

    var isSendingAnyMailbox: Bool {
        !sendingMailboxes.isEmpty
    }
}

@MainActor
final class MailInboxPaginationState {
    static let shared = MailInboxPaginationState()

    private var loadingScopes: Set<String> = []

    func begin(scope: String) -> Bool {
        loadingScopes.insert(scope).inserted
    }

    func finish(scope: String) {
        loadingScopes.remove(scope)
    }

    func isLoading(scope: String) -> Bool {
        loadingScopes.contains(scope)
    }
}

enum MailSendPayloadBudget {
    static let maximumBodyBytes = 25 * 1024 * 1024

    static func encodedBody(_ payload: MailSendPayload) throws -> Data {
        try JSONEncoder().encode(payload)
    }

    static func estimatedBodyBytes(_ payload: MailSendPayload, attachmentSizes: [Int]? = nil) throws -> Int {
        let sizes = attachmentSizes ?? payload.attachments.map(\.size)
        guard sizes.count == payload.attachments.count else { throw MailSendPayloadBudgetError.invalidAttachmentSize }

        let metadata = MailSendPayload(
            mailboxUser: payload.mailboxUser,
            to: payload.to,
            cc: payload.cc,
            bcc: payload.bcc,
            replyTo: payload.replyTo,
            subject: payload.subject,
            textBody: payload.textBody,
            attachments: payload.attachments.map {
                MailDraftAttachment.Payload(name: $0.name, type: $0.type, contentBase64: "", size: $0.size)
            }
        )
        var total = try JSONEncoder().encode(metadata).count
        guard total <= maximumBodyBytes else { throw MailSendPayloadBudgetError.bodyTooLarge }
        for size in sizes {
            guard size >= 0, size <= Int.max - 2 else { throw MailSendPayloadBudgetError.invalidAttachmentSize }
            let groups = (size + 2) / 3
            guard groups <= (Int.max - total) / 4 else { throw MailSendPayloadBudgetError.bodyTooLarge }
            total += groups * 4
            guard total <= maximumBodyBytes else { throw MailSendPayloadBudgetError.bodyTooLarge }
        }
        return total
    }

    static func validateEncodedBody(_ data: Data) throws {
        guard data.count <= maximumBodyBytes else { throw MailSendPayloadBudgetError.bodyTooLarge }
    }
}

enum MailSendPayloadBudgetError: LocalizedError {
    case invalidAttachmentSize
    case bodyTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidAttachmentSize:
            "Unable to read the selected attachment size. Choose the file again."
        case .bodyTooLarge:
            "This message exceeds the 25 MiB mail limit. Remove an attachment or shorten the message."
        }
    }
}

enum MailOverviewPageRequest {
    static func makeURL(baseURL: String, mailboxUser: String, mailboxID: String, cursor: String) throws -> URL {
        let user = mailboxUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let mailbox = mailboxID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !mailbox.isEmpty else { throw MailOverviewPageRequestError.missingScope }
        guard !cursor.isEmpty, cursor.utf8.count <= 1024 else { throw MailOverviewPageRequestError.invalidCursor }

        var components = URLComponents(
            url: baseURL.normalizedBaseURL.appendingAPIPath("mail/overview"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "mailboxUser", value: user),
            URLQueryItem(name: "mailboxId", value: mailbox),
            URLQueryItem(name: "after", value: cursor),
        ]
        guard let url = components?.url, url.usesSecureHanasandTransport else {
            throw MailOverviewPageRequestError.invalidURL
        }
        return url
    }
}

enum MailOverviewPageRequestError: LocalizedError {
    case missingScope
    case invalidCursor
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .missingScope: "Select a mailbox before loading older messages."
        case .invalidCursor: "The next page could not be loaded. Refresh the mailbox to continue."
        case .invalidURL: "Unable to create the mailbox page request."
        }
    }
}

enum MailOverviewPageMerge {
    static func appending(
        _ incoming: [MailOverviewEnvelope.Message],
        to existing: [MailOverviewEnvelope.Message]
    ) -> [MailOverviewEnvelope.Message] {
        var seen = Set(existing.map(\.id))
        return existing + incoming.filter { seen.insert($0.id).inserted }
    }
}
