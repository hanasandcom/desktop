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
            let backoffUntil: String?
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
            let backoffUntil: String?
        }
        struct Collection: Decodable, Equatable {
            let cadenceSeconds: Int?

            enum CodingKeys: String, CodingKey { case cadenceSeconds }
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                let value = try values.decodeIfPresent(Int.self, forKey: .cadenceSeconds)
                cadenceSeconds = value.flatMap { $0 >= 0 ? $0 : nil }
            }
        }

        let id: String
        let tenantId: String?
        let name: String?
        let family: String?
        let type: String?
        let lifecycleStatus: String?
        let executable: Bool?
        let url: String?
        let nextRunAt: String?
        let operatingMode: ThreatIntelligenceSourcePage.Source.OperatingMode?
        let health: Health?
        let coverage: Coverage?
        let qualification: Qualification?
        let collection: Collection?

        enum CodingKeys: String, CodingKey {
            case id, tenantId, name, family, type, lifecycleStatus, executable, url, nextRunAt
            case operatingMode, health, coverage, qualification, collection
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            tenantId = try values.decodeIfPresent(String.self, forKey: .tenantId)
            name = try values.decodeIfPresent(String.self, forKey: .name)
            family = try values.decodeIfPresent(String.self, forKey: .family)
            type = try values.decodeIfPresent(String.self, forKey: .type)
            lifecycleStatus = try values.decodeIfPresent(String.self, forKey: .lifecycleStatus)
            executable = try values.decodeIfPresent(Bool.self, forKey: .executable)
            url = try values.decodeIfPresent(String.self, forKey: .url)
            nextRunAt = Self.validTimestamp(try values.decodeIfPresent(String.self, forKey: .nextRunAt))
            operatingMode = try values.decodeIfPresent(ThreatIntelligenceSourcePage.Source.OperatingMode.self, forKey: .operatingMode)
            health = try values.decodeIfPresent(Health.self, forKey: .health)
            coverage = try values.decodeIfPresent(Coverage.self, forKey: .coverage)
            qualification = try values.decodeIfPresent(Qualification.self, forKey: .qualification)
            collection = try values.decodeIfPresent(Collection.self, forKey: .collection)
        }

        private static func validTimestamp(_ value: String?) -> String? {
            guard let value, ISO8601DateFormatter().date(from: value) != nil else { return nil }
            return value
        }

        var cadenceDescription: String {
            guard let seconds = collection?.cadenceSeconds else { return "Not reported" }
            if seconds == 0 { return "No interval" }
            let minutes = max(1, Int((Double(seconds) / 60).rounded()))
            if minutes >= 60 { return "\(max(1, Int((Double(minutes) / 60).rounded()))) hr" }
            return "\(minutes) min"
        }

        var displayedNextCheckAt: String? {
            let formatter = ISO8601DateFormatter()
            let explicit = nextRunAt.flatMap(formatter.date(from:))
            let backoff = (qualification?.backoffUntil ?? health?.backoffUntil).flatMap(formatter.date(from:))
            let fallback: Date? = {
                guard let seconds = collection?.cadenceSeconds, seconds > 0,
                    let lastAttempt = health?.lastAttemptAt,
                    let date = formatter.date(from: lastAttempt)
                else { return nil }
                let roundedCadenceMinutes = max(1, Int((Double(seconds) / 60).rounded()))
                return date.addingTimeInterval(TimeInterval(roundedCadenceMinutes) * 60)
            }()
            guard let next = [explicit, fallback, backoff].compactMap({ $0 }).max() else { return nil }
            return ISO8601DateFormatter().string(from: next)
        }

        var displayedBackoffUntil: String? {
            Self.validTimestamp(qualification?.backoffUntil ?? health?.backoffUntil)
        }

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
        let sourceIds: [String]?
        let sourceName: String?
        let sourceFamily: String?
        let status: String?
        let startedAt: String?
        let finishedAt: String?
        let nextRunAt: String?
        let rows: Int?
        let rowCount: Int?
        let captures: Int?
        let captureCount: Int?
        let screenshots: Int?
        let trigger: String?
        let message: String?
        let error: String?

        private struct Metadata: Decodable {
            let trigger: String?
        }

        private enum CodingKeys: String, CodingKey {
            case id, sourceId, sourceIds, sourceName, sourceFamily, status, startedAt, createdAt
            case finishedAt, completedAt, updatedAt, nextRunAt, rows, rowCount, processedCount, itemCount
            case captures, captureCount, screenshots, screenshotCount, trigger, metadata, message, error
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            sourceIds = try values.decodeIfPresent([String].self, forKey: .sourceIds)
            let primarySourceId = try values.decodeIfPresent(String.self, forKey: .sourceId)
            sourceId = (primarySourceId?.isEmpty == false ? primarySourceId : nil)
                ?? sourceIds?.first(where: { !$0.isEmpty })
            sourceName = try values.decodeIfPresent(String.self, forKey: .sourceName)
            sourceFamily = try values.decodeIfPresent(String.self, forKey: .sourceFamily)
            status = Self.normalizedStatus(try values.decodeIfPresent(String.self, forKey: .status))
            startedAt = try values.decodeIfPresent(String.self, forKey: .startedAt)
                ?? values.decodeIfPresent(String.self, forKey: .createdAt)
            finishedAt = try values.decodeIfPresent(String.self, forKey: .finishedAt)
                ?? values.decodeIfPresent(String.self, forKey: .completedAt)
                ?? values.decodeIfPresent(String.self, forKey: .updatedAt)
            nextRunAt = try values.decodeIfPresent(String.self, forKey: .nextRunAt)
            let rawRows = try values.decodeIfPresent(Int.self, forKey: .rows)
                ?? values.decodeIfPresent(Int.self, forKey: .rowCount)
                ?? values.decodeIfPresent(Int.self, forKey: .processedCount)
                ?? values.decodeIfPresent(Int.self, forKey: .itemCount)
            rows = rawRows.flatMap { $0 >= 0 ? $0 : nil }
            rowCount = try values.decodeIfPresent(Int.self, forKey: .rowCount).flatMap { $0 >= 0 ? $0 : nil }
            let rawCaptures = try values.decodeIfPresent(Int.self, forKey: .captures)
                ?? values.decodeIfPresent(Int.self, forKey: .captureCount)
            captures = rawCaptures.flatMap { $0 >= 0 ? $0 : nil }
            captureCount = try values.decodeIfPresent(Int.self, forKey: .captureCount).flatMap { $0 >= 0 ? $0 : nil }
            screenshots = try values.decodeIfPresent(Int.self, forKey: .screenshots).flatMap { $0 >= 0 ? $0 : nil }
                ?? values.decodeIfPresent(Int.self, forKey: .screenshotCount).flatMap { $0 >= 0 ? $0 : nil }
            let metadata = try? values.decode(Metadata.self, forKey: .metadata)
            trigger = try values.decodeIfPresent(String.self, forKey: .trigger)
                ?? metadata?.trigger
            message = try values.decodeIfPresent(String.self, forKey: .message)
            error = try values.decodeIfPresent(String.self, forKey: .error)
        }

        private static func normalizedStatus(_ value: String?) -> String? {
            guard let value else { return nil }
            let normalized = value.lowercased()
            if ["queued", "pending"].contains(normalized) { return "queued" }
            if ["running", "leased", "processing"].contains(normalized) { return "running" }
            if ["failed", "error", "dead_letter"].contains(normalized) { return "failed" }
            if normalized == "completed" { return "completed" }
            return "unknown"
        }

        var captureTotal: Int { captures ?? captureCount ?? 0 }
        var rowTotal: Int { rows ?? rowCount ?? 0 }
        func exactlyBelongs(to sourceID: String) -> Bool {
            sourceId == sourceID || sourceIds?.contains(sourceID) == true
        }
    }
    let collectionRuns: [Run]
    let total: Int
    let nextCursor: String?
    let previousCursor: String?

    var summary: Summary { Summary(runs: collectionRuns) }

    func sourceName(for run: Run, sources: [ThreatIntelligenceOperationalSourcePage.Source]) -> String {
        if let sourceName = run.sourceName?.trimmingCharacters(in: .whitespacesAndNewlines), !sourceName.isEmpty {
            return sourceName
        }
        if let sourceId = run.sourceId, let sourceName = sources.first(where: { $0.id == sourceId })?.name,
           !sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return sourceName
        }
        return run.sourceId ?? "Global source fleet"
    }

    func sourceFamily(for run: Run, sources: [ThreatIntelligenceOperationalSourcePage.Source]) -> String? {
        if let sourceFamily = run.sourceFamily?.trimmingCharacters(in: .whitespacesAndNewlines), !sourceFamily.isEmpty {
            return sourceFamily
        }
        return run.sourceId.flatMap { sourceId in sources.first(where: { $0.id == sourceId })?.family }
    }

    struct Summary: Equatable {
        let active: Int
        let completed: Int
        let failed: Int
        let captures: Int

        init(runs: [Run]) {
            active = runs.filter { ["queued", "running"].contains($0.status ?? "") }.count
            completed = runs.filter { $0.status == "completed" }.count
            failed = runs.filter { $0.status == "failed" }.count
            captures = runs.reduce(0) { partial, run in
                let (sum, overflow) = partial.addingReportingOverflow(run.captureTotal)
                return overflow ? Int.max : sum
            }
        }
    }
}

struct ThreatIntelligenceCapturePage: Decodable, Equatable {
    struct Capture: Decodable, Equatable, Identifiable {
        struct Metadata: Decodable, Equatable {
            let title: String?
            let headline: String?
            let actor: String?
            let domain: String?
            let threatActor: String?
            let summary: String?
            let excerpt: String?
            let safeExcerpt: String?
            let screenshotId: String?
            let screenshotHash: String?
            let screenshotTakenAt: String?
            let pageType: String?
            let adapter: String?
            let kind: String?
        }
        struct NormalizedEvidence: Decodable, Equatable {
            let status: String?
            let failureReason: String?
            let title: String?
            let author: String?
            let publishedAt: String?
            let headings: [String]?
            let namedEntities: [String]?
            let incidentLanguage: [String]?
            let text: String?
            let excerpt: String?
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
        let normalizedEvidence: NormalizedEvidence?
        let redactionReason: String?

        func exactlyBelongs(to sourceID: String) -> Bool { sourceId == sourceID }

        var safeExcerpt: String? {
            let candidates = [normalizedEvidence?.excerpt, normalizedEvidence?.text,
                             metadata?.safeExcerpt, metadata?.excerpt, metadata?.summary,
                             metadata?.headline, redactionReason]
            return candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty && $0.count <= 240 && $0.range(of: #"(?:window\.|WIZ_global_data|__NEXT_DATA__|<html|<script)"#, options: [.regularExpression, .caseInsensitive]) == nil })
        }

        var screenshotLabel: String? {
            metadata?.screenshotId ?? metadata?.screenshotHash
        }
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
