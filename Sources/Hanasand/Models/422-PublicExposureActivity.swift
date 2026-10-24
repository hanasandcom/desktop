import Foundation

struct PublicExposureActivityFilters: Equatable {
    var q = ""
    var company = ""
    var actor = ""
    var category = ""
    var size = ""
    var country = ""
    var from = ""
    var to = ""

    func queryItems(limit: Int = 50, offset: Int = 0) -> [URLQueryItem] {
        var values = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100))),
                      URLQueryItem(name: "offset", value: String(max(offset, 0)))]
        for (key, value) in [("q", q), ("company", company), ("actor", actor), ("category", category),
                             ("size", size), ("country", country), ("from", from), ("to", to)] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { values.append(URLQueryItem(name: key, value: trimmed)) }
        }
        return values
    }
}

struct PublicExposureActivityPage: Decodable, Equatable {
    struct Freshness: Decodable, Equatable {
        let latestClaimAt: String?
        let latestCollectedAt: String?
        let ageMinutes: Double?
        let collectionAgeMinutes: Double?
        let maxLiveAgeMinutes: Double?
    }
    struct Counts: Decodable, Equatable {
        let visible: Int?
        let total: Int?
        let needsReview: Int?
        let metadataOnly: Int?
    }
    struct Page: Decodable, Equatable {
        let limit: Int?
        let offset: Int?
        let total: Int?
        let nextOffset: Int?
        let hasMore: Bool?
    }
    struct Item: Decodable, Equatable, Identifiable {
        let id: String
        let actor: String
        let company: String
        let claimedData: String
        let claimedDataSize: String
        let country: String?
        let claimTime: String?
        let collectedAt: String?
        let status: String
        let confidence: Double?
        let sourceName: String?

        enum CodingKeys: String, CodingKey {
            case id, actor, company, claimedData, claimedDataSize, country, claimTime, collectedAt, status, confidence, sourceName
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            actor = try c.decodeIfPresent(String.self, forKey: .actor) ?? ""
            company = Self.decodeEncodedName(try c.decodeIfPresent(String.self, forKey: .company) ?? "")
            claimedData = try c.decodeIfPresent(String.self, forKey: .claimedData) ?? "Not disclosed by TA"
            claimedDataSize = try c.decodeIfPresent(String.self, forKey: .claimedDataSize) ?? "Not disclosed by TA"
            country = try c.decodeIfPresent(String.self, forKey: .country) ?? "Not disclosed by TA"
            claimTime = try c.decodeIfPresent(String.self, forKey: .claimTime)
            collectedAt = try c.decodeIfPresent(String.self, forKey: .collectedAt)
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? "unverified"
            let rawConfidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
            confidence = rawConfidence.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
            sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName)
        }

        private static func decodeEncodedName(_ value: String) -> String {
            let regex = try! NSRegularExpression(pattern: #"(?:%[0-9a-fA-F]{2})+"#)
            let matches = regex.matches(in: value, range: NSRange(value.startIndex..., in: value))
            var decoded = value
            for match in matches.reversed() {
                guard let range = Range(match.range, in: decoded),
                      let replacement = String(decoded[range]).removingPercentEncoding else { continue }
                decoded.replaceSubrange(range, with: replacement)
            }
            return decoded
        }
    }

    let generatedAt: String
    let status: String
    let freshness: Freshness?
    let counts: Counts?
    let page: Page?
    let items: [Item]

    enum CodingKeys: String, CodingKey { case generatedAt, status, freshness, counts, page, items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try c.decodeIfPresent(String.self, forKey: .generatedAt) ?? ""
        items = Array((try c.decodeIfPresent([Item].self, forKey: .items) ?? [])
            .filter { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.actor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.company.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(100))
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? (items.isEmpty ? "unavailable" : "stale")
        freshness = try c.decodeIfPresent(Freshness.self, forKey: .freshness)
        counts = try c.decodeIfPresent(Counts.self, forKey: .counts)
        page = try c.decodeIfPresent(Page.self, forKey: .page)
    }

    var nextOffset: Int? {
        if let next = page?.nextOffset { return next }
        if page?.hasMore == false { return nil }
        if let total = page?.total, let offset = page?.offset {
            let next = offset + items.count
            return next < total ? next : nil
        }
        return items.count >= (page?.limit ?? 50) ? (page?.offset ?? 0) + items.count : nil
    }
}

extension PublicExposureActivityPage.Item {
    static func merge(_ current: [Self], _ next: [Self], appending: Bool) -> [Self] {
        var seen = Set<String>()
        return (appending ? current + next : next + current).filter { seen.insert($0.id).inserted }
    }
}
