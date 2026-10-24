import Foundation

struct ShareChatContextFile: Decodable, Equatable, Identifiable {
    let id: String
    let path: String
    let content: String
}

struct ShareChatTreeItem: Decodable, Equatable {
    let id: String
    let name: String
    let type: String
    let children: [ShareChatTreeItem]

    enum CodingKeys: String, CodingKey { case id, name, type, children }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(String.self, forKey: .type)
        if type == "folder" {
            children = Array((try container.decodeIfPresent([ShareChatTreeItem].self, forKey: .children) ?? []).prefix(500))
        } else {
            children = []
        }
    }
}

struct ShareChatContext: Equatable {
    let shareID: String
    let workspaceId: String
    let workspaceKind: String
    let shareIds: [String]
    let selectedFilePath: String?
    let treePaths: [String]
    let files: [ShareChatContextFile]

    var promptContext: String {
        var sections = ["Share workspace \(shareID)."]
        if !treePaths.isEmpty {
            sections.append("Workspace files:\n\(treePaths.joined(separator: "\n"))")
        }
        for file in files {
            let limit = file.path == selectedFilePath ? 12_000 : 2_500
            sections.append("File (\(file.path)):\n\(String(file.content.prefix(limit)))")
        }
        return sections.joined(separator: "\n\n")
    }

    func apply(to conversation: inout DesktopAIConversation) {
        conversation.workspaceId = workspaceId
        conversation.workspaceKind = workspaceKind
        conversation.shareIds = Self.deduplicated([shareID] + conversation.shareIds)
        if let selectedFilePath {
            conversation.workspaceMeta["selectedFilePath"] = .string(selectedFilePath)
        }
    }

    func makeConversation(ownerID: String) -> DesktopAIConversation {
        var conversation = DesktopAIConversation(ownerId: ownerID)
        apply(to: &conversation)
        return conversation
    }

    static func deduplicated(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    static func validIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9._~-]{1,200}$"#, options: .regularExpression) != nil
    }

    static func validPath(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 512, !value.hasPrefix("/"), !value.contains("\\") else { return false }
        return !value.split(separator: "/").contains("..") && !value.split(separator: "/").contains(".")
    }
}
