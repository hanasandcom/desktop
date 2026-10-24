import SwiftUI

struct HostConsoleView: View {
    @Environment(\.desktopTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: HostConsoleSession

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

            NativeVMTerminalView(rows: session.terminal.historyRows, isConnected: session.isConnected, generation: session.generation,
                cursorRow: session.terminal.cursorHistoryRow, cursorColumn: session.terminal.cursorColumnPosition,
                cursorVisible: session.terminal.cursorVisible, cursorBlink: session.terminal.cursorBlink,
                cursorStyle: session.terminal.cursorStyle, applicationCursorKeys: session.terminal.applicationCursorKeys,
                bracketedPaste: session.terminal.bracketedPaste, mouseTracking: session.terminal.mouseTracking,
                mouseTrackingMode: session.terminal.mouseTrackingMode, mouseEncoding: session.terminal.mouseEncoding,
                alternateScreen: session.terminal.isAlternateScreen,
                columns: session.terminal.columns, screenRows: session.terminal.rows,
                onInput: session.sendInput,
                onResize: session.resize)
            .frame(minHeight: 300)

            Button("Ctrl-C", systemImage: "stop.fill") { session.sendControlC() }
                .disabled(!session.isConnected)
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

}
