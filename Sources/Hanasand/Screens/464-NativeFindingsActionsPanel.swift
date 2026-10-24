import SwiftUI

struct NativeFindingsActionsPanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var input = NativeFindingsActionInput()
    @State private var selectedAction: NativeFindingsAction = .saveWatchlist
    @State private var receipt: NativeFindingsActionReceipt?
    @State private var error = ""
    @State private var busy = false

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
                if !error.isEmpty {
                    Text(error).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if let receipt {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(receipt.message).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(receipt.isWarning ? theme.textSecondary : theme.text)
                        if let detail = receipt.detail { Text(detail).font(.system(size: 10)).foregroundStyle(theme.textTertiary) }
                    }.accessibilityElement(children: .combine)
                }
            }

            NativeGroupPanel(title: "Watchlist and collection", subtitle: "Changes apply to the selected workspace") {
                Text("Watchlist terms").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textSecondary)
                TextEditor(text: $input.terms).font(.system(size: 11)).frame(minHeight: 76, maxHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.divider, lineWidth: 1))
                Text("One term per line. Duplicate terms are removed when saved.")
                    .font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                HStack(spacing: 8) {
                    runButton(.saveWatchlist, icon: "checkmark")
                    runButton(.runCollection, icon: "arrow.clockwise")
                }
            }

            NativeGroupPanel(title: "Webhook delivery", subtitle: "Test records a dry run. Sending queued findings may notify configured destinations.") {
                TextField("HTTPS webhook URL (optional for queued delivery)", text: $input.webhookURL)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    runButton(.testWebhook, icon: "checkmark.shield")
                    runButton(.deliverWebhooks, icon: "paperplane")
                }
                NativeNotice(message: "Review delivery history after either action. A timeout can leave the result uncertain; refresh before retrying.")
            }

            NativeGroupPanel(title: "Source intake", subtitle: "Public Telegram channels only") {
                TextField("@channel or https://t.me/channel", text: $input.telegramTarget)
                    .textFieldStyle(.roundedBorder)
                runButton(.submitTelegramSource, icon: "tray.and.arrow.down")
            }

            NativeGroupPanel(title: "Public advisory evidence", subtitle: "Submit public, source-backed incident information") {
                TextField("Actor or source", text: $input.actor).textFieldStyle(.roundedBorder)
                TextField("Affected company", text: $input.company).textFieldStyle(.roundedBorder)
                TextField("Exposure details", text: $input.claimedData, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
                TextField("HTTPS source URL", text: $input.sourceURL).textFieldStyle(.roundedBorder)
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
    }

    private var subtitle: String {
        let selected = model.selectedOrganizationID
        return selected.isEmpty || selected == "personal" ? "Personal workspace" : "Workspace · \(selected)"
    }

    @ViewBuilder private func runButton(_ action: NativeFindingsAction, icon: String) -> some View {
        ActionButton(title: busy && selectedAction == action ? "Working…" : action.title, icon: icon) {
            Task { await perform(action) }
        }.disabled(busy || !model.hasHanasandAuth || readOnly || model.selectedOrganizationID.isEmpty)
    }

    @MainActor private func perform(_ action: NativeFindingsAction) async {
        guard !busy else { return }
        busy = true
        selectedAction = action
        receipt = nil
        error = ""
        let settings = model.settings
        do {
            let client = try NativeFindingsActionsClient(settings: settings)
            let outcome = try await client.perform(action, input: input) {
                settings == model.settings && !Task.isCancelled
            }
            guard settings == model.settings else { throw NativeFindingsActionsError.invalidScope }
            receipt = outcome
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }
}
