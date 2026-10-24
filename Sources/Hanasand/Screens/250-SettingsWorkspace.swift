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

struct NativeSettingsConfigurationDraft: Equatable {
    var websiteBaseURL: String
    var apiBaseURL: String
    var internalAPIBaseURL: String
    var cdnBaseURL: String
    var codexAPIPath: String
    var aiAPIURL: String
    var desktopAgentBaseURL: String
    var vpnURLScheme: String
    var rdpHost: String
    var vncHost: String
    var rdpUser: String
    var remoteDesktopProtocol: String
    var remoteDesktopTunnelCommand: String
    var serverBaseURL: String
    var serverStartPath: String
    var serverStopPath: String
    var serverLogsPath: String

    init(settings: HanasandDesktopSettings) {
        websiteBaseURL = settings.websiteBaseURL
        apiBaseURL = settings.apiBaseURL
        internalAPIBaseURL = settings.internalAPIBaseURL
        cdnBaseURL = settings.cdnBaseURL
        codexAPIPath = settings.codexAPIPath
        aiAPIURL = settings.aiAPIURL
        desktopAgentBaseURL = settings.desktopAgentBaseURL
        vpnURLScheme = settings.vpnURLScheme
        rdpHost = settings.rdpHost
        vncHost = settings.vncHost
        rdpUser = settings.rdpUser
        remoteDesktopProtocol = settings.remoteDesktopProtocol
        remoteDesktopTunnelCommand = settings.remoteDesktopTunnelCommand
        serverBaseURL = settings.serverBaseURL
        serverStartPath = settings.serverStartPath
        serverStopPath = settings.serverStopPath
        serverLogsPath = settings.serverLogsPath
    }

    func applying(to current: HanasandDesktopSettings) -> HanasandDesktopSettings {
        var updated = current
        updated.websiteBaseURL = websiteBaseURL
        updated.apiBaseURL = apiBaseURL
        updated.internalAPIBaseURL = internalAPIBaseURL
        updated.cdnBaseURL = cdnBaseURL
        updated.codexAPIPath = codexAPIPath
        updated.aiAPIURL = aiAPIURL
        updated.desktopAgentBaseURL = desktopAgentBaseURL
        updated.vpnURLScheme = vpnURLScheme
        updated.rdpHost = rdpHost
        updated.vncHost = vncHost
        updated.rdpUser = rdpUser
        updated.remoteDesktopProtocol = remoteDesktopProtocol
        updated.remoteDesktopTunnelCommand = remoteDesktopTunnelCommand
        updated.serverBaseURL = serverBaseURL
        updated.serverStartPath = serverStartPath
        updated.serverStopPath = serverStopPath
        updated.serverLogsPath = serverLogsPath
        return updated
    }
}

struct SettingsWorkspace: View {
    @EnvironmentObject var model: DesktopAgentModel
    @Environment(\.desktopTheme) var theme
    @State var showEndpointSettings = false
    @State var showRemoteSettings = false
    @State var confirmLogout = false
    @State private var configurationDraft: NativeSettingsConfigurationDraft?

    private var draft: NativeSettingsConfigurationDraft {
        configurationDraft ?? NativeSettingsConfigurationDraft(settings: model.settings)
    }

    private var draftSettings: HanasandDesktopSettings {
        draft.applying(to: model.settings)
    }

    private var hasConfigurationChanges: Bool {
        draft != NativeSettingsConfigurationDraft(settings: model.settings)
    }

    var body: some View {
        FeatureWorkspace(title: "Settings", subtitle: "Account, appearance, updater, and advanced connections") {
            HStack(spacing: 12) {
                FeatureCard(title: "Endpoints", value: model.settings.hasValidEndpoints ? "Valid" : "Check", icon: model.settings.hasValidEndpoints ? "checkmark.seal" : "exclamationmark.triangle")
                FeatureCard(title: "Session", value: model.hasHanasandAuth ? "Ready" : "Login", icon: "person.crop.circle.badge.checkmark")
                FeatureCard(title: "Update checks", value: settingsUpdateIntervalLabel, icon: "timer")
            }

            NativeGroupPanel(title: "Account", subtitle: model.hasHanasandAuth ? "Signed in and ready for API calls" : "Sign in from the login screen to refresh the session") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: model.hasHanasandAuth ? "checkmark.seal.fill" : "person.crop.circle.badge.exclamationmark")
                            .foregroundStyle(model.hasHanasandAuth ? theme.green : theme.textTertiary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.hasHanasandAuth ? "Session active" : "Session unavailable")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(theme.text)
                            Text(model.settings.userID.isEmpty ? "Hanasand handles tokens in the background after login." : model.settings.userID)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(theme.textSecondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(theme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    HStack {
                        Spacer()
                        ActionButton(title: "Log out", icon: "rectangle.portrait.and.arrow.right", tone: .danger) {
                            confirmLogout = true
                        }
                        .disabled(!model.hasHanasandAuth)
                    }
                    SettingsValidationPanel(settings: draftSettings)
                }
            }

            NativeGroupPanel(title: "Theme", subtitle: "Native appearance") {
                HStack(spacing: 8) {
                    ForEach(AppearancePreference.allCases) { option in
                        AppearanceOptionButton(option: option, isSelected: model.appearancePreference == option) {
                            model.appearancePreference = option
                        }
                    }
                    Spacer()
                }
            }

            SettingsDisclosurePanel(
                title: "Advanced endpoints",
                subtitle: endpointSummary,
                icon: "network",
                isExpanded: $showEndpointSettings
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    SettingsField(label: "Site base URL", text: draftBinding(\.websiteBaseURL))
                    SettingsField(label: "API base", text: draftBinding(\.apiBaseURL))
                    SettingsField(label: "Internal API", text: draftBinding(\.internalAPIBaseURL))
                    SettingsField(label: "CDN base", text: draftBinding(\.cdnBaseURL))
                    SettingsField(label: "Codex path", text: draftBinding(\.codexAPIPath))
                    SettingsField(label: "AI endpoint", text: draftBinding(\.aiAPIURL))
                    SettingsField(label: "Desktop agent", text: draftBinding(\.desktopAgentBaseURL))
                }
            }

            SettingsDisclosurePanel(
                title: "Remote control",
                subtitle: "\(model.remoteDesktopProtocolLabel) · \(model.settings.serverBaseURL.normalizedBaseURL.host ?? "server")",
                icon: model.remoteDesktopProtocolIcon,
                isExpanded: $showRemoteSettings
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    SettingsField(label: "VPN URL", text: draftBinding(\.vpnURLScheme))
                    Picker("Remote protocol", selection: draftBinding(\.remoteDesktopProtocol)) {
                        ForEach(RemoteDesktopProtocol.allCases) { remoteProtocol in
                            Label(remoteProtocol.label, systemImage: remoteProtocol.icon)
                                .tag(remoteProtocol.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    SettingsField(label: "RDP host", text: draftBinding(\.rdpHost))
                    SettingsField(label: "VNC host", text: draftBinding(\.vncHost))
                    SettingsField(label: "Remote user", text: draftBinding(\.rdpUser))
                    SettingsField(label: "Tunnel command", text: draftBinding(\.remoteDesktopTunnelCommand))
                    SettingsField(label: "Server base", text: draftBinding(\.serverBaseURL))
                    SettingsField(label: "Start path", text: draftBinding(\.serverStartPath))
                    SettingsField(label: "Stop path", text: draftBinding(\.serverStopPath))
                    SettingsField(label: "Logs path", text: draftBinding(\.serverLogsPath))
                }
            }

            HStack(spacing: 10) {
                ActionButton(title: "Discard changes", icon: "arrow.uturn.backward") {
                    configurationDraft = nil
                }
                .disabled(!hasConfigurationChanges)
                ActionButton(title: "Save changes", icon: "checkmark") {
                    model.settings = draftSettings
                    configurationDraft = nil
                }
                .disabled(!hasConfigurationChanges || !draftSettings.hasValidEndpoints)
                if hasConfigurationChanges && !draftSettings.hasValidEndpoints {
                    Text("Fix endpoint issues before saving.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .confirmationDialog("Log out of Hanasand?", isPresented: $confirmLogout) {
            Button("Log out", role: .destructive) {
                Task { await model.logoutFromHanasand() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the desktop app session and returns to the login screen.")
        }
    }

    var endpointSummary: String {
        let host = model.settings.apiBaseURL.normalizedBaseURL.host ?? "API"
        return model.settings.hasValidEndpoints ? "\(host) · all URLs valid" : "\(host) · review URL issues"
    }

    private func draftBinding<Value>(_ keyPath: WritableKeyPath<NativeSettingsConfigurationDraft, Value>) -> Binding<Value> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { value in
                var updated = draft
                updated[keyPath: keyPath] = value
                configurationDraft = updated
            }
        )
    }

    var settingsUpdateIntervalLabel: String {
        let seconds = DesktopAgentModel.automaticUpdateCheckInterval
        if seconds >= 60 { return "\(Int(seconds / 60)) min" }
        return "\(Int(seconds)) sec"
    }
}
