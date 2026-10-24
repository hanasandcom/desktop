import SwiftUI

struct HostConsoleView: View {
    @Environment(\.desktopTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: HostConsoleSession
    @State private var command = ""

    private let title: String

    init(host: HostOverviewEnvelope.Host, apiBaseURL: String, userID: String, token: String, isImpersonating: Bool) {
        title = host.name
        _session = StateObject(wrappedValue: HostConsoleSession(host: host.id, apiBaseURL: apiBaseURL, userID: userID, token: token, isImpersonating: isImpersonating))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    headerTitle
                    Spacer(minLength: 8)
                    consoleHeaderActions
                }
                VStack(alignment: .leading, spacing: 8) {
                    headerTitle
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        consoleHeaderActions
                    }
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(session.output.isEmpty ? "Waiting for host console…" : session.output)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .id("host-console-end")
                }
                .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
                .onChange(of: session.output) { _, _ in proxy.scrollTo("host-console-end", anchor: .bottom) }
            }
            .frame(minHeight: 300)

            ViewThatFits(in: .horizontal) {
                commandInputRow
                VStack(alignment: .leading, spacing: 8) {
                    commandField
                    HStack(spacing: 8) {
                        Button("Send") { sendCommand() }
                            .disabled(!session.isConnected || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Ctrl-C") { session.sendControlC() }
                            .disabled(!session.isConnected)
                    }
                }
            }
            Text("Connected to the server through Hanasand. Your commands run on \(title).")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
        }
        .padding(18)
        .frame(minWidth: 0, idealWidth: 720, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .background(theme.background)
        .onAppear { session.connect() }
        .onDisappear { session.disconnect() }
    }

    private func sendCommand() {
        let value = command
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        session.sendLine(value)
        command = ""
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) console")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(session.status)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(session.isConnected ? theme.green : theme.textSecondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private var consoleHeaderActions: some View {
        Group {
            Button("Reconnect", systemImage: "arrow.clockwise") {
                session.disconnect()
                session.connect()
            }
            .disabled(session.isConnected)
            Button("Close", systemImage: "xmark") { dismiss() }
        }
    }

    private var commandField: some View {
        TextField("Enter a command", text: $command)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 13, design: .monospaced))
            .frame(minWidth: 0)
            .onSubmit { sendCommand() }
    }

    private var commandInputRow: some View {
        HStack(spacing: 10) {
            commandField
            Button("Send") { sendCommand() }
                .disabled(!session.isConnected || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Ctrl-C") { session.sendControlC() }
                .disabled(!session.isConnected)
        }
    }
}
