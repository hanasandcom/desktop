import Foundation

struct NativeTIDarkwebFilters: Equatable {
    var query = ""
    var category = ""
    var legalTriage = ""
    var network = ""
    var reviewState = ""

    func queryItems(limit: Int = 50) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100)))]
        for (name, rawValue) in [
            ("q", query),
            ("category", category),
            ("legalTriage", legalTriage),
            ("network", network),
            ("reviewState", reviewState),
        ] {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { items.append(URLQueryItem(name: name, value: value)) }
        }
        return items
    }
}

struct NativeTIDarkwebStatusResponse: Decodable, Equatable {
    struct Status: Decodable, Equatable {
        struct Counts: Decodable, Equatable {
            var byNetwork: [String: Int]?
            var byLegalTriage: [String: Int]?
            var byLiveness: [String: Int]?
            var byReviewState: [String: Int]?
        }

        var indexedRecordCount: Int?
        var monitoredSourceCount: Int?
        var metadataOnly: Bool?
        var generatedAt: String?
        var latestRecordAt: String?
        var counts: Counts?
        var noLeakSerialization: SerializationCheck?
    }

    struct SerializationCheck: Decodable, Equatable {
        var passed: Bool?
    }

    var status: Status?
    var darkwebIndex: Status?

    var index: Status? { darkwebIndex ?? status }
}

struct NativeTIDarkwebSearchResponse: Decodable, Equatable {
    struct CanonicalIdentity: Decodable, Equatable {
        var type: String
        var canonicalName: String
        var aliases: [String]
        var canonicalPath: String
        var restrictedEvidenceState: String
        var restrictedRecordCount: Int
    }

    struct Record: Decodable, Equatable, Identifiable {
        var id: String
        var network: String
        var title: String
        var safeSummary: String
        var category: String
        var legalTriage: String
        var liveness: String
        var firstSeen: String
        var lastSeen: String
        var reviewState: String
        var actorHints: [String]?
        var victimHints: [String]?
        var datasetHints: [String]?
        var sectorHints: [String]?
        var countryHints: [String]?
        var safeLocatorHash: String
    }

    var generatedAt: String?
    var count: Int?
    var nextCursor: String?
    var rows: [Record]?
    var canonicalIdentity: CanonicalIdentity?
    var noLeakSerialization: NativeTIDarkwebStatusResponse.SerializationCheck?

    var records: [Record] { Array((rows ?? []).prefix(100)) }
}
