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

extension HanasandLoginGate {

    enum Field: Hashable {
        case username
        case password
        case resetUsername
        case resetCode
        case resetPassword
        case resetConfirm
        case signupName
        case signupUsername
        case signupEmail
        case signupPassword
        case signupCode
    }

    var body: some View {
        ZStack {
            theme.background
            GeometryReader { geometry in
                ScrollViewReader { scrollProxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 16) {
                            masthead
                            if model.pendingDeletionUserID.isEmpty {
                                if showsSignupForm {
                                    signupCard
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                } else {
                                    loginCard
                                    if model.passwordResetStep != .idle {
                                        recoveryCard
                                            .transition(.opacity.combined(with: .move(edge: .top)))
                                    }
                                }
                            } else {
                                pendingDeletionCard
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .frame(maxWidth: 448, alignment: .leading)
                        .padding(.vertical, 24)
                        .padding(.horizontal, 20)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: focusedField) { _, field in
                        guard let field else { return }
                        withAnimation(.easeInOut(duration: 0.18)) {
                            scrollProxy.scrollTo(field, anchor: .center)
                        }
                    }
                }
            }
        }
        .onAppear {
            focusedField = .username
        }
    }

    var masthead: some View {
        Text("Hanasand")
            .font(.system(size: 34, weight: .semibold))
            .tracking(-1.5)
            .foregroundStyle(theme.accent)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, 8)
    }

    var loginCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                authTextField("Email or username", text: $model.loginUsername, field: .username) {
                    focusedField = .password
                }
                authSecureField("Password", text: $model.loginPassword, field: .password) {
                    Task { await model.loginToHanasand() }
                }
            }

            primaryButton(
                title: model.isLoggingIn ? "Signing in…" : "Sign in",
                busy: model.isLoggingIn,
                expands: true,
                action: { Task { await model.loginToHanasand() } }
            )
            .frame(maxWidth: .infinity)
            .disabled(model.isLoggingIn)

            secondaryButton(
                title: model.isLoggingIn ? "Waiting" : "Continue with Google",
                busy: model.isLoggingIn,
                action: { Task { await model.beginGoogleSignIn() } }
            )
            .frame(maxWidth: .infinity)
            .disabled(model.isLoggingIn)

            secondaryButton(
                title: model.isLoggingIn ? "Waiting" : "Continue with SSO",
                busy: model.isLoggingIn,
                action: { model.beginHanasandSso() }
            )
            .frame(maxWidth: .infinity)
            .disabled(model.isLoggingIn)

            if !model.loginStatus.isEmpty {
                statusText(model.loginStatus, isSuccess: false)
            }

            HStack(spacing: 8) {
                Button("Create an account") {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                        model.cancelPasswordReset()
                        model.loginStatus = ""
                        showsSignupForm = true
                        focusedField = .signupUsername
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.isLoggingIn)

                Spacer(minLength: 8)

                if model.passwordResetStep == .idle {
                    Button("Forgot password?") {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                            model.beginPasswordReset()
                            focusedField = .resetUsername
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.textTertiary)
        }
        .padding(20)
        .background(theme.card)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(theme.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(theme.isLight ? 0.08 : 0.24), radius: 22, x: 0, y: 14)
    }

    var signupCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Create an account")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.text)
                Spacer()
                Button("Sign in") {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                        showsSignupForm = false
                        model.loginStatus = ""
                        focusedField = .username
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
                .disabled(model.isLoggingIn)
            }
            AccountSignupForm(focusedField: $focusedField)
            if !model.loginStatus.isEmpty {
                statusText(model.loginStatus, isSuccess: false)
            }
        }
        .padding(20)
        .background(theme.card)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(theme.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(theme.isLight ? 0.08 : 0.24), radius: 22, x: 0, y: 14)
    }

private struct AccountSignupForm: View {
    @FocusState.Binding var focusedField: HanasandLoginGate.Field?
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var waitingForCode = false
    @State private var challengeID: String?
    @State private var name = ""
    @State private var username = ""
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .signupUsername)
                    .id(HanasandLoginGate.Field.signupUsername)
                    .onSubmit { focusedField = .signupName }
                    .disabled(model.isLoggingIn || waitingForCode)
                if usernameIsReserved {
                    Text("Reserved username.")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.danger)
                }
                TextField("Full name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .signupName)
                    .id(HanasandLoginGate.Field.signupName)
                    .onSubmit { focusedField = .signupEmail }
                    .disabled(model.isLoggingIn || waitingForCode)
                TextField("Email address", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .signupEmail)
                    .id(HanasandLoginGate.Field.signupEmail)
                    .onSubmit { focusedField = .signupPassword }
                    .disabled(model.isLoggingIn || waitingForCode)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .signupPassword)
                    .id(HanasandLoginGate.Field.signupPassword)
                    .onSubmit { if canSubmit { Task { await submit() } } }
                    .disabled(model.isLoggingIn || waitingForCode)
                Text("Use at least 16 characters with an uppercase letter, lowercase letter, number, and symbol.")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if waitingForCode {
                    TextField("Six-digit email code", text: $code)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.oneTimeCode)
                        .focused($focusedField, equals: .signupCode)
                        .id(HanasandLoginGate.Field.signupCode)
                        .onSubmit { if canSubmit { Task { await submit() } } }
                        .onChange(of: code) { _, value in
                            code = String(value.filter(\.isNumber).prefix(6))
                        }
                    Text("The code expires after 10 minutes. Your signup details must stay the same while you verify.")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    Task { await submit() }
                } label: {
                    HStack(spacing: 7) {
                        if model.isLoggingIn { ProgressView().controlSize(.small) }
                        Text(waitingForCode ? "Verify email and create account" : "Create account")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(model.isLoggingIn || !canSubmit)

                if waitingForCode {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            resendVerificationButton
                            editSignupDetailsButton
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            resendVerificationButton
                            editSignupDetailsButton
                        }
                    }
                }
        }
    }

    private var resendVerificationButton: some View {
        Button {
            Task { await submit(resendingVerification: true) }
        } label: {
            Text(model.isLoggingIn ? "Sending…" : "Resend code")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(theme.textTertiary)
        .disabled(model.isLoggingIn || !canRequestVerification)
    }

    private var editSignupDetailsButton: some View {
        Button("Edit signup details") {
            waitingForCode = false
            challengeID = nil
            code = ""
            model.loginStatus = ""
            focusedField = .signupUsername
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(theme.textTertiary)
        .disabled(model.isLoggingIn)
    }

    private var canRequestVerification: Bool {
        let cleanUsername = ReservedUsernamePolicy.normalizedSignupUsername(username)
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let emailLooksValid = cleanEmail.range(of: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", options: .regularExpression) != nil
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && cleanUsername.range(of: "^[a-z0-9][a-z0-9._-]{2,39}$", options: .regularExpression) != nil
            && !ReservedUsernamePolicy.usernames.contains(cleanUsername)
            && emailLooksValid
            && AccountSignupClient.passwordMeetsRequirements(password)
    }

    private var canSubmit: Bool {
        canRequestVerification && (!waitingForCode || (challengeID != nil && code.count == 6))
    }

    private var usernameIsReserved: Bool {
        ReservedUsernamePolicy.usernames.contains(ReservedUsernamePolicy.normalizedSignupUsername(username))
    }

    @MainActor private func submit(resendingVerification: Bool = false) async {
        guard resendingVerification ? canRequestVerification : canSubmit else { return }
        do {
            let result = try await model.submitAccountSignup(
                name: name,
                username: username,
                email: email,
                password: password,
                challengeID: resendingVerification ? nil : challengeID,
                code: resendingVerification ? nil : (waitingForCode ? code : nil)
            )
            if case let .verificationRequired(value) = result {
                challengeID = value
                waitingForCode = true
                code = ""
                if resendingVerification {
                    model.loginStatus = "A new code has been sent. Check your inbox and junk folder; use the newest code."
                }
            }
        } catch {
            // The model publishes a safe, user-facing error message.
        }
    }
}

    var pendingDeletionCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Account pending deletion")
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                    .foregroundStyle(theme.text)
                Text("@\(model.pendingDeletionUserID) is scheduled to be permanently deleted on \(pendingDeletionDateText).")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                        model.clearPendingDeletionState()
                    }
                } label: {
                    Text("Go back")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                        .frame(height: 36)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.plain)

                Spacer()

                primaryButton(
                    title: model.isRestoringPendingDeletion ? "Restoring" : "Restore",
                    busy: model.isRestoringPendingDeletion,
                    action: { Task { await model.restorePendingDeletionAccount() } }
                )
                .disabled(model.isRestoringPendingDeletion)
            }
            if !model.pendingDeletionStatus.isEmpty {
                statusText(model.pendingDeletionStatus, isSuccess: model.pendingDeletionStatus.lowercased().contains("restored"))
            }
        }
        .padding(14)
        .background(theme.card)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(theme.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(theme.isLight ? 0.08 : 0.24), radius: 22, x: 0, y: 14)
    }

    var pendingDeletionDateText: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: model.pendingDeletionScheduledAt) ?? fallbackFormatter.date(from: model.pendingDeletionScheduledAt) else {
            return "the scheduled deletion time"
        }
        return date.formatted(date: .complete, time: .shortened)
    }
}
