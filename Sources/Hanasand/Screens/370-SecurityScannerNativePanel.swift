import SwiftUI

struct SecurityScannerNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @State private var dashboard: SecurityScannerDashboard?
    @State private var section: SecurityScannerPanelSection = .overview
    @State private var loading = false
    @State private var busy = ""
    @State private var error: String?
    @State private var notice: String?
    @State private var hostname = ""
    @State private var authorization: Set<String> = []
    @State private var nmapProfiles: [String: SecurityScannerNmapProfile] = [:]
    @State private var scheduleIntervals: [String: String] = [:]
    @State private var tenableScanIDs: [String: String] = [:]
    @State private var scheduleEnabled: [String: Bool] = [:]
    @State private var scheduleEngines: [String: Set<String>] = [:]
    @State private var zapDefinitionPaths: [String: String] = [:]
    @State private var findingQuery = ""
    @State private var findingEngine = "all"
    @State private var findingSeverity = "all"
    @State private var findingStatus = "actionable"
    @State private var findingAsset = "all"
    @State private var runQuery = ""
    @State private var runEngine = "all"
    @State private var runStatus = "all"
    @State private var tenableRegion = "us"
    @State private var tenableAccessKey = ""
    @State private var tenableSecretKey = ""
    @State private var findingStates: [String: String] = [:]
    @State private var findingNotes: [String: String] = [:]
    @State private var selectedAssets: Set<String> = []
    @State private var selectedEngines: Set<String> = ["nmap"]
    @State private var assessmentNmapProfile: SecurityScannerNmapProfile = .top1000
    @State private var assessmentScanID = ""
    @State private var runCursor: String?
    @State private var assessmentCursor: String?
    @State private var findingCursor: String?
    @State private var olderRuns: [SecurityScannerRun] = []
    @State private var olderAssessments: [SecurityScannerAssessment] = []
    @State private var olderFindings: [SecurityScannerFinding] = []
    @State private var selectedRun: SecurityScannerRun?
    @State private var selectedAssessmentReport: SecurityScannerAssessmentReport?

    private var snapshot: SecurityScannerDashboard { dashboard ?? SecurityScannerDashboard() }
    private var client: SecurityScannerClient? {
        try? SecurityScannerClient(settings: model.settings, onRefreshedToken: { token in
            guard !token.isEmpty else { return }
            try? DesktopCredentialStore.write(token, for: .authToken)
            model.settings.authToken = token
        })
    }
    private var clientFailure: String {
        do { _ = try SecurityScannerClient(settings: model.settings); return "Security Scanner is unavailable." }
        catch { return error.localizedDescription }
    }
    private var writeDisabled: Bool { !model.hasHanasandAuth || !model.settings.impersonationToken.isEmpty || !model.settings.impersonatingUserID.isEmpty || busy.isEmpty == false }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let error, dashboard == nil {
                NativeEmptyState(title: "Scanner unavailable", message: error)
                ActionButton(title: loading ? "Loading…" : "Retry", icon: "arrow.clockwise") { Task { await refresh() } }.disabled(loading)
            } else {
                if let error { CompactInfoCard(title: "Scanner connection", lines: [error]) }
                if let notice { CompactInfoCard(title: "Scanner", lines: [notice]) }
                if loading && dashboard == nil { ProgressView("Loading scanner data…") }
                if dashboard != nil { sectionContent }
            }
        }
        .task { await refresh() }
        .task(id: pollingKey) {
            guard !pollingKey.isEmpty else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                await refresh(quiet: true)
            }
        }
    }

    private var pollingKey: String {
        snapshot.runs.contains(where: { ["queued", "launching", "running", "exporting", "cancelling"].contains($0.status) })
            || snapshot.assessments.contains(where: { ["queued", "running", "cancelling"].contains($0.status) }) ? model.selectedOrganizationID : ""
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Security scanner").font(.title2.bold())
                    Text(model.selectedOrganizationName ?? "Organization workspace").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                ActionButton(title: loading ? "Refreshing…" : "Refresh", icon: "arrow.clockwise") { Task { await refresh() } }.disabled(loading)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SecurityScannerPanelSection.allCases) { item in
                        Button { section = item } label: {
                            Text(item.rawValue).font(.subheadline.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 7)
                                .background(section == item ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08), in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder private var sectionContent: some View {
        switch section {
        case .overview: overview
        case .assets: assetsView
        case .assessments: assessmentsView
        case .scanners: scannersView
        case .history: historyView
        case .findings: findingsView
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                FeatureCard(title: "Assets", value: "\(snapshot.assets.count)", icon: "network")
                FeatureCard(title: "Active scans", value: "\(snapshot.runs.filter { ["queued", "launching", "running", "exporting"].contains($0.status) }.count)", icon: "waveform.path.ecg")
                FeatureCard(title: "Open findings", value: "\(snapshot.findingSummary?.actionable ?? snapshot.findings.filter { !["resolved", "accepted_risk", "false_positive"].contains($0.status) }.count)", icon: "exclamationmark.shield")
            }
            NativeGroupPanel(title: "Coverage", subtitle: "Per-asset scanner status and freshness") {
                if snapshot.coverage.isEmpty {
                    NativeEmptyState(title: "No scan coverage yet", message: snapshot.assets.isEmpty ? "Add and verify an asset to begin." : "Run an authorized scan to populate coverage.")
                } else {
                    ForEach(snapshot.coverage) { coverage in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(assetName(coverage.assetId)) · \(engineName(coverage.engine))").font(.subheadline.weight(.semibold))
                                Text("\(coverage.state.replacingOccurrences(of: "_", with: " ")) · \(coverage.freshness) · \(coverage.freshnessReason)").font(.caption).foregroundStyle(.secondary)
                                if let web = coverage.webCoverage {
                                    Text("Web: \(web.urlsVisited.map(String.init) ?? "—") URLs · \(web.totalAlerts) alerts · \(web.complete ? "complete" : "partial")").font(.caption2).foregroundStyle(.secondary)
                                }
                                if let missing = coverage.missingAddresses, !missing.isEmpty { Text("Missing: \(missing.joined(separator: ", "))").font(.caption2).foregroundStyle(.orange).textSelection(.enabled) }
                            }
                            Spacer(minLength: 4)
                            if let date = coverage.lastRunAt { Text(date).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                        }.padding(.vertical, 4)
                    }
                }
            }
            NativeGroupPanel(title: "Recent activity", subtitle: "Latest assessments and scans") {
                ForEach(snapshot.assessments.prefix(4)) { assessment in
                    Label("Assessment · \(assessment.jobs.count) jobs · \(assessment.status)", systemImage: "checklist")
                }
                ForEach(snapshot.runs.prefix(5)) { run in
                    Label("\(engineName(run.engine)) · \(run.target) · \(run.status)", systemImage: "dot.radiowaves.left.and.right").lineLimit(2)
                }
                if snapshot.assessments.isEmpty && snapshot.runs.isEmpty { NativeEmptyState(title: "No scanner activity", message: "Add an asset, verify control, and start an authorized assessment.") }
                ActionButton(title: "New assessment", icon: "plus.circle") { section = .assessments }
            }
        }
    }

    private var assetsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            NativeGroupPanel(title: "Add an authorized asset", subtitle: "Verify domain control before scanning") {
                HStack {
                    TextField("example.com", text: $hostname).textFieldStyle(.roundedBorder)
                    ActionButton(title: busy == "asset:new" ? "Adding…" : "Add asset", icon: "plus") { Task { await addAsset() } }.disabled(writeDisabled || hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("The scanner requires verified ownership and an explicit authorization confirmation before scan or schedule actions.").font(.caption).foregroundStyle(.secondary)
            }
            if snapshot.assets.isEmpty { NativeEmptyState(title: "No assets", message: "Add a hostname you control, then publish the provided DNS TXT verification record.") }
            ForEach(snapshot.assets) { asset in assetCard(asset) }
        }
    }

    private func assetCard(_ asset: SecurityScannerAsset) -> some View {
        NativeGroupPanel(title: asset.hostname, subtitle: "\(asset.verificationStatus.capitalized) · \(asset.authorizedAddresses.count) authorized address(es)") {
            if asset.verificationStatus == "pending" {
                CompactInfoCard(title: "DNS verification record", lines: ["Name: \(asset.verificationRecordName)", "Value: \(asset.verificationRecordValue)"])
                ActionButton(title: busy == asset.id ? "Checking…" : "Verify DNS control", icon: "checkmark.shield") { Task { await verify(asset) } }.disabled(writeDisabled)
            }
            if asset.verificationStatus == "verified" {
                HStack {
                    Picker("Nmap profile", selection: Binding(get: { nmapProfiles[asset.id] ?? .top1000 }, set: { nmapProfiles[asset.id] = $0 })) {
                        ForEach(SecurityScannerNmapProfile.allCases) { Text($0.title).tag($0) }
                    }.frame(maxWidth: 250)
                    Toggle("I am authorized to scan", isOn: Binding(get: { authorization.contains(asset.id) }, set: { enabled in if enabled { authorization.insert(asset.id) } else { authorization.remove(asset.id) } }))
                        .toggleStyle(.checkbox)
                }
                HStack(spacing: 8) {
                    ForEach(SecurityScannerEngineID.allCases) { engine in
                        ActionButton(title: busy == "\(asset.id):\(engine.rawValue)" ? "Queueing…" : engine.title, icon: "play.fill") {
                            Task { await run(asset, engine: engine) }
                        }.disabled(writeDisabled || !authorization.contains(asset.id) || !engineAvailable(engine))
                    }
                }
                if let tenable = snapshot.tenableIntegration, tenable.configured {
                    Picker("Tenable configuration", selection: Binding(get: { tenableScanIDs[asset.id] ?? snapshot.tenableScans.first(where: \.enabled)?.id ?? "" }, set: { tenableScanIDs[asset.id] = $0 })) {
                        ForEach(snapshot.tenableScans.filter(\.enabled)) { Text($0.name).tag($0.id) }
                    }.frame(maxWidth: 340)
                }
                HStack {
                    TextField("OpenAPI definition path (optional)", text: Binding(get: { zapDefinitionPaths[asset.id] ?? asset.zapApiDefinitionPath ?? "" }, set: { zapDefinitionPaths[asset.id] = $0 }))
                        .textFieldStyle(.roundedBorder)
                    ActionButton(title: busy == "\(asset.id):zap-api" ? "Saving…" : "Save API definition", icon: "doc.badge.gearshape") { Task { await saveZapDefinition(asset) } }.disabled(writeDisabled)
                }
                Text("OWASP ZAP crawls same-origin pages. An OpenAPI path can seed API routes; out-of-scope addresses are filtered.").font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack {
                    TextField("Schedule interval in minutes", text: Binding(get: { scheduleIntervals[asset.id] ?? String(asset.intervalMinutes) }, set: { scheduleIntervals[asset.id] = $0 }))
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                    Toggle("Schedule enabled", isOn: Binding(get: { scheduleEnabled[asset.id] ?? asset.scheduleEnabled }, set: { scheduleEnabled[asset.id] = $0 }))
                        .toggleStyle(.checkbox)
                    ActionButton(title: busy == "\(asset.id):schedule" ? "Saving…" : "Save schedule", icon: "calendar.badge.clock") { Task { await saveSchedule(asset) } }
                        .disabled(writeDisabled || !authorization.contains(asset.id))
                }
                let initialPlan = asset.schedulePlan?.isEmpty == false ? asset.schedulePlan!.map(\.engine) : [asset.scheduleEngine ?? "nmap"]
                let chosenEngines = scheduleEngines[asset.id] ?? Set(initialPlan)
                HStack(spacing: 10) {
                    ForEach(SecurityScannerEngineID.allCases) { engine in
                        Toggle(engine.title, isOn: Binding(get: { chosenEngines.contains(engine.rawValue) }, set: { enabled in
                            var values = chosenEngines
                            if enabled { values.insert(engine.rawValue) } else { values.remove(engine.rawValue) }
                            scheduleEngines[asset.id] = values
                        })).toggleStyle(.checkbox).disabled(!engineAvailable(engine))
                    }
                }
                if chosenEngines.contains("nmap") {
                    Picker("Scheduled Nmap profile", selection: Binding(get: { nmapProfiles["schedule:\(asset.id)"] ?? .top1000 }, set: { nmapProfiles["schedule:\(asset.id)"] = $0 })) {
                        ForEach(SecurityScannerNmapProfile.allCases) { Text($0.title).tag($0) }
                    }.frame(maxWidth: 320)
                }
                if chosenEngines.contains("tenable-vm") {
                    Picker("Scheduled Tenable scan", selection: Binding(get: { tenableScanIDs["schedule:\(asset.id)"] ?? snapshot.tenableScans.first(where: \.enabled)?.id ?? "" }, set: { tenableScanIDs["schedule:\(asset.id)"] = $0 })) {
                        ForEach(snapshot.tenableScans.filter(\.enabled)) { Text($0.name).tag($0.id) }
                    }.frame(maxWidth: 320)
                }
                Text(asset.schedulePlan?.map { engineName($0.engine) }.joined(separator: " → ") ?? "\(asset.scheduleEnabled ? "Scheduled" : "No schedule") · every \(asset.intervalMinutes) min").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var assessmentsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            NativeGroupPanel(title: "New assessment", subtitle: "Select verified assets and available engines in run order") {
                let verified = snapshot.assets.filter { $0.verificationStatus == "verified" }
                if verified.isEmpty { NativeEmptyState(title: "No verified assets", message: "Add an asset and verify domain control before starting an assessment.") }
                ForEach(verified) { asset in
                    Toggle("\(asset.hostname) · \(asset.authorizedAddresses.count) authorized address(es)", isOn: Binding(get: { selectedAssets.contains(asset.id) }, set: { checked in if checked { selectedAssets.insert(asset.id) } else { selectedAssets.remove(asset.id) } })).toggleStyle(.checkbox)
                }
                Divider()
                ForEach(SecurityScannerEngineID.allCases) { engine in
                    Toggle("\(engine.title) · \(engineAvailable(engine) ? "Available" : "Unavailable")", isOn: Binding(get: { selectedEngines.contains(engine.rawValue) }, set: { checked in if checked { selectedEngines.insert(engine.rawValue) } else { selectedEngines.remove(engine.rawValue) } })).toggleStyle(.checkbox).disabled(!engineAvailable(engine))
                }
                if selectedEngines.contains(SecurityScannerEngineID.nmap.rawValue) {
                    Picker("Nmap coverage", selection: $assessmentNmapProfile) { ForEach(SecurityScannerNmapProfile.allCases) { Text($0.title).tag($0) } }.frame(maxWidth: 330)
                }
                if selectedEngines.contains(SecurityScannerEngineID.tenableVM.rawValue) {
                    Picker("Tenable scan configuration", selection: $assessmentScanID) {
                        Text("Choose configuration").tag("")
                        ForEach(snapshot.tenableScans.filter(\.enabled)) { Text($0.name).tag($0.id) }
                    }.frame(maxWidth: 330)
                }
                Text("Each engine runs across the selected assets before the next engine. The scanner rechecks DNS and public IP scope at launch; this is not a penetration test.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Toggle("I am authorized to scan the selected assets and public IPs", isOn: Binding(get: { !selectedAssets.isEmpty && selectedAssets.isSubset(of: authorization) }, set: { allowed in if allowed { authorization.formUnion(selectedAssets) } else { authorization.subtract(selectedAssets) } })).toggleStyle(.checkbox)
                    ActionButton(title: busy == "assessment" ? "Starting…" : "Start assessment", icon: "play.fill") { Task { await startAssessment() } }
                        .disabled(writeDisabled || selectedAssets.isEmpty || selectedEngines.isEmpty || !selectedAssets.isSubset(of: authorization) || (selectedEngines.contains("tenable-vm") && assessmentScanID.isEmpty))
                }
            }
            NativeGroupPanel(title: "Assessment history", subtitle: "\(snapshot.assessments.count + olderAssessments.count) loaded") {
                let items = uniqueAssessments
                if items.isEmpty { NativeEmptyState(title: "No assessments yet", message: "New assessments and their stage status will appear here.") }
                ForEach(items) { assessment in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack { Text("\(assessment.jobs.count) jobs · \(assessment.status)").font(.headline); Spacer(); Text(assessment.createdAt).font(.caption).foregroundStyle(.secondary) }
                        ForEach(assessment.jobs) { job in Text("Stage \(job.stageIndex + 1) · \(job.asset) · \(engineName(job.engine)) · \(job.status)\(job.error.map { " · \($0)" } ?? "")").font(.caption).textSelection(.enabled) }
                        HStack {
                            ActionButton(title: busy == "report:\(assessment.id)" ? "Loading…" : "View report", icon: "doc.text.magnifyingglass") { Task { await loadReport(assessment) } }
                            if ["queued", "running"].contains(assessment.status) { ActionButton(title: "Cancel", icon: "xmark.circle") { Task { await cancel(assessment) } }.disabled(writeDisabled) }
                        }
                    }.padding(.vertical, 4)
                }
                if let assessmentCursor { ActionButton(title: busy == "older:assessment" ? "Loading…" : "Load older", icon: "arrow.down.page") { Task { await loadOlderAssessments(assessmentCursor) } }.disabled(busy == "older:assessment") }
                if let report = selectedAssessmentReport { reportView(report) }
            }
        }
    }

    private var scannersView: some View {
        VStack(alignment: .leading, spacing: 12) {
            NativeGroupPanel(title: "Scanner suite", subtitle: "Configured engines and supported coverage") {
                ForEach(snapshot.scannerCatalog) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text(item.name).font(.subheadline.weight(.semibold)); Spacer(); Text(item.setup.replacingOccurrences(of: "-", with: " ").capitalized).font(.caption).foregroundStyle(item.setup == "configured" ? .green : .secondary) }
                        Text("\(item.category) · \(engineName(item.integration))").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 3)
                }
                if snapshot.scannerCatalog.isEmpty {
                    ForEach(snapshot.engines) { engine in Text("\(engine.name) · \(engine.status) · \(engine.version ?? "version unknown")\(engine.reason.map { " · \($0)" } ?? "")") }
                }
            }
            NativeGroupPanel(title: "Tenable VM", subtitle: snapshot.tenableIntegration?.configured == true ? "Connected · key \(snapshot.tenableIntegration?.accessKeyHint ?? "hidden")" : "Optional Nessus scan integration") {
                if let integration = snapshot.tenableIntegration, integration.configured {
                    Text("Region: \(integration.region ?? "unknown") · Last tested: \(integration.testedAt ?? "unknown")").font(.caption).foregroundStyle(.secondary)
                    ForEach(snapshot.tenableScans) { scan in Text("\(scan.enabled ? "✓" : "–") \(scan.name) · \(scan.status ?? "unknown") · targets: \(scan.targets)").font(.caption).textSelection(.enabled) }
                    ActionButton(title: busy == "tenable:disconnect" ? "Disconnecting…" : "Disconnect Tenable", icon: "link.badge.minus") { Task { await disconnectTenable() } }.disabled(writeDisabled)
                } else {
                    Picker("Region", selection: $tenableRegion) { ForEach(["us", "eu", "de", "au", "ca", "jp"], id: \.self) { Text($0.uppercased()).tag($0) } }.frame(maxWidth: 200)
                    SecureField("Access key", text: $tenableAccessKey).textFieldStyle(.roundedBorder)
                    SecureField("Secret key", text: $tenableSecretKey).textFieldStyle(.roundedBorder)
                    ActionButton(title: busy == "tenable:connect" ? "Checking…" : "Connect and verify", icon: "link") { Task { await configureTenable() } }.disabled(writeDisabled || tenableAccessKey.isEmpty || tenableSecretKey.isEmpty)
                    Text("Credentials are sent only to the scanner API over HTTPS. The service validates them before saving.").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(snapshot.engines) { engine in
                NativeGroupPanel(title: engine.name, subtitle: "\(engine.status.capitalized) · \(engine.version ?? "Version unknown")") {
                    if let reason = engine.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                    if !engine.coverage.isEmpty { Text("Covers: \(engine.coverage.joined(separator: ", "))").font(.caption) }
                    if !engine.notCovered.isEmpty { Text("Does not cover: \(engine.notCovered.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private var historyView: some View {
        NativeGroupPanel(title: "Scanner runs", subtitle: "\(uniqueRuns.count) loaded") {
            HStack {
                TextField("Search target, profile, or run ID", text: $runQuery).textFieldStyle(.roundedBorder)
                Picker("Engine", selection: $runEngine) { Text("All engines").tag("all"); ForEach(SecurityScannerEngineID.allCases) { Text($0.title).tag($0.rawValue) } }.frame(maxWidth: 180)
                Picker("Status", selection: $runStatus) { Text("All statuses").tag("all"); ForEach(["queued", "launching", "running", "exporting", "succeeded", "partial", "failed", "cancelling", "cancelled"], id: \.self) { Text($0.capitalized).tag($0) } }.frame(maxWidth: 180)
            }
            if uniqueRuns.isEmpty { NativeEmptyState(title: "No scanner runs", message: "Runs appear here after an asset scan or assessment starts.") }
            if !uniqueRuns.isEmpty && visibleRuns.isEmpty { NativeEmptyState(title: "No matching runs", message: "Change or clear a filter to see more scanner runs.") }
            ForEach(visibleRuns) { run in
                VStack(alignment: .leading, spacing: 7) {
                    HStack { Text("\(engineName(run.engine)) · \(run.target)").font(.headline); Spacer(); Text(run.status.capitalized).font(.caption.weight(.semibold)) }
                    Text("\(run.profile) · \(run.source ?? "unknown") · \(run.createdAt)").font(.caption).foregroundStyle(.secondary)
                    if let coverage = run.coverage { Text("Coverage: \(coverage.completedAddresses.map(String.init) ?? "—") / \(coverage.requestedAddresses.map(String.init) ?? "—") addresses · \(coverage.complete == true ? "complete" : "partial/unknown")").font(.caption2).foregroundStyle(.secondary) }
                    if let message = run.error { Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                    HStack {
                        ActionButton(title: selectedRun?.id == run.id ? "Selected" : "View details", icon: "doc.text") { Task { await openRun(run) } }
                        if ["queued", "launching", "running", "exporting", "cancelling"].contains(run.status) { ActionButton(title: busy == "run:\(run.id)" ? "Cancelling…" : "Cancel", icon: "xmark.circle") { Task { await cancel(run) } }.disabled(writeDisabled) }
                    }
                    if selectedRun?.id == run.id { runDetails(run) }
                }.padding(.vertical, 5)
                Divider()
            }
            if let runCursor { ActionButton(title: busy == "older:run" ? "Loading…" : "Load older runs", icon: "arrow.down.page") { Task { await loadOlderRuns(runCursor) } }.disabled(busy == "older:run") }
        }
    }

    private var findingsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            NativeGroupPanel(title: "Findings", subtitle: "\(snapshot.findingSummary?.total ?? snapshot.findings.count) total · \(snapshot.findingSummary?.actionable ?? snapshot.findings.filter { ["open", "in_progress", "pending_verification"].contains($0.status) }.count) actionable") {
                TextField("Search title, CVE, asset, or evidence", text: $findingQuery).textFieldStyle(.roundedBorder)
                HStack {
                    Picker("Engine", selection: $findingEngine) { Text("All engines").tag("all"); ForEach(SecurityScannerEngineID.allCases) { Text($0.title).tag($0.rawValue) } }.frame(maxWidth: 180)
                    Picker("Severity", selection: $findingSeverity) { Text("All severities").tag("all"); ForEach(["critical", "high", "medium", "low", "unknown"], id: \.self) { Text($0.capitalized).tag($0) } }.frame(maxWidth: 150)
                    Picker("Status", selection: $findingStatus) { Text("Actionable").tag("actionable"); Text("All statuses").tag("all"); ForEach(["open", "in_progress", "pending_verification", "accepted_risk", "false_positive", "resolved"], id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ").capitalized).tag($0) } }.frame(maxWidth: 180)
                    Picker("Asset", selection: $findingAsset) { Text("All assets").tag("all"); ForEach(snapshot.assets) { Text($0.hostname).tag($0.id) } }.frame(maxWidth: 200)
                }
                if uniqueFindings.isEmpty { NativeEmptyState(title: "No findings", message: "Findings appear after supported scanners complete runs.") }
                if !uniqueFindings.isEmpty && visibleFindings.isEmpty { NativeEmptyState(title: "No matching findings", message: "Change or clear a filter to see more findings.") }
                ForEach(visibleFindings) { finding in findingCard(finding) }
                if let findingCursor { ActionButton(title: busy == "older:finding" ? "Loading…" : "Load older findings", icon: "arrow.down.page") { Task { await loadOlderFindings(findingCursor) } }.disabled(busy == "older:finding") }
            }
        }
    }

    private func findingCard(_ finding: SecurityScannerFinding) -> some View {
        NativeGroupPanel(title: finding.title, subtitle: "\(finding.severity.uppercased()) · \(engineName(finding.engine)) · \(finding.asset) · \(finding.address ?? "address unknown")") {
            HStack { Text("\(finding.cvssScore.map { String(format: "CVSS %.1f", $0) } ?? "CVSS unknown") · \(finding.status.replacingOccurrences(of: "_", with: " "))").font(.caption.weight(.semibold)); Spacer(); Text(finding.cveIds.joined(separator: ", ")).font(.caption2).textSelection(.enabled) }
            if let description = finding.description { Text(description).font(.caption).textSelection(.enabled) }
            if let solution = finding.solution { CompactInfoCard(title: "Remediation", lines: [solution]) }
            if let evidence = finding.evidence { DisclosureGroup("Evidence") { Text(evidence).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
            Picker("Triage status", selection: Binding(get: { findingStates[finding.id] ?? finding.status }, set: { findingStates[finding.id] = $0 })) {
                ForEach(["open", "in_progress", "pending_verification", "accepted_risk", "false_positive", "resolved"], id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ").capitalized).tag($0) }
            }.frame(maxWidth: 260)
            TextField("Triage note", text: Binding(get: { findingNotes[finding.id] ?? finding.triageNote ?? "" }, set: { findingNotes[finding.id] = $0 }), axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...5)
            ActionButton(title: busy == "finding:\(finding.id)" ? "Saving…" : "Save triage", icon: "checkmark") { Task { await updateFinding(finding) } }.disabled(writeDisabled)
        }
    }

    private func reportView(_ report: SecurityScannerAssessmentReport) -> some View {
        NativeGroupPanel(title: "Assessment report · \(report.status)", subtitle: "\(report.jobs.count) jobs") {
            ForEach(report.jobs) { job in
                VStack(alignment: .leading, spacing: 3) {
                    Text("Stage \(job.stageIndex + 1) · \(job.asset) · \(engineName(job.engine)) · \(job.status)").font(.subheadline.weight(.semibold))
                    if let run = job.run {
                        Text("Run \(run.id) · \(run.target) · \(run.status)").font(.caption).textSelection(.enabled)
                        runDetails(run)
                    }
                    if let error = job.reportError ?? job.error { Text(error).font(.caption).foregroundStyle(.orange) }
                }
            }
        }
    }

    private func runDetails(_ run: SecurityScannerRun) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Run \(run.id)").font(.caption.monospaced()).textSelection(.enabled)
            if let digest = run.rawXmlSha256 { Text("Report SHA-256: \(digest)").font(.caption2.monospaced()).textSelection(.enabled) }
            if let coverage = run.coverage {
                Text("Requested: \(coverage.requestedAddresses.map(String.init) ?? "unknown") · Attempted: \(coverage.attemptedAddresses.map(String.init) ?? "unknown") · Completed: \(coverage.completedAddresses.map(String.init) ?? "unknown")").font(.caption)
                if let addresses = coverage.completedAddressList, !addresses.isEmpty { Text("Completed addresses: \(addresses.joined(separator: ", "))").font(.caption2).textSelection(.enabled) }
                if let missing = coverage.missingAddresses, !missing.isEmpty { Text("Missing addresses: \(missing.joined(separator: ", "))").font(.caption2).foregroundStyle(.orange).textSelection(.enabled) }
                if let origin = coverage.origin { Text("Origin: \(origin) · URLs visited: \(coverage.urlsVisited.map(String.init) ?? "unknown") · Alerts: \(coverage.totalAlerts.map(String.init) ?? "unknown")").font(.caption) }
                if !((coverage.truncationReasons ?? []).isEmpty) { Text("Truncated: \(coverage.truncationReasons!.joined(separator: ", "))").font(.caption).foregroundStyle(.orange) }
            }
            if let hosts = run.hosts, !hosts.isEmpty {
                Text("Nmap hosts · \(hosts.count)").font(.caption.weight(.semibold))
                ForEach(hosts) { host in
                    DisclosureGroup("\(host.address) · \(host.timedOut ? "timed out" : host.status) · \(host.ports.filter { $0.state == "open" }.count) open ports") {
                        if host.ports.filter({ $0.state == "open" }).isEmpty { Text("No open ports were reported.").font(.caption).foregroundStyle(.secondary) }
                        ForEach(host.ports.filter { $0.state == "open" }) { port in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(port.port)/\(port.protocolName) · \(port.service ?? "unknown service")\(port.product.map { " · \($0)" } ?? "")\(port.version.map { " \($0)" } ?? "")\(port.extraInfo.map { " · \($0)" } ?? "")").font(.caption)
                                scriptEvidence(port.scriptResults)
                            }
                        }
                        scriptEvidence(host.scriptResults)
                    }.font(.caption)
                }
            }
            if let findings = run.findings, !findings.isEmpty {
                Text("Scanner findings · \(findings.count)").font(.caption.weight(.semibold))
                ForEach(findings) { finding in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(finding.severity.uppercased()) · \(finding.title)").font(.caption.weight(.semibold))
                        Text("\(finding.provider) · \(finding.assetAddress)\(finding.port.map { ":\($0)" } ?? "")\(finding.cveIDs?.isEmpty == false ? " · \(finding.cveIDs!.joined(separator: ", "))" : "")").font(.caption2).foregroundStyle(.secondary)
                        if let description = finding.description { Text(description).font(.caption2) }
                        if let evidence = finding.evidence { Text(evidence).font(.caption2.monospaced()).textSelection(.enabled) }
                        if let solution = finding.solution { Text("Remediation: \(solution)").font(.caption2) }
                    }.padding(.vertical, 3)
                }
            } else if run.engine != "nmap" && run.status == "succeeded" {
                Text("No findings returned. Review scan coverage before treating this as a clean result.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(8).background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private func scriptEvidence(_ evidence: [SecurityScannerScriptEvidence]?) -> some View {
        if let evidence, !evidence.isEmpty {
            ForEach(evidence) { script in
                DisclosureGroup("NSE evidence · \(script.scriptID)") {
                    Text(script.output + (script.truncated ? "\n… output truncated" : ""))
                        .font(.caption2.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.font(.caption2)
            }
        }
    }

    private var uniqueRuns: [SecurityScannerRun] {
        Dictionary((snapshot.runs + olderRuns).map { ("\($0.engine):\($0.id)", $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.createdAt > $1.createdAt }
    }
    private var uniqueAssessments: [SecurityScannerAssessment] {
        Dictionary((snapshot.assessments + olderAssessments).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.createdAt > $1.createdAt }
    }
    private var uniqueFindings: [SecurityScannerFinding] {
        Dictionary((snapshot.findings + olderFindings).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { ($0.lastSeen ?? "") > ($1.lastSeen ?? "") }
    }
    private var visibleFindings: [SecurityScannerFinding] {
        let query = findingQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return uniqueFindings.filter { finding in
            (findingEngine == "all" || finding.engine == findingEngine)
                && (findingSeverity == "all" || finding.severity.lowercased() == findingSeverity)
                && (findingStatus == "all" || (findingStatus == "actionable" ? ["open", "in_progress", "pending_verification"].contains(finding.status) : finding.status == findingStatus))
                && (findingAsset == "all" || finding.assetId == findingAsset)
                && (query.isEmpty || [finding.title, finding.asset, finding.address ?? "", finding.externalId, finding.description ?? "", finding.evidence ?? "", finding.cveIds.joined(separator: " ")].joined(separator: " ").lowercased().contains(query))
        }
    }
    private var visibleRuns: [SecurityScannerRun] {
        let query = runQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return uniqueRuns.filter { run in
            (runEngine == "all" || run.engine == runEngine) && (runStatus == "all" || run.status == runStatus)
                && (query.isEmpty || [run.target, run.profile, run.engine, run.status, run.id].joined(separator: " ").lowercased().contains(query))
        }
    }

    @MainActor private func refresh(quiet: Bool = false) async {
        guard let client else { if !quiet { error = clientFailure }; return }
        if !quiet { loading = true; error = nil }
        defer { if !quiet { loading = false } }
        do {
            dashboard = try await client.dashboard()
            if dashboard?.engines.contains(where: { $0.id == "nmap" && $0.status == "available" }) == true { selectedEngines.insert("nmap") }
            runCursor = dashboard?.runsNextCursor
            assessmentCursor = dashboard?.assessmentsNextCursor
            findingCursor = dashboard?.findingsNextCursor
            error = dashboard?.scannerError
        } catch { if !quiet || dashboard == nil { self.error = error.localizedDescription } }
    }

    @MainActor private func addAsset() async {
        await perform("asset:new", success: "Asset added. Publish its DNS TXT record, then verify domain control.") { client in _ = try await client.createAsset(hostname: hostname) ; hostname = "" }
    }
    @MainActor private func verify(_ asset: SecurityScannerAsset) async {
        await perform(asset.id, success: "DNS verification complete.") { client in
            let updated = try await client.verifyAsset(asset)
            if var current = dashboard { current.assets = current.assets.map { $0.id == updated.id ? updated : $0 }; dashboard = current }
            notice = updated.verificationStatus == "verified" ? "Domain control verified." : "TXT record was not found. DNS changes can take time to propagate."
        }
    }
    @MainActor private func run(_ asset: SecurityScannerAsset, engine: SecurityScannerEngineID) async {
        let key = "\(asset.id):\(engine.rawValue)"
        await perform(key, success: "\(engine.title) scan queued.") { client in
            _ = try await client.runScan(asset: asset, engine: engine, authorized: authorization.contains(asset.id), nmapProfile: nmapProfiles[asset.id] ?? .top1000, tenableScanID: tenableScanIDs[asset.id] ?? snapshot.tenableScans.first(where: \.enabled)?.id)
            await refresh(quiet: true)
        }
    }
    @MainActor private func saveSchedule(_ asset: SecurityScannerAsset) async {
        await perform("\(asset.id):schedule", success: "Scan schedule saved.") { client in
            let interval = Int(scheduleIntervals[asset.id] ?? String(asset.intervalMinutes)) ?? 0
            let plan = asset.schedulePlan?.isEmpty == false ? asset.schedulePlan! : [SecurityScannerEngineSelection(engine: "nmap", scanId: nil, profile: (nmapProfiles[asset.id] ?? .top1000).rawValue)]
            let selected = scheduleEngines[asset.id] ?? Set(plan.map(\.engine))
            let configuredPlan = selected.sorted().compactMap { raw -> SecurityScannerEngineSelection? in
                guard let engine = SecurityScannerEngineID(rawValue: raw), engineAvailable(engine) else { return nil }
                if engine == .nmap { return .init(engine: raw, scanId: nil, profile: (nmapProfiles["schedule:\(asset.id)"] ?? .top1000).rawValue) }
                if engine == .tenableVM { return .init(engine: raw, scanId: tenableScanIDs["schedule:\(asset.id)"] ?? snapshot.tenableScans.first(where: \.enabled)?.id, profile: nil) }
                return .init(engine: raw, scanId: nil, profile: nil)
            }
            guard !configuredPlan.isEmpty else { error = "Choose at least one available scanner for the schedule."; return }
            let updated = try await client.setSchedule(asset: asset, enabled: scheduleEnabled[asset.id] ?? asset.scheduleEnabled, intervalMinutes: interval, authorized: authorization.contains(asset.id), engines: configuredPlan)
            if var current = dashboard { current.assets = current.assets.map { $0.id == updated.id ? updated : $0 }; dashboard = current }
        }
    }
    @MainActor private func saveZapDefinition(_ asset: SecurityScannerAsset) async {
        await perform("\(asset.id):zap-api", success: "OpenAPI definition saved.") { client in
            let updated = try await client.saveZapApiDefinition(asset: asset, path: zapDefinitionPaths[asset.id] ?? asset.zapApiDefinitionPath)
            if var current = dashboard { current.assets = current.assets.map { $0.id == updated.id ? updated : $0 }; dashboard = current }
        }
    }
    @MainActor private func startAssessment() async {
        await perform("assessment", success: "Authorized assessment queued.") { client in
            let engines = selectedEngines.compactMap { raw -> SecurityScannerEngineSelection? in
                guard let engine = SecurityScannerEngineID(rawValue: raw), engineAvailable(engine) else { return nil }
                if engine == .nmap { return .init(engine: raw, scanId: nil, profile: assessmentNmapProfile.rawValue) }
                if engine == .tenableVM { return .init(engine: raw, scanId: assessmentScanID, profile: nil) }
                return .init(engine: raw, scanId: nil, profile: nil)
            }
            _ = try await client.startAssessment(assetIDs: Array(selectedAssets), engines: engines, authorized: selectedAssets.isSubset(of: authorization))
            selectedAssets.removeAll()
            await refresh(quiet: true)
        }
    }
    @MainActor private func cancel(_ assessment: SecurityScannerAssessment) async {
        await perform("assessment:\(assessment.id)", success: "Cancellation requested.") { client in try await client.cancelAssessment(assessment); await refresh(quiet: true) }
    }
    @MainActor private func cancel(_ run: SecurityScannerRun) async {
        await perform("run:\(run.id)", success: "Cancellation requested.") { client in try await client.cancelRun(run); await refresh(quiet: true) }
    }
    @MainActor private func updateFinding(_ finding: SecurityScannerFinding) async {
        await perform("finding:\(finding.id)", success: "Finding triage saved.") { client in
            try await client.updateFinding(finding, status: findingStates[finding.id] ?? finding.status, note: findingNotes[finding.id] ?? finding.triageNote ?? "")
            await refresh(quiet: true)
        }
    }
    @MainActor private func configureTenable() async {
        await perform("tenable:connect", success: "Tenable credentials verified and saved.") { client in
            try await client.configureTenable(region: tenableRegion, accessKey: tenableAccessKey, secretKey: tenableSecretKey)
            tenableAccessKey = ""; tenableSecretKey = ""; await refresh(quiet: true)
        }
    }
    @MainActor private func disconnectTenable() async {
        await perform("tenable:disconnect", success: "Tenable connection removed.") { client in try await client.disconnectTenable(); await refresh(quiet: true) }
    }
    @MainActor private func openRun(_ current: SecurityScannerRun) async {
        guard let client else { return }
        busy = "run-detail:\(current.id)"; defer { busy = "" }
        do { selectedRun = try await client.run(id: current.id, engine: current.engine) } catch { self.error = error.localizedDescription }
    }
    @MainActor private func loadReport(_ item: SecurityScannerAssessment) async {
        guard let client else { return }
        busy = "report:\(item.id)"; defer { busy = "" }
        do { selectedAssessmentReport = try await client.assessmentReport(item) } catch let cause { error = cause.localizedDescription }
    }
    @MainActor private func loadOlderRuns(_ cursor: String) async {
        guard let client else { return }
        busy = "older:run"; defer { busy = "" }
        do { let page = try await client.runHistory(cursor: cursor); olderRuns += page.items; runCursor = page.nextCursor }
        catch let cause { error = cause.localizedDescription }
    }
    @MainActor private func loadOlderAssessments(_ cursor: String) async {
        guard let client else { return }
        busy = "older:assessment"; defer { busy = "" }
        do { let page = try await client.assessmentHistory(cursor: cursor); olderAssessments += page.items; assessmentCursor = page.nextCursor }
        catch let cause { error = cause.localizedDescription }
    }
    @MainActor private func loadOlderFindings(_ cursor: String) async {
        guard let client else { return }
        busy = "older:finding"; defer { busy = "" }
        do { let page = try await client.findingHistory(cursor: cursor); olderFindings += page.items; findingCursor = page.nextCursor }
        catch let cause { error = cause.localizedDescription }
    }
    @MainActor private func perform(_ key: String, success: String, operation: (SecurityScannerClient) async throws -> Void) async {
        guard let client else { error = clientFailure; return }
        busy = key; error = nil; notice = nil
        defer { busy = "" }
        do { try await operation(client); notice = success; if dashboard == nil { await refresh() } }
        catch { self.error = error.localizedDescription }
    }

    private func engineAvailable(_ engine: SecurityScannerEngineID) -> Bool {
        snapshot.engines.first(where: { $0.id == engine.rawValue })?.status == "available"
            && (engine != .tenableVM || (snapshot.tenableIntegration?.configured == true && snapshot.tenableScans.contains(where: \.enabled)))
    }
    private func assetName(_ id: String) -> String { snapshot.assets.first(where: { $0.id == id })?.hostname ?? id }
    private func engineName(_ id: String) -> String { SecurityScannerEngineID(rawValue: id)?.title ?? id }
}
