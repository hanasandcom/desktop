import Foundation

struct NativeShareGitFile: Codable, Equatable, Identifiable {
    let path: String
    let index: String
    let workingTree: String
    let selected: Bool

    var id: String { path }

    func validate() throws {
        guard NativeShareGitSafety.isSafeRelativePath(path), index.utf8.count <= 8,
              workingTree.utf8.count <= 8 else { throw NativeShareGitError.invalidResponse }
    }
}

struct NativeShareGitStatus: Codable, Equatable {
    let files: [NativeShareGitFile]
    let branchSummary: String?

    func validate() throws {
        guard files.count <= NativeShareGitLimits.fileCount,
              (branchSummary?.utf8.count ?? 0) <= NativeShareGitLimits.fieldBytes,
              Set(files.map(\.path)).count == files.count else { throw NativeShareGitError.invalidResponse }
        try files.forEach { try $0.validate() }
    }
}

struct NativeShareGitRepositoryFile: Codable, Equatable {
    let path: String
    let name: String
    let content: String

    func validate() throws {
        guard NativeShareGitSafety.isSafeRelativePath(path), !name.isEmpty,
              name.utf8.count <= NativeShareGitLimits.fieldBytes,
              content.utf8.count <= NativeShareGitLimits.fileBytes else { throw NativeShareGitError.invalidResponse }
    }
}

struct NativeShareGitSyncEvent: Codable, Equatable {
    let timestamp: String
    let status: String
    let source: String
    let message: String
}

struct NativeShareGitCredential: Codable, Equatable {
    let provider: String
    let hasCredential: Bool
    let tokenHint: String?
    let attachedAt: String?
    let lastUsedAt: String?
    let lastValidatedAt: String?

    func validate() throws {
        guard provider == "github_pat",
              (tokenHint?.utf8.count ?? 0) <= 32,
              (attachedAt?.utf8.count ?? 0) <= 64,
              (lastUsedAt?.utf8.count ?? 0) <= 64,
              (lastValidatedAt?.utf8.count ?? 0) <= 64 else { throw NativeShareGitError.invalidResponse }
    }
}

struct NativeShareGitRepository: Codable, Equatable, Identifiable {
    let id: String
    let ownerId: String
    let accessScope: String
    let name: String
    let fullName: String
    let branch: String
    let defaultBranch: String
    let sourcePath: String
    let sourceUrl: String
    let authMode: String
    let authHint: String?
    let syncStatus: String
    let lastSyncedAt: String?
    let lastSyncError: String?
    let syncHistory: [NativeShareGitSyncEvent]
    let stackType: String
    let stackReason: String?
    let stackSupported: Bool
    let files: [NativeShareGitRepositoryFile]
    let truncated: Bool
    let importedAt: String
    let credential: NativeShareGitCredential

    func validate(expectedOwnerID: String? = nil) throws {
        guard NativeShareGitSafety.isIdentifier(id), NativeShareGitSafety.isIdentifier(ownerId),
              expectedOwnerID.map({ $0 == ownerId }) ?? true,
              ["owned", "shared_conversation"].contains(accessScope),
              !name.isEmpty, !fullName.isEmpty,
              name.utf8.count <= NativeShareGitLimits.fieldBytes,
              fullName.utf8.count <= NativeShareGitLimits.fieldBytes,
              branch.utf8.count <= NativeShareGitLimits.fieldBytes,
              defaultBranch.utf8.count <= NativeShareGitLimits.fieldBytes,
              sourcePath.utf8.count <= NativeShareGitLimits.fieldBytes,
              sourceUrl.utf8.count <= NativeShareGitLimits.fieldBytes,
              ["public", "github_token"].contains(authMode),
              ["ready", "syncing", "error"].contains(syncStatus),
              ["nextjs_docker", "fastify_postgres", "fastify_worker_redis", "unknown"].contains(stackType),
              (authHint?.utf8.count ?? 0) <= NativeShareGitLimits.fieldBytes,
              (lastSyncError?.utf8.count ?? 0) <= NativeShareGitLimits.fieldBytes,
              (stackReason?.utf8.count ?? 0) <= NativeShareGitLimits.fieldBytes,
              files.count <= NativeShareGitLimits.fileCount,
              syncHistory.count <= 12 else { throw NativeShareGitError.invalidResponse }
        try files.forEach { try $0.validate() }
        try credential.validate()
    }
}

struct NativeShareGitCredentialResponse: Decodable, Equatable {
    let credential: NativeShareGitCredential
}

struct NativeShareGitCommitResponse: Decodable, Equatable {
    let ok: Bool
    let commit: String
    let status: NativeShareGitStatus
}

struct NativeShareGitPersistResponse: Decodable, Equatable {
    let ok: Bool
    let id: String
}

enum NativeShareGitLimits {
    static let responseBytes = 32 * 1024 * 1024
    static let fileCount = 10_000
    static let fileBytes = 250_000
    static let totalFileBytes = 32 * 1024 * 1024
    static let fieldBytes = 2_048
    static let pathBytes = 1_024
    static let commitMessageBytes = 2_000
    static let commitPaths = 500
}

enum NativeShareGitSafety {
    static func isIdentifier(_ value: String) -> Bool {
        value.utf8.count <= 200 && value.range(of: "^[A-Za-z0-9._~-]{1,200}$", options: .regularExpression) != nil
    }

    static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= NativeShareGitLimits.pathBytes,
              !value.hasPrefix("/"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        return !value.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    static func validateCommit(message: String, paths: [String]) throws {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= NativeShareGitLimits.commitMessageBytes,
              paths.count > 0, paths.count <= NativeShareGitLimits.commitPaths,
              Set(paths).count == paths.count,
              paths.allSatisfy(isSafeRelativePath) else { throw NativeShareGitError.invalidInput }
    }
}

enum NativeShareGitError: LocalizedError, Equatable {
    case signInRequired
    case impersonationUnsupported
    case invalidEndpoint
    case invalidInput
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to manage Git for this workspace."
        case .impersonationUnsupported: "Git workspace operations are disabled during account impersonation."
        case .invalidEndpoint: "The configured AI API endpoint is invalid."
        case .invalidInput: "Review the repository input, commit message, and selected file paths."
        case .invalidResponse: "The Git service returned a response that could not be verified."
        case let .requestFailed(status): "Git workspace request failed (HTTP \(status))."
        }
    }
}
