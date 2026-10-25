import Foundation

enum SupportDeskStatusFilter: String, CaseIterable, Identifiable {
    case open, resolved, all
    var id: String { rawValue }
    var title: String { self == .resolved ? "Resolved" : self == .all ? "All statuses" : "Open" }
}

enum SupportDeskStarsFilter: String, CaseIterable, Identifiable {
    case all, rated, unrated, one = "1", two = "2", three = "3", four = "4", five = "5"
    var id: String { rawValue }
    var title: String {
        switch self { case .all: "All ratings"; case .rated: "Rated"; case .unrated: "Unrated"; default: "\(rawValue) stars" }
    }
}

enum SupportDeskFeedbackFilter: String, CaseIterable, Identifiable {
    case all, comment, none
    var id: String { rawValue }
    var title: String { self == .comment ? "With comment" : self == .none ? "No comment" : "All feedback" }
}

struct SupportDeskFilters: Equatable {
    var search = ""
    var from = ""
    var to = ""
    var stars: SupportDeskStarsFilter = .all
    var feedback: SupportDeskFeedbackFilter = .all
    var status: SupportDeskStatusFilter = .open
}

struct SupportDeskTicket: Decodable, Identifiable, Equatable {
    let id: String
    let subject: String
    var status: String
    let updatedAt: String
    let createdAt: String?
    let userID: String?
    let userName: String?
    let agentName: String?
    let channel: String?
    var lastMessage: String?
    let replyCount: Int?
    let feedbackRating: Int?
    let feedbackComment: String?
    let resolutionVersion: Int?

    enum CodingKeys: String, CodingKey {
        case id, subject, status, updatedAt = "updated_at", createdAt = "created_at"
        case userID = "user_id", userName = "user_name", agentName = "agent_name", channel
        case lastMessage = "last_message", replyCount = "reply_count", feedbackRating = "feedback_rating"
        case feedbackComment = "feedback_comment", resolutionVersion = "resolution_version"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        subject = try values.decode(String.self, forKey: .subject)
        status = try values.decode(String.self, forKey: .status)
        updatedAt = try values.decode(String.self, forKey: .updatedAt)
        createdAt = try? values.decode(String.self, forKey: .createdAt)
        userID = try? values.decode(String.self, forKey: .userID)
        userName = try? values.decode(String.self, forKey: .userName)
        agentName = try? values.decode(String.self, forKey: .agentName)
        channel = try? values.decode(String.self, forKey: .channel)
        lastMessage = try? values.decode(String.self, forKey: .lastMessage)
        replyCount = try? values.decode(Int.self, forKey: .replyCount)
        let rating = try? values.decode(Int.self, forKey: .feedbackRating)
        feedbackRating = rating.flatMap { (1...5).contains($0) ? $0 : nil }
        feedbackComment = try? values.decode(String.self, forKey: .feedbackComment)
        let version = try? values.decode(Int.self, forKey: .resolutionVersion)
        resolutionVersion = version.flatMap { $0 >= 0 ? $0 : nil }
    }
}

struct SupportDeskMessage: Decodable, Identifiable, Equatable {
    let id: String
    let senderID: String?
    let senderName: String
    let senderKind: String?
    let body: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, senderID = "sender_id", senderName = "sender_name", senderKind = "sender_kind", body, createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        senderID = try? values.decode(String.self, forKey: .senderID)
        senderName = (try? values.decode(String.self, forKey: .senderName)) ?? "Unknown sender"
        senderKind = try? values.decode(String.self, forKey: .senderKind)
        body = try values.decode(String.self, forKey: .body)
        createdAt = try values.decode(String.self, forKey: .createdAt)
    }
}

struct SupportDeskSnapshot: Equatable {
    let scope: String
    let isSupport: Bool
    let realtime: Bool
    let tickets: [SupportDeskTicket]
}

struct SupportDiscordLinkCode: Decodable, Equatable {
    let code: String
    let expiresAt: Date

    private enum CodingKeys: String, CodingKey {
        case code, expiresAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        code = try values.decode(String.self, forKey: .code)
        let rawExpiry = try values.decode(String.self, forKey: .expiresAt)
        guard let expiry = Self.parseExpiry(rawExpiry) else {
            throw DecodingError.dataCorruptedError(forKey: .expiresAt, in: values, debugDescription: "Invalid ISO-8601 expiry")
        }
        expiresAt = expiry
    }

    private static func parseExpiry(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

struct SupportGuestConversation: Decodable, Equatable {
    let id: String?
    let channel: String
    let agentName: String?
    let status: String
    let pending: Bool
    let hasResponse: Bool
    let resolutionVersion: Int?
    let feedbackRating: Int?
    let feedbackComment: String?
    let closeFeedbackFound: Bool?
    let messages: [SupportDeskMessage]
    let tickets: [SupportDeskTicket]
    let accepted: Bool?

    enum CodingKeys: String, CodingKey {
        case id, channel, status, pending, messages, tickets, accepted
        case agentName = "agent_name"
        case hasResponse = "has_response", resolutionVersion = "resolution_version"
        case feedbackRating = "feedback_rating", feedbackComment = "feedback_comment"
        case closeFeedbackFound = "close_feedback_found"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try? values.decode(String.self, forKey: .id)
        channel = try values.decode(String.self, forKey: .channel)
        let rawAgentName = try? values.decode(String.self, forKey: .agentName)
        let cleanAgentName = rawAgentName?.trimmingCharacters(in: .whitespacesAndNewlines)
        agentName = cleanAgentName.flatMap { !$0.isEmpty && $0.count <= 120 && !$0.contains(where: \.isNewline) ? $0 : nil }
        status = try values.decode(String.self, forKey: .status)
        pending = try values.decode(Bool.self, forKey: .pending)
        hasResponse = (try? values.decode(Bool.self, forKey: .hasResponse)) ?? false
        let version = try? values.decode(Int.self, forKey: .resolutionVersion)
        resolutionVersion = version.flatMap { $0 >= 0 ? $0 : nil }
        let rating = try? values.decode(Int.self, forKey: .feedbackRating)
        feedbackRating = rating.flatMap { (1...5).contains($0) ? $0 : nil }
        feedbackComment = try? values.decode(String.self, forKey: .feedbackComment)
        closeFeedbackFound = try? values.decode(Bool.self, forKey: .closeFeedbackFound)
        messages = try values.decode([SupportDeskMessage].self, forKey: .messages)
        tickets = try values.decode([SupportDeskTicket].self, forKey: .tickets)
        accepted = try? values.decode(Bool.self, forKey: .accepted)
    }

    var humanAgentStatus: String? {
        guard channel == "human" else { return nil }
        let fallbackAgent = messages.reversed().first(where: { $0.senderKind == "support" })?.senderName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let assignedAgent = agentName ?? fallbackAgent.flatMap { !$0.isEmpty && $0.count <= 120 && !$0.contains(where: \.isNewline) ? $0 : nil }
        return assignedAgent.map { "Speaking with \($0)" } ?? "Waiting for support"
    }
}

struct SupportVMUnavailableTicketPrefill: Equatable {
    let vmName: String
    let subject: String
    let message: String

    static func fromNativeRoute(query: [String: String], isAuthenticated: Bool, isSupportQueue: Bool,
                                now: Date = Date()) -> Self? {
        guard isAuthenticated, !isSupportQueue, query["newTicket"] == "vm-sudo-password",
              let rawName = query["vm"], let vmName = sanitizedVMName(rawName) else { return nil }
        let subject = "Sudo password unavailable for \(vmName)"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: now)
        let message = "I could not display the sudo password for VM \(vmName). The page reported: “Unavailable. Contact Support if the problem persists.”\n\nTime: \(timestamp)\nPage: /vms"
        guard subject.count <= 160, message.count <= 10_000 else { return nil }
        return Self(vmName: vmName, subject: subject, message: message)
    }

    static func sanitizedVMName(_ rawName: String) -> String? {
        let allowed = rawName.unicodeScalars.filter {
            (65...90).contains(Int($0.value)) || (97...122).contains(Int($0.value))
                || (48...57).contains(Int($0.value)) || $0 == "." || $0 == "_" || $0 == "-"
        }
        let value = String(String.UnicodeScalarView(allowed)).prefix(100)
        let result = String(value)
        return result.isEmpty ? nil : result
    }
}

enum SupportDeskClientError: LocalizedError {
    case signInRequired, invalidServiceURL, invalidResponse, invalidTicket, readOnly
    case requestFailed(Int, String?)
    case uncertainResult
    case invalidDraft(String)

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to view Support."
        case .invalidServiceURL: "Support requires a valid HTTPS service address."
        case .invalidResponse: "Support returned an invalid response. Refresh to try again."
        case .invalidTicket: "Choose a valid support conversation."
        case .readOnly: "Refresh verified Support access in your own account before changing this conversation."
        case let .requestFailed(status, message): message ?? "Support request failed (HTTP \(status))."
        case .uncertainResult: "The operation outcome is unknown. Refresh and review the conversation before another change."
        case let .invalidDraft(message): message
        }
    }
}
