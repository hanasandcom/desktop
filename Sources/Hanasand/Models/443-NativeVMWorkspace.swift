import Foundation

struct NativeVMInventoryItem: Equatable, Identifiable {
    let name: String
    let owner: String
    let createdBy: String?
    let organizationID: String?
    let organizationName: String?
    let accessUsers: [String]
    let managed: Bool?
    let canAssignOrganization: Bool?
    let status: String?
    let statusReason: String?
    let statusCheckedAt: String?
    let deletedAt: String?
    let deleteAfter: String?
    let deletionError: String?
    let restoredInstanceMissing: Bool?
    let primaryHost: String?
    let failoverHost: String?
    let failoverPremium: Bool?
    let failoverEnabled: Bool?
    let alwaysRunningPremium: Bool?
    let alwaysRunningEnabled: Bool?
    let type: String?
    let architecture: String?
    let created: String?
    let lastUsed: String?
    let cpuLimit: String?
    let memoryLimit: String?
    let imageDescription: String?
    let imageOS: String?
    let imageVersion: String?
    let ipv4: String?
    let lastChecked: String?

    var id: String { name }
    var isScheduledForDeletion: Bool { deletedAt != nil || deleteAfter != nil }

    var dashboardVM: DashboardVM {
        DashboardVM(
            name: name,
            owner: owner,
            createdBy: createdBy,
            accessUsers: accessUsers,
            status: status,
            type: type,
            architecture: architecture,
            created: created,
            lastUsed: lastUsed,
            description: imageDescription,
            cpuLimit: cpuLimit,
            memoryLimit: memoryLimit,
            ipv4: ipv4,
            lastChecked: lastChecked
        )
    }
}

struct NativeVMInventorySnapshot: Equatable {
    let items: [NativeVMInventoryItem]
    let isComplete: Bool
    let warnings: [String]
}

struct NativeVMInventoryFilter: Equatable {
    var query = ""
    var status = "all"
    var lifecycle = "all"
    var editor = ""
    var minimumCPU = ""
    var minimumMemoryGiB = ""
}

func nativeVMFilterInventory(_ items: [NativeVMInventoryItem], filter: NativeVMInventoryFilter) -> [NativeVMInventoryItem] {
    let query = filter.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let minimumCPU = Double(filter.minimumCPU) ?? 0
    let minimumMemory = Double(filter.minimumMemoryGiB) ?? 0
    return items.filter { item in
        if !query.isEmpty && !item.name.lowercased().contains(query) { return false }
        if minimumCPU > 0 && (Double(item.cpuLimit ?? "") ?? 0) < minimumCPU { return false }
        if minimumMemory > 0 && (nativeVMMemoryGiB(item.memoryLimit) ?? 0) < minimumMemory { return false }
        if filter.editor == "with" && item.accessUsers.isEmpty { return false }
        if filter.editor == "without" && !item.accessUsers.isEmpty { return false }
        if !filter.editor.isEmpty && !["with", "without"].contains(filter.editor) && !item.accessUsers.contains(filter.editor) { return false }
        if filter.lifecycle == "active" && item.isScheduledForDeletion { return false }
        if filter.lifecycle == "deleted" && !item.isScheduledForDeletion { return false }
        let status = (item.status ?? "").lowercased()
        if filter.status == "running" && !["running", "frozen", "starting"].contains(status) { return false }
        if filter.status == "stopped" && !["stopped", "shut off"].contains(status) { return false }
        return true
    }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

func nativeVMPage(_ items: [NativeVMInventoryItem], limit: Int) -> [NativeVMInventoryItem] {
    Array(items.prefix(max(0, limit)))
}

func nativeVMMemoryGiB(_ rawValue: String?) -> Double? {
    guard let rawValue else { return nil }
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let regex = try? NSRegularExpression(pattern: #"^([\d.]+)\s*(B|KB|KIB|MB|MIB|GB|GIB|TB|TIB)?$"#, options: [.caseInsensitive]),
          let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
          let numberRange = Range(match.range(at: 1), in: trimmed),
          let number = Double(trimmed[numberRange]), number.isFinite, number >= 0 else { return nil }
    let unit = Range(match.range(at: 2), in: trimmed).map { String(trimmed[$0]).uppercased() } ?? "GB"
    let powers: [String: Int] = ["B": -30, "KB": -20, "KIB": -20, "MB": -10, "MIB": -10, "GB": 0, "GIB": 0, "TB": 10, "TIB": 10]
    guard let power = powers[unit] else { return nil }
    return number * pow(2, Double(power))
}

struct NativeVMWorkspaceDetails: Equatable {
    let name: String
    let fields: [(String, String)]
    let profiles: [String]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.fields.elementsEqual(rhs.fields, by: ==) && lhs.profiles == rhs.profiles
    }
}

struct NativeVMMetric: Equatable, Identifiable {
    let id: String
    let recordedAt: String?
    let powerState: String?
    let poweredOnAt: String?
    let poweredOffAt: String?
    let values: [(String, String)]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.recordedAt == rhs.recordedAt && lhs.powerState == rhs.powerState
            && lhs.poweredOnAt == rhs.poweredOnAt && lhs.poweredOffAt == rhs.poweredOffAt
            && lhs.values.elementsEqual(rhs.values, by: ==)
    }
}

func nativeVMMetricIsStale(_ metric: NativeVMMetric, now: Date = .now) -> Bool {
    guard let recordedAt = metric.recordedAt else { return false }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let standard = ISO8601DateFormatter()
    standard.formatOptions = [.withInternetDateTime]
    guard let timestamp = fractional.date(from: recordedAt) ?? standard.date(from: recordedAt) else { return false }
    return now.timeIntervalSince(timestamp) > 180
}

struct NativeVMChartPoint: Equatable {
    let x: Double
    let y: Double
}

func nativeVMCPUHistorySegments(_ newestFirst: [NativeVMMetric]) -> [[NativeVMChartPoint]] {
    let ordered = newestFirst.reversed().map { metric in
        metric.values.first(where: { $0.0 == "CPU usage (%)" }).flatMap { Double($0.1) }
    }
    let valid = ordered.compactMap { $0 }.filter { $0.isFinite && $0 >= 0 }
    let ceiling = max(100, valid.max() ?? 100)
    var segments: [[NativeVMChartPoint]] = []
    var current: [NativeVMChartPoint] = []
    for (index, value) in ordered.enumerated() {
        guard let value, value.isFinite, value >= 0 else {
            if !current.isEmpty { segments.append(current); current = [] }
            continue
        }
        let x = ordered.count <= 1 ? 0.5 : Double(index) / Double(ordered.count - 1)
        current.append(NativeVMChartPoint(x: x, y: 1 - value / ceiling))
    }
    if !current.isEmpty { segments.append(current) }
    return segments
}

struct NativeVMPublicService: Equatable, Identifiable {
    let id: String
    let name: String
    let type: String
    let port: Int
    let hostname: String?
    let createdAt: String?
}

enum NativeVMPublicServiceType: String, CaseIterable, Identifiable {
    case http
    case tls
    case minecraftJava = "minecraft-java"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .http: "Website (HTTP)"
        case .tls: "TLS over TCP"
        case .minecraftJava: "Minecraft Java"
        }
    }
    var defaultPort: String {
        switch self {
        case .http: "80"
        case .tls: "443"
        case .minecraftJava: "25565"
        }
    }
}

struct NativeVMManagementAccess: Equatable {
    let scope: String
    let vmName: String
    let capturedAt: Date
    let canManage: Bool
    let services: [NativeVMPublicService]
}

enum NativeVMWorkspaceClientError: LocalizedError, Equatable {
    case invalidEndpoint
    case invalidVMName
    case invalidResponse
    case responseTooLarge
    case permissionDenied
    case staleManagementSnapshot
    case invalidServiceInput
    case uncertainOutcome
    case httpStatus(Int)

    var errorDescription: String {
        switch self {
        case .invalidEndpoint: "VM details require a valid secure API address."
        case .invalidVMName: "The selected VM name is invalid."
        case .invalidResponse: "The VM service returned an invalid response."
        case .responseTooLarge: "The VM response is larger than expected."
        case .permissionDenied: "Current permission to manage this VM could not be verified."
        case .staleManagementSnapshot: "Refresh this VM's public services before changing them."
        case .invalidServiceInput: "Enter a valid public service name, type, and guest port."
        case .uncertainOutcome: "The service change may have been accepted. Refresh public services before trying again."
        case let .httpStatus(status): "The VM service returned HTTP \(status)."
        }
    }
}
