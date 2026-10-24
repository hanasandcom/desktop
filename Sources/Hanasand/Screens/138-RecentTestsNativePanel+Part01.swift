import AppKit
import ApplicationServices
import Combine
import CryptoKit
import Darwin
import Foundation
import Network
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

extension RecentTestsNativePanel {
    var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)]
    }

    var loadClient: LoadTestingClient? {
        let userID = model.userIDForRequests
        let token = model.authTokenForRequests
        let anonymousClientID = userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.settings.impersonationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.settings.impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? LoadTestingAnonymousIdentity.current() : nil
        return try? LoadTestingClient(
            apiBaseURL: model.settings.apiBaseURL.normalizedBaseURL,
            userID: userID,
            token: token,
            anonymousClientID: anonymousClientID,
            impersonationToken: model.settings.impersonationToken,
            impersonatingUserID: model.settings.impersonatingUserID
        )
    }

    var canSubmit: Bool {
        guard let loadClient, let remaining = quota?.remaining else { return false }
        return loadClient.canWrite && permissionConfirmed && !loading && !busy && !submissionLocked && remaining > 0 && isValidTarget && isValidScenario
    }

    var canRerun: Bool {
        guard let loadClient, let remaining = quota?.remaining else { return false }
        return loadClient.canRerun && permissionConfirmed && !loading && !busy && !submissionLocked && remaining > 0
    }

    var canJoinLive: Bool {
        guard let loadClient else { return false }
        return loadClient.isAuthenticated && loadClient.canRead && loadClient.canWrite && !loading && !busy
            && model.settings.impersonationToken.isEmpty && model.settings.impersonatingUserID.isEmpty
    }

    var isValidTarget: Bool {
        (try? LoadTestingClient.validate(url: targetURL)) != nil
    }

    var currentRows: [DashboardRecentTest] {
        let rows = selectedLane == .mine ? myTests : recentTests
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (rows ?? []).filter { test in
            (selectedStatus == "all" || test.statusLabel.lowercased() == selectedStatus) &&
            (query.isEmpty || "\(test.id) \(test.displayURL) \(test.statusLabel)".lowercased().contains(query))
        }
    }

    var allRows: [DashboardRecentTest] {
        var rows: [String: DashboardRecentTest] = [:]
        for test in (myTests ?? []) + (recentTests ?? []) { rows[test.id] = test }
        return rows.values.sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            overviewCards
            launchPanel
            if let detail = selectedTest { selectedTestPanel(detail) }
            historyPanel
        }
        .task {
            await refresh(manual: false)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { break }
                await refresh(manual: false)
            }
        }
        .task(id: initialTestID) {
            guard let initialTestID, !initialTestID.isEmpty else { return }
            lookupID = initialTestID
            await openResult(id: initialTestID)
        }
        .onDisappear { liveSession.stop() }
        .onChange(of: model.settings.impersonationToken) { _, _ in liveSession.stop() }
        .onChange(of: model.settings.impersonatingUserID) { _, _ in liveSession.stop() }
        .confirmationDialog("Start this load test?", isPresented: $showStartConfirmation, titleVisibility: .visible) {
            Button("I own this endpoint or have written permission · Start", role: .destructive) {
                Task { await createTest() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(targetURL)\n\(selectedScenario.description)\n\(selectedScenario.stages.map { "\($0.duration): \($0.target) users" }.joined(separator: " · "))\n\nThe server queues work immediately. Closing this window will not stop it.")
        }
        .confirmationDialog("Rerun this endpoint check?", isPresented: $showRerunConfirmation, titleVisibility: .visible) {
            Button("I have permission · Queue rerun", role: .destructive) {
                if let selectedTest { Task { await rerun(selectedTest) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(selectedTest?.displayURL ?? "")\nThis uses the saved traffic configuration and adds a run to the server queue.")
        }
        .confirmationDialog("Join public live output?", isPresented: $showLiveJoinConfirmation, titleVisibility: .visible) {
            Button("Join public stream", role: .destructive) {
                guard let selectedTest, canJoinLive, let client = loadClient else { return }
                liveSession.join(
                    apiBaseURL: model.settings.apiBaseURL.normalizedBaseURL,
                    id: selectedTest.id,
                    reviewed: true,
                    hasAuth: client.isAuthenticated,
                    canWrite: client.canWrite,
                    isImpersonating: !model.settings.impersonationToken.isEmpty || !model.settings.impersonatingUserID.isEmpty
                )
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This stream is public and sends no account credentials. Joining can start the server’s global queued load-test runner. It does not create a new test. It will not reconnect automatically.")
        }
    }

    var overviewCards: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            FeatureCard(title: "Loaded tests", value: "\(allRows.count)", icon: "speedometer")
            FeatureCard(title: "Queued", value: "\(allRows.filter { $0.statusLabel.lowercased() == "queued" }.count)", icon: "clock")
            FeatureCard(title: "Running", value: "\(allRows.filter { $0.statusLabel.lowercased() == "running" }.count)", icon: "waveform.path.ecg")
            FeatureCard(title: "Failed", value: "\(allRows.filter { ["failed", "error"].contains($0.statusLabel.lowercased()) }.count)", icon: "exclamationmark.triangle")
        }
    }

    var launchPanel: some View {
        NativeGroupPanel(title: "Check an endpoint you control", subtitle: "Permission-gated · traffic is queued by the Hanasand service") {
            if model.settings.impersonationToken.isEmpty == false || model.settings.impersonatingUserID.isEmpty == false {
                NativeNotice(message: "Load generation is read-only while impersonating. Switch back to your own account to start or rerun checks.", title: "Read-only")
            } else if loadClient?.canRead != true {
                NativeNotice(message: model.hasHanasandAuth ? "The configured API address is invalid or insecure." : "Sign in to inspect your own checks, recent checks, and usage allowance.", title: model.hasHanasandAuth ? "API unavailable" : "Sign-in required")
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    testField("Endpoint URL", text: $targetURL, placeholder: "https://api.example.com/health")
                    scenarioPicker
                    startCheckButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    testField("Endpoint URL", text: $targetURL, placeholder: "https://api.example.com/health")
                    HStack(spacing: 10) {
                        scenarioPicker
                        startCheckButton
                    }
                }
            }
            Text("\(selectedScenario.description) · \(selectedScenario.timeout)s timeout · \(selectedScenario.stages.map { "\($0.duration):\($0.target)" }.joined(separator: ", "))")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    testField("Timeout seconds", text: $timeoutDraft, placeholder: "30")
                        .frame(maxWidth: 180)
                    testField("Stages · duration:users", text: $stagesDraft, placeholder: "30s:5, 1m:15")
                }
                VStack(alignment: .leading, spacing: 8) {
                    testField("Timeout seconds", text: $timeoutDraft, placeholder: "30")
                    testField("Stages · duration:users", text: $stagesDraft, placeholder: "30s:5, 1m:15")
                }
            }
            .disabled(selectedScenarioID != LoadTestingScenario.customID)
            if selectedScenarioID == LoadTestingScenario.customID && !isValidScenario {
                Text("Use 1–8 stages in duration:users format, 0–100 users per stage, 10 minutes total, and a timeout from 1–120 seconds.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.danger)
            }

            Toggle(isOn: $permissionConfirmed) {
                Text("I own this endpoint or have written permission to generate this traffic.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
            }
            .toggleStyle(.checkbox)
            .disabled(loading || busy || submissionLocked || loadClient?.canWrite != true)
            if !targetURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isValidTarget {
                Text("Enter a valid HTTP or HTTPS endpoint without embedded credentials.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.danger)
            }

            if let quota {
                HStack(spacing: 8) {
                    FeatureCard(title: "Plan", value: quota.plan.capitalized, icon: "person.crop.circle")
                    FeatureCard(title: "Allowance", value: "\(quota.used) / \(quota.limit)", icon: "gauge.with.dots.needle.50percent")
                    FeatureCard(title: "Remaining", value: "\(quota.remaining)", icon: "checkmark.circle")
                }
                if quota.remaining == 0 {
                    NativeNotice(message: "The server reports no checks remaining for this plan. Refresh after the allowance resets or changes.", title: "Allowance used")
                }
            } else if loadClient?.canRead == true {
                Text("Usage allowance unavailable. Refresh to retry.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            }

            if submissionLocked {
                NativeNotice(message: "A previous request may have reached the server. Refresh stored results and review them before submitting again. Requests are not retried automatically.", title: "Submission locked")
            }
            if !errorMessage.isEmpty { NativeNotice(message: errorMessage, title: "Load testing") }
            if !noticeMessage.isEmpty { NativeNotice(message: noticeMessage, title: "Load testing") }
        }
    }

    var historyPanel: some View {
        NativeGroupPanel(title: "Run management", subtitle: "Stored results from your account or the public recent lane.") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    historyLanePicker
                    SearchFieldRow(placeholder: "Search URL, ID, or status", text: $searchText)
                    refreshHistoryButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    historyLanePicker
                    HStack(spacing: 8) {
                        SearchFieldRow(placeholder: "Search URL, ID, or status", text: $searchText)
                        refreshHistoryButton
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(statuses, id: \.self) { status in
                        FilterChip(title: status.capitalized, active: selectedStatus == status) { selectedStatus = status }
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("Look up test ID", text: $lookupID)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .padding(10)
                    .background(theme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                ActionButton(title: "Open result", icon: "doc.text.magnifyingglass") { Task { await openResult(id: lookupID) } }
                    .disabled(loading || busy || loadClient?.canRead != true)
            }
            if loading { ProgressView("Loading stored checks…").controlSize(.small) }
            let available = selectedLane == .mine ? myTests : recentTests
            let laneError = selectedLane == .mine ? myError : recentError
            if let laneError, !laneError.isEmpty {
                NativeNotice(message: laneError, title: selectedLane.title)
            } else if available == nil {
                NativeEmptyState(title: "Tests not loaded", message: loadClient?.canRead == true ? "Refresh stored results to try again." : "Sign in to load this history.")
            } else if currentRows.isEmpty {
                NativeEmptyState(title: searchText.isEmpty && selectedStatus == "all" ? "No tests in this history" : "No matching tests", message: searchText.isEmpty && selectedStatus == "all" ? "New checks and recent runs will appear here." : "Adjust the search or status filter.")
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(currentRows) { test in testCard(test) }
                }
            }
        }
    }

    private var scenarioPicker: some View {
        Picker("Scenario", selection: Binding(get: { selectedScenarioID }, set: { selectScenario($0) })) {
            Text("Custom").tag(LoadTestingScenario.customID)
            ForEach(LoadTestingScenario.all) { scenario in Text(scenario.title).tag(scenario.id) }
        }
        .pickerStyle(.menu)
        .frame(width: 132)
    }

    private var startCheckButton: some View {
        ActionButton(title: busy ? "Starting…" : "Start check", icon: "play.circle") {
            guard canSubmit else { return }
            showStartConfirmation = true
        }
        .disabled(!canSubmit)
    }

    private var historyLanePicker: some View {
        Picker("History", selection: Binding(get: { selectedLane }, set: { selectedLane = $0; selectedStatus = "all" })) {
            ForEach(LoadTestingLane.allCases) { lane in Text(lane.title).tag(lane) }
        }
        .pickerStyle(.segmented)
    }

    private var refreshHistoryButton: some View {
        ActionButton(title: "Refresh", icon: "arrow.clockwise") { Task { await refresh(manual: true) } }
            .disabled(loading || busy || loadClient?.canRead != true)
    }

    func testField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 10, weight: .black)).foregroundStyle(theme.textTertiary).textCase(.uppercase)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.text)
                .padding(11)
                .background(theme.field)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    var selectedScenario: LoadTestingScenario {
        if selectedScenarioID == LoadTestingScenario.customID {
            return LoadTestingScenario(id: LoadTestingScenario.customID, title: "Custom", description: "Custom traffic profile", timeout: Int(timeoutDraft) ?? 0, stages: parsedStages)
        }
        return LoadTestingScenario.all.first(where: { $0.id == selectedScenarioID }) ?? LoadTestingScenario.all[0]
    }

    var parsedStages: [LoadTestStagePayload] {
        stagesDraft.split(separator: ",", omittingEmptySubsequences: false).compactMap { segment in
            let pieces = segment.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard pieces.count == 2, let target = Int(pieces[1]) else { return nil }
            return LoadTestStagePayload(duration: pieces[0], target: target)
        }
    }

    var isValidScenario: Bool {
        guard selectedScenarioID == LoadTestingScenario.customID else { return true }
        guard let timeout = Int(timeoutDraft), (1...120).contains(timeout),
              !parsedStages.isEmpty, parsedStages.count <= 8,
              stagesDraft.split(separator: ",", omittingEmptySubsequences: false).count == parsedStages.count,
              parsedStages.allSatisfy(LoadTestingClient.validStage) else { return false }
        return parsedStages.compactMap { LoadTestingClient.durationSeconds($0.duration) }.reduce(0, +) <= 600
    }

    func selectScenario(_ id: String) {
        selectedScenarioID = id
        guard let scenario = LoadTestingScenario.all.first(where: { $0.id == id }) else { return }
        timeoutDraft = String(scenario.timeout)
        stagesDraft = scenario.stages.map { "\($0.duration):\($0.target)" }.joined(separator: ", ")
    }

    func refresh(manual: Bool) async {
        guard !busy, !loading else { return }
        guard let client = loadClient, client.canRead else {
            if !loading {
                errorMessage = model.hasHanasandAuth ? "The API address is invalid or insecure." : "Sign in to inspect load tests."
            }
            return
        }
        loading = true
        if manual { errorMessage = "" }
        defer { loading = false }
        async let mineResult = capture { try await client.history(.mine) }
        async let recentResult = capture { try await client.history(.recent) }
        async let quotaResult = capture { try await client.quota() }
        let (mineResponse, recentResponse, quotaResponse) = await (mineResult, recentResult, quotaResult)
        let detailResponse: Result<DashboardRecentTest, Error>?
        if let selectedTest { detailResponse = await capture { try await client.result(id: selectedTest.id) } }
        else { detailResponse = nil }
        var failures: [String] = []
        switch mineResponse { case .success(let value): myTests = value; myError = nil; case .failure(let error): myError = error.localizedDescription; failures.append("My tests: \(error.localizedDescription)") }
        switch recentResponse { case .success(let value): recentTests = value; recentError = nil; case .failure(let error): recentError = error.localizedDescription; failures.append("Recent tests: \(error.localizedDescription)") }
        switch quotaResponse { case .success(let value): quota = value; case .failure(let error): quota = nil; failures.append("Allowance: \(error.localizedDescription)") }
        if let detailResponse {
            switch detailResponse { case .success(let value): selectedTest = value; case .failure(let error): failures.append("Selected test: \(error.localizedDescription)") }
        }
        errorMessage = failures.joined(separator: "\n")
        let authFailure = failures.contains { $0.contains("401") || $0.localizedCaseInsensitiveContains("access could not be verified") }
        if authFailure { submissionLocked = true }
        if manual && failures.isEmpty { submissionLocked = false; noticeMessage = "Stored results and usage allowance refreshed." }
    }

    func openResult(id: String) async {
        guard let client = loadClient, client.canRead else { errorMessage = "Sign in to open a test result."; return }
        if liveSession.testID != nil && liveSession.testID != id { liveSession.stop() }
        loading = true; errorMessage = ""; noticeMessage = ""
        defer { loading = false }
        do { selectedTest = try await client.result(id: id.trimmingCharacters(in: .whitespacesAndNewlines)); lookupID = selectedTest?.id ?? id }
        catch { errorMessage = error.localizedDescription; if let clientError = error as? LoadTestingClientError, clientError.isUncertain { submissionLocked = true } }
    }

    func createTest() async {
        guard permissionConfirmed, canSubmit, let client = loadClient else { return }
        liveSession.stop()
        busy = true; errorMessage = ""; noticeMessage = ""; submissionLocked = true
        defer { busy = false }
        do {
            let created = try await client.create(url: targetURL, scenario: selectedScenario)
            selectedTest = created; lookupID = created.id; targetURL = ""; permissionConfirmed = false
            noticeMessage = "Test queued. The server starts the requested traffic automatically; no second run was submitted."
            busy = false
            await refresh(manual: false)
            submissionLocked = false
        } catch {
            errorMessage = error.localizedDescription
            if let clientError = error as? LoadTestingClientError, let nextQuota = clientError.quota { quota = nextQuota }
            let shouldLock = (error as? LoadTestingClientError).map { $0.isUncertain || (clientErrorStatus($0) == 401 || clientErrorStatus($0) == 403) } ?? true
            submissionLocked = shouldLock
        }
    }

    func rerun(_ test: DashboardRecentTest) async {
        guard permissionConfirmed, canSubmit, let client = loadClient,
              !["queued", "running"].contains(test.statusLabel.lowercased()) else { return }
        liveSession.stop()
        busy = true; errorMessage = ""; noticeMessage = ""; submissionLocked = true
        defer { busy = false }
        do {
            try await client.rerun(id: test.id)
            noticeMessage = "Rerun queued. Refresh stored results to review its latest status."
            busy = false
            await refresh(manual: false)
            submissionLocked = false
        } catch {
            errorMessage = error.localizedDescription
            let clientError = error as? LoadTestingClientError
            submissionLocked = clientError?.isUncertain == true || clientError.map { clientErrorStatus($0) == 401 || clientErrorStatus($0) == 403 } == true
        }
    }

    func clientErrorStatus(_ error: LoadTestingClientError) -> Int? {
        if case .http(let status, _, _) = error { return status }
        return nil
    }

    func capture<T>(_ operation: @escaping () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }
}
