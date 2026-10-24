import SwiftUI

struct NativeVMConsolePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @StateObject private var session: NativeVMConsoleSession
    @State private var reviewConsole = false
    private let vmName: String
    private let provisioningFlow: Bool

    init(vmName: String, apiBaseURL: String, userID: String, token: String, isImpersonating: Bool, provisioningFlow: Bool) {
        self.vmName = vmName
        self.provisioningFlow = provisioningFlow
        _session = StateObject(wrappedValue: NativeVMConsoleSession(
            apiBaseURL: apiBaseURL,
            vmName: vmName,
            userID: userID,
            token: token,
            isImpersonating: isImpersonating,
            provisioningFlow: provisioningFlow,
            organizationID: ""
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if provisioningFlow {
                NativeGroupPanel(title: "VM boot output", subtitle: session.bootLog.status) {
                    ScrollView {
                        Text(session.bootLog.text.isEmpty ? "Boot output will appear here while the VM starts." : session.bootLog.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.text)
                            .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 180)
                }
            }
            NativeGroupPanel(title: "VM console", subtitle: "Interactive console session · \(vmName)") {
                HStack(spacing: 8) {
                    Text(session.status).font(.system(size: 12, weight: .medium)).foregroundStyle(session.isConnected ? theme.green : theme.textSecondary)
                    Spacer()
                    ActionButton(title: session.isConnected ? "Connected" : session.isPreparing ? "Preparing…" : "Reconnect", icon: session.isConnected ? "checkmark.circle" : "terminal") { reviewConsole = true }.disabled(session.isConnected || session.isPreparing)
                    ActionButton(title: "Back to VMs", icon: "chevron.left") { model.openNativeDashboard(path: "/vms", label: "VMs") }
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
                    .frame(minHeight: 280)
                if !session.isConnected {
                    Text("The terminal accepts keyboard input after connection. ANSI color, cursor movement, erase, and alternate-screen controls are supported; advanced terminal modes may differ from a full xterm.")
                        .font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                }
                HStack(spacing: 8) {
                    ActionButton(title: "Ctrl-C", icon: "stop.fill") { session.sendControlC() }.disabled(!session.isConnected)
                    Text("Click terminal to type · Paste button for clipboard")
                        .font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                }
            }
        }
        .padding(16)
        .task(id: credentialScope) {
            session.updateCredentials(
                apiBaseURL: model.settings.apiBaseURL,
                userID: model.userIDForRequests,
                token: model.authTokenForRequests,
                isImpersonating: !model.settings.impersonationToken.isEmpty || !model.settings.impersonatingUserID.isEmpty,
                provisioningFlow: model.selectedNativeDashboardQuery["provisioning"] == "1",
                organizationID: model.selectedOrganizationID
            )
            reviewConsole = true
        }
        .confirmationDialog(
            "Open VM console?",
            isPresented: $reviewConsole,
            titleVisibility: .visible
        ) {
            Button("Open console") { startSession(reviewed: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This opens a server shell for \(vmName). If the VM is stopped, opening the console may start it.")
        }
        .onDisappear { session.disconnect() }
    }

    private var credentialScope: String {
        "\(model.settings.apiBaseURL)|\(model.userIDForRequests)|\(model.authTokenForRequests.hashValue)|\(model.settings.impersonationToken.hashValue)|\(model.settings.impersonatingUserID)|\(model.selectedOrganizationID)|\(model.selectedNativeDashboardQuery["provisioning"] ?? "")"
    }

    private func startSession(reviewed: Bool) {
        if session.isConnected || session.isPreparing { return }
        session.connect(reviewed: reviewed)
    }

}
