import Foundation

enum DesktopAIJSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: DesktopAIJSONValue]), array([DesktopAIJSONValue]), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let object = try? value.decode([String: Self].self) { self = .object(object) }
        else { self = .array(try value.decode([Self].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .bool(let item): try value.encode(item)
        case .object(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }
}

struct DesktopAIWorkspace: Decodable, Equatable {
    let conversations: [DesktopAIConversation]
    let repositories: [DesktopAIRepository]
    let deployments: [DesktopAIDeployment]
    let releases: [DesktopAIRelease]
    let deployQuota: DesktopAIDeployQuota?
    let runtimeState: [String: DesktopAIJSONValue]?

    var connectedModelNames: [String] {
        guard case .array(let values)? = runtimeState?["connectedModelNames"] else { return [] }
        return Array(Set(values.compactMap { value -> String? in
            guard case .string(let name) = value else { return nil }
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : clean
        })).sorted()
    }

    enum CodingKeys: String, CodingKey { case conversations, repositories, deployments, releases, deployQuota, runtimeState }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversations = Array((try c.decodeIfPresent([DesktopAIConversation].self, forKey: .conversations) ?? []).prefix(500))
        repositories = Array((try c.decodeIfPresent([DesktopAIRepository].self, forKey: .repositories) ?? []).prefix(200))
        deployments = Array((try c.decodeIfPresent([DesktopAIDeployment].self, forKey: .deployments) ?? []).prefix(200))
        releases = Array((try c.decodeIfPresent([DesktopAIRelease].self, forKey: .releases) ?? []).prefix(200))
        deployQuota = try c.decodeIfPresent(DesktopAIDeployQuota.self, forKey: .deployQuota)
        runtimeState = try c.decodeIfPresent([String: DesktopAIJSONValue].self, forKey: .runtimeState)
    }
}

struct DesktopAIShare: Decodable, Equatable, Identifiable {
    let id: String
    let path: String?
    let alias: String?
    let locked: Bool?

    var displayName: String {
        [path, alias, id].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? id
    }
}

struct DesktopAIVMTarget: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
}

struct DesktopAIDeploymentEvent: Decodable, Equatable, Identifiable {
    let stage: String
    let message: String
    let timestamp: String
    var id: String { "\(stage)-\(timestamp)" }
}

struct DesktopAIDeployment: Decodable, Equatable, Identifiable {
    let id: String
    let ownerId: String
    let conversationId: String
    let repositoryId: String?
    let workspaceKind: String?
    let workspaceId: String?
    let vmName: String
    let serviceName: String
    let stackType: String
    let accessPolicy: String
    let status: String
    let previewUrl: String?
    let healthcheckUrl: String?
    let events: [DesktopAIDeploymentEvent]
    let failureReason: String?
    let createdAt: String
    let updatedAt: String
    let completedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, ownerId, conversationId, repositoryId, workspaceKind, workspaceId, vmName, serviceName,
             stackType, accessPolicy, status, previewUrl, healthcheckUrl, events, failureReason, createdAt, updatedAt, completedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        ownerId = try c.decodeIfPresent(String.self, forKey: .ownerId) ?? ""
        conversationId = try c.decodeIfPresent(String.self, forKey: .conversationId) ?? ""
        repositoryId = try c.decodeIfPresent(String.self, forKey: .repositoryId)
        workspaceKind = try c.decodeIfPresent(String.self, forKey: .workspaceKind)
        workspaceId = try c.decodeIfPresent(String.self, forKey: .workspaceId)
        vmName = try c.decodeIfPresent(String.self, forKey: .vmName) ?? "Unknown target"
        serviceName = try c.decodeIfPresent(String.self, forKey: .serviceName) ?? ""
        stackType = try c.decodeIfPresent(String.self, forKey: .stackType) ?? "unknown"
        accessPolicy = try c.decodeIfPresent(String.self, forKey: .accessPolicy) ?? "owner_only"
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        previewUrl = try c.decodeIfPresent(String.self, forKey: .previewUrl)
        healthcheckUrl = try c.decodeIfPresent(String.self, forKey: .healthcheckUrl)
        events = Array((try c.decodeIfPresent([DesktopAIDeploymentEvent].self, forKey: .events) ?? []).suffix(100))
        failureReason = try c.decodeIfPresent(String.self, forKey: .failureReason)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? createdAt
        completedAt = try c.decodeIfPresent(String.self, forKey: .completedAt)
    }
}

struct DesktopAIDeployQuota: Decodable, Equatable {
    let used: Int
    let limit: Int
    let remaining: Int
    let windowMinutes: Int
    let resetsAt: String
    let activeRunning: Int
    let maxRunning: Int
    let runningRemaining: Int
    let sharedAcrossCollaborators: Bool
}

struct DesktopAIRelease: Decodable, Equatable, Identifiable {
    let id: String
    let ownerId: String
    let conversationId: String
    let deploymentId: String?
    let vmName: String
    let stackType: String
    let accessPolicy: String
    var status: String
    let previewUrl: String?
    let createdAt: String
    var updatedAt: String
    let notes: String?
}

struct DesktopAIDeploymentSnapshot: Decodable, Equatable {
    let deployments: [DesktopAIDeployment]
    let quota: DesktopAIDeployQuota?
}

struct DesktopAIReleaseSnapshot: Decodable, Equatable {
    let releases: [DesktopAIRelease]
}

struct DesktopAIStartDeploymentResponse: Decodable, Equatable {
    let deployment: DesktopAIDeployment?
    let quota: DesktopAIDeployQuota?
    let error: String?
}

struct DesktopAIStartDeploymentResult: Equatable {
    let response: DesktopAIStartDeploymentResponse
    let statusCode: Int
}

struct DesktopAIRollbackResponse: Decodable, Equatable {
    let release: DesktopAIRelease?
    let error: String?
}

struct DesktopAIReleaseSupportBundleResponse: Decodable, Equatable {
    let bundle: DesktopAIJSONValue?
    let error: String?
}

struct DesktopAIWorkspaceToolCall: Decodable, Equatable, Identifiable {
    struct ProjectFile: Decodable, Equatable {
        let path: String
        let content: String
    }

    let id: String
    let action: String
    let shareId: String?
    let path: String?
    let content: String?
    let url: String?
    let method: String?
    let headers: [String: String]?
    let body: String?
    let projectName: String?
    let vmName: String?
    let command: String?
    let timeoutMs: Int?
    let captureScreenshot: Bool?
    let projectFiles: [ProjectFile]?

    enum CodingKeys: String, CodingKey {
        case action, shareId, path, content, url, method, headers, body, projectName, vmName, command,
             timeoutMs, captureScreenshot, projectFiles
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID().uuidString
        action = try c.decode(String.self, forKey: .action)
        shareId = try c.decodeIfPresent(String.self, forKey: .shareId)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        method = try c.decodeIfPresent(String.self, forKey: .method)
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        projectName = try c.decodeIfPresent(String.self, forKey: .projectName)
        vmName = try c.decodeIfPresent(String.self, forKey: .vmName)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        timeoutMs = try c.decodeIfPresent(Int.self, forKey: .timeoutMs)
        captureScreenshot = try c.decodeIfPresent(Bool.self, forKey: .captureScreenshot)
        projectFiles = try c.decodeIfPresent([ProjectFile].self, forKey: .projectFiles)
    }

    var requiresConfirmation: Bool {
        switch action {
        case "update_share", "run_terminal_command", "scaffold_nextjs_docker", "create_vm", "create_project": true
        case "http_request": !["GET", "HEAD"].contains((method ?? "GET").uppercased())
        default: false
        }
    }

    var confirmationSummary: String {
        switch action {
        case "update_share": "Replace the contents of \(path ?? shareId ?? "the selected repository file")."
        case "run_terminal_command": "Run `\(command ?? "")` in the attached repository’s restricted terminal."
        case "create_vm": "Create VM `\(vmName ?? projectName ?? "hanasand-project")` with the Hanasand VM service."
        case "create_project": "Create a repository and provision a VM for `\(projectName ?? "hanasand-project")`."
        case "scaffold_nextjs_docker": "Create or update a Next.js + Docker starter in the attached repository."
        case "http_request": "Send HTTP \((method ?? "GET").uppercased()) to \(url ?? "the requested endpoint")."
        default: "Run \(action)."
        }
    }

    static func parse(from content: String) -> [Self] {
        let pattern = #"<hanasand-tool>([\s\S]*?)</hanasand-tool>"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = content as NSString
        return expression.matches(in: content, range: NSRange(location: 0, length: source.length)).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            let json = source.substring(with: match.range(at: 1))
            guard let data = json.data(using: .utf8), let call = try? JSONDecoder().decode(Self.self, from: data),
                  ["read_share", "update_share", "http_request", "browser_task", "scaffold_nextjs_docker", "create_vm", "create_project", "run_terminal_command"].contains(call.action) else { return nil }
            return call
        }
    }

    static func stripTags(from content: String) -> String {
        content.replacingOccurrences(of: #"<hanasand-tool>[\s\S]*?</hanasand-tool>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct DesktopAIWorkspaceToolArtifact: Decodable, Equatable, Identifiable {
    let kind: String
    let title: String
    let path: String?
    let url: String?
    let content: String?
    var id: String { "\(kind)-\(title)-\(url ?? path ?? "")" }
}

struct DesktopAIWorkspaceToolResult: Equatable {
    let ok: Bool
    let message: String
    var artifacts: [DesktopAIWorkspaceToolArtifact] = []
}

struct DesktopAIPendingToolAction: Equatable, Identifiable {
    let id: String
    let conversationID: String
    let call: DesktopAIWorkspaceToolCall
}

struct DesktopAIWorkspaceToolShareFile: Decodable {
    let id: String?
    let name: String?
    let path: String?
    let content: String?
    let locked: Bool?
}

struct DesktopAIWorkspaceBrowserResult: Decodable {
    let ok: Bool?
    let url: String?
    let title: String?
    let textExcerpt: String?
    let screenshotPath: String?
    let consoleMessages: [String]?
    let pageErrors: [String]?
    let error: String?
}

struct DesktopAIWorkspaceVMCreateResponse: Decodable {
    let error: String?
}

struct DesktopAIWorkspaceProjectVM: Decodable {
    let status: String?
    let status_reason: String?
}

struct DesktopAIWorkspacePublicServices: Decodable {
    struct Service: Decodable {
        let port: Int
    }
    let services: [Service]
    let portAlias: String
}

struct DesktopAIConversationCollaborator: Decodable, Equatable, Identifiable {
    let userId: String
    let name: String?
    let avatar: String?
    let role: String
    let invitedBy: String?
    let createdAt: String?
    var id: String { userId }
    var displayName: String {
        let value = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? userId : value
    }
}

struct DesktopAIConversationCollaboration: Decodable, Equatable {
    let role: String
    let canInvite: Bool
    let seatLimit: Int
    let seatCount: Int
    let remainingSeats: Int
    let collaborators: [DesktopAIConversationCollaborator]

    enum CodingKeys: String, CodingKey { case role, canInvite, seatLimit, seatCount, remainingSeats, collaborators }
    init(role: String, canInvite: Bool, seatLimit: Int, seatCount: Int, remainingSeats: Int,
         collaborators: [DesktopAIConversationCollaborator]) {
        self.role = role; self.canInvite = canInvite; self.seatLimit = seatLimit
        self.seatCount = seatCount; self.remainingSeats = remainingSeats; self.collaborators = collaborators
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? "owner"
        canInvite = try c.decodeIfPresent(Bool.self, forKey: .canInvite) ?? (role == "owner")
        seatLimit = try c.decodeIfPresent(Int.self, forKey: .seatLimit) ?? 5
        seatCount = try c.decodeIfPresent(Int.self, forKey: .seatCount) ?? 1
        remainingSeats = try c.decodeIfPresent(Int.self, forKey: .remainingSeats) ?? max(seatLimit - seatCount, 0)
        collaborators = Array((try c.decodeIfPresent([DesktopAIConversationCollaborator].self, forKey: .collaborators) ?? []).prefix(20))
    }

    static func fallback(role: String) -> Self {
        .init(role: role, canInvite: role == "owner", seatLimit: 5, seatCount: 1, remainingSeats: 4, collaborators: [])
    }
}

struct DesktopAIConversationEnvelope: Decodable {
    let conversation: DesktopAIConversation?
    let error: String?
}

struct DesktopAIRemoveCollaboratorResponse: Decodable {
    let ok: Bool?
    let conversation: DesktopAIConversation?
    let error: String?
}

struct DesktopAIConversation: Decodable, Equatable, Identifiable {
    let id: String
    let ownerId: String
    var title: String
    var preferredModel: String?
    var activeModel: String?
    var modelStrategy: String
    var workspaceId: String?
    var workspaceKind: String?
    var shareIds: [String]
    var workspaceMeta: [String: DesktopAIJSONValue]
    var messages: [DesktopAIMessage]
    let collaborationRole: String
    var collaboration: DesktopAIConversationCollaboration
    var archivedAt: String?
    let createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, ownerId, title, preferredModel, activeModel, modelStrategy, workspaceId, workspaceKind,
             shareIds, workspaceMeta, messages, collaboration, archivedAt, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        ownerId = try c.decodeIfPresent(String.self, forKey: .ownerId) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "New chat"
        preferredModel = try c.decodeIfPresent(String.self, forKey: .preferredModel)
        activeModel = try c.decodeIfPresent(String.self, forKey: .activeModel)
        modelStrategy = try c.decodeIfPresent(String.self, forKey: .modelStrategy) ?? "auto"
        workspaceId = try c.decodeIfPresent(String.self, forKey: .workspaceId)
        workspaceKind = try c.decodeIfPresent(String.self, forKey: .workspaceKind)
        shareIds = Array((try c.decodeIfPresent([String].self, forKey: .shareIds) ?? []).prefix(100))
        workspaceMeta = try c.decodeIfPresent([String: DesktopAIJSONValue].self, forKey: .workspaceMeta) ?? [:]
        messages = Array((try c.decodeIfPresent([DesktopAIMessage].self, forKey: .messages) ?? []).suffix(500))
        let collab = try c.decodeIfPresent(Collaboration.self, forKey: .collaboration)
        collaborationRole = collab?.role ?? "owner"
        collaboration = try c.decodeIfPresent(DesktopAIConversationCollaboration.self, forKey: .collaboration)
            ?? .fallback(role: collaborationRole)
        archivedAt = try c.decodeIfPresent(String.self, forKey: .archivedAt)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? createdAt
    }

    private struct Collaboration: Decodable { let role: String? }

    init(id: String = UUID().uuidString.lowercased(), ownerId: String, title: String = "New chat", createdAt: String = ISO8601DateFormatter().string(from: Date())) {
        self.id = id; self.ownerId = ownerId; self.title = title; preferredModel = nil; activeModel = nil
        modelStrategy = "auto"; workspaceId = nil; workspaceKind = nil; shareIds = []; workspaceMeta = [:]
        messages = []; collaborationRole = "owner"; collaboration = .fallback(role: "owner")
        archivedAt = nil; self.createdAt = createdAt; updatedAt = createdAt
    }

    var canWrite: Bool { ["owner", "editor"].contains(collaborationRole) }

    func persistencePayload() -> [String: DesktopAIJSONValue] {
        ["id": .string(id), "title": .string(title), "preferredModel": preferredModel.map(DesktopAIJSONValue.string) ?? .null,
         "activeModel": activeModel.map(DesktopAIJSONValue.string) ?? .null, "modelStrategy": .string(modelStrategy),
         "workspaceKind": workspaceKind.map(DesktopAIJSONValue.string) ?? .null,
         "workspaceId": workspaceId.map(DesktopAIJSONValue.string) ?? .null,
         "shareIds": .array(shareIds.map(DesktopAIJSONValue.string)), "workspaceMeta": .object(workspaceMeta),
         "archivedAt": archivedAt.map(DesktopAIJSONValue.string) ?? .null]
    }
}

struct DesktopAIMessage: Decodable, Equatable, Identifiable {
    let id: String
    var role: String
    var content: String
    var pending: Bool
    var error: Bool
    var modelName: String?
    var metadata: [String: DesktopAIJSONValue]
    let createdAt: String

    enum CodingKeys: String, CodingKey { case id, role, content, pending, error, modelName, metadata, createdAt }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? "assistant"
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        pending = try c.decodeIfPresent(Bool.self, forKey: .pending) ?? false
        error = try c.decodeIfPresent(Bool.self, forKey: .error) ?? false
        modelName = try c.decodeIfPresent(String.self, forKey: .modelName)
        metadata = try c.decodeIfPresent([String: DesktopAIJSONValue].self, forKey: .metadata) ?? [:]
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }

    init(id: String = UUID().uuidString.lowercased(), role: String, content: String, pending: Bool = false, error: Bool = false, modelName: String? = nil, metadata: [String: DesktopAIJSONValue] = [:], createdAt: String = ISO8601DateFormatter().string(from: Date())) {
        self.id = id; self.role = role; self.content = content; self.pending = pending; self.error = error
        self.modelName = modelName; self.metadata = metadata; self.createdAt = createdAt
    }

    func persistencePayload() -> [String: DesktopAIJSONValue] {
        ["id": .string(id), "role": .string(role), "content": .string(content), "pending": .bool(pending),
         "error": .bool(error), "modelName": modelName.map(DesktopAIJSONValue.string) ?? .null,
         "metadata": .object(metadata), "createdAt": .string(createdAt)]
    }
}

struct DesktopAIRepository: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    let fullName: String
    let branch: String
    let sourceUrl: String
    let syncStatus: String

    enum CodingKeys: String, CodingKey { case id, name, fullName, branch, sourceUrl, syncStatus }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Repository"
        fullName = try c.decodeIfPresent(String.self, forKey: .fullName) ?? name
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? ""
        sourceUrl = try c.decodeIfPresent(String.self, forKey: .sourceUrl) ?? ""
        syncStatus = try c.decodeIfPresent(String.self, forKey: .syncStatus) ?? "unknown"
    }
}
