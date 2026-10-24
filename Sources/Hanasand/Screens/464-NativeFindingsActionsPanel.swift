import SwiftUI

struct NativeFindingsActionsPanelState {
    var input = NativeFindingsActionInput()
    var selectedAction: NativeFindingsAction = .saveWatchlist
    var receipt: NativeFindingsActionReceipt?
    var error = ""
    var busy = false
    private(set) var operationID = UUID()

    mutating func resetForWorkspaceChange() {
        operationID = UUID()
        input = NativeFindingsActionInput()
        selectedAction = .saveWatchlist
        receipt = nil
        error = ""
        busy = false
    }

    mutating func begin(_ action: NativeFindingsAction) -> UUID {
        selectedAction = action
        receipt = nil
        error = ""
        busy = true
        operationID = UUID()
        return operationID
    }

    @discardableResult
    mutating func finish(operationID expectedID: UUID, receipt: NativeFindingsActionReceipt?, error: String?) -> Bool {
        guard operationID == expectedID else { return false }
        self.receipt = receipt
        self.error = error ?? ""
        busy = false
        return true
    }
}

struct NativeFindingsActionsPanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var state = NativeFindingsActionsPanelState()

    private var workspaceKey: String {
        [model.settings.websiteBaseURL, model.userIDForRequests, model.settings.authToken,
         model.selectedOrganizationID, model.settings.selectedOrganizationUserID,
         model.settings.impersonatingUserID, model.settings.impersonationToken].joined(separator: "|")
    }

    private var readOnly: Bool {
        !model.settings.impersonationToken.isEmpty || !model.settings.impersonatingUserID.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NativeGroupPanel(title: "Findings Actions", subtitle: subtitle) {
                Text("Run watchlist, collection, delivery, source, and evidence actions in this native workspace.")
                    .font(.system(size: 12)).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                if !model.hasHanasandAuth {
                    NativeNotice(message: "Sign in to use Findings Actions.")
                } else if readOnly {
                    NativeNotice(message: "Actions are unavailable while impersonating. Return to your account first.")
                } else if model.selectedOrganizationID.isEmpty {
                    NativeNotice(message: "Choose a workspace before running actions.")
                }
                if !state.error.isEmpty {
                    Text(state.error).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if let receipt = state.receipt {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(receipt.message).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(receipt.isWarning ? theme.textSecondary : theme.text)
                        if let detail = receipt.detail { Text(detail).font(.system(size: 10)).foregroundStyle(theme.textTertiary) }
                    }.accessibilityElement(children: .combine)
                }
            }

            NativeGroupPanel(title: "Watchlist and collection", subtitle: "Changes apply to the selected workspace") {
                Text("Watchlist terms").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textSecondary)
                TextEditor(text: $state.input.terms).font(.system(size: 11)).frame(minHeight: 76, maxHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.divider, lineWidth: 1))
                Text("One term per line. Duplicate terms are removed when saved.")
                    .font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                HStack(spacing: 8) {
                    runButton(.saveWatchlist, icon: "checkmark")
                    runButton(.runCollection, icon: "arrow.clockwise")
                }
            }

            NativeGroupPanel(title: "Webhook delivery", subtitle: "Test records a dry run. Sending queued findings may notify configured destinations.") {
                TextField("HTTPS webhook URL (optional for queued delivery)", text: $state.input.webhookURL)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    runButton(.testWebhook, icon: "checkmark.shield")
                    runButton(.deliverWebhooks, icon: "paperplane")
                }
                NativeNotice(message: "Review delivery history after either action. A timeout can leave the result uncertain; refresh before retrying.")
            }

            NativeGroupPanel(title: "Source intake", subtitle: "Public Telegram channels only") {
                TextField("@channel or https://t.me/channel", text: $state.input.telegramTarget)
                    .textFieldStyle(.roundedBorder)
                runButton(.submitTelegramSource, icon: "tray.and.arrow.down")
            }

            NativeGroupPanel(title: "Public advisory evidence", subtitle: "Submit public, source-backed incident information") {
                TextField("Actor or source", text: $state.input.actor).textFieldStyle(.roundedBorder)
                TextField("Affected company", text: $state.input.company).textFieldStyle(.roundedBorder)
                TextField("Exposure details", text: $state.input.claimedData, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
                TextField("HTTPS source URL", text: $state.input.sourceURL).textFieldStyle(.roundedBorder)
                runButton(.ingestAdvisory, icon: "doc.text.magnifyingglass")
                NativeNotice(message: "Evidence is submitted for review; this action does not confirm the claim is accurate.")
            }

            NativeGroupPanel(title: "Case handoff", subtitle: "Use the public advisory details above") {
                Text("Submit the evidence, update its watchlist term, rebuild matching findings, and open a case from the matched finding. If a webhook URL is set, the handoff records a dry-run delivery.")
                    .font(.system(size: 11)).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                runButton(.openCase, icon: "checkmark.square")
            }
        }
        .padding(16)
        .onChange(of: workspaceKey) { _, _ in
            state.resetForWorkspaceChange()
        }
    }

    private var subtitle: String {
        let selected = model.selectedOrganizationID
        return selected.isEmpty || selected == "personal" ? "Personal workspace" : "Workspace · \(selected)"
    }

    @ViewBuilder private func runButton(_ action: NativeFindingsAction, icon: String) -> some View {
        ActionButton(title: state.busy && state.selectedAction == action ? "Working…" : action.title, icon: icon) {
            Task { await perform(action) }
        }.disabled(state.busy || !model.hasHanasandAuth || readOnly || model.selectedOrganizationID.isEmpty)
    }

    @MainActor private func perform(_ action: NativeFindingsAction) async {
        guard !state.busy else { return }
        let currentOperation = state.begin(action)
        let settings = model.settings
        do {
            let client = try NativeFindingsActionsClient(settings: settings)
            let outcome = try await client.perform(action, input: state.input) {
                settings == model.settings && !Task.isCancelled
            }
            guard settings == model.settings else { throw NativeFindingsActionsError.invalidScope }
            state.finish(operationID: currentOperation, receipt: outcome, error: nil)
        } catch {
            state.finish(operationID: currentOperation, receipt: nil, error: error.localizedDescription)
        }
    }
}
