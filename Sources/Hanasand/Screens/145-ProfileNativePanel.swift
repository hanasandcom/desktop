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

struct ProfileNativePanel: View {
    @EnvironmentObject var model: DesktopAgentModel
    @Environment(\.desktopTheme) var theme
    @State var pendingSessionRevoke: ProfileAccountSession?
    @State private var accountSessions: [ProfileAccountSession] = []
    @State private var sessionSearch = ""
    @State private var expandedSessionID: Int?
    @State private var isLoadingAccountSessions = false
    @State private var accountSessionsError: String?
    @State private var accountSessionsStatus: String?
    @State private var isMutatingAccountSessions = false
    @State private var accountActivity: AccountActivityStats?
    @State private var accountActivityError: String?
    @State private var isLoadingAccountActivity = false
    @State var pendingCertificateDelete: DashboardCertificate?
    @State var pendingSshKeyDelete: ProfileSshKey?
    @State var isAddingSshKey = false
    @State var confirmRevokeOtherSessions = false
    @State var confirmLogout = false
    @State var confirmDeleteAccount = false

    var body: some View {
        if let profile = model.profile {
            VStack(alignment: .leading, spacing: 14) {
                NativeGroupPanel(title: "Account", subtitle: profile.id) {
                    HStack(spacing: 8) {
                        Image(systemName: profile.active == false ? "person.crop.circle.badge.xmark" : "person.crop.circle")
                            .foregroundStyle(profile.active == false ? theme.danger : theme.accent)
                        Text(profile.displayName).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                        Text(profile.active == false ? "Inactive" : "Active").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary)
                    }
                    Text("ID  \(profile.id)  ·  Avatar  \(profile.avatar ?? "none")")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(theme.textTertiary)
                        .textSelection(.enabled)
                    SettingsField(label: "Display name", text: $model.profileEditName)
                        .disabled(!model.canEditProfileIdentity || model.isSavingProfileIdentity)
                    SettingsField(label: "Username", text: $model.profileEditUsername)
                        .disabled(!model.canEditProfileIdentity || model.isSavingProfileIdentity)
                        .autocorrectionDisabled()
                    if model.isProfileIdentityImpersonating {
                        NativeNotice(message: "Return to your own account to edit profile details.", tone: .info)
                    }
                    if model.isLoadingProfileIdentity {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading profile details…")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                    HStack(spacing: 10) {
                        Button {
                            Task { await model.updateProfileIdentity() }
                        } label: {
                            Label(model.isSavingProfileIdentity ? "Saving profile…" : "Save profile", systemImage: "checkmark")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canSaveProfileIdentity)
                        if model.isSavingProfileIdentity {
                            ProgressView().controlSize(.small)
                        }
                    }
                    if let message = model.profileIdentityError {
                        NativeNotice(message: message, title: model.profileIdentityLoaded ? "Profile was not updated" : "Profile details unavailable")
                    }
                    if let message = model.profileIdentityNotice {
                        NativeNotice(message: message, title: "Profile updated", tone: .success)
                    }
                    HStack(spacing: 10) {
                        ActionButton(title: "Log out", icon: "rectangle.portrait.and.arrow.right") {
                            confirmLogout = true
                        }
                        ActionButton(title: "Delete account", icon: "trash", tone: .danger) {
                            confirmDeleteAccount = true
                        }
                    }
                    if let roles = profile.roles, !roles.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                            ForEach(roles) { role in
                                let priorityText: String = role.priority.map { String($0) } ?? "unknown"
                                CompactInfoCard(
                                    title: role.displayName,
                                    lines: [
                                        role.description ?? role.id,
                                        "Priority: \(priorityText)",
                                    ]
                                )
                            }
                        }
                    } else {
                        CompactInfoCard(title: "Roles", lines: ["No roles returned for this session."])
                    }
                }

                accountActivitySection

                NativeGroupPanel(title: "Security", subtitle: "Active sessions and SSH certificates") {
                    HStack(spacing: 12) {
                        FeatureCard(title: "Token expiry", value: profile.expiresAt.map { formatDateText($0, fallback: $0) } ?? "No expiry", icon: "key")
                        FeatureCard(
                            title: "Active sessions",
                            value: isLoadingAccountSessions ? "Loading" : (accountSessionsError == nil ? "\(accountSessions.filter(\.isActive).count)" : "Unavailable"),
                            icon: "laptopcomputer"
                        )
                        FeatureCard(title: "Managed certs", value: "\(model.profileCertificates.filter { $0.isManaged }.count)", icon: "checkmark.shield")
                    }
                    HStack(spacing: 10) {
                        ActionButton(title: "Refresh security", icon: "arrow.clockwise") {
                            Task {
                                await model.loadNativeDashboardData()
                                await loadAccountSessions()
                            }
                        }
                        ActionButton(title: "Logout others", icon: "rectangle.portrait.and.arrow.right", tone: .danger) {
                            confirmRevokeOtherSessions = true
                        }
                        .disabled(isMutatingAccountSessions || accountSessions.filter(\.isActive).filter { !$0.current }.isEmpty || model.isProfileIdentityImpersonating)
                    }

                    if model.isProfileIdentityImpersonating {
                        NativeNotice(message: "Return to your own account to review or change sessions.", tone: .info)
                    } else {
                        TextField("Find a session by device, IP, network, or status", text: $sessionSearch)
                            .textFieldStyle(.roundedBorder)
                            .disabled(isMutatingAccountSessions)
                        if isLoadingAccountSessions {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Loading signed-in devices…").font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                            }
                        } else if let accountSessionsError {
                            NativeNotice(message: accountSessionsError, title: "Sessions unavailable")
                            ActionButton(title: "Retry sessions", icon: "arrow.clockwise") { Task { await loadAccountSessions() } }
                        } else if accountSessions.isEmpty {
                            CompactInfoCard(title: "No sessions found", lines: ["No session records were returned for this account."])
                        } else if visibleAccountSessions.isEmpty {
                            CompactInfoCard(title: "No matching sessions", lines: ["Try another device, address, network, or status."])
                        } else {
                            if let accountSessionsStatus {
                                NativeNotice(message: accountSessionsStatus, tone: .success)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                                ForEach(visibleAccountSessions) { session in
                                    VStack(alignment: .leading, spacing: 10) {
                                        CompactInfoCard(
                                            title: "\(session.deviceLabel) · \(session.current ? "this device" : session.isActive ? "active" : "revoked")",
                                            lines: [
                                                session.addressLabel,
                                                "Last active: \(formatDateText(session.lastSeenAt, fallback: "unknown"))",
                                                session.locationLabel,
                                            ]
                                        )
                                        HStack(spacing: 8) {
                                            ActionButton(title: expandedSessionID == session.id ? "Hide details" : "Device details", icon: "info.circle") {
                                                expandedSessionID = expandedSessionID == session.id ? nil : session.id
                                            }
                                            if session.isActive {
                                                ActionButton(title: session.current ? "Log out this device" : "Revoke session", icon: "xmark.shield", tone: .danger) {
                                                    if session.current { confirmLogout = true }
                                                    else { pendingSessionRevoke = session }
                                                }
                                                .disabled(isMutatingAccountSessions)
                                            }
                                        }
                                        if expandedSessionID == session.id {
                                            VStack(alignment: .leading, spacing: 5) {
                                                Text("Network: \(session.networkLabel)")
                                                Text("Approximate location: \(session.locationLabel)")
                                                Text("Signed in: \(formatDateText(session.createdAt, fallback: "unknown"))")
                                                Text("User agent: \(session.userAgent.isEmpty ? "Not recorded" : session.userAgent)")
                                                    .textSelection(.enabled)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(theme.textTertiary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if model.profileCertificates.isEmpty {
                        CompactInfoCard(title: "Certificates", lines: ["No certificates returned."])
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                            ForEach(model.profileCertificates) { certificate in
                                VStack(alignment: .leading, spacing: 10) {
                                    CompactInfoCard(
                                        title: certificate.name,
                                        lines: [
                                            certificate.isManaged ? "Managed by Hanasand API" : "User managed",
                                            "Owner: \(certificate.owner ?? "unknown")",
                                            "Key: \(certificate.keySuffix)",
                                        ]
                                    )
                                    HStack {
                                        Spacer()
                                        ActionButton(title: "Delete", icon: "trash", tone: .danger) {
                                            pendingCertificateDelete = certificate
                                        }
                                        .disabled(model.isLoadingNativeDashboard)
                                    }
                                }
                            }
                        }
                    }

                    sshKeysSection
                }
            }
            .alert("Revoke session?", isPresented: sessionRevokePresented) {
                Button("Revoke", role: .destructive) {
                    guard let pendingSessionRevoke else { return }
                    Task { await revokeAccountSession(pendingSessionRevoke) }
                }
                Button("Cancel", role: .cancel) {
                    pendingSessionRevoke = nil
                }
            } message: {
                Text("This will immediately revoke the selected \(pendingSessionRevoke?.deviceLabel ?? "device") session. That device will need to sign in again.")
            }
            .alert("Delete certificate?", isPresented: certificateDeletePresented) {
                Button("Delete", role: .destructive) {
                    guard let pendingCertificateDelete else { return }
                    Task { await model.deleteProfileCertificate(pendingCertificateDelete) }
                }
                Button("Cancel", role: .cancel) {
                    pendingCertificateDelete = nil
                }
            } message: {
                Text("This removes \(pendingCertificateDelete?.name ?? "the selected certificate") from the account.")
            }
            .alert("Remove SSH key?", isPresented: sshKeyDeletePresented) {
                Button("Remove", role: .destructive) {
                    guard let pendingSshKeyDelete else { return }
                    Task { await model.deleteProfileSshKey(pendingSshKeyDelete) }
                }
                Button("Cancel", role: .cancel) { pendingSshKeyDelete = nil }
            } message: {
                Text("This removes \(pendingSshKeyDelete?.name ?? "the selected key") from your profile and managed hosts.")
            }
            .alert("Logout other devices?", isPresented: $confirmRevokeOtherSessions) {
                Button("Logout others", role: .destructive) {
                    Task { await revokeOtherAccountSessions() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This keeps the current token and revokes other active sessions for this account.")
            }
            .alert("Log out of Hanasand?", isPresented: $confirmLogout) {
                Button("Log out", role: .destructive) {
                    Task { await model.logoutFromHanasand() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears the desktop app session and returns to the login screen.")
            }
            .alert("Delete account?", isPresented: $confirmDeleteAccount) {
                Button("Delete", role: .destructive) {
                    Task { await model.scheduleAccountDeletion() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This logs out every device and schedules permanent deletion after 30 days.")
            }
            .task(id: sessionCredentialKey) { await loadAccountSessions() }
            .task(id: activityCredentialKey) { await loadAccountActivity() }
        } else {
            NativeEmptyState(title: "Profile not loaded", message: "Hanasand session is not ready yet. Log in again if this profile does not load.")
        }
    }

    private var visibleAccountSessions: [ProfileAccountSession] {
        let terms = sessionSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return accountSessions.filter { $0.matches(search: terms) }
    }

    private var sessionCredentialKey: String {
        "\(model.settings.apiBaseURL)|\(model.settings.userID)|\(model.settings.authToken.hashValue)|\(model.settings.impersonationToken.hashValue)|\(model.settings.impersonatingUserID)"
    }

    private var activityCredentialKey: String { sessionCredentialKey }

    @ViewBuilder
    private var accountActivitySection: some View {
        NativeGroupPanel(title: "Activity", subtitle: "Recent sign-ins") {
            HStack {
                Spacer()
                ActionButton(title: "Refresh activity", icon: "arrow.clockwise") { Task { await loadAccountActivity() } }
                    .disabled(isLoadingAccountActivity || model.isProfileIdentityImpersonating)
            }
            if model.isProfileIdentityImpersonating {
                NativeNotice(message: "Return to your own account to view account activity.", tone: .info)
            } else if isLoadingAccountActivity {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading account activity…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                }
            } else if let accountActivityError {
                NativeNotice(message: accountActivityError, title: "Account activity unavailable")
                ActionButton(title: "Retry activity", icon: "arrow.clockwise") { Task { await loadAccountActivity() } }
            } else if let accountActivity {
                let lastYear = recentAccountActivity(accountActivity.loginDays, dayCount: 365)
                let lastTwelveWeeks = recentAccountActivity(accountActivity.loginDays, dayCount: 84)
                VStack(alignment: .leading, spacing: 9) {
                    Text("Login activity")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.text)
                    Text("\(lastYear.filter { $0.logins > 0 }.count) active days · \(lastYear.reduce(0) { $0 + $1.logins }) sign-ins in the past year")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 10, maximum: 12), spacing: 4)], spacing: 4) {
                        ForEach(lastTwelveWeeks) { day in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(day.logins == 0 ? theme.divider : theme.accent.opacity(min(1, 0.3 + Double(day.logins) / 8)))
                                .frame(width: 11, height: 11)
                                .help("\(day.day): \(day.logins) sign-ins")
                                .accessibilityLabel("\(day.day): \(day.logins) sign-ins")
                        }
                    }
                    Text("Past 12 weeks · More color shows more sign-ins")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("No account activity data was returned.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    @MainActor
    private func loadAccountActivity() async {
        guard model.hasHanasandAuth, !model.isProfileIdentityImpersonating else {
            accountActivity = nil
            accountActivityError = model.isProfileIdentityImpersonating ? nil : "Sign in to view account activity."
            return
        }
        isLoadingAccountActivity = true
        accountActivityError = nil
        accountActivity = nil
        defer { isLoadingAccountActivity = false }
        let requestCredentialKey = activityCredentialKey
        do {
            let stats = try await model.loadOwnAccountActivityStats()
            guard activityCredentialKey == requestCredentialKey else { return }
            accountActivity = stats
        } catch {
            guard activityCredentialKey == requestCredentialKey else { return }
            accountActivityError = error.localizedDescription
        }
    }

    @MainActor
    private func loadAccountSessions() async {
        guard model.hasHanasandAuth, !model.isProfileIdentityImpersonating else {
            accountSessions = []
            accountSessionsError = model.isProfileIdentityImpersonating ? nil : "Sign in to review account sessions."
            return
        }
        isLoadingAccountSessions = true
        accountSessionsError = nil
        accountSessionsStatus = nil
        accountSessions = []
        defer { isLoadingAccountSessions = false }
        let requestCredentialKey = sessionCredentialKey
        do {
            let sessions = try await makeSessionsClient().load()
            guard sessionCredentialKey == requestCredentialKey else { return }
            accountSessions = sessions.sorted { $0.current && !$1.current }
        } catch {
            guard sessionCredentialKey == requestCredentialKey else { return }
            accountSessionsError = error.localizedDescription
        }
    }

    private func makeSessionsClient() throws -> ProfileAccountSessionsClient {
        try ProfileAccountSessionsClient(
            baseURL: model.settings.apiBaseURL.normalizedBaseURL,
            userID: model.settings.userID,
            token: model.settings.authToken,
            impersonationToken: model.settings.impersonationToken,
            impersonatingUserID: model.settings.impersonatingUserID
        )
    }

    @MainActor
    private func revokeAccountSession(_ session: ProfileAccountSession) async {
        guard !session.current, !isMutatingAccountSessions else { return }
        isMutatingAccountSessions = true
        accountSessionsError = nil
        accountSessionsStatus = nil
        defer { isMutatingAccountSessions = false }
        do {
            try await makeSessionsClient().revoke(session)
            await loadAccountSessions()
            accountSessionsStatus = "Session revoked."
        } catch {
            accountSessionsError = error.localizedDescription
        }
    }

    @MainActor
    private func revokeOtherAccountSessions() async {
        guard !isMutatingAccountSessions, !model.isProfileIdentityImpersonating else { return }
        isMutatingAccountSessions = true
        accountSessionsError = nil
        accountSessionsStatus = nil
        defer { isMutatingAccountSessions = false }
        do {
            try await makeSessionsClient().revokeOthers()
            await loadAccountSessions()
            accountSessionsStatus = "Other sessions revoked."
        } catch {
            accountSessionsError = error.localizedDescription
        }
    }

    @ViewBuilder
    var sshKeysSection: some View {
        Divider().overlay(theme.divider)
        if let message = model.profileSshKeyError {
            NativeNotice(message: message, title: "SSH key was not changed")
        }
        if let message = model.profileSshKeyNotice {
            NativeNotice(message: message, title: "SSH key updated", tone: .success)
        }
        if model.profileSshKeys.isEmpty, let message = model.profileSshKeyLoadError {
            NativeNotice(message: message, title: "SSH keys unavailable")
        }
        HStack(alignment: .firstTextBaseline) {
            Text("SSH keys").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text)
            Spacer()
            ActionButton(title: isAddingSshKey ? "Cancel" : "Add SSH key", icon: isAddingSshKey ? "xmark" : "plus") {
                isAddingSshKey.toggle()
            }
            .disabled(model.isLoadingNativeDashboard || model.isProfileIdentityImpersonating)
        }
        if model.isProfileIdentityImpersonating {
            NativeNotice(message: "Return to your own account to manage SSH keys.", tone: .info)
        }
        if isAddingSshKey {
            TextField("Key name", text: $model.profileSshKeyName)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $model.profileSshPublicKey)
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 86)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.divider))
            ActionButton(title: model.isLoadingNativeDashboard ? "Saving…" : "Save SSH key", icon: "checkmark") {
                Task {
                    await model.addProfileSshKey()
                    if model.profileSshKeyName.isEmpty && model.profileSshPublicKey.isEmpty {
                        isAddingSshKey = false
                    }
                }
            }
            .disabled(model.isLoadingNativeDashboard || model.profileSshKeyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.profileSshPublicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isProfileIdentityImpersonating)
        }
        if model.profileSshKeys.isEmpty && model.profileSshKeyLoadError == nil {
            CompactInfoCard(title: "SSH keys", lines: ["No SSH keys added."])
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                ForEach(model.profileSshKeys) { key in
                    VStack(alignment: .leading, spacing: 8) {
                        CompactInfoCard(
                            title: "\(key.name) · \(key.keyType)",
                            lines: [
                                key.fingerprint,
                                "Added: \(key.addedAt.map { formatDateText($0, fallback: $0) } ?? "unknown")",
                                "Last used: \(key.lastUsedAt.map { formatDateText($0, fallback: $0) } ?? "never")",
                                [key.lastUsedServer, key.lastUsedIp].compactMap { $0 }.joined(separator: " · "),
                            ].filter { !$0.isEmpty }
                        )
                        HStack {
                            Spacer()
                            ActionButton(title: "Remove", icon: "trash", tone: .danger) {
                                pendingSshKeyDelete = key
                            }
                            .disabled(model.isLoadingNativeDashboard || model.isProfileIdentityImpersonating)
                        }
                    }
                }
            }
        }
    }

    var sessionRevokePresented: Binding<Bool> {
        Binding(
            get: { pendingSessionRevoke != nil },
            set: { visible in
                if !visible {
                    pendingSessionRevoke = nil
                }
            }
        )
    }

    var certificateDeletePresented: Binding<Bool> {
        Binding(
            get: { pendingCertificateDelete != nil },
            set: { visible in
                if !visible {
                    pendingCertificateDelete = nil
                }
            }
        )
    }

    var sshKeyDeletePresented: Binding<Bool> {
        Binding(
            get: { pendingSshKeyDelete != nil },
            set: { visible in
                if !visible { pendingSshKeyDelete = nil }
            }
        )
    }
}

private func recentAccountActivity(_ days: [AccountActivityDay], dayCount: Int) -> [AccountActivityDay] {
    let dayCounts = Dictionary(uniqueKeysWithValues: days.map { ($0.day, $0.logins) })
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    let end = calendar.startOfDay(for: Date())
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return (0..<max(0, dayCount)).compactMap { offset in
        guard let date = calendar.date(byAdding: .day, value: offset - dayCount + 1, to: end) else { return nil }
        let day = formatter.string(from: date)
        return AccountActivityDay(day: day, logins: dayCounts[day] ?? 0)
    }
}
