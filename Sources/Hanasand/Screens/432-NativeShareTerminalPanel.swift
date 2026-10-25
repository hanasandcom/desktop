import SwiftUI

struct NativeShareTerminalPanel: View {
    let apiBaseURL: URL
    let alias: String
    let userID: String
    let connectionEnabled: Bool
    let onClose: () -> Void

    @StateObject private var session: NativeShareTerminalSession
    @State private var command = ""
    @Environment(\.desktopTheme) private var theme

    init(apiBaseURL: URL, alias: String, userID: String, connectionEnabled: Bool,
         onClose: @escaping () -> Void) {
        self.apiBaseURL = apiBaseURL
        self.alias = alias
        self.userID = userID
        self.connectionEnabled = connectionEnabled
        self.onClose = onClose
        _session = StateObject(wrappedValue: NativeShareTerminalSession(
            apiBaseURL: apiBaseURL, alias: alias, userID: userID
        ))
    }

    var body: some View {
        NativeGroupPanel(title: "Browser terminal", subtitle: "Read-only commands: pwd, ls [path], clear, help",
                         fillsAvailableWidth: true) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(session.status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                Label("\(session.participants)", systemImage: "eye")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .help("Connected participants")
            }

            if let error = session.errorMessage, !error.isEmpty {
                NativeNotice(message: error, title: "Browser terminal", tone: .error)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        if session.output.isEmpty {
                            Text(connectionEnabled ? "Connecting to the browser terminal…" : "Terminal is unavailable in this preview.")
                                .foregroundStyle(theme.textSecondary)
                                .id("terminal-empty")
                        }
                        ForEach(Array(session.output.enumerated()), id: \.offset) { index, chunk in
                            Text(displayText(chunk))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(theme.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 190)
                .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .onChange(of: session.output.count) { _, _ in
                    if let last = session.output.indices.last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    commandField
                    ActionButton(title: "Run", icon: "paperplane.fill") { submit() }
                        .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !session.isConnected)
                }
                VStack(spacing: 8) {
                    commandField
                    ActionButton(title: "Run", icon: "paperplane.fill", expands: true) { submit() }
                        .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !session.isConnected)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    ActionButton(title: "Reconnect", icon: "arrow.clockwise") { session.reconnect() }
                        .disabled(!connectionEnabled || session.lifecycle == .connecting)
                    ActionButton(title: "Restart terminal", icon: "power") { session.restart() }
                        .disabled(!connectionEnabled || session.lifecycle == .connecting)
                    ActionButton(title: "Close", icon: "chevron.down", expands: true, action: onClose)
                }
                VStack(spacing: 8) {
                    ActionButton(title: "Reconnect", icon: "arrow.clockwise", expands: true) { session.reconnect() }
                        .disabled(!connectionEnabled || session.lifecycle == .connecting)
                    ActionButton(title: "Restart terminal", icon: "power", expands: true) { session.restart() }
                        .disabled(!connectionEnabled || session.lifecycle == .connecting)
                    ActionButton(title: "Close", icon: "chevron.down", expands: true, action: onClose)
                }
            }
        }
        .task {
            guard connectionEnabled else { return }
            session.connect()
        }
        .onDisappear { session.disconnect() }
    }

    private var commandField: some View {
        TextField("pwd, ls [path], clear, help", text: $command)
            .font(.system(size: 12, design: .monospaced))
            .textFieldStyle(.roundedBorder)
            .onSubmit { submit() }
            .disabled(!session.isConnected)
    }

    private var statusColor: Color {
        switch session.lifecycle {
        case .ready: theme.green
        case .connecting: .orange
        case .failed: theme.danger
        case .closed: theme.textSecondary
        }
    }

    private func submit() {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        command = ""
        Task { _ = await session.sendInput(value + "\r") }
    }

    private func displayText(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{001B}c", with: "")
    }
}
