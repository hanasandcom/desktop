import Foundation

struct InfrastructureContainer: Identifiable, Equatable {
    struct Port: Equatable {
        let ip: String
        let privatePort: Int
        let publicPort: Int?
        let type: String
    }

    let id: String
    let name: String
    let image: String
    let state: String
    let health: String
    let cpuPercent: Double?
    let memoryBytes: Double?
    let memoryLimitBytes: Double?
    let memoryPercent: Double?
    let uptimeSeconds: Double?
    let restartCount: Int?
    let createdAt: String
    let statsUpdatedAt: String
    let unavailableReason: String
    let ports: [Port]

    var isRunning: Bool { state.localizedCaseInsensitiveContains("running") }
    var displayName: String { name.isEmpty ? String(id.prefix(12)) : name }
    var isProtectedLogsContainer: Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "")
            .lowercased()
        return normalized == "processor"
            || normalized == "logs"
            || normalized == "hanasand-log-collector"
            || normalized.hasPrefix("logs-")
            || normalized.hasPrefix("logs_")
    }
    var cpuLabel: String { cpuPercent.map { String(format: "%.1f%%", $0) } ?? "Unavailable" }
    var memoryLabel: String { memoryBytes.map(Self.byteLabel) ?? "Unavailable" }
    var memoryLimitLabel: String { memoryLimitBytes.map(Self.byteLabel) ?? "Unavailable" }

    fileprivate static func byteLabel(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "Unavailable" }
        return ByteCountFormatter.string(fromByteCount: Int64(min(value, Double(Int64.max))), countStyle: .memory)
    }
}

struct InfrastructureContainersSnapshot: Equatable {
    let accountScope: String
    let generatedAt: String
    let source: String
    let unavailableReason: String
    let containers: [InfrastructureContainer]

    var activeContainers: [InfrastructureContainer] {
        containers.filter { !["exited", "dead", "removing"].contains($0.state.lowercased()) }
    }
}

struct InfrastructureRuntimeLogs: Equatable {
    struct Entry: Equatable {
        let id: String
        let service: String
        let level: String
        let message: String
        let createdAt: String
        let source: String
    }

    let source: String
    let generatedAt: String
    let unavailableReason: String
    let runtimeAvailable: Bool
    let nativeAvailable: Bool
    let entries: [Entry]
}

struct InfrastructureBlocklistEntry: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case ip
        case userAgent = "user_agent"

        var id: String { rawValue }
        var label: String { self == .ip ? "IP address" : "User agent" }
    }

    let id: Int
    let kind: Kind
    let value: String
    let isVPN: Bool
    let isProxy: Bool
    let isTor: Bool
    let isRelay: Bool
    let owner: String
    let location: String
    let requests: Int?
    let createdAt: String
    let updatedAt: String

    var signals: [String] {
        [(isVPN ? "VPN" : nil), (isProxy ? "Proxy" : nil), (isTor ? "Tor" : nil), (isRelay ? "Relay" : nil)].compactMap { $0 }
    }
}

struct InfrastructureBlocklistDraft: Equatable {
    var kind: InfrastructureBlocklistEntry.Kind
    var value: String
    var isVPN: Bool
    var isProxy: Bool
    var isTor: Bool

    init(kind: InfrastructureBlocklistEntry.Kind = .ip, value: String = "", isVPN: Bool = false, isProxy: Bool = false, isTor: Bool = false) {
        self.kind = kind
        self.value = value
        self.isVPN = isVPN
        self.isProxy = isProxy
        self.isTor = isTor
    }

    init(entry: InfrastructureBlocklistEntry? = nil) {
        kind = entry?.kind ?? .ip
        value = entry?.value ?? ""
        isVPN = entry?.isVPN ?? false
        isProxy = entry?.isProxy ?? false
        isTor = entry?.isTor ?? false
    }
}

enum InfrastructureViewsError: LocalizedError {
    case signInRequired
    case ownAccountRequired
    case insecureEndpoint
    case invalidScope
    case accessDenied
    case invalidResponse
    case responseTooLarge
    case invalidDraft
    case staleInventory
    case uncertainResult
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to inspect infrastructure."
        case .ownAccountRequired: "Return to your own account before using infrastructure controls."
        case .insecureEndpoint: "Infrastructure requests require a valid HTTPS endpoint."
        case .invalidScope: "The active infrastructure account could not be verified. Refresh before continuing."
        case .accessDenied: "Your current account does not have access to this infrastructure page."
        case .invalidResponse: "The infrastructure service returned an incomplete response."
        case .responseTooLarge: "The infrastructure response exceeded its size limit."
        case .invalidDraft: "Enter a valid IP address or user agent."
        case .staleInventory: "Refresh and select a current container before restarting it."
        case .uncertainResult: "The result could not be confirmed. Refresh the current state before trying again."
        case let .requestFailed(status): "Infrastructure request failed (HTTP \(status))."
        }
    }
}
