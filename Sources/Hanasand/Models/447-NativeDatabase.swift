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

struct NativeBackupRetention: Decodable {
    let policyDays: Int?
    let examined: Int
    let deleted: Int
    let deletedBytes: Int?
    let cutoffAt: String
}

struct NativeBackupOperation: Decodable, Identifiable {
    struct Integrity: Decodable {
        let schemas: Int
        let tables: Int
        let estimatedRows: Int?
    }

    let id: String
    let kind: String
    let trigger: String?
    let actorId: String?
    let status: String
    let stage: String
    let startedAt: String
    let finishedAt: String?
    let durationMs: Int?
    let file: String?
    let targetDatabase: String?
    let checksumSha256: String?
    let sizeBytes: Int?
    let archiveEntries: Int?
    let sourceIntegrity: Integrity?
    let restoredIntegrity: Integrity?
    let targetRemoved: Bool?
    let retention: NativeBackupRetention?
    let error: String?
    let releaseCommit: String?
}

struct NativeBackupService: Decodable, Identifiable {
    let id: String
    let name: String
    let database: String?
    let status: String
    let error: String?
    let dbSize: String?
    let totalStorage: String?
    let lastBackup: String?
    let lastAttempt: String?
    let lastSuccess: String?
    let lastFailure: String?
    let lastError: String?
    let nextBackup: String?
    let schedule: String?
    let scheduleTimezone: String?
    let scheduleEnabled: Bool?
    let retention: String?
    let retentionOutcome: NativeBackupRetention?
    let storageTarget: String?
    let latestFile: String?
    let latestSize: String?
    let latestDuration: String?
    let latestChecksum: String?
    let latestVerifiedAt: String?
    let releaseCommit: String?
    let healthCheck: String?
    let currentOperation: NativeBackupOperation?
    let operations: [NativeBackupOperation]

    enum CodingKeys: String, CodingKey {
        case id, name, database, status, error, dbSize, totalStorage, lastBackup, lastAttempt, lastSuccess, lastFailure, lastError
        case nextBackup, schedule, scheduleTimezone, scheduleEnabled, retention, retentionOutcome, storageTarget
        case latestFile, latestSize, latestDuration, latestChecksum, latestVerifiedAt, releaseCommit
        case healthCheck, currentOperation, operations
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        database = try values.decodeIfPresent(String.self, forKey: .database)
        status = try values.decode(String.self, forKey: .status)
        error = try values.decodeIfPresent(String.self, forKey: .error)
        dbSize = try values.decodeIfPresent(String.self, forKey: .dbSize)
        totalStorage = try values.decodeIfPresent(String.self, forKey: .totalStorage)
        lastBackup = try values.decodeIfPresent(String.self, forKey: .lastBackup)
        lastAttempt = try values.decodeIfPresent(String.self, forKey: .lastAttempt)
        lastSuccess = try values.decodeIfPresent(String.self, forKey: .lastSuccess)
        lastFailure = try values.decodeIfPresent(String.self, forKey: .lastFailure)
        lastError = try values.decodeIfPresent(String.self, forKey: .lastError)
        nextBackup = try values.decodeIfPresent(String.self, forKey: .nextBackup)
        schedule = try values.decodeIfPresent(String.self, forKey: .schedule)
        scheduleTimezone = try values.decodeIfPresent(String.self, forKey: .scheduleTimezone)
        scheduleEnabled = try values.decodeIfPresent(Bool.self, forKey: .scheduleEnabled)
        retention = try values.decodeIfPresent(String.self, forKey: .retention)
        retentionOutcome = try values.decodeIfPresent(NativeBackupRetention.self, forKey: .retentionOutcome)
        storageTarget = try values.decodeIfPresent(String.self, forKey: .storageTarget)
        latestFile = try values.decodeIfPresent(String.self, forKey: .latestFile)
        latestSize = try values.decodeIfPresent(String.self, forKey: .latestSize)
        latestDuration = try values.decodeIfPresent(String.self, forKey: .latestDuration)
        latestChecksum = try values.decodeIfPresent(String.self, forKey: .latestChecksum)
        latestVerifiedAt = try values.decodeIfPresent(String.self, forKey: .latestVerifiedAt)
        releaseCommit = try values.decodeIfPresent(String.self, forKey: .releaseCommit)
        healthCheck = try values.decodeIfPresent(String.self, forKey: .healthCheck)
        currentOperation = try values.decodeIfPresent(NativeBackupOperation.self, forKey: .currentOperation)
        operations = try values.decodeIfPresent([NativeBackupOperation].self, forKey: .operations) ?? []
    }
}

struct NativeBackupFile: Decodable, Identifiable {
    let service: String
    let file: String
    let mtime: String?
    let size: String?
    let sizeBytes: Int?
    let verified: Bool
    let checksumSha256: String?
    let verifiedAt: String?
    let releaseCommit: String?
    var id: String { "\(service)-\(file)" }
}

struct NativeBackupDashboard: Decodable {
    let backups: [NativeBackupService]
    let files: [NativeBackupFile]
    let errors: [String]
}

struct NativeBackupActionResult: Decodable {
    let message: String
    let operation: NativeBackupOperation
}

func backupOperation(withID id: String, in dashboard: NativeBackupDashboard) -> NativeBackupOperation? {
    for service in dashboard.backups {
        if service.currentOperation?.id == id { return service.currentOperation }
        if let operation = service.operations.first(where: { $0.id == id }) { return operation }
    }
    return nil
}

func shouldRefreshBackupOperation(currentOperation: NativeBackupOperation?, trackedOperation: NativeBackupOperation?) -> Bool {
    currentOperation != nil || trackedOperation?.status.lowercased() == "running"
}
