import CryptoKit
import SwiftUI

private struct PendingThesisCodeReview: Equatable {
    let item: ThesisCodeNode
    let approved: Bool
    let eventID: String
}

struct ThesisCodeReviewNativePanel: View {
    @Environment(\.desktopTheme) private var theme
    let settings: HanasandDesktopSettings
    let canReview: Bool

    @State private var inventory: ThesisCodeInventory?
    @State private var selectedID = ""
    @State private var detail: ThesisCodeSource?
    @State private var query = ""
    @State private var kindFilter = "all"
    @State private var statusFilter = "all"
    @State private var priorityOrder = true
    @State private var limit = 100
    @State private var sourceLineLimit = 300
    @State private var loading = false
    @State private var error = ""
    @State private var notice = ""
    @State private var pendingReview: PendingThesisCodeReview?
    @State private var reviewSubmissionAttempted = false
    @State private var showingReviewConfirmation = false
    @State private var retryChecked = false
    @State private var historyHasMore = false
    @State private var accessDenied = false

    private var currentNode: ThesisCodeNode? { inventory?.nodes.first { $0.id == selectedID } }
    private var staleDetail: Bool {
        guard let item = detail?.item, let currentNode else { return detail != nil }
        return item.sha256 != currentNode.sha256 || item.reviewHash != currentNode.reviewHash
    }
    private var canRecordReview: Bool {
        guard let item = detail?.item, let currentNode, let pendingReview else { return false }
        return canReview && settings.impersonationToken.isEmpty && settings.impersonatingUserID.isEmpty
            && inventory?.syncReady == true && selectedID == item.id && item.id == currentNode.id
            && item.sha256 == currentNode.sha256 && item.reviewHash == currentNode.reviewHash
            && pendingReview.item.id == item.id && pendingReview.item.sha256 == item.sha256
            && pendingReview.item.reviewHash == item.reviewHash
    }
    private var filteredNodes: [ThesisCodeNode] {
        let matches = (inventory?.nodes ?? []).filter { node in
            (kindFilter == "all" || node.kind.rawValue == kindFilter)
                && (statusFilter == "all" || node.reviewStatus == statusFilter)
                && (query.isEmpty || "\(node.title) \(node.file)".localizedCaseInsensitiveContains(query))
        }
        return matches.sorted { lhs, rhs in
            if priorityOrder {
                let left = reviewPriority(lhs), right = reviewPriority(rhs)
                if left != right { return left < right }
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }
    private var taskScope: String {
        let tokenDigest = SHA256.hash(data: Data(settings.authToken.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(settings.websiteBaseURL)|\(settings.userID)|\(tokenDigest)|\(!settings.impersonationToken.isEmpty)|\(settings.impersonatingUserID)|\(canReview)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NativeGroupPanel(title: "Source inventory", subtitle: inventory.map { "Release \($0.release) · \($0.nodes.count) indexed items" } ?? "Browse source and dependency review", fillsAvailableWidth: true) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { refreshButton; syncLabel }
                    VStack(alignment: .leading, spacing: 8) { refreshButton; syncLabel }
                }
                if !error.isEmpty { Text(error).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.danger).textSelection(.enabled) }
                if !notice.isEmpty { NativeNotice(message: notice) }

                TextField("Find source files", text: $query)
                    .textFieldStyle(.roundedBorder)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { kindPicker; statusPicker; sortButton }
                    VStack(alignment: .leading, spacing: 8) { kindPicker; statusPicker; sortButton }
                }
                Text("\(filteredNodes.count) matching items")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
                ForEach(Array(filteredNodes.prefix(limit))) { node in
                    Button { Task { await selectSource(node.id) } } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(node.reviewStatus.uppercased()) · \(node.title)")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(node.file).font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.textTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(9).background(selectedID == node.id ? theme.accentSoft : theme.cardRaised, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).disabled(loading)
                }
                if filteredNodes.count > limit {
                    ActionButton(title: "Load 100 more items", icon: "ellipsis") { limit += 100 }
                }
                if inventory == nil && !loading && error.isEmpty {
                    NativeEmptyState(title: "Source inventory unavailable", message: "Refresh to try loading the current release.")
                }
            }

            if let detail { sourceDetail(detail) }
            if pendingReview != nil, canRecordReview, !retryChecked {
                Text("Review outcome is uncertain. Refresh this source before retrying the same review.")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
            }
        }
        .task(id: taskScope) { await pollInventory() }
        .confirmationDialog(
            pendingReview?.approved == true ? "Approve this source?" : "Revoke this approval?",
            isPresented: $showingReviewConfirmation,
            titleVisibility: .visible
        ) {
            Button(reviewSubmissionAttempted ? "Retry same review" : pendingReview?.approved == true ? "Record review" : "Revoke approval", role: pendingReview?.approved == false ? .destructive : nil) {
                Task { await saveReview() }
            }.disabled(!canRecordReview || (pendingReview != nil && !retryChecked))
            Button("Cancel", role: .cancel) {}
        } message: {
            if let item = pendingReview?.item {
                Text("\(item.file)\n\(item.sha256)\nRecord your review of the current source and its dependencies.")
            }
        }
    }

    private var refreshButton: some View {
        ActionButton(title: loading ? "Refreshing…" : "Refresh inventory and source", icon: "arrow.clockwise") {
            Task { await refreshManually() }
        }.disabled(loading)
    }

    @ViewBuilder private var syncLabel: some View {
        if let sync = inventory?.sync {
            Text([sync.phase, sync.checkedAt, sync.warning, sync.error].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 10)).foregroundStyle(sync.error == nil ? theme.textTertiary : theme.danger)
                .textSelection(.enabled).lineLimit(3)
        } else {
            Text("Inventory sync status not supplied").font(.system(size: 10)).foregroundStyle(theme.textTertiary)
        }
    }

    private var kindPicker: some View {
        Picker("Source type", selection: $kindFilter) {
            Text("All types").tag("all")
            ForEach(ThesisCodeKind.allCases) { kind in Text(kind.rawValue.capitalized).tag(kind.rawValue) }
        }.pickerStyle(.menu).fixedSize()
    }

    private var statusPicker: some View {
        Picker("Review status", selection: $statusFilter) {
            Text("All review states").tag("all")
            Text("Unreviewed").tag("unreviewed")
            Text("Changed").tag("changed")
            Text("Approved").tag("approved")
        }.pickerStyle(.menu).fixedSize()
    }

    private var sortButton: some View {
        ActionButton(title: priorityOrder ? "Sort alphabetically" : "Sort by review priority", icon: "arrow.up.arrow.down") {
            priorityOrder.toggle()
        }
    }

    @ViewBuilder private func sourceDetail(_ value: ThesisCodeSource) -> some View {
        let item = value.item
        NativeGroupPanel(title: item.title, subtitle: "\(item.file)\(item.line.map { ":\($0)" } ?? "")", fillsAvailableWidth: true) {
            if staleDetail { NativeNotice(message: "This source changed. Reload it before reviewing.") }
            Text("Content SHA256  \(item.sha256)\nReview hash  \(item.reviewHash)")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.textTertiary).textSelection(.enabled)
            ScrollView(.horizontal, showsIndicators: true) {
                Text(item.content?.split(separator: "\n", omittingEmptySubsequences: false).prefix(sourceLineLimit).joined(separator: "\n") ?? "")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 340, alignment: .top)
            if (item.content?.split(separator: "\n", omittingEmptySubsequences: false).count ?? 0) > sourceLineLimit {
                ActionButton(title: "Show 300 more source lines", icon: "text.alignleft") { sourceLineLimit += 300 }
            }
            dependencyPanel(for: item)
            reviewControls(for: item)
            reviewHistory(value)
        }
    }

    @ViewBuilder private func dependencyPanel(for item: ThesisCodeNode) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Dependencies · \(item.dependencies.count)").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
            if item.dependencies.isEmpty { Text("No indexed dependencies.").font(.system(size: 11)).foregroundStyle(theme.textSecondary) }
            else {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 7) {
                        ForEach(item.dependencies, id: \.self) { id in
                            let node = inventory?.nodes.first { $0.id == id }
                            ActionButton(title: node?.title ?? id, icon: "arrow.turn.down.right") {
                                Task { await selectSource(id) }
                            }.disabled(node == nil || loading)
                        }
                    }
                }
            }
            let dependents = inventory?.nodes.filter { $0.dependencies.contains(item.id) } ?? []
            Text("Used by · \(dependents.count)").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
            if !dependents.isEmpty {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 7) {
                        ForEach(dependents) { node in
                            ActionButton(title: node.title, icon: "arrow.turn.up.right") {
                                Task { await selectSource(node.id) }
                            }.disabled(loading)
                        }
                    }
                }
            }
            if !item.unresolved.isEmpty {
                Text("Inspect manually: \(item.unresolved.joined(separator: " · "))")
                    .font(.system(size: 10)).foregroundStyle(theme.textTertiary).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private func reviewControls(for item: ThesisCodeNode) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { approveButton(item); revokeButton(item); retryButton(item) }
            VStack(alignment: .leading, spacing: 8) { approveButton(item); revokeButton(item); retryButton(item) }
        }
        if !canReview { Text("Hanasand organization owners and editors can record source reviews.").font(.system(size: 10)).foregroundStyle(theme.textTertiary) }
        if inventory?.syncReady == false { Text("Reviews are unavailable while Git synchronization is incomplete.").font(.system(size: 10)).foregroundStyle(theme.danger) }
    }

    private func approveButton(_ item: ThesisCodeNode) -> some View {
        ActionButton(title: "Approve source", icon: "checkmark.seal") { confirmReview(item, approved: true) }
            .disabled(loading || !canReview || staleDetail || inventory?.syncReady != true || pendingReview != nil)
    }

    private func revokeButton(_ item: ThesisCodeNode) -> some View {
        ActionButton(title: "Revoke approval", icon: "xmark.seal", tone: .danger) { confirmReview(item, approved: false) }
            .disabled(loading || !canReview || staleDetail || inventory?.syncReady != true || pendingReview != nil)
    }

    @ViewBuilder private func retryButton(_ item: ThesisCodeNode) -> some View {
        if let pendingReview, pendingReview.item.id == item.id, reviewSubmissionAttempted, retryChecked {
            ActionButton(title: "Retry same review", icon: "arrow.clockwise") { showingReviewConfirmation = true }
                .disabled(loading || !canRecordReview)
        }
    }

    @ViewBuilder private func reviewHistory(_ value: ThesisCodeSource) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Review history").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
            if value.history.isEmpty { Text("No reviews recorded for this source.").font(.system(size: 11)).foregroundStyle(theme.textSecondary) }
            ForEach(value.history) { event in
                Text("\(event.approved ? "Approved" : "Revoked") · \(event.reviewer) · \(event.reviewedAt) · \(event.reviewHash == value.item.reviewHash ? "current source" : "earlier source")")
                    .font(.system(size: 10)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
            }
            if historyHasMore {
                ActionButton(title: "Older reviews", icon: "clock.arrow.circlepath") {
                    Task { await loadOlderHistory() }
                }.disabled(loading)
            }
        }
    }

    @MainActor private func pollInventory() async {
        inventory = nil; selectedID = ""; detail = nil
        pendingReview = nil; reviewSubmissionAttempted = false; retryChecked = false; accessDenied = false; error = ""; notice = ""
        if !settings.impersonationToken.isEmpty || !settings.impersonatingUserID.isEmpty {
            error = "Return to your own account to view the source inventory."; return
        }
        while !Task.isCancelled {
            await loadInventory(manual: inventory == nil)
            do { try await Task.sleep(for: .seconds(3)) } catch { break }
        }
    }

    @MainActor private func loadInventory(manual: Bool) async {
        guard !loading, manual || !accessDenied else { return }
        guard settings.impersonationToken.isEmpty && settings.impersonatingUserID.isEmpty else {
            error = "Return to your own account to view the source inventory."; return
        }
        loading = true; defer { loading = false }
        do {
            let client = try ThesisCodeReviewClient(settings: settings)
            if let value = try await client.inventory(since: manual ? nil : inventory?.cursor) { inventory = value }
            error = ""
            if manual { accessDenied = false }
            if manual, !selectedID.isEmpty {
                if inventory?.nodes.contains(where: { $0.id == selectedID }) != true {
                    selectedID = ""; detail = nil; pendingReview = nil; reviewSubmissionAttempted = false; retryChecked = false
                    notice = "This source is no longer in the current release. Choose another item from the refreshed inventory."
                } else {
                    try await loadSource(using: client, id: selectedID, manual: true)
                }
            }
        } catch { recordError(error) }
    }

    @MainActor private func refreshManually() async {
        await loadInventory(manual: true)
    }

    @MainActor private func selectSource(_ id: String) async {
        guard !loading else { return }
        guard inventory?.nodes.contains(where: { $0.id == id }) == true else {
            error = "This source is not in the current release. Refresh the inventory."; return
        }
        loading = true; error = ""; notice = ""; defer { loading = false }
        do {
            let client = try ThesisCodeReviewClient(settings: settings)
            try await loadSource(using: client, id: id, manual: false)
        } catch { recordError(error) }
    }

    @MainActor private func loadSource(using client: ThesisCodeReviewClient, id: String, manual: Bool) async throws {
        let value = try await client.source(id: id)
        selectedID = id; detail = value; sourceLineLimit = 300; historyHasMore = value.history.count == 50
        if manual {
            error = ""
            if let pendingReview, pendingReview.item.id != value.item.id
                || pendingReview.item.sha256 != value.item.sha256 || pendingReview.item.reviewHash != value.item.reviewHash {
                self.pendingReview = nil; reviewSubmissionAttempted = false; retryChecked = false
                notice = "This source changed. Review the current version before recording a new review."
            } else if let pendingReview,
               value.history.contains(where: { $0.eventID == pendingReview.eventID && $0.itemID == pendingReview.item.id && $0.reviewHash == pendingReview.item.reviewHash && $0.contentHash == pendingReview.item.sha256 && $0.approved == pendingReview.approved }) {
                self.pendingReview = nil; retryChecked = false
                reviewSubmissionAttempted = false
                notice = "The previous review is recorded."
            } else if pendingReview != nil {
                retryChecked = true
                notice = "Source refreshed. You can retry the same review if it was not recorded."
            }
        }
    }

    @MainActor private func loadOlderHistory() async {
        guard !loading, let detail, let before = detail.history.last?.eventID else { return }
        loading = true; error = ""; defer { loading = false }
        do {
            let older = try await ThesisCodeReviewClient(settings: settings).source(id: detail.item.id, before: before)
            self.detail = ThesisCodeSource(item: detail.item, history: detail.history + older.history)
            historyHasMore = older.history.count == 50
        } catch { recordError(error) }
    }

    @MainActor private func confirmReview(_ item: ThesisCodeNode, approved: Bool) {
        guard detail?.item.id == item.id, !staleDetail, inventory?.syncReady == true else { return }
        pendingReview = PendingThesisCodeReview(item: item, approved: approved, eventID: UUID().uuidString.lowercased())
        reviewSubmissionAttempted = false; retryChecked = true; showingReviewConfirmation = true
    }

    @MainActor private func saveReview() async {
        guard canRecordReview, let pendingReview, retryChecked else { return }
        loading = true; error = ""; notice = ""; retryChecked = false; reviewSubmissionAttempted = true; defer { loading = false }
        do {
            let receipt = try await ThesisCodeReviewClient(settings: settings).review(pendingReview.item, approved: pendingReview.approved, eventID: pendingReview.eventID, canReview: canReview)
            self.pendingReview = nil; reviewSubmissionAttempted = false; retryChecked = false
            notice = "Review recorded at \(receipt.reviewedAt)."
            let client = try ThesisCodeReviewClient(settings: settings)
            if let latest = try await client.inventory() { inventory = latest }
            try await loadSource(using: client, id: pendingReview.item.id, manual: false)
        } catch {
            recordError(error)
            notice = "The review outcome is uncertain. Refresh this source before retrying the same review."
        }
    }

    @MainActor private func recordError(_ error: Error) {
        self.error = error.localizedDescription
        if let reviewError = error as? ThesisCodeReviewError,
           case .requestFailed(let status, _) = reviewError, status == 401 || status == 403 {
            accessDenied = true
        }
    }

    private func reviewPriority(_ node: ThesisCodeNode, now: Date = Date()) -> Int {
        if node.reviewStatus == "approved" { return 2 }
        guard node.reviewStatus == "changed", let reviewedAt = node.review?.reviewedAt,
              let date = ISO8601DateFormatter().date(from: reviewedAt),
              now.timeIntervalSince(date) < 14 * 24 * 60 * 60 else { return 0 }
        return 1
    }
}
