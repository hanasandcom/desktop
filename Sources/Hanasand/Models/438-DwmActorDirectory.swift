import Foundation

struct DwmActorDirectoryPage: Decodable, Equatable {
    struct Actor: Decodable, Equatable, Identifiable {
        let actor: String
        let aliases: [String]
        let sourceFamilies: [String]
        let sourceCount: Int
        let captureCount: Int
        let latestSeenAt: String?
        let confidence: Double
        let watchState: String
        let summary: String

        var id: String { actor }

        private enum CodingKeys: String, CodingKey {
            case actor, aliases, sourceFamilies, sourceCount, captureCount
            case latestSeenAt, confidence, watchState, summary
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            actor = try values.decode(String.self, forKey: .actor)
            aliases = try values.decodeIfPresent([String].self, forKey: .aliases) ?? []
            sourceFamilies = try values.decodeIfPresent([String].self, forKey: .sourceFamilies) ?? []
            sourceCount = try values.decode(Int.self, forKey: .sourceCount)
            captureCount = try values.decode(Int.self, forKey: .captureCount)
            latestSeenAt = try values.decodeIfPresent(String.self, forKey: .latestSeenAt)
            confidence = try values.decode(Double.self, forKey: .confidence)
            watchState = try values.decode(String.self, forKey: .watchState)
            summary = try values.decodeIfPresent(String.self, forKey: .summary) ?? ""

            guard Self.validText(actor, limit: 300),
                  aliases.count <= 100, aliases.allSatisfy({ Self.validText($0, limit: 300) }),
                  sourceFamilies.count <= 100, sourceFamilies.allSatisfy({ Self.validText($0, limit: 120) }),
                  sourceCount >= 0, captureCount >= 0,
                  latestSeenAt.map({ Self.validText($0, limit: 100) }) ?? true,
                  confidence.isFinite, (0...1).contains(confidence),
                  ["active_monitoring", "metadata_only", "needs_more_sources"].contains(watchState),
                  summary.count <= 8_000, !summary.containsControlCharacters else {
                throw DecodingError.dataCorruptedError(forKey: .actor, in: values, debugDescription: "Actor overview is invalid")
            }
        }

        private static func validText(_ value: String, limit: Int) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && value.count <= limit
                && !value.containsControlCharacters
        }
    }

    let schemaVersion: String
    let tenantID: String
    let actorOverviews: [Actor]

    private enum CodingKeys: String, CodingKey { case schemaVersion, tenantId, actorOverviews }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(String.self, forKey: .schemaVersion)
        tenantID = try values.decode(String.self, forKey: .tenantId)
        actorOverviews = try values.decode([Actor].self, forKey: .actorOverviews)
        guard schemaVersion == "dwm.product.v1",
              Self.validWorkspaceID(tenantID),
              actorOverviews.count <= 10_000,
              Set(actorOverviews.map(\.actor)).count == actorOverviews.count else {
            throw DecodingError.dataCorruptedError(forKey: .actorOverviews, in: values, debugDescription: "Actor directory snapshot is invalid")
        }
    }

    func validate(tenantID requestedTenantID: String) throws {
        guard tenantID == requestedTenantID else { throw DwmActorDirectoryError.scopeChanged }
    }

    static func validWorkspaceID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_.:@-]{1,200}$", options: .regularExpression) != nil
            && value != "." && value != ".." && !value.containsControlCharacters
    }
}

enum DwmActorDirectoryError: LocalizedError {
    case signInRequired
    case impersonationUnsupported
    case invalidOrganization
    case invalidBaseURL
    case scopeChanged

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to view monitored actors."
        case .impersonationUnsupported: "Return to your own account to view monitored actors."
        case .invalidOrganization: "Select the organization associated with this actor directory."
        case .invalidBaseURL: "Configure a secure Hanasand website address to view monitored actors."
        case .scopeChanged: "Your account or selected organization changed. Reopen the monitored actor directory."
        }
    }
}

private extension String {
    var containsControlCharacters: Bool { unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
}
