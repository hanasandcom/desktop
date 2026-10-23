import Foundation

struct ThreatIntelSearchResult: Decodable {
    struct Candidate: Decodable, Identifiable {
        var id: String { "\(name):\(url?.absoluteString ?? "")" }
        let name: String
        let description: String
        let aliases: [String]
        let url: URL?
        enum CodingKeys: String, CodingKey { case canonicalName, description, associatedNames, sourceUrl }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .canonicalName) ?? ""
            description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
            aliases = try c.decodeIfPresent([String].self, forKey: .associatedNames) ?? []
            url = Self.safeURL(try c.decodeIfPresent(String.self, forKey: .sourceUrl))
        }
    }
    struct Source: Decodable, Identifiable {
        var id: String { stableID }
        let stableID: String
        let name: String
        let type: String
        let provenance: String
        let collectedAt: String
        let url: URL?
        enum CodingKeys: String, CodingKey { case id, name, type, provenance, collectedAt, lastCollectedAt, url }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
            provenance = try c.decodeIfPresent(String.self, forKey: .provenance) ?? ""
            collectedAt = try c.decodeIfPresent(String.self, forKey: .lastCollectedAt) ?? c.decodeIfPresent(String.self, forKey: .collectedAt) ?? ""
            url = Candidate.safeURL(try c.decodeIfPresent(String.self, forKey: .url))
            stableID = try c.decodeIfPresent(String.self, forKey: .id)
                ?? [name, type, url?.absoluteString ?? ""].joined(separator: "|")
        }
    }
    struct Activity: Decodable, Identifiable {
        var id: String { [date, title, detail, sourceIDs.joined(separator: ","), url?.absoluteString ?? ""].joined(separator: "|") }
        let title: String
        let detail: String
        let date: String
        let sourceIDs: [String]
        let reviewState: String
        let corroboration: String
        let url: URL?
        enum CodingKeys: String, CodingKey { case title, detail, date, sourceIds, reviewState, corroborationState, url }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Activity"
            detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
            date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
            sourceIDs = try c.decodeIfPresent([String].self, forKey: .sourceIds) ?? []
            reviewState = try c.decodeIfPresent(String.self, forKey: .reviewState) ?? ""
            corroboration = try c.decodeIfPresent(String.self, forKey: .corroborationState) ?? ""
            url = Candidate.safeURL(try c.decodeIfPresent(String.self, forKey: .url))
        }
    }
    struct Technique: Decodable, Identifiable {
        var id: String { "\(attackID):\(name)" }
        let attackID: String
        let name: String
        let tactic: String
        let detail: String
        let sourceIDs: [String]
        enum CodingKeys: String, CodingKey { case attackId, name, tactic, detail, sourceIds }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            attackID = try c.decodeIfPresent(String.self, forKey: .attackId) ?? ""
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            tactic = try c.decodeIfPresent(String.self, forKey: .tactic) ?? ""
            detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
            sourceIDs = try c.decodeIfPresent([String].self, forKey: .sourceIds) ?? []
        }
    }
    struct Target: Decodable, Identifiable {
        var id: String { "\(sector):\(regions.joined(separator: ","))" }
        let sector: String
        let regions: [String]
        let rationale: String
        enum CodingKeys: String, CodingKey { case sector, regions, rationale }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sector = try c.decodeIfPresent(String.self, forKey: .sector) ?? ""
            regions = try c.decodeIfPresent([String].self, forKey: .regions) ?? []
            rationale = try c.decodeIfPresent(String.self, forKey: .rationale) ?? ""
        }
    }

    let query: String
    let summary: String
    let status: String
    let mode: String
    let generatedAt: String
    let refreshAfterSeconds: Int
    let confidence: Double?
    let aliases: [String]
    let notes: [String]
    let catalogOnly: Bool
    let candidates: [Candidate]
    let sources: [Source]
    let activity: [Activity]
    let techniques: [Technique]
    let targets: [Target]

    enum CodingKeys: String, CodingKey { case query, summary, status, mode, generatedAt, refreshAfterSeconds, confidence, aliases, notes, actorIdentity, sources, recentActivity, ttps, targets }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        query = try c.decode(String.self, forKey: .query)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "ready"
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? ""
        generatedAt = try c.decodeIfPresent(String.self, forKey: .generatedAt) ?? ""
        refreshAfterSeconds = min(60, max(0, try c.decodeIfPresent(Int.self, forKey: .refreshAfterSeconds) ?? 0))
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence).flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
        let identity = try c.decodeIfPresent(Identity.self, forKey: .actorIdentity) ?? Identity()
        catalogOnly = identity.catalogMatched && !identity.activityEvidenceAvailable
        candidates = identity.candidates
        sources = try c.decodeIfPresent([Source].self, forKey: .sources) ?? []
        activity = try c.decodeIfPresent([Activity].self, forKey: .recentActivity) ?? []
        techniques = try c.decodeIfPresent([Technique].self, forKey: .ttps) ?? []
        targets = try c.decodeIfPresent([Target].self, forKey: .targets) ?? []
    }

    private struct Identity: Decodable {
        let catalogMatched: Bool
        let activityEvidenceAvailable: Bool
        let candidates: [Candidate]
        enum CodingKeys: String, CodingKey { case catalogMatched, activityEvidenceAvailable, candidates }
        init() { catalogMatched = false; activityEvidenceAvailable = false; candidates = [] }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            catalogMatched = try c.decodeIfPresent(Bool.self, forKey: .catalogMatched) ?? false
            activityEvidenceAvailable = try c.decodeIfPresent(Bool.self, forKey: .activityEvidenceAvailable) ?? false
            candidates = try c.decodeIfPresent([Candidate].self, forKey: .candidates) ?? []
        }
    }
}

private extension ThreatIntelSearchResult.Candidate {
    static func safeURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), url.scheme?.lowercased() == "https",
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
}

struct ThreatSavedSearch: Decodable, Identifiable {
    var id: String { query }
    let query: String
    let savedAt: String
    enum CodingKeys: String, CodingKey { case query, savedAt, saved_at }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        query = try c.decode(String.self, forKey: .query)
        savedAt = try c.decodeIfPresent(String.self, forKey: .savedAt) ?? c.decodeIfPresent(String.self, forKey: .saved_at) ?? ""
    }
}
struct ThreatSavedSearchList: Decodable { let savedSearches: [ThreatSavedSearch] }
struct ThreatSavedSearchMutation: Encodable { let query: String }
