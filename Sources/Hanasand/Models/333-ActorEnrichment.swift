import Foundation

struct ActorEnrichmentOverview: Decodable, Equatable {
    struct Profile: Decodable, Equatable, Identifiable {
        let id: String
        let name: String
        let aliases: [String]
        let confidence: Double?
        let updatedAt: String
        let sourceIDs: [String]
        let captureIDs: [String]
        let evidenceCount: Int

        enum CodingKeys: String, CodingKey {
            case id, canonicalName, name, aliases, confidence, updatedAt, lastSeenAt
            case sourceIDs = "sourceIds", captureIDs = "captureIds", evidenceCount
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            name = try values.decodeIfPresent(String.self, forKey: .canonicalName)
                ?? values.decodeIfPresent(String.self, forKey: .name) ?? "Unknown actor"
            aliases = Array((try values.decodeIfPresent([String].self, forKey: .aliases) ?? []).prefix(50))
            let rawConfidence = try values.decodeIfPresent(Double.self, forKey: .confidence)
            confidence = rawConfidence.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
            updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt)
                ?? values.decodeIfPresent(String.self, forKey: .lastSeenAt) ?? ""
            sourceIDs = Array((try values.decodeIfPresent([String].self, forKey: .sourceIDs) ?? []).prefix(100))
            captureIDs = Array((try values.decodeIfPresent([String].self, forKey: .captureIDs) ?? []).prefix(500))
            let count = try values.decodeIfPresent(Int.self, forKey: .evidenceCount) ?? captureIDs.count
            evidenceCount = max(0, count)
        }
    }

    struct Update: Decodable, Equatable, Identifiable {
        let id: String
        let actorID: String
        let actorName: String?
        let observedAt: String
        let sourceID: String?
        let sourceName: String?
        let captureIDs: [String]
        let kind: String
        let summary: String

        enum CodingKeys: String, CodingKey {
            case id, subjectId, actorName, observedAt, sourceId, sourceName, captureIds, kind, metadata
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            actorID = try values.decodeIfPresent(String.self, forKey: .subjectId) ?? ""
            actorName = try values.decodeIfPresent(String.self, forKey: .actorName)
            observedAt = try values.decodeIfPresent(String.self, forKey: .observedAt) ?? ""
            sourceID = try values.decodeIfPresent(String.self, forKey: .sourceId)
            sourceName = try values.decodeIfPresent(String.self, forKey: .sourceName)
            captureIDs = Array((try values.decodeIfPresent([String].self, forKey: .captureIds) ?? []).prefix(100))
            kind = try values.decodeIfPresent(String.self, forKey: .kind) ?? "updated"
            let metadata = try values.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
            let fields: [String]
            if case .object(let characterization)? = metadata["characterization"] {
                fields = Array(characterization.keys)
            } else {
                fields = []
            }
            let aliases: [String]
            if case .array(let values)? = metadata["aliasesAdded"] {
                aliases = values.compactMap { value in
                    if case .string(let alias) = value { return alias }
                    return nil
                }
            } else {
                aliases = []
            }
            let changes = fields + aliases.map { "alias: \($0)" }
            summary = changes.isEmpty ? "New retained evidence linked to this profile." : changes.sorted().joined(separator: " · ")
        }
    }

    struct WorkerStatus: Decodable, Equatable {
        struct Worker: Decodable, Equatable {
            let state: String
            let lastRunAt: String?
            let lastSuccessfulRunAt: String?
            let currentFailure: String?
            let snapshotFresh: Bool?
        }
        struct Productivity: Decodable, Equatable {
            let profiles: Int?
            let wordsAdded: Int?
            let newFacts: Int?
        }
        struct LatestRun: Decodable, Equatable {
            let id: String
            let status: String
            let actorCount: Int
            let sourceCount: Int
            let changedFieldCount: Int
            let evidenceCount: Int
            let failureCount: Int
            let finishedAt: String?
        }
        let worker: Worker
        let queued: Int
        let productivity: Productivity?
        let latestRun: LatestRun?
    }

    let profiles: [Profile]
    let updates: [Update]
    let status: WorkerStatus
}

struct ActorEnrichmentRunPage: Decodable, Equatable {
    struct Run: Decodable, Equatable, Identifiable {
        let id: String
        let status: String
        let startedAt: String?
        let finishedAt: String?
        let actorCount: Int
        let sourceCount: Int
        let changedFieldCount: Int
        let evidenceCount: Int
        let failureCount: Int
        let error: String?
    }

    let runs: [Run]
    let total: Int
    let nextCursor: String?
    let previousCursor: String?
}
