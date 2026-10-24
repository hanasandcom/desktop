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
                                loginCard
                                if model.passwordResetStep != .idle {
                                    recoveryCard
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                            } else {
                                pendingDeletionCard
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .frame(width: 392, alignment: .leading)
                        .padding(.vertical, 24)
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
        VStack(spacing: 9) {
            Text("Hanasand")
                .font(.system(size: 46, weight: .semibold, design: .serif))
                .kerning(0.5)
                .foregroundStyle(theme.text)
            Rectangle()
                .fill(theme.text.opacity(0.22))
                .frame(width: 44, height: 1)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, 14)
    }

    var loginCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 7) {
                authTextField("Username", text: $model.loginUsername, field: .username) {
                    focusedField = .password
                }
                authSecureField("Password", text: $model.loginPassword, field: .password) {
                    Task { await model.loginToHanasand() }
                }
            }

            HStack(alignment: .center, spacing: 12) {
                primaryButton(
                    title: model.isLoggingIn ? "Logging in" : "Log in",
                    busy: model.isLoggingIn,
                    action: { Task { await model.loginToHanasand() } }
                )
                .disabled(model.isLoggingIn)

                Spacer(minLength: 12)

                if model.passwordResetStep == .idle {
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                            model.beginPasswordReset()
                            focusedField = .resetUsername
                        }
                    } label: {
                        Text("Forgot password?")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }

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
            AccountSignupForm(focusedField: $focusedField)
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

private struct AccountSignupForm: View {
    @FocusState.Binding var focusedField: HanasandLoginGate.Field?
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var expanded = false
    @State private var waitingForCode = false
    @State private var challengeID: String?
    @State private var name = ""
    @State private var username = ""
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                expanded.toggle()
                model.loginStatus = ""
                focusedField = expanded ? .signupName : .username
            } label: {
                Text(expanded ? "Already have an account? Log in" : "Create an account")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(model.isLoggingIn)

            if expanded {
                Divider().overlay(theme.divider)
                Text("Create your Hanasand account")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.text)
                TextField("Full name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .signupName)
                    .id(HanasandLoginGate.Field.signupName)
                    .onSubmit { focusedField = .signupUsername }
                    .disabled(model.isLoggingIn || waitingForCode)
                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .signupUsername)
                    .id(HanasandLoginGate.Field.signupUsername)
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

                HStack(spacing: 8) {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack(spacing: 7) {
                            if model.isLoggingIn { ProgressView().controlSize(.small) }
                            Text(waitingForCode ? "Verify email and create account" : "Send verification code")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isLoggingIn || !canSubmit)

                    if waitingForCode {
                        Button("Start over") {
                            waitingForCode = false
                            challengeID = nil
                            code = ""
                            model.loginStatus = ""
                            focusedField = .signupName
                        }
                        .disabled(model.isLoggingIn)
                    }
                }
            }
        }
    }

    private var canSubmit: Bool {
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let emailLooksValid = cleanEmail.range(of: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", options: .regularExpression) != nil
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              cleanUsername.range(of: "^[a-z0-9][a-z0-9._-]{2,39}$", options: .regularExpression) != nil,
              emailLooksValid, AccountSignupClient.passwordMeetsRequirements(password) else { return false }
        return !waitingForCode || (challengeID != nil && code.count == 6)
    }

    @MainActor private func submit() async {
        guard canSubmit else { return }
        do {
            let result = try await model.submitAccountSignup(
                name: name,
                username: username,
                email: email,
                password: password,
                challengeID: challengeID,
                code: waitingForCode ? code : nil
            )
            if case let .verificationRequired(value) = result {
                challengeID = value
                waitingForCode = true
                code = ""
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
