import SwiftUI

struct NativeVMConsolePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @StateObject private var session: NativeVMConsoleSession
    @State private var command = ""
    private let vmName: String

    init(vmName: String, apiBaseURL: String, userID: String, token: String, isImpersonating: Bool, provisioningFlow: Bool) {
        self.vmName = vmName
        _session = StateObject(wrappedValue: NativeVMConsoleSession(
            apiBaseURL: apiBaseURL,
            vmName: vmName,
            userID: userID,
            token: token,
            isImpersonating: isImpersonating,
            provisioningFlow: provisioningFlow
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NativeGroupPanel(title: "VM console", subtitle: "Interactive console session · \(vmName)") {
                HStack(spacing: 8) {
                    Text(session.status).font(.system(size: 12, weight: .medium)).foregroundStyle(session.isConnected ? theme.green : theme.textSecondary)
                    Spacer()
                    ActionButton(title: "Reconnect", icon: "arrow.clockwise") { session.disconnect(); startSession() }.disabled(session.isConnected || session.isPreparing)
                    ActionButton(title: "Back to VMs", icon: "chevron.left") { model.openNativeDashboard(path: "/vms", label: "VMs") }
                }
                ScrollViewReader { proxy in
                    ScrollView([.horizontal, .vertical]) {
                        Text(session.output.isEmpty ? "Waiting for VM console output…" : session.output)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(theme.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
                            .id("vm-console-end")
                            .padding(12)
                    }
                    .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
                    .background(GeometryReader { geometry in
                        Color.clear
                            .onChange(of: geometry.size, initial: true) { _, size in
                                guard session.isConnected else { return }
                                session.resize(columns: Int(size.width / 7), rows: Int(size.height / 15))
                            }
                            .onChange(of: session.isConnected) { _, connected in
                                if connected {
                                    session.resize(columns: Int(geometry.size.width / 7), rows: Int(geometry.size.height / 15))
                                }
                            }
                    })
                    .onChange(of: session.output) { _, _ in proxy.scrollTo("vm-console-end", anchor: .bottom) }
                }
                HStack(spacing: 8) {
                    TextField("Enter a command", text: $command)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit(sendCommand)
                    ActionButton(title: "Send", icon: "arrow.up") { sendCommand() }.disabled(!session.isConnected || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    ActionButton(title: "Ctrl-C", icon: "stop.fill") { session.sendControlC() }.disabled(!session.isConnected)
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
                provisioningFlow: model.selectedNativeDashboardQuery["provisioning"] == "1"
            )
            startSession()
        }
        .onDisappear { session.disconnect() }
    }

    private var credentialScope: String {
        "\(model.settings.apiBaseURL)|\(model.userIDForRequests)|\(model.authTokenForRequests.hashValue)|\(model.settings.impersonationToken.hashValue)|\(model.settings.impersonatingUserID)|\(model.selectedNativeDashboardQuery["provisioning"] ?? "")"
    }

    private func startSession() {
        if session.isConnected || session.isPreparing { return }
        session.connect()
    }

    private func sendCommand() {
        let value = command
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        session.sendLine(value)
        command = ""
    }
}
