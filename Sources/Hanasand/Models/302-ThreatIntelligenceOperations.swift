import Foundation

struct ThreatIntelligenceOperationsPage: Decodable, Equatable {
    struct Profile: Decodable, Equatable, Identifiable {
        let id: String
        let name: String
        let normalizedName: String
        let actorType: String
        let aliases: [String]
        let confidence: Double?
        let evidenceCount: Int?
        let sourceIDs: [String]
        let captureIDs: [String]
        let reviewState: String
        let firstSeenAt: String
        let lastSeenAt: String
        let updatedAt: String

        enum CodingKeys: String, CodingKey {
            case id, canonicalName, normalizedName, actorType, aliases, confidence, evidenceCount, sourceIds, captureIds
            case reviewState, firstSeenAt, lastSeenAt, updatedAt
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            name = try values.decodeIfPresent(String.self, forKey: .canonicalName) ?? "Unknown actor"
            normalizedName = try values.decodeIfPresent(String.self, forKey: .normalizedName) ?? ""
            actorType = try values.decodeIfPresent(String.self, forKey: .actorType) ?? ""
            aliases = Array((try values.decodeIfPresent([String].self, forKey: .aliases) ?? []).prefix(50))
            let confidence = try values.decodeIfPresent(Double.self, forKey: .confidence)
            self.confidence = confidence.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
            let evidenceCount = try values.decodeIfPresent(Int.self, forKey: .evidenceCount)
            self.evidenceCount = evidenceCount.flatMap { $0 >= 0 ? $0 : nil }
            sourceIDs = Array((try values.decodeIfPresent([String].self, forKey: .sourceIds) ?? []).prefix(100))
            captureIDs = Array((try values.decodeIfPresent([String].self, forKey: .captureIds) ?? []).prefix(500))
            reviewState = try values.decodeIfPresent(String.self, forKey: .reviewState) ?? ""
            firstSeenAt = try values.decodeIfPresent(String.self, forKey: .firstSeenAt) ?? ""
            lastSeenAt = try values.decodeIfPresent(String.self, forKey: .lastSeenAt) ?? ""
            updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        }
    }

    let profiles: [Profile]
    let total: Int
    let page: Int
    let nextPage: Int?
}

struct ThreatIntelligenceSourcePage: Decodable, Equatable {
    struct Source: Decodable, Equatable, Identifiable {
        struct OperatingMode: Decodable, Equatable {
            let accessMethod: String
            let metadataOnly: Bool
            let approvalState: String
            let policyVersion: String

            enum CodingKeys: String, CodingKey { case accessMethod, metadataOnly, approvalState, policyVersion }
            init(accessMethod: String, metadataOnly: Bool, approvalState: String, policyVersion: String) {
                self.accessMethod = accessMethod
                self.metadataOnly = metadataOnly
                self.approvalState = approvalState
                self.policyVersion = policyVersion
            }
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                accessMethod = try values.decodeIfPresent(String.self, forKey: .accessMethod) ?? ""
                metadataOnly = try values.decodeIfPresent(Bool.self, forKey: .metadataOnly) ?? false
                approvalState = try values.decodeIfPresent(String.self, forKey: .approvalState) ?? ""
                policyVersion = try values.decodeIfPresent(String.self, forKey: .policyVersion) ?? ""
            }
        }

        struct Collection: Decodable, Equatable {
            let cadenceSeconds: Int?
            let freshnessTargetSeconds: Int?
            let lastSeenAt: String
            let createdAt: String
            let updatedAt: String

            enum CodingKeys: String, CodingKey { case cadenceSeconds, freshnessTargetSeconds, lastSeenAt, createdAt, updatedAt }
            init(cadenceSeconds: Int?, freshnessTargetSeconds: Int?, lastSeenAt: String, createdAt: String, updatedAt: String) {
                self.cadenceSeconds = cadenceSeconds
                self.freshnessTargetSeconds = freshnessTargetSeconds
                self.lastSeenAt = lastSeenAt
                self.createdAt = createdAt
                self.updatedAt = updatedAt
            }
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                cadenceSeconds = try values.decodeIfPresent(Int.self, forKey: .cadenceSeconds)
                freshnessTargetSeconds = try values.decodeIfPresent(Int.self, forKey: .freshnessTargetSeconds)
                lastSeenAt = try values.decodeIfPresent(String.self, forKey: .lastSeenAt) ?? ""
                createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
                updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
            }
        }

        let id: String
        let name: String
        let type: String
        let status: String
        let risk: String
        let trustScore: Double?
        let language: String
        let tags: [String]
        let url: URL?
        let locatorRedacted: Bool
        let operatingMode: OperatingMode
        let collection: Collection

        enum CodingKeys: String, CodingKey {
            case id, name, type, status, risk, trustScore, language, tags, url, locatorRedacted
            case operatingMode, collection
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            name = try values.decodeIfPresent(String.self, forKey: .name) ?? "Unnamed source"
            type = try values.decodeIfPresent(String.self, forKey: .type) ?? ""
            status = try values.decodeIfPresent(String.self, forKey: .status) ?? ""
            risk = try values.decodeIfPresent(String.self, forKey: .risk) ?? ""
            let trust = try values.decodeIfPresent(Double.self, forKey: .trustScore)
            trustScore = trust.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
            language = try values.decodeIfPresent(String.self, forKey: .language) ?? ""
            tags = Array((try values.decodeIfPresent([String].self, forKey: .tags) ?? []).prefix(50))
            let rawURL = try values.decodeIfPresent(String.self, forKey: .url)
            url = Self.safeURL(rawURL)
            locatorRedacted = try values.decodeIfPresent(Bool.self, forKey: .locatorRedacted) ?? false
            operatingMode =
                try values.decodeIfPresent(OperatingMode.self, forKey: .operatingMode)
                ?? OperatingMode(accessMethod: "", metadataOnly: false, approvalState: "", policyVersion: "")
            collection =
                try values.decodeIfPresent(Collection.self, forKey: .collection)
                ?? Collection(cadenceSeconds: nil, freshnessTargetSeconds: nil, lastSeenAt: "", createdAt: "", updatedAt: "")
        }

        private static func safeURL(_ value: String?) -> URL? {
            guard let value, let url = URL(string: value), url.scheme?.lowercased() == "https",
                url.host != nil, url.user == nil, url.password == nil
            else { return nil }
            return url
        }
    }

    let sources: [Source]
    let total: Int
    let page: Int
    let nextPage: Int?
}

/// Operator-only operational source data, distinct from the public source catalogue above.
struct ThreatIntelligenceOperationalSourcePage: Decodable, Equatable {
    struct Source: Decodable, Equatable, Identifiable {
        struct Health: Decodable, Equatable {
            let state: String?
            let lastAttemptAt: String?
            let lastSuccessAt: String?
            let lastUsefulItemAt: String?
            let lastFailureReason: String?
            let consecutiveFailures: Int?
        }
        struct Coverage: Decodable, Equatable {
            let captureCount: Int?
            let customerMatchCount: Int?
            let observedDomains: [String]?
        }
        struct Qualification: Decodable, Equatable {
            let qualifies: Bool?
            let reasons: [String]?
            let lastUsefulAt: String?
            let productiveCheckCount: Int?
        }

        let id: String
        let tenantId: String?
        let name: String?
        let family: String?
        let type: String?
        let lifecycleStatus: String?
        let executable: Bool?
        let url: String?
        let operatingMode: ThreatIntelligenceSourcePage.Source.OperatingMode?
        let health: Health?
        let coverage: Coverage?
        let qualification: Qualification?

        static func allowedStatusChange(source: Self, status: String) -> Bool {
            source.id.range(of: "^[A-Za-z0-9_.:@-]{1,200}$", options: .regularExpression) != nil
                && source.id != "." && source.id != ".."
                && (status == "active" || status == "paused")
                && (source.tenantId == nil || source.tenantId?.range(of: "^[A-Za-z0-9_.:-]{1,200}$", options: .regularExpression) != nil)
        }
    }

    let rows: [Source]
    let total: Int
    let nextCursor: String?
    let previousCursor: String?
}

struct ThreatIntelligenceCollectionRunPage: Decodable, Equatable {
    struct Run: Decodable, Equatable, Identifiable {
        let id: String
        let sourceId: String?
        let status: String?
        let startedAt: String?
        let finishedAt: String?
        let rows: Int?
        let rowCount: Int?
        let captureCount: Int?
        let message: String?
        let error: String?
    }
    let collectionRuns: [Run]
    let total: Int
    let nextCursor: String?
    let previousCursor: String?
}

struct ThreatIntelligenceCapturePage: Decodable, Equatable {
    struct Capture: Decodable, Equatable, Identifiable {
        struct Metadata: Decodable, Equatable {
            let title: String?
            let headline: String?
            let actor: String?
            let domain: String?
            let threatActor: String?
        }
        let id: String
        let sourceId: String?
        let sourceName: String?
        let collectedAt: String?
        let publishedAt: String?
        let mediaType: String?
        let storageKind: String?
        let locatorRedacted: Bool?
        let metadata: Metadata?
    }
    let captures: [Capture]
    let total: Int
    let nextCursor: String?
    let previousCursor: String?
}

struct ThreatIntelligenceTimelinessSnapshot: Decodable, Equatable {
    struct Item: Decodable, Equatable, Identifiable {
        struct ReportReference: Decodable, Equatable {
            let role: String
            let timestamp: String
            let evidencePath: String
            let referenceURL: URL?
            let referenceTitle: String
            let recordedBy: String
            let recordedAt: String

            enum CodingKeys: String, CodingKey { case role, timestamp, evidencePath, referenceUrl, referenceTitle, recordedBy, recordedAt }
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                role = try values.decodeIfPresent(String.self, forKey: .role) ?? ""
                timestamp = try values.decodeIfPresent(String.self, forKey: .timestamp) ?? ""
                evidencePath = try values.decodeIfPresent(String.self, forKey: .evidencePath) ?? ""
                referenceTitle = try values.decodeIfPresent(String.self, forKey: .referenceTitle) ?? ""
                recordedBy = try values.decodeIfPresent(String.self, forKey: .recordedBy) ?? ""
                recordedAt = try values.decodeIfPresent(String.self, forKey: .recordedAt) ?? ""
                let rawURL = try values.decodeIfPresent(String.self, forKey: .referenceUrl)
                if let rawURL, let parsed = URL(string: rawURL),
                    ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
                    parsed.host != nil, parsed.user == nil, parsed.password == nil
                {
                    referenceURL = parsed
                } else {
                    referenceURL = nil
                }
            }

            func matches(_ evidence: ThreatIntelligenceFirstReportEvidence) -> Bool {
                role == evidence.role && evidencePath == evidence.evidencePath
                    && referenceURL?.normalizedPublicReference == evidence.normalizedReferenceURL
                    && ISO8601DateFormatter().date(from: timestamp) == ISO8601DateFormatter().date(from: evidence.timestamp)
            }
        }

        let id: String
        let actorName: String
        let sourceName: String
        let sourceFamily: String
        let title: String
        let summary: String
        let status: String
        let updatedAt: String
        let stages: [String: String]
        let missingStages: [String]
        let sources: [SourceReference]
        let reportReferences: [ReportReference]
        let anomalies: [String]

        struct SourceReference: Decodable, Equatable, Identifiable {
            let title: String
            let url: URL?
            var id: String { title + (url?.absoluteString ?? "") }

            enum CodingKeys: String, CodingKey { case title, url }
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                title = try values.decodeIfPresent(String.self, forKey: .title) ?? "Source"
                let rawURL = try values.decodeIfPresent(String.self, forKey: .url)
                if let rawURL, let parsed = URL(string: rawURL), parsed.scheme?.lowercased() == "https",
                    parsed.host != nil, parsed.user == nil, parsed.password == nil
                {
                    url = parsed
                } else {
                    url = nil
                }
            }
        }

        enum CodingKeys: String, CodingKey {
            case id, actorName, sourceName, sourceFamily, title, summary, status, updatedAt
            case stages, missingStages, sources, reportReferences, timestampAnomalies
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            actorName = try values.decodeIfPresent(String.self, forKey: .actorName) ?? ""
            sourceName = try values.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
            sourceFamily = try values.decodeIfPresent(String.self, forKey: .sourceFamily) ?? ""
            title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
            summary = try values.decodeIfPresent(String.self, forKey: .summary) ?? ""
            status = try values.decodeIfPresent(String.self, forKey: .status) ?? ""
            updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
            stages = try values.decodeIfPresent([String: String].self, forKey: .stages) ?? [:]
            missingStages = Array((try values.decodeIfPresent([String].self, forKey: .missingStages) ?? []).prefix(30))
            sources = Array((try values.decodeIfPresent([SourceReference].self, forKey: .sources) ?? []).prefix(20))
            reportReferences = Array((try values.decodeIfPresent([ReportReference].self, forKey: .reportReferences) ?? []).prefix(50))
            anomalies = Array((try values.decodeIfPresent([String].self, forKey: .timestampAnomalies) ?? []).prefix(50))
        }
    }

    struct Summary: Decodable, Equatable {
        let recordCount: Int?
        let counts: [String: Int]

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: DynamicCodingKey.self)
            var counts: [String: Int] = [:]
            for key in values.allKeys {
                if let value = try? values.decode(Int.self, forKey: key), value >= 0 { counts[key.stringValue] = value }
            }
            self.counts = counts
            recordCount = counts["recordCount"]
        }
    }

    struct Metric: Decodable, Equatable, Identifiable {
        let name: String
        let sampleSize: Int?
        let medianSeconds: Double?
        let p95Seconds: Double?
        let p99Seconds: Double?
        var id: String { name }
    }

    struct Metrics: Decodable, Equatable {
        struct Value: Decodable, Equatable {
            let sampleSize: Int?
            let medianSeconds: Double?
            let p95Seconds: Double?
            let p99Seconds: Double?
        }

        struct Group: Decodable, Equatable, Identifiable {
            let name: String
            let recordCount: Int
            let metrics: [String: Value]
            var id: String { name }
        }

        let byStage: [Metric]
        let bySourceFamily: [Group]
        let byActor: [Group]
        enum CodingKeys: String, CodingKey { case byStage, bySourceFamily, byActor }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            byStage = Array((try values.decodeIfPresent([Metric].self, forKey: .byStage) ?? []).prefix(30))
            bySourceFamily = Array((try values.decodeIfPresent([Group].self, forKey: .bySourceFamily) ?? []).prefix(30))
            byActor = Array((try values.decodeIfPresent([Group].self, forKey: .byActor) ?? []).prefix(30))
        }
    }

    struct Quality: Decodable, Equatable {
        struct Field: Decodable, Equatable, Identifiable {
            let name: String
            let presentCount: Int?
            let missingCount: Int?
            let coverage: Double?
            var id: String { name }
        }
        let fields: [Field]
        struct Issue: Decodable, Equatable, Identifiable {
            let name: String
            let count: Int
            var id: String { name }
        }
        struct Group: Decodable, Equatable, Identifiable {
            let name: String
            let recordCount: Int
            let missing: [String: Int]
            let issues: [String: Int]
            var id: String { name }
        }
        let issues: [Issue]
        let bySourceClass: [Group]
        enum CodingKeys: String, CodingKey { case fields, issues, bySourceClass }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            fields = Array((try values.decodeIfPresent([Field].self, forKey: .fields) ?? []).prefix(30))
            issues = Array((try values.decodeIfPresent([Issue].self, forKey: .issues) ?? []).prefix(30))
            bySourceClass = Array((try values.decodeIfPresent([Group].self, forKey: .bySourceClass) ?? []).prefix(30))
        }
    }

    struct Page: Decodable, Equatable {
        let total: Int
        let nextCursor: String?
    }

    let generatedAt: String
    let summary: Summary
    let items: [Item]
    let metrics: Metrics
    let quality: Quality
    let page: Page
}

enum ThreatIntelligenceTimelinessScope: Equatable {
    case global
    case tenant(String)

    var tenantID: String? {
        guard case let .tenant(value) = self else { return nil }
        return value
    }

    var isValid: Bool {
        guard let tenantID else { return true }
        return tenantID.range(of: "^[A-Za-z0-9_.:-]{1,200}$", options: .regularExpression) != nil
    }
}

struct ThreatIntelligenceFirstReportEvidence: Equatable {
    let recordID: String
    let role: String
    let timestamp: String
    let referenceURL: String
    let evidencePath: String
    let referenceTitle: String

    var normalizedReferenceURL: String? {
        guard let url = URL(string: referenceURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return url.normalizedPublicReference
    }

    var validationError: String? {
        guard recordID.range(of: "^[A-Za-z0-9_.:-]{1,200}$", options: .regularExpression) != nil else {
            return "Select a retained record."
        }
        guard ["actor", "victim", "publisher"].contains(role) else {
            return "Choose the reporting party."
        }
        let timestamp = timestamp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard timestamp.range(of: #"(?:Z|[+-]\d{2}:\d{2})$"#, options: [.regularExpression, .caseInsensitive]) != nil,
            ISO8601DateFormatter().date(from: timestamp) != nil
        else { return "Enter the published timestamp with its timezone." }
        guard evidencePath.range(of: #"^[A-Za-z0-9_.$:\[\]-]{3,200}$"#, options: .regularExpression) != nil else {
            return "Enter the source-field path, such as article.time[datetime]."
        }
        guard let url = URL(string: referenceURL.trimmingCharacters(in: .whitespacesAndNewlines)),
            ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
            url.user == nil, url.password == nil, url.absoluteString.count <= 2_048,
            !url.searchParametersContainSensitiveKey,
            !url.host!.lowercased().hasSuffix(".local"),
            !url.host!.lowercased().hasSuffix(".internal"),
            !url.host!.lowercased().hasSuffix(".onion"),
            !url.host!.lowercased().hasSuffix(".i2p"),
            !Self.isPrivateOrReservedHost(url.host!.lowercased())
        else { return "Enter a public HTTP or HTTPS reference URL." }
        guard referenceTitle.count <= 240 else { return "Keep the reference title to 240 characters or fewer." }
        return nil
    }

    private static func isPrivateOrReservedHost(_ host: String) -> Bool {
        if ["localhost", "::1"].contains(host) || host.contains(":") { return true }
        let pieces = host.split(separator: ".")
        guard pieces.count == 4, pieces.allSatisfy({ UInt8($0) != nil }) else { return false }
        let octets = pieces.compactMap { UInt8($0) }
        guard octets.count == 4 else { return true }
        let first = octets[0], second = octets[1]
        return first == 0 || first == 10 || first == 127 || first >= 224
            || (first == 169 && second == 254)
            || (first == 172 && (16...31).contains(second))
            || (first == 192 && second == 168)
    }
}

struct ThreatIntelligenceFirstReportEvidenceReceipt: Decodable, Equatable {
    let created: Bool
    let reference: ThreatIntelligenceTimelinessSnapshot.Item.ReportReference
    let item: ThreatIntelligenceTimelinessSnapshot.Item
}

private extension URL {
    var normalizedPublicReference: String? {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false),
            ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
            components.host != nil, components.user == nil, components.password == nil
        else { return nil }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path.isEmpty { components.path = "/" }
        return components.string
    }

    var searchParametersContainSensitiveKey: Bool {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems?.contains { item in
            ["token", "secret", "password", "authorization", "cookie", "api_key", "apikey", "signature"].contains { item.name.localizedCaseInsensitiveContains($0) }
        } == true
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }
    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
