import Foundation

struct ThesisDocument: Codable, Equatable {
    var title: String
    var body: String
    var revision: Int

    static let bodyLimit = 1_000_000

    func validated() throws -> ThesisDocument {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf16.count <= 500, !title.contains("\n"), !title.contains("\r"),
              body.utf16.count <= Self.bodyLimit, revision >= 0 else {
            throw ThesisClientError.invalidDocument
        }
        return self
    }
}

struct ThesisAccess: Decodable, Equatable {
    let member: Bool
    let canEdit: Bool
}

struct ThesisHistoryEntry: Decodable, Identifiable, Equatable {
    let revision: Int
    let title: String
    let savedAt: String
    let immediate: Bool

    var id: Int { revision }

    enum CodingKeys: String, CodingKey {
        case revision, title, immediate
        case savedAt = "saved_at"
    }
}

enum ThesisClientError: LocalizedError, Equatable {
    case signInRequired
    case invalidBaseURL
    case invalidIdentity
    case readOnly
    case invalidDocument
    case invalidResponse
    case requestFailed(Int, String?)
    case conflict(ThesisDocument)

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to open Thesis."
        case .invalidBaseURL: "Thesis requires a valid HTTPS API address."
        case .invalidIdentity: "The signed-in account could not be verified."
        case .readOnly: "This account can view Thesis but cannot edit it."
        case .invalidDocument: "The thesis title or content exceeds the service limits."
        case .invalidResponse: "The Thesis service returned an invalid response."
        case let .requestFailed(status, message): message ?? "Thesis request failed (HTTP \(status))."
        case .conflict: "Another editor saved a newer version. Refresh and review the shared document before saving."
        }
    }
}
