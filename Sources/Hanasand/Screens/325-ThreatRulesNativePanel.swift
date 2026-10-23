import SwiftUI

struct ThreatRulesNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    let category: String
    @State private var page: ThreatRulesPage?
    @State private var selected: ThreatRuleRecord?
    @State private var selectedDetail: RuleDetailEnvelope?
    @State private var selectedDetailRequestID: String?
    @State private var ruleHitCount: Int?
    @State private var storageEstimate: RuleStorageEstimateEnvelope.Estimate?
    @State private var storageEstimateStatus = ""
    @State private var loadingOlderAudit = false
    @State private var draftName = ""
    @State private var draftExplanation = ""
    @State private var draftSeverity = "medium"
    @State private var draftEnabled = true
    @State private var draftDefinition = ""
    @State private var search = ""
    @State private var pageNumber = 0
    @State private var preview: ThreatRulePreview?
    @State private var previewFrom = Calendar.current.date(byAdding: .hour, value: -24, to: .now) ?? .now
    @State private var status = ""
    @State private var error = ""
    @State private var busy = false
    @State private var confirmSave = false
    @State private var showingEditor = false

    private var organizationID: String { model.selectedOrganizationID }
    private var rules: [ThreatRuleRecord] { page?.rules.filter { item in
        search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || "\(item.name) \(item.id) \(item.explanation) \(item.family ?? "")".localizedCaseInsensitiveContains(search.trimmingCharacters(in: .whitespacesAndNewlines))
    } ?? [] }
    private var visibleRules: [ThreatRuleRecord] { Array(rules.dropFirst(pageNumber * 30).prefix(30)) }
    private var canManage: Bool { !model.settings.impersonationToken.isEmpty || !model.settings.impersonatingUserID.isEmpty ? false : ["owner", "admin", "editor"].contains(page?.organization.role.lowercased() ?? "") }
    private var canEditDraft: Bool {
        guard canManage, category != "analysis" || page?.canManageRetention == true else { return false }
        return selected == nil || selectedDetail?.canEdit == true
    }
    private var isBuiltIn: Bool { selected?.source == "hanasand" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NativeGroupPanel(title: title, subtitle: page.map { "\($0.organization.name) · \($0.rules.count) rules" } ?? "Organization-scoped detection configuration") {
                HStack(spacing: 8) {
                    ActionButton(title: busy ? "Loading…" : "Refresh", icon: "arrow.clockwise") { Task { await load() } }.disabled(busy)
                    ActionButton(title: "Create rule", icon: "plus") { beginNewRule() }.disabled(busy || !canEditDraft)
                }
                TextField("Search name, ID, or description", text: $search).textFieldStyle(.roundedBorder)
                if !error.isEmpty { Text(error).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.danger).textSelection(.enabled) }
                if !status.isEmpty { Text(status).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary).textSelection(.enabled) }
                if page != nil && !canManage { NativeNotice(message: "Read-only view. Organization owners, administrators, and editors can change rules.") }
                if let page, category == "analysis", canManage, !page.canManageRetention { NativeNotice(message: "Analyze rules require active Hanasand owner or editor access for log retention.") }
                if !model.settings.impersonationToken.isEmpty || !model.settings.impersonatingUserID.isEmpty { NativeNotice(message: "Read-only while impersonating. Return to your own account before changing rules.") }
            }

            if showingEditor { editor }
            else if let selected { detail(selected) }
            else if page != nil {
                NativeGroupPanel(title: "\(title) · \(rules.count)", subtitle: "Showing \(visibleRules.count) of \(rules.count)") {
                    if visibleRules.isEmpty { NativeEmptyState(title: "No rules found", message: search.isEmpty ? "This category has no rules." : "No rules match this search.") }
                    ForEach(visibleRules) { rule in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(rule.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                            Text(rule.explanation).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                            Text("\(rule.enabled ? "Enabled" : "Disabled") · \(rule.severity) · \(rule.source) · \(rule.hitCount.map(String.init) ?? "Hits unavailable") hits")
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary)
                            ActionButton(title: "Open rule", icon: "arrow.right") { Task { await open(rule) } }.disabled(busy)
                        }.padding(.vertical, 7)
                    }
                    HStack(spacing: 8) {
                        ActionButton(title: "Previous", icon: "chevron.left") { pageNumber = max(0, pageNumber - 1) }.disabled(pageNumber == 0)
                        Text("Page \(pageNumber + 1) of \(max(1, Int(ceil(Double(rules.count) / 30))))").font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary)
                        ActionButton(title: "Next", icon: "chevron.right") { pageNumber += 1 }.disabled((pageNumber + 1) * 30 >= rules.count)
                    }
                }
            } else if busy { NativeEmptyState(title: "Loading rules", message: "Checking the selected organization and rule access.") }
            else { NativeEmptyState(title: model.hasHanasandAuth ? "Select an organization" : "Sign in required", message: model.hasHanasandAuth ? "Choose an active organization in Organizations to review its rules." : "Sign in to review organization rules.") }
        }
        .task(id: "\(organizationID):\(category):\(model.userIDForRequests)") { await load() }
        .task(id: "\(organizationID):\(selected?.id ?? "")") { await refreshSelectedRuleMetrics() }
        .confirmationDialog("Save rule changes?", isPresented: $confirmSave, titleVisibility: .visible) {
            Button(selected == nil ? "Create rule" : "Save changes", role: draftAction == "drop" ? .destructive : nil) { Task { await save() } }
            Button("Cancel", role: .cancel) { }
        } message: { Text(draftAction == "drop" ? "This Analyze rule can drop eligible future events. Existing events will not be reprocessed." : "This rule applies to new events. Existing events will not be reprocessed.") }
    }

    private var title: String {
        switch category { case "match": "Match rules"; case "analysis": "Analysis rules"; default: "Detection rules" }
    }
    private var draftAction: String { (try? decodeDefinition()["action"]?.stringValue) ?? "keep" }

    @ViewBuilder private var editor: some View {
        NativeGroupPanel(title: selected?.name ?? "New \(title.dropLast())", subtitle: selected.map { "Version \($0.version) · \($0.source)" } ?? "New rules apply to future events") {
            HStack(spacing: 8) {
                ActionButton(title: "Back to rules", icon: "chevron.left") { showingEditor = false; preview = nil }.disabled(busy)
                if selected != nil { ActionButton(title: "Check matches", icon: "checkmark.magnifyingglass") { Task { await checkMatches() } }.disabled(busy) }
                ActionButton(title: "Save", icon: "checkmark") { confirmSave = true }.disabled(busy || !canEditDraft)
            }
            TextField("Rule name", text: $draftName).textFieldStyle(.roundedBorder).disabled(!canEditDraft || busy)
            TextField("Description", text: $draftExplanation, axis: .vertical).lineLimit(3...6).textFieldStyle(.roundedBorder).disabled(!canEditDraft || busy)
            HStack {
                Text("Severity").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
                Picker("Severity", selection: $draftSeverity) { ForEach(["low", "medium", "high", "critical"], id: \.self) { Text($0.capitalized).tag($0) } }.frame(maxWidth: 170).disabled(!canEditDraft || busy || draftAction == "drop")
                Toggle("Enabled", isOn: $draftEnabled).toggleStyle(.switch).disabled(!canEditDraft || busy)
            }
            Text("Rule definition (JSON)").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textSecondary)
            TextEditor(text: $draftDefinition).font(.system(size: 11, design: .monospaced)).frame(minHeight: 170).overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.divider, lineWidth: 1)).disabled(!canEditDraft || busy)
            if selected?.source == "hanasand" { NativeNotice(message: "This built-in rule keeps its complete definition, including selectors and protection settings, when you save.") }
            if let preview {
                NativeGroupPanel(title: "Preview · \(preview.count) matches", subtitle: "Scanned \(preview.scanned) stored events · sampled results") {
                    if preview.events.isEmpty { Text("No matching events in this preview.").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary) }
                    ForEach(preview.events.prefix(20)) { event in
                        Text("\(event.timestamp) · \(event.normalized["message"]?.stringValue ?? event.id)").font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder private func detail(_ rule: ThreatRuleRecord) -> some View {
        NativeGroupPanel(title: rule.name, subtitle: "Version \(rule.version) · \(rule.source)") {
            HStack(spacing: 8) {
                ActionButton(title: "Back to rules", icon: "chevron.left") { selected = nil; selectedDetail = nil; selectedDetailRequestID = nil; ruleHitCount = nil; storageEstimate = nil; preview = nil }
                if selectedDetail?.isHistorical == true {
                    ActionButton(title: "Open current rule", icon: "arrow.uturn.backward") { Task { await openCurrentRule() } }.disabled(busy)
                } else if selectedDetail?.canEdit == true {
                    ActionButton(title: "Edit rule", icon: "pencil") { beginEdit(rule) }.disabled(busy)
                }
            }
            if selectedDetail?.isHistorical == true {
                NativeNotice(message: "Historical version \(rule.version). This snapshot is read-only.")
            } else if selectedDetail?.canEdit != true {
                NativeNotice(message: "Read-only view. Your current organization role cannot edit this rule.")
            }
            Text(rule.explanation).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
            Text("\(rule.enabled ? "Enabled" : "Disabled") · \(rule.severity) · \(rule.stage) · \(rule.action) · \(ruleHitCount.map(String.init) ?? "Unavailable") hits")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary)
            if rule.stage == "analyze" && rule.action == "drop" {
                if let storageEstimate {
                    Text("Undropped estimate: \(storageEstimate.count) events · \(storageEstimate.bytes) bytes · checked \(storageEstimate.checkedDate)")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary).textSelection(.enabled)
                } else {
                    Text("Storage estimate: \(storageEstimateStatus.isEmpty ? "Unavailable" : storageEstimateStatus)")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary)
                }
            }
            ForEach(Array(rule.conditions.enumerated()), id: \.offset) { index, condition in
                Text("\(index + 1). \(condition.path) \(condition.operation) \(condition.value)").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
            }
        }
        if let selectedDetail {
            NativeGroupPanel(title: "Audit history · \(selectedDetail.audit.count)", subtitle: "Organization rule changes · newest first") {
                if selectedDetail.audit.isEmpty {
                    Text("No recorded changes for this rule in this organization.")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary)
                }
                ForEach(selectedDetail.audit) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(auditAction(entry.event_type))
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text)
                            if let action = entry.action, !action.isEmpty {
                                Text("· \(action)").font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textSecondary)
                            }
                        }
                        Text("\(entry.actor_id ?? "System") · \(entry.created_at)")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary).textSelection(.enabled)
                        ForEach(auditChangedFields(entry), id: \.key) { change in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(change.key.capitalized).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.textSecondary)
                                if let before = change.before {
                                    Text("Before: \(displayAuditValue(before))")
                                        .font(.system(size: 10, weight: .regular, design: .monospaced)).foregroundStyle(theme.textTertiary).textSelection(.enabled)
                                }
                                if let after = change.after {
                                    Text("After: \(displayAuditValue(after))")
                                        .font(.system(size: 10, weight: .regular, design: .monospaced)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack(spacing: 8) {
                            if let version = auditVersion(entry.before["version"]), version != selectedDetail.rule.version {
                                ActionButton(title: "View version \(version)", icon: "clock.arrow.circlepath") { Task { await openRuleVersion(version) } }.disabled(busy)
                            }
                            if let version = auditVersion(entry.after["version"]), version != selectedDetail.rule.version {
                                ActionButton(title: "View version \(version)", icon: "clock.arrow.circlepath") { Task { await openRuleVersion(version) } }.disabled(busy)
                            }
                        }
                    }
                    .padding(.vertical, 7)
                }
                if selectedDetail.nextOffset != nil {
                    ActionButton(title: loadingOlderAudit ? "Loading older changes…" : "Load older changes", icon: "arrow.down") { Task { await loadOlderAudit() } }
                        .disabled(busy || loadingOlderAudit)
                }
            }
        }
    }

    private func auditAction(_ eventType: String) -> String {
        switch eventType {
        case "event.rule.created": "Rule created"
        case "event.rule.imported": "Rule imported"
        default: "Rule updated"
        }
    }

    private func auditVersion(_ value: ThreatRuleJSON?) -> String? {
        guard let version = value?.stringValue, !version.isEmpty else { return nil }
        return version
    }

    private func auditChangedFields(_ entry: RuleAuditRecord) -> [(key: String, before: ThreatRuleJSON?, after: ThreatRuleJSON?)] {
        Set(entry.before.keys).union(entry.after.keys).sorted().compactMap { key in
            let before = entry.before[key]
            let after = entry.after[key]
            guard before != after else { return nil }
            return (key, before, after)
        }
    }

    private func displayAuditValue(_ value: ThreatRuleJSON) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "Unavailable" }
        return String(text.prefix(1000))
    }

    private func load() async {
        selected = nil
        selectedDetail = nil
        selectedDetailRequestID = nil
        ruleHitCount = nil
        storageEstimate = nil
        storageEstimateStatus = ""
        showingEditor = false
        guard model.hasHanasandAuth, !organizationID.isEmpty, model.settings.selectedOrganizationUserID == model.userIDForRequests else { page = nil; return }
        busy = true; error = ""; status = "Loading \(title.lowercased())"
        defer { busy = false }
        do {
            let value = try await ThreatRulesClient(settings: model.settings).loadRules(category: category)
            guard organizationID == model.selectedOrganizationID, value.organization.id == organizationID else { throw ThreatRulesError.organizationScopeChanged }
            page = value; status = "Loaded \(value.rules.count) rules for \(value.organization.name)."
        } catch { page = nil; self.error = error.localizedDescription }
    }

    private func open(_ rule: ThreatRuleRecord) async {
        busy = true; error = ""; defer { busy = false }
        do {
            let requestID = rule.id.replacingOccurrences(of: #"\.v\d+$"#, with: "", options: .regularExpression)
            let loaded = try await ThreatRulesClient(settings: model.settings).loadRule(id: requestID, organizationID: organizationID)
            guard organizationID == model.selectedOrganizationID else { throw ThreatRulesError.organizationScopeChanged }
            selectedDetail = loaded
            selectedDetailRequestID = requestID
            selected = loaded.rule
            ruleHitCount = loaded.triggerCount
            storageEstimate = nil
            storageEstimateStatus = loaded.isHistorical ? "Unavailable for historical versions" : "Loading estimate…"
            showingEditor = false
        }
        catch { self.error = error.localizedDescription }
    }

    private func openRuleVersion(_ version: String) async {
        guard let selected else { return }
        let id = "\(selected.id.replacingOccurrences(of: #"\.v\d+$"#, with: "", options: .regularExpression)).v\(version)"
        await loadRuleDetail(id: id)
    }

    private func openCurrentRule() async {
        guard let selected else { return }
        await loadRuleDetail(id: selected.id.replacingOccurrences(of: #"\.v\d+$"#, with: "", options: .regularExpression))
    }

    private func loadRuleDetail(id: String, offset: Int = 0, appendAudit: Bool = false) async {
        busy = true
        error = ""
        defer { busy = false }
        do {
            let loaded = try await ThreatRulesClient(settings: model.settings).loadRule(id: id, organizationID: organizationID, offset: offset)
            guard organizationID == model.selectedOrganizationID else { throw ThreatRulesError.organizationScopeChanged }
            if appendAudit, let current = selectedDetail {
                selectedDetail = RuleDetailEnvelope(
                    organizationId: loaded.organizationId,
                    canEdit: current.canEdit,
                    isHistorical: current.isHistorical,
                    rule: current.rule,
                    triggerCount: current.triggerCount,
                    audit: current.audit + loaded.audit,
                    nextOffset: loaded.nextOffset
                )
            } else {
                selectedDetail = loaded
                selectedDetailRequestID = id
                selected = loaded.rule
                ruleHitCount = loaded.triggerCount
                storageEstimate = nil
                storageEstimateStatus = loaded.isHistorical ? "Unavailable for historical versions" : "Loading estimate…"
                showingEditor = false
            }
        } catch let caughtError { error = caughtError.localizedDescription }
    }

    private func loadOlderAudit() async {
        guard let nextOffset = selectedDetail?.nextOffset, let requestID = selectedDetailRequestID else { return }
        loadingOlderAudit = true
        defer { loadingOlderAudit = false }
        await loadRuleDetail(id: requestID, offset: nextOffset, appendAudit: true)
    }

    private func refreshSelectedRuleMetrics() async {
        guard selected != nil, !showingEditor else { return }
        await updateSelectedRuleMetrics()
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard !Task.isCancelled, selected != nil, !showingEditor else { return }
            await updateSelectedRuleMetrics()
        }
    }

    private func updateSelectedRuleMetrics() async {
        guard let selected else { return }
        let client = ThreatRulesClient(settings: model.settings)
        do {
            let hitCount = try await client.loadRuleHitCount(id: selected.id, organizationID: organizationID)
            guard selected.id == self.selected?.id, organizationID == model.selectedOrganizationID else { return }
            ruleHitCount = hitCount
            if selectedDetail?.isHistorical == true {
                storageEstimate = nil
                storageEstimateStatus = "Unavailable for historical versions"
            } else if selected.stage == "analyze" && selected.action == "drop" {
                let estimateValue = try await client.loadRuleStorageEstimate(id: selected.id, organizationID: organizationID)
                guard selected.id == self.selected?.id, organizationID == model.selectedOrganizationID else { return }
                storageEstimate = estimateValue
                storageEstimateStatus = estimateValue == nil ? "Pending" : "Available"
            } else {
                storageEstimate = nil
                storageEstimateStatus = "Not applicable"
            }
            if let current = selectedDetail {
                selectedDetail = RuleDetailEnvelope(organizationId: current.organizationId, canEdit: current.canEdit, isHistorical: current.isHistorical, rule: current.rule, triggerCount: hitCount, audit: current.audit, nextOffset: current.nextOffset)
            }
        } catch {
            guard selected.id == self.selected?.id else { return }
            storageEstimate = nil
            storageEstimateStatus = "Unavailable"
        }
    }

    private func beginNewRule() {
        selected = nil; draftName = ""; draftExplanation = ""; draftSeverity = "medium"; draftEnabled = true
        let stage = category == "analysis" ? "analyze" : category == "detection" ? "detect" : "match"
        draftDefinition = #"{"stage":"\#(stage)","action":"keep","match":"all","conditions":[{"path":"event_type","operator":"equals","value":""}]}"#
        preview = nil; error = ""; showingEditor = true
    }

    private func beginEdit(_ rule: ThreatRuleRecord) {
        selected = rule; draftName = rule.name; draftExplanation = rule.explanation; draftSeverity = rule.severity; draftEnabled = rule.enabled
        if let data = try? JSONEncoder().encode(rule.definition), let object = try? JSONSerialization.jsonObject(with: data), let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), let string = String(data: pretty, encoding: .utf8) { draftDefinition = string }
        preview = nil; error = ""; showingEditor = true
    }

    private func decodeDefinition() throws -> ThreatRuleJSON {
        guard let data = draftDefinition.data(using: .utf8) else { throw ThreatRulesError.invalidInput("Enter a rule definition.") }
        return try JSONDecoder().decode(ThreatRuleJSON.self, from: data)
    }

    private func save() async {
        guard page != nil, canEditDraft else { error = ThreatRulesError.permissionDenied.localizedDescription; return }
        busy = true; error = ""; status = "Saving rule"; defer { busy = false }
        do {
            let saved = try await ThreatRulesClient(settings: model.settings).saveRule(selected, category: category, organizationID: organizationID, name: draftName, explanation: draftExplanation, severity: draftSeverity, enabled: draftEnabled, definition: decodeDefinition())
            guard organizationID == model.selectedOrganizationID else { throw ThreatRulesError.organizationScopeChanged }
            selected = saved; showingEditor = false; status = "Rule saved. Existing events were not reprocessed."; preview = nil
            await load()
            await loadRuleDetail(id: saved.id.replacingOccurrences(of: #"\.v\d+$"#, with: "", options: .regularExpression))
        } catch { self.error = error.localizedDescription }
    }

    private func checkMatches() async {
        busy = true; error = ""; defer { busy = false }
        do {
            let definition = try decodeDefinition()
            let from = ISO8601DateFormatter().string(from: previewFrom)
            let until = ISO8601DateFormatter().string(from: .now)
            preview = try await ThreatRulesClient(settings: model.settings).preview(definition: definition, organizationID: organizationID, from: from, until: until)
        } catch { self.error = error.localizedDescription }
    }
}

struct ThreatRuleTuningNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var access: TuningAccess?
    @State private var snapshot: ThreatRuleTuningSnapshot?
    @State private var rules: [ThreatRuleSummary] = []
    @State private var status = ""
    @State private var error = ""
    @State private var busy = false
    @State private var sort = "event_count"
    @State private var descending = true
    @State private var query = ""
    @State private var tuningPattern: ThreatRuleTuningPattern?
    @State private var tuningName = ""
    @State private var tuningExplanation = ""
    @State private var tuningPreview: StoredRulePreview?
    @State private var confirmCreate = false
    @State private var tuningRule: ThreatRuleRecord?
    @State private var reprocessing: ThreatRuleReprocessState?
    @State private var reprocessPreview: StoredRulePreview?
    @State private var confirmReprocess = false
    @State private var cancelJob: ThreatRuleReprocessJob?

    private var client: ThreatRulesClient { ThreatRulesClient(settings: model.settings) }
    private var patterns: [ThreatRuleTuningPattern] {
        let filtered = (snapshot?.logs ?? []).filter { query.isEmpty || "\($0.message) \($0.ip) \($0.userAgent)".localizedCaseInsensitiveContains(query) }
        return filtered.sorted { left, right in
            let ascending: Bool
            switch sort {
            case "message": ascending = left.message.localizedStandardCompare(right.message) == .orderedAscending
            case "ip": ascending = left.ip.localizedStandardCompare(right.ip) == .orderedAscending
            case "user_agent": ascending = left.userAgent.localizedStandardCompare(right.userAgent) == .orderedAscending
            case "storage_bytes": ascending = (Double(left.storageBytes) ?? 0) < (Double(right.storageBytes) ?? 0)
            default: ascending = (Double(left.eventCount) ?? 0) < (Double(right.eventCount) ?? 0)
            }
            return descending ? !ascending : ascending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NativeGroupPanel(title: "Rule tuning", subtitle: "Stored logs · fixed Hanasand workspace") {
                HStack(spacing: 8) {
                    ActionButton(title: "Refresh", icon: "arrow.clockwise") { Task { await load() } }.disabled(busy)
                    ActionButton(title: busy ? "Refreshing…" : "Refresh summary", icon: "chart.bar.xaxis") { Task { await refreshSummary() } }.disabled(busy || access?.canWrite != true)
                }
                if !error.isEmpty { Text(error).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.danger).textSelection(.enabled) }
                if !status.isEmpty { Text(status).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary).textSelection(.enabled) }
                if access != nil && access?.canWrite != true { NativeNotice(message: "Read-only view. Changes require active Hanasand owner or editor access in your own account.") }
                Text("Snapshot: \(snapshot?.generatedAt ?? "not available") · \(snapshot?.pending == true ? "preparing" : snapshot?.refreshing == true ? "refreshing" : "stored summary")")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary).textSelection(.enabled)
            }
            if access != nil {
                NativeGroupPanel(title: "Stored log patterns", subtitle: "Up to 100 patterns from a 1% page sample; counts and row bytes are estimates") {
                    TextField("Filter message, IP, or user agent", text: $query).textFieldStyle(.roundedBorder)
                    HStack {
                        Picker("Sort by", selection: $sort) { Text("Event count").tag("event_count"); Text("Storage bytes").tag("storage_bytes"); Text("Message").tag("message"); Text("IP").tag("ip"); Text("User agent").tag("user_agent") }.frame(maxWidth: 210)
                        ActionButton(title: descending ? "Descending" : "Ascending", icon: "arrow.up.arrow.down") { descending.toggle() }
                    }
                    if patterns.isEmpty { NativeEmptyState(title: snapshot == nil ? "Loading log summary" : "No stored log patterns", message: "Refresh the summary to load the latest sampled patterns.") }
                    ForEach(patterns.prefix(100)) { pattern in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(pattern.message).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text).textSelection(.enabled)
                            Text("IP: \(pattern.ip.isEmpty ? "Not recorded" : pattern.ip) · User agent: \(pattern.userAgent.isEmpty ? "Not recorded" : pattern.userAgent)")
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                            Text("Estimated count: \(pattern.eventCount) · 24h: \(pattern.last24hCount) · estimated bytes: \(pattern.storageBytes) · last seen: \(pattern.lastTriggered ?? "Not recorded")")
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary).textSelection(.enabled)
                            ActionButton(title: "Tune this pattern", icon: "slider.horizontal.3") {
                                tuningPattern = pattern
                                tuningName = String("Suppress: \(pattern.message)".prefix(120))
                                tuningExplanation = "Suppress this repeated stored log pattern using the message and available IP and user agent fields."
                                tuningPreview = nil
                            }.disabled(access?.canWrite != true || busy)
                        }.padding(.vertical, 6)
                    }
                }
                if let pattern = tuningPattern {
                    NativeGroupPanel(title: "Tune stored pattern", subtitle: "Analyze · Drop · Hanasand workspace") {
                        Text("Pattern: \(pattern.message)").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                        TextField("Rule name", text: $tuningName).textFieldStyle(.roundedBorder).disabled(busy || access?.canWrite != true)
                        TextField("Description", text: $tuningExplanation, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder).disabled(busy || access?.canWrite != true)
                        HStack(spacing: 8) {
                            ActionButton(title: busy ? "Checking…" : "Preview stored matches", icon: "checkmark.magnifyingglass") { Task { await previewPattern(pattern) } }.disabled(busy || access?.canWrite != true)
                            ActionButton(title: "Cancel", icon: "xmark") { tuningPattern = nil; tuningPreview = nil }.disabled(busy)
                        }
                        if let tuningPreview {
                            Text("\(tuningPreview.count) estimated matches · \(tuningPreview.scanned) stored events scanned · \(tuningPreview.bytes) estimated bytes")
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary)
                            ForEach(tuningPreview.events.prefix(20)) { event in
                                Text("\(event.timestamp) · \(event.normalized["message"]?.stringValue ?? event.id)").font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                            }
                            ActionButton(title: "Review and create rule", icon: "checkmark") { confirmCreate = true }.disabled(busy || access?.canWrite != true)
                        }
                    }
                }
                NativeGroupPanel(title: "Saved custom rules", subtitle: "Hanasand workspace rules") {
                    ForEach(rules) { rule in
                        HStack {
                            Text("\(rule.name) · \(rule.enabled ? "Enabled" : "Disabled") · \(rule.stage) · \(rule.action)")
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                            ActionButton(title: "Review", icon: "arrow.right") { Task { await openTuningRule(rule) } }.disabled(busy)
                        }
                    }
                    if rules.isEmpty { Text("No saved custom rules.").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary) }
                }
                if let rule = tuningRule {
                    NativeGroupPanel(title: rule.name, subtitle: "Version \(rule.version) · \(rule.stage) · \(rule.action) · \(rule.enabled ? "Enabled" : "Disabled")") {
                        Text(rule.explanation).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                        ForEach(Array(rule.conditions.enumerated()), id: \.offset) { index, condition in
                            Text("\(index + 1). \(condition.path) \(condition.operation) \(condition.value)").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                        }
                        HStack(spacing: 8) {
                            ActionButton(title: "Refresh job status", icon: "arrow.clockwise") { Task { await refreshReprocessing(rule) } }.disabled(busy)
                            if rule.enabled && rule.stage == "analyze" && rule.action == "drop" {
                                ActionButton(title: "Preview stored logs", icon: "checkmark.magnifyingglass") { Task { await previewSavedRule(rule) } }.disabled(busy)
                            }
                            ActionButton(title: "Close", icon: "xmark") { tuningRule = nil; reprocessing = nil; reprocessPreview = nil }.disabled(busy)
                        }
                        if let reprocessPreview {
                            NativeNotice(message: "Preview: \(reprocessPreview.count) estimated matches · \(reprocessPreview.scanned) stored events scanned · \(reprocessPreview.bytes) estimated bytes. This is a sample and can change before processing.")
                            ForEach(reprocessPreview.events.prefix(20)) { event in
                                Text("\(event.timestamp) · \(event.normalized["message"]?.stringValue ?? event.id)").font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                            }
                            ActionButton(title: "Start reprocessing", icon: "trash") { confirmReprocess = true }.disabled(busy || access?.canWrite != true)
                        }
                        if let reprocessing {
                            if let existing = reprocessing.existing { Text("Current estimate: \(existing.count) matching events · \(existing.bytes) bytes.").font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary) }
                            ForEach(reprocessing.jobs) { job in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(job.status.capitalized) · \(job.matched) matched · \(job.removedEvents) events removed · \(job.removedSources) sources removed")
                                        .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                                    if !["queued", "running"].contains(job.status), let message = job.error, !message.isEmpty { Text(message).font(.system(size: 10, weight: .medium)).foregroundStyle(theme.danger).textSelection(.enabled) }
                                    if ["queued", "running"].contains(job.status) { ActionButton(title: "Stop run", icon: "stop.fill") { cancelJob = job }.disabled(busy || access?.canWrite != true) }
                                }.padding(.vertical, 4)
                            }
                        }
                    }
                }
            } else if !model.hasHanasandAuth { NativeEmptyState(title: "Sign in required", message: "Sign in to review Hanasand stored-log tuning.") }
        }
        .task(id: "\(model.userIDForRequests):\(model.settings.impersonatingUserID)") { await load() }
        .confirmationDialog("Create Analyze drop rule?", isPresented: $confirmCreate, titleVisibility: .visible) {
            Button("Create rule", role: .destructive) { Task { await createTunedRule() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The new rule applies to future events. Existing matching Low logs and originals are unchanged until a separate reprocessing run is confirmed.")
        }
        .confirmationDialog("Reprocess stored logs?", isPresented: $confirmReprocess, titleVisibility: .visible) {
            Button("Start reprocessing", role: .destructive) { Task { await startReprocessing() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The API preview is sampled. This run can permanently remove eligible matching Low log events and originals for the saved rule version \(tuningRule?.version ?? ""). Protected events remain. Review the job status after starting.")
        }
        .confirmationDialog("Stop reprocessing?", isPresented: Binding(get: { cancelJob != nil }, set: { if !$0 { cancelJob = nil } }), titleVisibility: .visible) {
            Button("Stop run", role: .destructive) { guard let rule = tuningRule, let job = cancelJob else { return }; cancelJob = nil; Task { await stopReprocessing(rule, job: job) } }
            Button("Keep running", role: .cancel) { cancelJob = nil }
        } message: { Text("Only a queued or running job can be stopped. Refresh the status if the run has changed.") }
    }

    private func load() async {
        guard model.hasHanasandAuth else { access = nil; error = "Sign in to review stored-log tuning."; return }
        busy = true; error = ""; defer { busy = false }
        do {
            let verified = try await client.tuningAccess()
            async let data = client.loadTuningSnapshot(access: verified)
            async let saved = client.loadTuningRules(access: verified)
            snapshot = try await data; rules = try await saved; access = verified
            status = "Loaded the Hanasand tuning snapshot and \(rules.count) custom rules."
        } catch { access = nil; snapshot = nil; rules = []; self.error = error.localizedDescription }
    }

    private func refreshSummary() async {
        guard let access, access.canWrite else { error = ThreatRulesError.permissionDenied.localizedDescription; return }
        busy = true; error = ""; defer { busy = false }
        do {
            try await client.refreshTuningSnapshot(access: access)
            status = "Summary refresh queued. The current stored snapshot remains visible while it updates."
            try await Task.sleep(for: .seconds(1))
            snapshot = try await client.loadTuningSnapshot(access: access)
        } catch { self.error = error.localizedDescription }
    }

    private func conditions(for pattern: ThreatRuleTuningPattern) -> [ThreatRuleCondition] {
        var values = [ThreatRuleCondition(path: "message", operation: "equals", value: pattern.message, caseSensitive: true)]
        if let range = pattern.message.range(of: #"^failed exec: (\/\S+)$"#, options: .regularExpression) {
            let executable = String(pattern.message[range]).replacingOccurrences(of: "failed exec: ", with: "")
            values += [
                ThreatRuleCondition(path: "metadata.collector", operation: "equals", value: "auditd", caseSensitive: true),
                ThreatRuleCondition(path: "event_type", operation: "equals", value: "process", caseSensitive: true),
                ThreatRuleCondition(path: "action", operation: "equals", value: "exec", caseSensitive: true),
                ThreatRuleCondition(path: "outcome", operation: "equals", value: "failure", caseSensitive: true),
                ThreatRuleCondition(path: "process.executable", operation: "equals", value: executable, caseSensitive: true),
            ]
        }
        if let path = pattern.ipPath, !pattern.ip.isEmpty { values.append(ThreatRuleCondition(path: path, operation: "equals", value: pattern.ip, caseSensitive: true)) }
        if let path = pattern.userAgentPath, !pattern.userAgent.isEmpty { values.append(ThreatRuleCondition(path: path, operation: "equals", value: pattern.userAgent, caseSensitive: true)) }
        return Array(values.prefix(8))
    }

    private func previewPattern(_ pattern: ThreatRuleTuningPattern) async {
        guard let access else { return }
        busy = true; error = ""; tuningPreview = nil; defer { busy = false }
        do {
            let until = ISO8601DateFormatter().string(from: .now)
            tuningPreview = try await client.previewStored(conditions: conditions(for: pattern), action: "drop", access: access, from: nil, until: until)
        } catch { self.error = error.localizedDescription }
    }

    private func createTunedRule() async {
        guard let access, access.canWrite, let pattern = tuningPattern, tuningPreview != nil else { error = ThreatRulesError.permissionDenied.localizedDescription; return }
        busy = true; error = ""; defer { busy = false }
        do {
            let rule = try await client.createTuningRule(access: access, name: tuningName, explanation: tuningExplanation, conditions: conditions(for: pattern))
            rules.insert(ThreatRuleSummary(rule: rule), at: 0); tuningPattern = nil; tuningPreview = nil
            status = "Rule saved as version \(rule.version). Existing events were not reprocessed."
        } catch { self.error = error.localizedDescription }
    }

    private func openTuningRule(_ summary: ThreatRuleSummary) async {
        guard let access else { return }
        busy = true; error = ""; reprocessPreview = nil; reprocessing = nil; defer { busy = false }
        do { tuningRule = try await client.loadTuningRule(id: summary.id, access: access) }
        catch { self.error = error.localizedDescription }
    }

    private func refreshReprocessing(_ rule: ThreatRuleRecord) async {
        guard let access else { return }
        busy = true; error = ""; defer { busy = false }
        do { reprocessing = try await client.loadReprocessing(rule: rule, access: access) }
        catch { self.error = error.localizedDescription }
    }

    private func previewSavedRule(_ rule: ThreatRuleRecord) async {
        guard let access else { return }
        busy = true; error = ""; reprocessPreview = nil; defer { busy = false }
        do {
            let until = ISO8601DateFormatter().string(from: .now)
            reprocessPreview = try await client.previewStored(conditions: rule.conditions, action: rule.action, access: access, from: nil, until: until)
            reprocessing = try await client.loadReprocessing(rule: rule, access: access)
        } catch { self.error = error.localizedDescription }
    }

    private func startReprocessing() async {
        guard let access, let rule = tuningRule, let preview = reprocessPreview else { error = "Refresh the current rule and preview before starting a run."; return }
        busy = true; error = ""; defer { busy = false }
        do {
            let job = try await client.startReprocessing(rule: rule, preview: preview, reviewedVersion: rule.version, access: access)
            status = "Reprocessing job \(job.id) is \(job.status)."
            reprocessing = try await client.loadReprocessing(rule: rule, access: access)
        } catch { self.error = error.localizedDescription }
    }

    private func stopReprocessing(_ rule: ThreatRuleRecord, job: ThreatRuleReprocessJob) async {
        guard let access else { return }
        busy = true; error = ""; defer { busy = false }
        do {
            _ = try await client.cancelReprocessing(rule: rule, job: job, access: access)
            reprocessing = try await client.loadReprocessing(rule: rule, access: access)
            status = "Stop confirmed. The run status was refreshed."
        } catch { self.error = error.localizedDescription }
    }
}
