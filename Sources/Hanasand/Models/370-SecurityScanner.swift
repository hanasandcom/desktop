import Foundation

enum SecurityScannerEngineID: String, Codable, CaseIterable, Identifiable {
    case nmap, naabu, tenableVM = "tenable-vm", gvm, zap, testssl, nuclei, nikto, sslyze, wapiti, whatweb, httpx, tlsx, katana, wafw00f
    var id: String { rawValue }
    var title: String {
        switch self {
        case .nmap: "Nmap"
        case .naabu: "Naabu"
        case .tenableVM: "Tenable VM"
        case .gvm: "Greenbone"
        case .zap: "OWASP ZAP"
        case .testssl: "testssl.sh"
        case .nuclei: "Nuclei"
        case .nikto: "Nikto"
        case .sslyze: "SSLyze"
        case .wapiti: "Wapiti"
        case .whatweb: "WhatWeb"
        case .httpx: "httpx"
        case .tlsx: "tlsx"
        case .katana: "Katana"
        case .wafw00f: "WAFW00F"
        }
    }

    var defaultProfile: String? {
        switch self {
        case .nmap, .tenableVM, .gvm: nil
        case .naabu: "naabu-top-100"
        case .zap: "bounded-web-dast-v1"
        case .testssl: "tls-default-v1"
        case .nuclei: "safe-http-v1"
        case .nikto: "nikto-safe-web-v1"
        case .sslyze: "sslyze-tls-safe-v1"
        case .wapiti: "wapiti-passive-web-v1"
        case .whatweb: "whatweb-stealthy-host-v1"
        case .httpx: "httpx-root-probe-v1"
        case .tlsx: "tlsx-certificate-metadata-v1"
        case .katana: "katana-same-origin-crawl-v1"
        case .wafw00f: "wafw00f-exact-origin-detection-v1"
        }
    }
}

enum SecurityScannerNmapProfile: String, Codable, CaseIterable, Identifiable {
    case top100 = "tcp-top-100", top1000 = "tcp-top-1000", safeVuln = "tcp-top-1000-safe-vuln", allTCP = "tcp-all", udpTop100 = "udp-top-100"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .top100: "Quick · top 100 TCP ports"
        case .top1000: "Standard · top 1,000 TCP ports"
        case .safeVuln: "Safe checks · top 1,000 ports + NSE"
        case .allTCP: "Thorough · all TCP ports"
        case .udpTop100: "UDP · top 100 ports"
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

    var servicesPaused: Bool {
        (scannerError ?? "").localizedCaseInsensitiveContains("stopped pending disk expansion")
    }

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

enum SecurityScannerFindingSort: String, CaseIterable, Identifiable {
    case severity
    case firstSeen

    var id: String { rawValue }
    var title: String {
        switch self {
        case .severity: "Severity"
        case .firstSeen: "First seen"
        }
    }

    func sorted(_ findings: [SecurityScannerFinding]) -> [SecurityScannerFinding] {
        let ranked = findings.enumerated().map { index, finding in
            (index: index, finding: finding, firstSeen: Self.firstSeenDate(finding))
        }
        return ranked.sorted { left, right in
            if self == .severity {
                let severityDifference = Self.severityRank(left.finding.severity) - Self.severityRank(right.finding.severity)
                if severityDifference != 0 { return severityDifference < 0 }
                let statusDifference = Self.statusRank(left.finding.status) - Self.statusRank(right.finding.status)
                if statusDifference != 0 { return statusDifference < 0 }
            }

            if left.firstSeen != right.firstSeen { return left.firstSeen < right.firstSeen }
            let severityDifference = Self.severityRank(left.finding.severity) - Self.severityRank(right.finding.severity)
            if severityDifference != 0 { return severityDifference < 0 }
            let titleDifference = left.finding.title.localizedCaseInsensitiveCompare(right.finding.title)
            if titleDifference != .orderedSame { return titleDifference == .orderedAscending }
            return left.index < right.index
        }
        .map(\.finding)
    }

    private static func severityRank(_ severity: String) -> Int {
        switch severity.lowercased() {
        case "critical": 0
        case "high": 1
        case "medium": 2
        case "low": 3
        case "info", "informational": 4
        default: 5
        }
    }

    private static func statusRank(_ status: String) -> Int {
        switch status {
        case "open": 0
        case "in_progress": 1
        case "pending_verification": 2
        case "accepted_risk": 3
        case "false_positive": 4
        case "resolved": 5
        default: 6
        }
    }

    private static func firstSeenDate(_ finding: SecurityScannerFinding) -> Date {
        let value = finding.firstSeen ?? finding.lastSeen ?? finding.updatedAt
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) ?? .distantFuture
    }
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
    let rawOutputSha256: String?
    let reportHashes: [String: String]?
    let attemptedAddresses: [String]?
    let completedAddresses: [String]?
    let coverage: SecurityScannerRunCoverage?
    let hosts: [SecurityScannerHost]?
    let findings: [SecurityScannerRunFinding]?
    let observations: [SecurityScannerObservation]?
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
    let url: String?
    let method: String?
    let parameter: String?
    let pluginID: String?
    let nvtOID: String?
    let qualityOfDetection: String?
    let disposition: String?
    let uri: String?
    let host: String?
    let matchedAt: String?
    let tags: [String]?
    let references: [String]?
    let checkID: String?
    let plugin: String?
    let targetOrigin: String?
    let target: String?
    let statusCode: Int?
    let firewall: String?
    let manufacturer: String?
    let observed: Bool?

    enum CodingKeys: String, CodingKey {
        case findingID = "findingId", provider, title, severity, description, solution, evidence, assetAddress
        case port, protocolName = "protocol", cveIDs = "cveIds", confidence, instanceURL = "instanceUrl", url, method, parameter
        case pluginID = "pluginId", nvtOID = "nvtOid", qualityOfDetection, disposition, uri, host, matchedAt, tags
        case references = "reference", checkID = "checkId", plugin, targetOrigin, target, statusCode, firewall, manufacturer, observed
    }
}

struct SecurityScannerObservation: Codable, Equatable, Identifiable {
    let id: String
    let checkID: String?
    let host: String?
    let port: Int?
    let severity: String?
    let disposition: String?
    let result: String?
    let cve: String?
    let cwe: String?
    let evidence: String?
    let address: String?
    let url: String?
    let statusCode: Int?
    let title: String?
    let contentType: String?
    let contentLength: Int?
    let webServer: String?
    let technologies: [String]?
    let hostname: String?
    let probeStatus: Bool?
    let tlsVersion: String?
    let cipher: String?
    let connectionMode: String?
    let sni: String?
    let subjectCommonNames: [String]?
    let subjectAlternativeNames: [String]?
    let subjectOrganizations: [String]?
    let notBefore: String?
    let notAfter: String?
    let certificateSHA256: String?
    let certificateSerial: String?
    let method: String?
    let detected: Bool?
    let firewall: String?
    let manufacturer: String?

    enum CodingKeys: String, CodingKey {
        case id, host, port, severity, disposition, result, cve, cwe, evidence, address, url, title
        case checkID = "checkId", statusCode, contentType, contentLength, webServer, technologies, hostname
        case probeStatus, tlsVersion, cipher, connectionMode, sni, subjectCommonNames, subjectAlternativeNames
        case subjectOrganizations, notBefore, notAfter, certificateSHA256 = "certificateSha256", certificateSerial
        case method, detected, firewall, manufacturer
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
    let clientUrlsDiscovered: Int?
    let traditionalSpiderComplete: Bool?
    let clientSpiderComplete: Bool?
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

enum SecurityScannerHistoryFilter {
    static func runs(_ items: [SecurityScannerRun], query: String, engine: String, status: String) -> [SecurityScannerRun] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.filter { run in
            (engine == "all" || run.engine == engine)
                && (status == "all" || run.status == status)
                && (needle.isEmpty || [run.target, run.engine, run.profile, run.status, run.source ?? "", run.id].joined(separator: " ").lowercased().contains(needle))
        }
    }

    static func assessments(_ items: [SecurityScannerAssessment], query: String, status: String) -> [SecurityScannerAssessment] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.filter { assessment in
            (status == "all" || assessment.status == status)
                && (needle.isEmpty || [assessment.status, assessment.source] .joined(separator: " ").lowercased().contains(needle)
                    || assessment.jobs.contains { job in
                        [job.asset, job.engine, job.profile, job.stage, job.status].joined(separator: " ").lowercased().contains(needle)
                    })
        }
    }

    static func page<T>(_ items: [T], index: Int, size: Int) -> [T] {
        guard size > 0, !items.isEmpty else { return [] }
        let safeIndex = max(0, index)
        let start = min(safeIndex * size, items.count)
        let end = min(start + size, items.count)
        return Array(items[start..<end])
    }

    static func pageCount(total: Int, size: Int) -> Int {
        guard size > 0 else { return 0 }
        return max(1, (total + size - 1) / size)
    }
}

enum SecurityScannerPanelSection: String, CaseIterable, Identifiable {
    case overview = "Overview", assessments = "Assessments", assets = "Assets", scanners = "Scanners", history = "Scan history", findings = "Findings"
    var id: String { rawValue }
}
