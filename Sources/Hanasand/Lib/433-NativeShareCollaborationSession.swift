import Foundation

/// Deterministic state machine for one share-room socket. Callers pass the room/account and
/// generation captured when the socket was created so late callbacks cannot mutate a new session.
struct NativeShareCollaborationSession: Equatable {
    private(set) var identity: NativeShareCollaborationIdentity
    private(set) var clientID: String
    private(set) var userID: String
    private(set) var displayName: String
    private(set) var generation = 0
    private(set) var connection: NativeShareCollaborationConnection = .disconnected
    private(set) var saveState: NativeShareCollaborationSaveState = .saved
    private(set) var localContent: String
    private(set) var persistedContent: String
    private(set) var participants: Int?
    private(set) var presence: [String: NativeShareCollaborationPresenceUser] = [:]
    private(set) var conflict: NativeShareCollaborationConflict?
    private(set) var lastError: String?

    private var queuedContent: String?
    private var inFlightContent: String?
    private var lastRemoteTimestamp: Date?

    init(identity: NativeShareCollaborationIdentity, clientID: String, userID: String,
         displayName: String, initialContent: String) throws {
        guard identity.isValid,
              NativeShareCollaborationProtocol.validIdentifier(clientID),
              initialContent.utf8.count <= NativeShareWorkspaceLimits.contentBytes,
              userID.utf8.count <= 128, displayName.utf8.count <= 256,
              (identity.accountID == "guest" ? userID.isEmpty || userID == "guest" : userID == identity.accountID) else {
            throw NativeShareCollaborationProtocolError.invalidIdentity
        }
        self.identity = identity
        self.clientID = clientID
        self.userID = userID
        self.displayName = displayName
        self.localContent = initialContent
        self.persistedContent = initialContent
    }

    /// Starts or restarts a socket. Changing either room or account discards room-bound
    /// collaboration state; reconnecting the same identity preserves the local draft.
    @discardableResult
    mutating func connect(identity nextIdentity: NativeShareCollaborationIdentity) throws -> Int {
        guard nextIdentity.isValid else { throw NativeShareCollaborationProtocolError.invalidIdentity }
        guard (nextIdentity.accountID == "guest" ? userID.isEmpty || userID == "guest" : userID == nextIdentity.accountID) else {
            throw NativeShareCollaborationProtocolError.invalidCredentials
        }
        if identity != nextIdentity {
            identity = nextIdentity
            localContent = ""
            persistedContent = ""
            queuedContent = nil
            inFlightContent = nil
            conflict = nil
            participants = nil
            presence = [:]
            lastRemoteTimestamp = nil
            lastError = nil
            saveState = .saved
        } else if inFlightContent != nil, conflict == nil {
            // The socket may have delivered the snapshot before closing. Replay the latest
            // local snapshot after reconnect even when it equals our last confirmed baseline.
            queuedContent = localContent
            self.inFlightContent = nil
            saveState = queuedContent == nil ? .saved : .queued
        }
        generation &+= 1
        connection = .connecting
        participants = nil
        presence = [:]
        lastError = nil
        return generation
    }

    /// Marks the current socket ready and emits hello followed by the newest queued edit.
    mutating func markConnected(identity callbackIdentity: NativeShareCollaborationIdentity,
                                generation callbackGeneration: Int) -> [NativeShareCollaborationOutbound] {
        guard accepts(callbackIdentity, generation: callbackGeneration) else { return [] }
        connection = .connected
        lastError = nil
        var output: [NativeShareCollaborationOutbound] = [
            .hello(clientID: clientID, userID: userID, displayName: displayName)
        ]
        if conflict == nil, let edit = dequeueLatestEdit() { output.append(.edit(content: edit)) }
        return output
    }

    /// Coalesces local input to the latest snapshot. A detected remote conflict blocks
    /// transmission until the UI explicitly resolves it.
    @discardableResult
    mutating func edit(_ content: String) throws -> [NativeShareCollaborationOutbound] {
        guard content.utf8.count <= NativeShareWorkspaceLimits.contentBytes else {
            throw NativeShareWorkspaceError.invalidResponse
        }
        localContent = content
        lastError = nil
        if let currentConflict = conflict {
            conflict = NativeShareCollaborationConflict(localContent: content,
                                                        remoteContent: currentConflict.remoteContent,
                                                        timestamp: currentConflict.timestamp,
                                                        author: currentConflict.author)
            saveState = .queued
            return []
        }
        if inFlightContent == nil, content == persistedContent {
            queuedContent = nil
            saveState = .saved
            return []
        }
        if inFlightContent == nil, connection == .connected {
            inFlightContent = content
            queuedContent = nil
            saveState = .saving
            return [.edit(content: content)]
        }
        queuedContent = content
        saveState = .queued
        return []
    }

    /// Requeues the freshest draft after a send failure without overwriting it with an
    /// older in-flight snapshot.
    mutating func sendFailed(identity callbackIdentity: NativeShareCollaborationIdentity,
                             generation callbackGeneration: Int, message: String? = nil) {
        guard accepts(callbackIdentity, generation: callbackGeneration) else { return }
        if conflict == nil, inFlightContent != nil {
            queuedContent = localContent
        }
        inFlightContent = nil
        connection = .disconnected
        saveState = queuedContent == nil && conflict == nil && localContent == persistedContent ? .saved : .queued
        lastError = bounded(message)
    }

    /// Closes the active connection, preserving queued work. Late close callbacks are ignored.
    mutating func disconnect(identity callbackIdentity: NativeShareCollaborationIdentity,
                             generation callbackGeneration: Int) {
        guard accepts(callbackIdentity, generation: callbackGeneration) else { return }
        if conflict == nil, inFlightContent != nil {
            queuedContent = localContent
        }
        inFlightContent = nil
        connection = .disconnected
        saveState = queuedContent == nil && conflict == nil && localContent == persistedContent ? .saved : .queued
    }

    /// Applies a single JSON socket message after verifying it belongs to this exact
    /// account/room connection. Malformed data is reported without changing document state.
    @discardableResult
    mutating func receive(_ text: String, identity callbackIdentity: NativeShareCollaborationIdentity,
                          generation callbackGeneration: Int) -> [NativeShareCollaborationOutbound] {
        guard accepts(callbackIdentity, generation: callbackGeneration), connection == .connected else { return [] }
        let event: NativeShareCollaborationEvent
        do {
            event = try NativeShareCollaborationProtocol.parse(text)
        } catch {
            lastError = "The collaboration server sent an invalid message."
            return []
        }
        switch event {
        case let .update(content, timestamp, newParticipants, clientID):
            guard lastRemoteTimestamp.map({ timestamp > $0 }) ?? true else { return [] }
            lastRemoteTimestamp = timestamp
            participants = newParticipants ?? participants
            if content == localContent {
                persistedContent = content
                queuedContent = nil
                inFlightContent = nil
                conflict = nil
                saveState = .saved
                lastError = nil
            } else if conflict != nil || localContent != persistedContent || inFlightContent != nil || queuedContent != nil {
                conflict = NativeShareCollaborationConflict(localContent: localContent,
                                                            remoteContent: content,
                                                            timestamp: timestamp,
                                                            author: clientID.flatMap { presence[$0] })
                queuedContent = nil
                inFlightContent = nil
                saveState = .queued
                lastError = "A collaborator changed this document. Review both versions before saving."
            } else {
                localContent = content
                persistedContent = content
                saveState = .saved
                lastError = nil
            }
            return []
        case let .ack(content):
            guard let inFlightContent, content == inFlightContent else { return [] }
            self.inFlightContent = nil
            persistedContent = content
            if conflict == nil, localContent == content {
                queuedContent = nil
                saveState = .saved
                lastError = nil
            } else if conflict == nil {
                queuedContent = localContent == content ? nil : localContent
                saveState = queuedContent == nil ? .saved : .queued
            }
            if conflict == nil, let next = dequeueLatestEdit() { return [.edit(content: next)] }
            return []
        case let .join(count, users):
            participants = count
            presence = [:]
            for user in users { presence[user.clientID] = user }
            return []
        case let .presence(user):
            presence[user.clientID] = user
            return []
        case let .error(message):
            if inFlightContent != nil, conflict == nil { queuedContent = localContent }
            self.inFlightContent = nil
            saveState = queuedContent == nil && conflict == nil && localContent == persistedContent ? .saved : .queued
            lastError = message
            return []
        case .unknown:
            return []
        }
    }

    /// Explicitly keeps the remote snapshot and discards the local conflicting draft.
    mutating func useRemoteConflict() {
        guard let conflict else { return }
        localContent = conflict.remoteContent
        persistedContent = conflict.remoteContent
        self.conflict = nil
        queuedContent = nil
        inFlightContent = nil
        saveState = .saved
        lastError = nil
    }

    /// Explicitly keeps the local draft, based on the remote version observed in conflict.
    /// The next send is a whole-document write; callers should still use server authorization.
    @discardableResult
    mutating func keepLocalConflict() -> [NativeShareCollaborationOutbound] {
        guard let conflict else { return [] }
        persistedContent = conflict.remoteContent
        localContent = conflict.localContent
        self.conflict = nil
        queuedContent = localContent == persistedContent ? nil : localContent
        inFlightContent = nil
        saveState = queuedContent == nil ? .saved : .queued
        lastError = nil
        guard connection == .connected, let next = dequeueLatestEdit() else { return [] }
        return [.edit(content: next)]
    }

    private func accepts(_ callbackIdentity: NativeShareCollaborationIdentity, generation callbackGeneration: Int) -> Bool {
        identity == callbackIdentity && generation == callbackGeneration
    }

    private mutating func dequeueLatestEdit() -> String? {
        guard let queuedContent else {
            queuedContent = nil
            saveState = .saved
            return nil
        }
        self.queuedContent = nil
        inFlightContent = queuedContent
        saveState = .saving
        return queuedContent
    }

    private func bounded(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return String(text.prefix(2_000))
    }
}
