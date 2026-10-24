import Foundation

struct NativeDatabaseOverview: Decodable {
    struct Health: Decodable {
        let message: String
        let detail: String?
        let category: String?
    }

    struct Query: Decodable, Identifiable {
        let database: String?
        let user: String?
        let state: String?
        let durationSeconds: Double?
        let waitEventType: String?
        let waitEvent: String?
        let query: String?
        let isLongRunning: Bool
        var id: String { "\(database ?? "")|\(user ?? "")|\(state ?? "")|\(durationSeconds ?? 0)|\(query ?? "")" }
    }

    struct Table: Decodable, Identifiable, Hashable {
        let schema: String
        let name: String
        let sizeBytes: Int?
        let estimatedRows: Int?
        let columns: [String]
        let lastWriteObservedAt: String?
        var id: String { "\(schema).\(name)" }
    }

    struct Database: Decodable, Identifiable {
        let name: String
        let sizeBytes: Int?
        let connections: Int?
        let replica: Bool?
        let memory: Bool?
        let tableCount: Int?
        let tables: [Table]?
        var id: String { name }
    }

    struct Instance: Decodable, Identifiable {
        let id: String
        let engine: String
        let status: String
        let databases: [Database]
    }

    struct Storage: Decodable {
        struct Disk: Decodable {
            let totalBytes: Int
            let availableBytes: Int
            let dailyGrowthBytes: Int?
            let daysUntilFull: Double?
        }
        let sampledAt: String
        let stale: Bool?
        let host: String
        let disk: Disk
        let instances: [Instance]
    }

    let status: String
    let generatedAt: String
    let clusterCount: Int?
    let databaseCount: Int?
    let totalSizeBytes: Int?
    let activeQueries: Int?
    let averageQuerySeconds: Double?
    let longRunningThresholdSeconds: Double?
    let longestQuery: Query?
    let queries: [Query]
    let querySummary: QuerySummary?
    let health: Health
    let storage: Storage?

    struct QuerySummary: Decodable {
        let count: Int
        let longRunningCount: Int
        let longestDurationSeconds: Double?
    }
}

struct NativeDatabaseAccess: Equatable {
    let allowed: Bool
    let canEdit: Bool
    let scope: String
}

struct NativeDatabasePage: Decodable {
    let items: [NativeDatabaseOverview.Table]?
    let rows: [[String: JSONValue]]?
    let fields: [String]?
    let nextCursor: String?
    let totalRows: Int?
    let elapsedMs: Double?
}

struct NativeDatabaseQueryResult: Decodable {
    let rows: [[String: JSONValue]]
    let rowCount: Int
    let fields: [String]
}
