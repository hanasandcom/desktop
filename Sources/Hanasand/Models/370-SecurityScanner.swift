import Foundation

enum SecurityScannerEngineID: String, Codable, CaseIterable, Identifiable {
    case nmap, tenableVM = "tenable-vm", gvm, zap
    var id: String { rawValue }
    var title: String {
        switch self { case .nmap: "Nmap"; case .tenableVM: "Tenable VM"; case .gvm: "Greenbone"; case .zap: "OWASP ZAP" }
    }
}

enum SecurityScannerNmapProfile: String, Codable, CaseIterable, Identifiable {
    case top100 = "tcp-top-100", top1000 = "tcp-top-1000", safeVuln = "tcp-top-1000-safe-vuln", allTCP = "tcp-all"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .top100: "Quick · top 100 TCP ports"
        case .top1000: "Standard · top 1,000 TCP ports"
        case .safeVuln: "Safe checks · top 1,000 ports + NSE"
        case .allTCP: "Thorough · all TCP ports"
        }
    }
}

struct SecurityScannerAsset: Codable, Identifiable, Equatable {
    let id: String
    let hostname: String
    let verificationStatus: String
    let verificationRecordName: String
    let verificationRecordValue: String
    let verificationMethod: String
    let verifiedAt: String?
    let scanAuthorizedAt: String?
    let authorizedAddresses: [String]
    let scheduleEnabled: Bool
    let schedulePlan: [SecurityScannerEngineSelection]?
    let scheduleEngine: String?
    let scheduleScanId: String?
    let scheduleProfile: String?
    let zapApiDefinitionPath: String?
    let intervalMinutes: Int
    let nextRunAt: String?
    let createdAt: String
}

struct SecurityScannerEngineSelection: Codable, Equatable {
    let engine: String
    let scanId: String?
    let profile: String?
}

struct SecurityScannerEngine: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let status: String
    let version: String?
    let reason: String?
    let profiles: [SecurityScannerProfile]
    let coverage: [String]
    let notCovered: [String]
}

struct SecurityScannerProfile: Codable, Equatable {
    let id: String
    let name: String
    let safe: Bool
}

struct SecurityScannerCatalogEntry: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let category: String
    let integration: String
    let setup: String
}

struct SecurityScannerCoverage: Codable, Identifiable, Equatable {
    var id: String { "\(assetId):\(engine)" }
    let assetId: String
    let engine: String
    let state: String
    let freshness: String
    let lastRunId: String?
    let lastRunAt: String?
    let source: String?
    let profile: String?
    let status: String?
    let authorizedAddresses: [String]
    let requestedAddresses: [String]
    let coverageKnown: Bool
    let attemptedAddresses: Int?
    let reportedAttemptedAddresses: Int?
    let reportedCompletedAddresses: Int?
    let completedAddresses: Int?
    let completedAddressList: [String]?
    let missingAddresses: [String]?
    let unattemptedAddresses: [String]?
    let scopeMatchesAuthorizedSnapshot: Bool?
    let freshnessWindowHours: Int
    let ageHours: Double?
    let freshnessReason: String
    let verificationStatus: String?
    let webCoverage: SecurityScannerWebCoverage?
}

struct SecurityScannerWebCoverage: Codable, Equatable {
    let origin: String
    let requestedAddresses: Int
    let confirmedAddresses: [String]
    let urlsVisited: Int?
    let urlsDiscovered: Int?
    let crawlComplete: Bool?
    let totalAlerts: Int
    let acceptedAlerts: Int
    let acceptedInstances: Int
    let scopeFiltered: Bool
    let truncated: Bool
    let truncationReasons: [String]
    let complete: Bool
}

struct SecurityScannerDashboard: Codable, Equatable {
    var assets: [SecurityScannerAsset] = []
    var coverage: [SecurityScannerCoverage] = []
    var engines: [SecurityScannerEngine] = []
    var scannerCatalog: [SecurityScannerCatalogEntry] = []
    var runs: [SecurityScannerRun] = []
    var runsNextCursor: String?
    var assessments: [SecurityScannerAssessment] = []
    var assessmentsNextCursor: String?
    var findings: [SecurityScannerFinding] = []
    var findingsNextCursor: String?
    var scannerError: String?
    var tenableIntegration: SecurityScannerTenableIntegration?
    var tenableScans: [SecurityScannerTenableScan] = []
    var findingSummary: SecurityScannerFindingSummary?

    private enum CodingKeys: String, CodingKey {
        case assets, coverage, engines, scannerCatalog, runs, runsNextCursor, assessments, assessmentsNextCursor
        case findings, findingsNextCursor, scannerError, tenableIntegration, tenableScans, findingSummary
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        assets = try values.decodeIfPresent([SecurityScannerAsset].self, forKey: .assets) ?? []
        coverage = try values.decodeIfPresent([SecurityScannerCoverage].self, forKey: .coverage) ?? []
        engines = try values.decodeIfPresent([SecurityScannerEngine].self, forKey: .engines) ?? []
        scannerCatalog = try values.decodeIfPresent([SecurityScannerCatalogEntry].self, forKey: .scannerCatalog) ?? []
        runs = try values.decodeIfPresent([SecurityScannerRun].self, forKey: .runs) ?? []
        runsNextCursor = try values.decodeIfPresent(String.self, forKey: .runsNextCursor)
        assessments = try values.decodeIfPresent([SecurityScannerAssessment].self, forKey: .assessments) ?? []
        assessmentsNextCursor = try values.decodeIfPresent(String.self, forKey: .assessmentsNextCursor)
        findings = try values.decodeIfPresent([SecurityScannerFinding].self, forKey: .findings) ?? []
        findingsNextCursor = try values.decodeIfPresent(String.self, forKey: .findingsNextCursor)
        scannerError = try values.decodeIfPresent(String.self, forKey: .scannerError)
        tenableIntegration = try values.decodeIfPresent(SecurityScannerTenableIntegration.self, forKey: .tenableIntegration)
        tenableScans = try values.decodeIfPresent([SecurityScannerTenableScan].self, forKey: .tenableScans) ?? []
        findingSummary = try values.decodeIfPresent(SecurityScannerFindingSummary.self, forKey: .findingSummary)
    }
}

struct SecurityScannerFindingSummary: Codable, Equatable {
    let total: Int
    let actionable: Int
    let criticalOrHigh: Int
}

struct SecurityScannerTenableIntegration: Codable, Equatable {
    let provider: String
    let configured: Bool
    let credentialStoreAvailable: Bool
    let region: String?
    let accessKeyHint: String?
    let testedAt: String?
    let updatedAt: String?
    let error: String?
}

struct SecurityScannerTenableScan: Codable, Identifiable, Equatable {
    let id: String
    let scheduleUuid: String?
    let name: String
    let enabled: Bool
    let status: String?
    let scannerName: String?
    let targets: String
}

struct SecurityScannerFinding: Codable, Identifiable, Equatable {
    let id: String
    let assetId: String?
    let asset: String
    let address: String?
    let engine: String
    let externalId: String
    let title: String
    let severity: String
    let cvssScore: Double?
    let cveIds: [String]
    let description: String?
    let solution: String?
    let evidence: String?
    var status: String
    var triageNote: String?
    let firstSeen: String?
    let lastSeen: String?
    let updatedAt: String
}

struct SecurityScannerRun: Codable, Identifiable, Equatable {
    let id: String
    let scannerRunId: String?
    let requestId: String
    let assetId: String
    let target: String
    let targetOrigin: String?
    let engine: String
    let profile: String
    let source: String?
    let status: String
    let createdAt: String
    let startedAt: String?
    let finishedAt: String?
    let error: String?
    let engineVersion: String?
    let rawXmlSha256: String?
    let coverage: SecurityScannerRunCoverage?
    let hosts: [SecurityScannerHost]?
    let findings: [SecurityScannerRunFinding]?
}

struct SecurityScannerHost: Codable, Equatable, Identifiable {
    var id: String { address }
    let address: String
    let status: String
    let timedOut: Bool
    let ports: [SecurityScannerPort]
    let scriptResults: [SecurityScannerScriptEvidence]?
}

struct SecurityScannerPort: Codable, Equatable, Identifiable {
    var id: String { "\(protocolName):\(port)" }
    let port: Int
    let protocolName: String
    let state: String
    let service: String?
    let product: String?
    let version: String?
    let extraInfo: String?
    let scriptResults: [SecurityScannerScriptEvidence]?

    enum CodingKeys: String, CodingKey { case port, protocolName = "protocol", state, service, product, version, extraInfo, scriptResults }
}

struct SecurityScannerScriptEvidence: Codable, Equatable, Identifiable {
    var id: String { "\(scriptID):\(output.hashValue)" }
    let scriptID: String
    let output: String
    let truncated: Bool

    enum CodingKeys: String, CodingKey { case scriptID = "id", output, truncated }
}

struct SecurityScannerRunFinding: Codable, Equatable, Identifiable {
    var id: String { findingID }
    let findingID: String
    let provider: String
    let title: String
    let severity: String
    let description: String?
    let solution: String?
    let evidence: String?
    let assetAddress: String
    let port: Int?
    let protocolName: String?
    let cveIDs: [String]?
    let confidence: String?
    let instanceURL: String?
    let method: String?
    let parameter: String?

    enum CodingKeys: String, CodingKey {
        case findingID = "findingId", provider, title, severity, description, solution, evidence, assetAddress
        case port, protocolName = "protocol", cveIDs = "cveIds", confidence, instanceURL = "instanceUrl", method, parameter
    }
}

struct SecurityScannerRunCoverage: Codable, Equatable {
    let known: Bool?
    let requestedAddresses: Int?
    let attemptedAddresses: Int?
    let completedAddresses: Int?
    let completedAddressList: [String]?
    let missingAddresses: [String]?
    let unattemptedAddresses: [String]?
    let openPorts: Int?
    let origin: String?
    let urlsVisited: Int?
    let urlsDiscovered: Int?
    let crawlComplete: Bool?
    let totalAlerts: Int?
    let acceptedAlerts: Int?
    let acceptedInstances: Int?
    let scopeFiltered: Bool?
    let truncationReasons: [String]?
    let truncated: Bool?
    let complete: Bool?
}

struct SecurityScannerAssessment: Codable, Identifiable, Equatable {
    let id: String
    let requestId: String
    let status: String
    let source: String
    let createdAt: String
    let startedAt: String?
    let finishedAt: String?
    let jobs: [SecurityScannerAssessmentJob]
}

struct SecurityScannerAssessmentJob: Codable, Identifiable, Equatable {
    let id: String
    let assetId: String
    let asset: String
    let engine: String
    let profile: String
    let stageIndex: Int
    let stage: String
    let runId: String?
    let status: String
    let error: String?
    let attemptCount: Int
    let nextAttemptAt: String?
    let createdAt: String
    let startedAt: String?
    let finishedAt: String?
}

struct SecurityScannerAssessmentReport: Codable, Equatable {
    let id: String
    let requestId: String
    let status: String
    let source: String
    let createdAt: String
    let startedAt: String?
    let finishedAt: String?
    let jobs: [SecurityScannerAssessmentReportJob]
}

struct SecurityScannerAssessmentReportJob: Codable, Identifiable, Equatable {
    let id: String
    let assetId: String
    let asset: String
    let engine: String
    let profile: String
    let stageIndex: Int
    let stage: String
    let runId: String?
    let status: String
    let error: String?
    let attemptCount: Int
    let nextAttemptAt: String?
    let createdAt: String
    let startedAt: String?
    let finishedAt: String?
    let run: SecurityScannerRun?
    let reportError: String?
}

struct SecurityScannerHistoryPage<T: Decodable>: Decodable {
    let items: [T]
    let nextCursor: String?
}

enum SecurityScannerPanelSection: String, CaseIterable, Identifiable {
    case overview = "Overview", assessments = "Assessments", assets = "Assets", scanners = "Scanners", history = "Scan history", findings = "Findings"
    var id: String { rawValue }
}
