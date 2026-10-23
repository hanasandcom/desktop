import SwiftUI

struct PasswordCheckNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var hash = ""
    @State private var result: PasswordCheckResult?
    @State private var error = ""
    @State private var isChecking = false
    @State private var requestTask: Task<Void, Never>?
    @FocusState private var hashFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NativeGroupPanel(title: "Check password", subtitle: "Leaked password records") {
                Text("Enter a SHA-1 hash as on the website. Only its first five characters are sent; the complete hash stays on this Mac and clears when the check starts.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                TextField("40-character SHA-1 hash", text: $hash)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .textCase(.uppercase)
                    .autocorrectionDisabled()
                    .focused($hashFieldFocused)
                    .disabled(isChecking)
                    .onSubmit { check() }
                    .onChange(of: hash) { _, value in
                        if value.count > 80 { hash = String(value.prefix(80)) }
                        else if value != value.uppercased() { hash = value.uppercased() }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(theme.cardRaised)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.divider, lineWidth: 1))
                    .accessibilityLabel("SHA-1 hash")

                HStack(spacing: 8) {
                    ActionButton(title: isChecking ? "Checking…" : "Check hash", icon: "magnifyingglass") { check() }
                        .disabled(isChecking || hash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    ActionButton(title: isChecking ? "Cancel" : "Clear", icon: isChecking ? "xmark" : "eraser") { clear() }
                }
                if !error.isEmpty { NativeNotice(message: error) }
            }

            if let result {
                NativeGroupPanel(title: result.count > 0 ? "Found in leaked records" : "No match found",
                                 subtitle: "\(result.count.formatted()) occurrence\(result.count == 1 ? "" : "s")") {
                    Text(result.count > 0
                         ? "This hash appears \(result.count.formatted()) times in the checked records. If it belongs to your password, replace it wherever you use it."
                         : "No match was found in the checked records. This result does not establish that a password is safe.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(result.count > 0 ? theme.danger : theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    ForEach(result.files) { file in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.file).font(.system(size: 12, weight: .bold)).foregroundStyle(theme.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Text("\(file.count.formatted()) occurrences · Lines \(file.lineRanges.map { $0.lowerBound == $0.upperBound ? "\($0.lowerBound)" : "\($0.lowerBound)–\($0.upperBound)" }.joined(separator: ", "))")
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary).textSelection(.enabled)
                        }
                    }
                    ActionButton(title: "Check another hash", icon: "arrow.left") { clear() }
                }
            }
        }
        .onDisappear { cancelRequest() }
    }

    private func check() {
        guard !isChecking else { return }
        let submittedHash = hash
        hash = ""
        result = nil
        error = ""
        isChecking = true
        hashFieldFocused = false
        requestTask = Task {
            do {
                let apiBase = model.settings.apiBaseURL.normalizedBaseURL
                let checked = try await PasswordCheckClient.check(hash: submittedHash, apiBaseURL: apiBase)
                guard !Task.isCancelled else { return }
                result = checked
            } catch is CancellationError {
                // The user cancelled the request or left the panel.
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            if !Task.isCancelled { isChecking = false }
            requestTask = nil
        }
    }

    private func clear() {
        cancelRequest()
        hash = ""
        result = nil
        error = ""
        isChecking = false
    }

    private func cancelRequest() {
        requestTask?.cancel()
        requestTask = nil
    }
}
