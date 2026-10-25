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

private enum ThreatResultSection: String, CaseIterable {
    case activity = "Recent activity"
    case sources = "Sources"
    case techniques = "Techniques"
    case targets = "Targets"
}

private struct ThreatSearchRequest: Equatable {
    let id: UUID
    let query: String
    let refresh: Bool
    let scope: ThreatIntelligenceSearchScope
}

private struct ThreatSearchTaskKey: Equatable {
    let requestID: UUID?
    let scope: ThreatIntelligenceSearchScope
    let isActive: Bool
}

enum ThreatIntelligenceRouteSearch {
    static func initialQuery(path: String?, detailID: String, query: String? = nil) -> String? {
        guard path == "/ti" else { return nil }
        let detail = detailID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty { return detail }
        let routeQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return routeQuery.isEmpty ? nil : routeQuery
    }

    static func panelInitialQuery(routeInitialQuery: String?, path: String?, detailID: String, query: String? = nil) -> String? {
        let routed = routeInitialQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !routed.isEmpty { return routed }
        return initialQuery(path: path, detailID: detailID, query: query)
    }
}

struct ThreatIntelligenceNativePanel: View {
    let initialQuery: String?
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @State private var section: ThreatResultSection = .activity
    @State private var removingSearch: String?
    @State private var searchRequest: ThreatSearchRequest?
    @State private var viewIsVisible = false
    @State private var autoRefreshNotice: String?

    init(initialQuery: String? = nil) {
        self.initialQuery = initialQuery
    }

    private var routeSearchQuery: String? {
        ThreatIntelligenceRouteSearch.panelInitialQuery(
            routeInitialQuery: initialQuery,
            path: model.selectedDashboardPath,
            detailID: model.selectedNativeDashboardDetailID,
            query: model.selectedNativeDashboardQuery["q"]
        )
    }

    private var result: ThreatIntelSearchResult? { model.threatSearchResult }
    private var currentSearchScope: ThreatIntelligenceSearchScope { model.threatIntelligenceSearchScope }
    private var searchTaskKey: ThreatSearchTaskKey {
        ThreatSearchTaskKey(
            requestID: searchRequest?.id,
            scope: currentSearchScope,
            isActive: viewIsVisible && scenePhase == .active
        )
    }
    private var rowsRemaining: Int {
        guard let result else { return 0 }
        switch section {
        case .activity: return result.activity.count
        case .sources: return result.sources.count
        case .techniques: return result.techniques.count
        case .targets: return result.targets.count
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NativeGroupPanel(title: "Threat intelligence search", subtitle: "Search actor, domain, CVE, or organization evidence") {
                TextField("Actor, domain, CVE, or organization", text: $model.threatSearchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { beginSearch(query: model.threatSearchQuery) }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        searchButton
                        clearButton
                        if model.isLoadingThreatSearch { ProgressView().controlSize(.small) }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        searchButton
                        clearButton
                        if model.isLoadingThreatSearch { ProgressView().controlSize(.small) }
                    }
                }
                if !model.threatSearchStatus.isEmpty { Text(model.threatSearchStatus).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary).textSelection(.enabled) }
            }

            NativeGroupPanel(title: "Saved searches", subtitle: "Saved to your Hanasand account") {
                if !model.hasHanasandAuth {
                    Text("Public searches are available without an account. Sign in to save searches to your account.")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                    ActionButton(title: "Sign in to manage saved searches", icon: "person.crop.circle", expands: true) {
                        model.openNativeDashboard(path: "/login", label: "Sign in", query: ["next": "/ti"])
                    }
                } else {
                    if !model.threatSavedSearchStatus.isEmpty { Text(model.threatSavedSearchStatus).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary) }
                    if model.threatSavedSearches.isEmpty {
                        Text("Save a search to find it on your account later.").font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(model.threatSavedSearches) { item in
                                HStack(spacing: 6) {
                                    Button(item.query) {
                                        beginSearch(query: item.query)
                                    }
                                    .buttonStyle(.bordered)
                                    Button { removingSearch = item.query } label: { Image(systemName: "xmark.circle") }
                                        .buttonStyle(.plain).help("Remove saved search")
                                        .disabled(model.isMutatingThreatSavedSearch || !model.settings.impersonationToken.isEmpty)
                                }
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        ActionButton(title: model.isMutatingThreatSavedSearch ? "Saving…" : "Save current search", icon: "bookmark") {
                            Task { await model.changeThreatSavedSearch(result?.query ?? model.threatSearchQuery, save: true) }
                        }
                        .disabled(model.isMutatingThreatSavedSearch || model.isLoadingThreatSearch || result == nil || !model.settings.impersonationToken.isEmpty || !model.settings.impersonatingUserID.isEmpty)
                        ActionButton(title: "Refresh saved searches", icon: "arrow.clockwise") { Task { await model.loadThreatSavedSearches() } }
                            .disabled(model.isMutatingThreatSavedSearch)
                    }
                }
            }

            if let result { resultView(result) }
            else if !model.hasHanasandAuth {
                NativeEmptyState(title: "Search public threat intelligence", message: "Enter a query above to search source-backed activity without an account.")
            } else if !model.isLoadingThreatSearch {
                NativeEmptyState(title: "Search for threat intelligence", message: "Search the Hanasand intelligence catalogue and review source-backed activity.")
            }
        }
        .onAppear {
            viewIsVisible = true
            if let query = routeSearchQuery { beginSearch(query: query) }
        }
        .onDisappear {
            viewIsVisible = false
            stopAutomaticRefresh(notice: nil)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                stopAutomaticRefresh(notice: "Automatic refresh stopped while the app is inactive. Select Refresh result to continue.")
            }
        }
        .onChange(of: currentSearchScope) { _, _ in
            stopAutomaticRefresh(notice: nil)
            model.threatSearchResult = nil
            model.threatSearchStatus = ""
            if viewIsVisible, scenePhase == .active, let query = routeSearchQuery { beginSearch(query: query) }
        }
        .onChange(of: model.threatSearchQuery) { _, query in
            let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let request = searchRequest, normalized != request.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                stopAutomaticRefresh(notice: nil)
            }
            if let result, normalized != result.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                model.threatSearchResult = nil
            }
        }
        .task(id: searchTaskKey) {
            guard let request = searchRequest,
                  request.scope == currentSearchScope,
                  viewIsVisible, scenePhase == .active else { return }
            await searchAndRefresh(request)
        }
        .confirmationDialog("Remove saved search?", isPresented: Binding(get: { removingSearch != nil }, set: { if !$0 { removingSearch = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                guard let query = removingSearch else { return }
                removingSearch = nil
                Task { await model.changeThreatSavedSearch(query, save: false) }
            }
            Button("Cancel", role: .cancel) { removingSearch = nil }
        } message: { Text(removingSearch ?? "") }
    }

    private var searchButton: some View {
        ActionButton(title: model.isLoadingThreatSearch ? "Searching…" : "Search", icon: "magnifyingglass") {
            beginSearch(query: model.threatSearchQuery)
        }
        .disabled(model.isLoadingThreatSearch || model.threatSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
    }

    private var clearButton: some View {
        ActionButton(title: "Clear", icon: "xmark") {
            stopAutomaticRefresh(notice: nil)
            model.threatSearchQuery = ""
            model.threatSearchResult = nil
            model.threatSearchStatus = ""
            model.threatSearchResultLimit = 20
        }
    }

    private func beginSearch(query rawQuery: String, refresh: Bool = false) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...200).contains(query.count) else {
            model.threatSearchStatus = "Enter a search between 2 and 200 characters."
            return
        }
        if searchRequest != nil { stopAutomaticRefresh(notice: nil) }
        model.threatSearchQuery = query
        autoRefreshNotice = nil
        searchRequest = ThreatSearchRequest(id: UUID(), query: query, refresh: refresh, scope: currentSearchScope)
    }

    private func stopAutomaticRefresh(notice: String?) {
        if searchRequest != nil { model.cancelThreatIntelligenceSearch() }
        searchRequest = nil
        autoRefreshNotice = notice
    }

    @MainActor
    private func searchAndRefresh(_ request: ThreatSearchRequest) async {
        var budget = ThreatSearchPollingBudget(query: request.query, scope: request.scope)
        guard await model.searchThreatIntelligence(refresh: request.refresh, expectedScope: request.scope),
              isCurrent(request) else { return }

        while isCurrent(request), let result = model.threatSearchResult {
            guard let delay = budget.nextIntervalSeconds(
                resultQuery: result.query,
                resultStatus: result.status,
                refreshAfterSeconds: result.refreshAfterSeconds,
                currentQuery: model.threatSearchQuery,
                currentScope: currentSearchScope
            ) else {
                if !ThreatSearchPollingBudget.isTerminalStatus(result.status) {
                    autoRefreshNotice = budget.remainingRefreshes == 0
                        ? "Automatic refresh paused after \(ThreatSearchPollingBudget.maximumRefreshes) attempts. Select Refresh result to try again."
                        : "This search is still processing. Select Refresh result to check again."
                }
                return
            }

            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard isCurrent(request) else { return }
            autoRefreshNotice = "Checking for updated threat evidence…"
            guard await model.searchThreatIntelligence(refresh: true, expectedScope: request.scope),
                  isCurrent(request) else {
                if isCurrent(request) {
                    autoRefreshNotice = "Automatic refresh failed. Select Refresh result to try again."
                }
                return
            }
            autoRefreshNotice = nil
        }
    }

    private func isCurrent(_ request: ThreatSearchRequest) -> Bool {
        !Task.isCancelled && searchRequest?.id == request.id &&
            request.scope == currentSearchScope && viewIsVisible && scenePhase == .active &&
            request.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ==
                model.threatSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    @ViewBuilder private func resultView(_ result: ThreatIntelSearchResult) -> some View {
        NativeGroupPanel(title: result.query, subtitle: "\(result.status.replacingOccurrences(of: "_", with: " ").capitalized)\(result.generatedAt.isEmpty ? "" : " · \(result.generatedAt)")") {
            if result.catalogOnly {
                NativeNotice(message: "Catalog identity only. Recent activity evidence is not available for this match.")
            }
            if !result.summary.isEmpty { Text(result.summary).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.textSecondary).textSelection(.enabled) }
            if !result.aliases.isEmpty { Text("Also known as: \(result.aliases.joined(separator: ", "))").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary).textSelection(.enabled) }
            if let confidence = result.confidence { Text("Confidence: \(Int((confidence * 100).rounded()))%").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textTertiary) }
            ForEach(result.candidates) { candidate in
                VStack(alignment: .leading, spacing: 5) {
                    Text(candidate.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                    Text(candidate.description).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                    if !candidate.aliases.isEmpty { Text("Aliases: \(candidate.aliases.joined(separator: ", "))").font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary) }
                    if candidate.url != nil { ActionButton(title: "Open candidate source", icon: "arrow.up.right.square") { model.openThreatEvidence(candidate.url) } }
                }
            }
            ForEach(Array(result.notes.enumerated()), id: \.offset) { _, note in Text(note).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary).textSelection(.enabled) }
            HStack(spacing: 8) {
                ActionButton(title: "Refresh result", icon: "arrow.clockwise") {
                    beginSearch(query: result.query, refresh: true)
                }
                    .disabled(model.isLoadingThreatSearch)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { resultSectionFilters(result) }
                    VStack(alignment: .leading, spacing: 8) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) { resultSectionFilters(result) }
                        }
                    }
                }
            }
            if let autoRefreshNotice { Text(autoRefreshNotice).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary) }
        }

        NativeGroupPanel(title: section.rawValue, subtitle: "Showing \(min(rowsRemaining, model.threatSearchResultLimit)) of \(rowsRemaining)") {
            if rowsRemaining == 0 {
                Text("No \(section.rawValue.lowercased()) returned for this result.").font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textTertiary)
            } else {
                switch section {
                case .activity:
                    ForEach(Array(result.activity.prefix(model.threatSearchResultLimit).enumerated()), id: \.offset) { _, item in
                        record(title: item.title, subtitle: [item.date, item.reviewState, item.corroboration].filter { !$0.isEmpty }.joined(separator: " · "), detail: item.detail, sourceIDs: item.sourceIDs, url: item.url)
                    }
                case .sources:
                    ForEach(Array(result.sources.prefix(model.threatSearchResultLimit)) ) { item in
                        record(title: item.name.isEmpty ? item.id : item.name, subtitle: [item.type, item.collectedAt].filter { !$0.isEmpty }.joined(separator: " · "), detail: item.provenance, sourceIDs: [], url: item.url)
                    }
                case .techniques:
                    ForEach(Array(result.techniques.prefix(model.threatSearchResultLimit))) { item in
                        record(title: "\(item.attackID) \(item.name)".trimmingCharacters(in: .whitespaces), subtitle: item.tactic, detail: item.detail, sourceIDs: item.sourceIDs, url: nil)
                    }
                case .targets:
                    ForEach(Array(result.targets.prefix(model.threatSearchResultLimit))) { item in
                        record(title: item.sector, subtitle: item.regions.joined(separator: ", "), detail: item.rationale, sourceIDs: [], url: nil)
                    }
                }
                if rowsRemaining > model.threatSearchResultLimit {
                    ActionButton(title: "Show 20 more", icon: "chevron.down") { model.threatSearchResultLimit += 20 }
                }
            }
        }
    }

    @ViewBuilder private func resultSectionFilters(_ result: ThreatIntelSearchResult) -> some View {
        ForEach(ThreatResultSection.allCases, id: \.self) { value in
            FilterChip(title: sectionTitle(value, result), active: section == value) {
                section = value
                model.threatSearchResultLimit = 20
            }
        }
    }

    private func sectionTitle(_ value: ThreatResultSection, _ result: ThreatIntelSearchResult) -> String {
        let count: Int
        switch value { case .activity: count = result.activity.count; case .sources: count = result.sources.count; case .techniques: count = result.techniques.count; case .targets: count = result.targets.count }
        return "\(value.rawValue) · \(count)"
    }

    private func record(title: String, subtitle: String, detail: String, sourceIDs: [String], url: URL?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.isEmpty ? "Untitled evidence" : title).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text).textSelection(.enabled)
            if !subtitle.isEmpty { Text(subtitle).font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary) }
            if !detail.isEmpty { Text(detail).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary).textSelection(.enabled) }
            if !sourceIDs.isEmpty { Text("Sources: \(sourceIDs.joined(separator: ", "))").font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary).textSelection(.enabled) }
            if url != nil { ActionButton(title: "Open source", icon: "arrow.up.right.square") { model.openThreatEvidence(url) } }
        }
        .padding(.vertical, 5)
    }
}
