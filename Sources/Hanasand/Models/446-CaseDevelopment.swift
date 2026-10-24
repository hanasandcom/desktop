import Foundation

struct CaseDevelopmentEntry: Decodable, Identifiable, Equatable {
    let repositoryID: String
    let kind: String
    let externalID: String
    let title: String
    let url: String
    let author: String
    let state: String
    let branch: String
    let updatedAt: String
    let repositoryURL: String
    let provider: String

    var id: String { "\(repositoryID):\(kind):\(externalID)" }

    enum CodingKeys: String, CodingKey {
        case repositoryID = "repository_id"
        case kind
        case externalID = "external_id"
        case title, url, author, state, branch
        case updatedAt = "updated_at"
        case repositoryURL = "repository_url"
        case provider
    }

    var validatedExternalURL: URL? {
        guard let entryURL = URL(string: url), entryURL.scheme?.lowercased() == "https",
              entryURL.host != nil, entryURL.user == nil, entryURL.password == nil else { return nil }
        return entryURL
    }

    func isValid() -> Bool {
        guard CaseDevelopmentRepository.validID(repositoryID),
              ["commit", "pull_request"].contains(kind),
              !externalID.isEmpty, externalID.utf8.count <= 128,
              !title.isEmpty, title.utf8.count <= 2_000,
              !state.isEmpty, state.utf8.count <= 80,
              branch.utf8.count <= 512,
              !updatedAt.isEmpty,
              ["github", "forgejo", "gitlab"].contains(provider),
              let repository = URL(string: repositoryURL), repository.scheme?.lowercased() == "https",
              repository.host != nil, repository.user == nil, repository.password == nil,
              repository.query == nil, repository.fragment == nil,
              validatedExternalURL != nil else { return false }
        return true
    }
}

struct CaseDevelopmentPage: Decodable, Equatable {
    let items: [CaseDevelopmentEntry]
    let hasMore: Bool
}

struct CaseDevelopmentCommit: Decodable, Identifiable, Equatable {
    let externalID: String
    let title: String
    let author: String
    let updatedAt: String

    var id: String { externalID }

    enum CodingKeys: String, CodingKey {
        case externalID = "external_id"
        case title, author
        case updatedAt = "updated_at"
    }

    func isValid() -> Bool {
        externalID.range(of: "^[A-Fa-f0-9]{40,64}$", options: .regularExpression) != nil
            && !title.isEmpty && title.utf8.count <= 2_000
            && author.utf8.count <= 500 && !updatedAt.isEmpty
    }
}

struct CaseDevelopmentCommitPage: Decodable, Equatable {
    let items: [CaseDevelopmentCommit]
    let nextCursor: String?
}

struct CaseDevelopmentRepository: Decodable, Identifiable, Equatable {
    let id: String
    let provider: String
    let repositoryURL: String
    let organizationID: String?
    let canManage: Bool
    let lastReceivedAt: String?
    let lastWarning: String?

    enum CodingKeys: String, CodingKey {
        case id, provider
        case repositoryURL = "repository_url"
        case organizationID = "organization_id"
        case canManage = "can_manage"
        case lastReceivedAt = "last_received_at"
        case lastWarning = "last_warning"
    }

    func isValid(expectedOrganizationID: String?) -> Bool {
        guard Self.validID(id), ["github", "forgejo", "gitlab"].contains(provider),
              let url = URL(string: repositoryURL), url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              organizationID == expectedOrganizationID else { return false }
        return true
    }

    static func validID(_ value: String) -> Bool {
        value.range(of: "^[A-Fa-f0-9-]{36}$", options: .regularExpression) != nil
    }
}

struct CaseDevelopmentRepositorySetup: Decodable, Equatable {
    let id: String
    let secret: String
    let webhookPath: String
}

struct CaseDevelopmentMutationReceipt: Decodable, Equatable {
    let ok: Bool
}

enum CaseDevelopmentMutationOutcome {
    static func needsReview(afterDispatch: Bool, error: CaseDevelopmentClientError) -> Bool {
        guard afterDispatch else { return false }
        switch error {
        case .transport, .invalidResponse:
            return true
        case .requestFailed(let status):
            return status >= 500 || status == 408
        case .signInRequired, .impersonationUnsupported, .invalidEndpoint, .invalidInput:
            return false
        }
    }
}
