import Foundation

struct NativeShareCollaborationIdentity: Equatable, Hashable {
    let shareID: String
    let accountID: String

    var isValid: Bool {
        NativeShareCollaborationProtocol.validIdentifier(shareID)
            && (accountID == "guest" || NativeShareCollaborationProtocol.validIdentifier(accountID))
    }
}

struct NativeShareCollaborationPresenceUser: Decodable, Equatable, Identifiable {
    let clientID: String
    let userID: String?
    let displayName: String?
    let color: String?
    let cursorLine: Int?
    let cursorColumn: Int?
    let selectionLength: Int?
    let editing: Bool?
    let updatedAt: String?

    var id: String { clientID }

    private enum CodingKeys: String, CodingKey {
        case clientID = "clientId"
        case userID = "userId"
        case displayName, color, cursorLine, cursorColumn, selectionLength, editing, updatedAt
    }
}

struct NativeShareCollaborationConflict: Equatable {
    let localContent: String
    let remoteContent: String
    let timestamp: Date
    let author: NativeShareCollaborationPresenceUser?
}

enum NativeShareCollaborationConnection: Equatable {
    case disconnected
    case connecting
    case connected
}

enum NativeShareCollaborationSaveState: Equatable {
    case saved
    case saving
    case queued
}

enum NativeShareCollaborationOutbound: Equatable {
    case hello(clientID: String, userID: String, displayName: String)
    case edit(content: String)
    case cursor(line: Int, column: Int, selectionLength: Int, editing: Bool)
    case editing(Bool)
}

enum NativeShareCollaborationEvent: Equatable {
    case update(content: String, timestamp: Date, participants: Int?, clientID: String?)
    case ack(content: String)
    case join(participants: Int, users: [NativeShareCollaborationPresenceUser])
    case presence(NativeShareCollaborationPresenceUser)
    case error(String)
    case unknown
}

enum NativeShareCollaborationProtocolError: LocalizedError, Equatable {
    case invalidEndpoint
    case invalidIdentity
    case invalidCredentials
    case invalidFrame

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "The share collaboration address is invalid."
        case .invalidIdentity: "The share collaboration room or account is invalid."
        case .invalidCredentials: "The share collaboration credentials do not match the current account."
        case .invalidFrame: "The share collaboration server returned an invalid message."
        }
    }
}

enum NativeShareCollaborationProtocol {
    static let maximumFrameBytes = 8 * 1024 * 1024
    static let maximumParticipants = 1_000_000
    static let maximumPresenceUsers = 512

    static func socketURL(apiBaseURL: String, shareID: String) throws -> URL {
        guard validIdentifier(shareID),
              var components = URLComponents(string: apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "wss"].contains(components.scheme?.lowercased() ?? ""), components.host != nil,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw NativeShareCollaborationProtocolError.invalidEndpoint
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encodedID = shareID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        guard let encodedID, !encodedID.contains("/") else { throw NativeShareCollaborationProtocolError.invalidEndpoint }
        let apiWebSocketRoot = basePath.hasSuffix("/ws") ? basePath : basePath + "/ws"
        components.scheme = "wss"
        components.path = "/" + [apiWebSocketRoot, "share", encodedID].filter { !$0.isEmpty }.joined(separator: "/")
        guard let url = components.url, url.scheme == "wss", url.host == URLComponents(string: apiBaseURL)?.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw NativeShareCollaborationProtocolError.invalidEndpoint
        }
        return url
    }

    static func helloFrame(clientID: String, userID: String, displayName: String) throws -> String {
        guard validIdentifier(clientID), userID.utf8.count <= 128, displayName.utf8.count <= 256 else {
            throw NativeShareCollaborationProtocolError.invalidCredentials
        }
        return try encode(["type": "hello", "clientId": clientID, "userId": userID, "displayName": displayName])
    }

    static func editFrame(identity: NativeShareCollaborationIdentity, userID: String, token: String,
                          dpop: String? = nil, content: String) throws -> String {
        guard identity.isValid,
              (identity.accountID == "guest" ? userID.isEmpty || userID == "guest" : userID == identity.accountID),
              token.utf8.count <= 4_096, (dpop?.utf8.count ?? 0) <= 8_192,
              content.utf8.count <= NativeShareWorkspaceLimits.contentBytes else {
            throw NativeShareCollaborationProtocolError.invalidCredentials
        }
        var payload: [String: String] = [
            "type": "edit", "userId": userID, "token": token,
            "id": identity.shareID, "content": content,
        ]
        if let dpop, !dpop.isEmpty { payload["dpop"] = dpop }
        return try encode(payload)
    }

    static func cursorFrame(line: Int, column: Int, selectionLength: Int, editing: Bool = true) throws -> String {
        guard (1...1_000_000).contains(line), (1...1_000_000).contains(column),
              (0...NativeShareWorkspaceLimits.contentBytes).contains(selectionLength) else {
            throw NativeShareCollaborationProtocolError.invalidFrame
        }
        return try encode(["type": "cursor", "line": line, "column": column,
                           "selectionLength": selectionLength, "editing": editing])
    }

    static func editingFrame(_ editing: Bool) throws -> String {
        try encode(["type": "editing", "editing": editing])
    }

    static func parse(_ text: String) throws -> NativeShareCollaborationEvent {
        guard text.utf8.count <= maximumFrameBytes, let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(Message.self, from: data) else {
            throw NativeShareCollaborationProtocolError.invalidFrame
        }
        switch message.type {
        case "update":
            guard let content = message.content,
                  content.utf8.count <= NativeShareWorkspaceLimits.contentBytes,
                  let rawTimestamp = message.timestamp, let timestamp = parseTimestamp(rawTimestamp),
                  validParticipants(message.participants) else {
                throw NativeShareCollaborationProtocolError.invalidFrame
            }
            guard (message.clientID?.utf8.count ?? 0) <= 200 else { throw NativeShareCollaborationProtocolError.invalidFrame }
            return .update(content: content, timestamp: timestamp, participants: message.participants, clientID: message.clientID)
        case "ack":
            guard let content = message.content, content.utf8.count <= NativeShareWorkspaceLimits.contentBytes else {
                throw NativeShareCollaborationProtocolError.invalidFrame
            }
            return .ack(content: content)
        case "join":
            guard let participants = message.participants, validParticipants(participants),
                  (message.users?.count ?? 0) <= maximumPresenceUsers else {
                throw NativeShareCollaborationProtocolError.invalidFrame
            }
            let users = message.users ?? []
            guard users.allSatisfy(validPresenceUser) else { throw NativeShareCollaborationProtocolError.invalidFrame }
            return .join(participants: participants, users: users)
        case "presence":
            guard let user = message.user, validPresenceUser(user) else { throw NativeShareCollaborationProtocolError.invalidFrame }
            return .presence(user)
        case "error":
            let detail = String((message.error ?? "Unable to save your changes. Please retry.").prefix(2_000))
            return .error(detail)
        default:
            return .unknown
        }
    }

    static func validIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9._~-]{1,200}$"#, options: .regularExpression) != nil
    }

    private static func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= maximumFrameBytes, let text = String(data: data, encoding: .utf8) else {
            throw NativeShareCollaborationProtocolError.invalidFrame
        }
        return text
    }

    private static func validParticipants(_ value: Int?) -> Bool {
        value.map { (0...maximumParticipants).contains($0) } ?? true
    }

    private static func validPresenceUser(_ user: NativeShareCollaborationPresenceUser) -> Bool {
        validIdentifier(user.clientID)
            && (user.userID?.utf8.count ?? 0) <= 128
            && (user.displayName?.utf8.count ?? 0) <= 256
            && (user.color?.utf8.count ?? 0) <= 128
            && (user.cursorLine.map { (1...1_000_000).contains($0) } ?? true)
            && (user.cursorColumn.map { (1...1_000_000).contains($0) } ?? true)
            && (user.selectionLength.map { (0...NativeShareWorkspaceLimits.contentBytes).contains($0) } ?? true)
            && (user.updatedAt?.utf8.count ?? 0) <= 128
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        guard value.utf8.count <= 64 else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    private struct Message: Decodable {
        let type: String
        let content: String?
        let timestamp: String?
        let participants: Int?
        let clientID: String?
        let users: [NativeShareCollaborationPresenceUser]?
        let user: NativeShareCollaborationPresenceUser?
        let error: String?
    }
}
