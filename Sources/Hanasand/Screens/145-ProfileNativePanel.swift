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
    @State var pendingSessionRevoke: DashboardAuthSession?
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

                NativeGroupPanel(title: "Security", subtitle: "Active sessions and SSH certificates") {
                    HStack(spacing: 12) {
                        FeatureCard(title: "Token expiry", value: profile.expiresAt.map { formatDateText($0, fallback: $0) } ?? "No expiry", icon: "key")
                        FeatureCard(title: "Active sessions", value: "\(model.profileSessions.filter { $0.revokedAt == nil }.count)", icon: "laptopcomputer")
                        FeatureCard(title: "Managed certs", value: "\(model.profileCertificates.filter { $0.isManaged }.count)", icon: "checkmark.shield")
                    }
                    HStack(spacing: 10) {
                        ActionButton(title: "Refresh security", icon: "arrow.clockwise") {
                            Task { await model.loadNativeDashboardData() }
                        }
                        ActionButton(title: "Logout others", icon: "rectangle.portrait.and.arrow.right", tone: .danger) {
                            confirmRevokeOtherSessions = true
                        }
                        .disabled(model.profileSessions.filter { $0.revokedAt == nil }.count <= 1)
                    }

                    if model.profileSessions.isEmpty {
                        CompactInfoCard(title: "Sessions", lines: ["No session records returned."])
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                            ForEach(model.profileSessions) { session in
                                VStack(alignment: .leading, spacing: 10) {
                                    CompactInfoCard(
                                        title: "\(session.deviceLabel) \(session.revokedAt == nil ? "active" : "revoked")",
                                        lines: [
                                            "IP: \(session.ip ?? "unknown")",
                                            "Last seen: \(formatDateText(session.lastSeenAt, fallback: "unknown"))",
                                            session.userAgent ?? "Unknown client",
                                        ]
                                    )
                                    if session.revokedAt == nil {
                                        HStack {
                                            Spacer()
                                            ActionButton(title: "Revoke", icon: "xmark.shield", tone: .danger) {
                                                pendingSessionRevoke = session
                                            }
                                            .disabled(model.isLoadingNativeDashboard)
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
                    Task { await model.revokeProfileSession(pendingSessionRevoke) }
                }
                Button("Cancel", role: .cancel) {
                    pendingSessionRevoke = nil
                }
            } message: {
                Text("This will immediately revoke the selected \(pendingSessionRevoke?.deviceLabel ?? "device") session.")
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
                    Task { await model.revokeOtherProfileSessions() }
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
        } else {
            NativeEmptyState(title: "Profile not loaded", message: "Hanasand session is not ready yet. Log in again if this profile does not load.")
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
