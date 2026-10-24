import AppKit
import SwiftUI

struct SubscriptionNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var data: AccountSubscriptionEnvelope?
    @State private var loading = false
    @State private var openingBilling = false
    @State private var error = ""
    @State private var revision = 0
    @State private var requestID = UUID()

    private var scope: String {
        "\(model.settings.apiBaseURL)|\(model.userIDForRequests)|\(model.authTokenForRequests)|\(model.settings.impersonationToken)|\(revision)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Current account subscription and access")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                ActionButton(title: "Refresh", icon: "arrow.clockwise") { revision += 1 }
                    .disabled(loading || openingBilling)
            }

            if loading {
                ProgressView("Loading subscription and allowances…")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(theme.card, in: RoundedRectangle(cornerRadius: 12))
            } else if !error.isEmpty {
                NativeEmptyState(title: "Subscription unavailable", message: error)
            } else if let data {
                planCard(data)
                accessCard(data)
                allowancesCard(data)
            } else {
                NativeEmptyState(title: "Subscription unavailable", message: "Refresh to try again.")
            }
            availablePlansCard
        }
        .task(id: scope) { await refresh() }
        .onDisappear { requestID = UUID() }
    }

    private var availablePlansCard: some View {
        NativeGroupPanel(title: "Available plans", subtitle: "Current offers from Hanasand", fillsAvailableWidth: true) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(CommercialAccessPlans.all) { plan in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(plan.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(plan.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(plan.monthlyPriceLabel)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.text)
                        Text(plan.quota)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(plan.features, id: \.self) { feature in
                                Label(feature, systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                    .padding(12)
                    .background(theme.card, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.divider, lineWidth: 1))
                }
            }
            if !model.settings.impersonationToken.isEmpty {
                Text("Return to your own account to choose a plan.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            }
            Text("Subscription management opens Stripe's secure billing portal in your default browser.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textTertiary)
        }
    }

    private func planCard(_ data: AccountSubscriptionEnvelope) -> some View {
        NativeGroupPanel(title: "Subscription", subtitle: "Current account status", fillsAvailableWidth: true) {
            if let subscription = data.subscription {
                detail("Plan", value: label(subscription.planId))
                detail("Status", value: label(subscription.status))
                detail("Current period starts", value: date(subscription.currentPeriodStart))
                detail("Current period ends", value: date(subscription.currentPeriodEnd))
                if subscription.cancelAtPeriodEnd {
                    Label("Scheduled to end after the current period", systemImage: "calendar.badge.exclamationmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                }
            } else {
                Text("No subscription was reported for this account.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
            }
            ActionButton(title: openingBilling ? "Opening…" : "Manage billing", icon: "arrow.up.right") {
                Task { await openBilling() }
            }
            .disabled(loading || openingBilling || !model.settings.impersonationToken.isEmpty || !model.hasHanasandAuth)
            if !model.settings.impersonationToken.isEmpty {
                Text("Return to your own account to manage billing.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            }
            Text("Payments and subscription changes are managed securely by Stripe.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textTertiary)
        }
    }

    private func accessCard(_ data: AccountSubscriptionEnvelope) -> some View {
        NativeGroupPanel(title: "Active access", subtitle: "Features reported by active entitlements", fillsAvailableWidth: true) {
            if data.entitlements.isEmpty {
                Text("No active plan access was reported.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
            } else {
                ForEach(data.entitlements) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(label(item.planId)).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                        if item.features.isEmpty {
                            Text("No features were reported.").font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                        } else {
                            Text(item.features.map(label).joined(separator: " · "))
                                .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func allowancesCard(_ data: AccountSubscriptionEnvelope) -> some View {
        NativeGroupPanel(title: "Allowances", subtitle: "Usage reported by the billing service", fillsAvailableWidth: true) {
            if data.quotas.isEmpty {
                Text("Allowances were not reported.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
            } else {
                ForEach(data.quotas) { quota in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(quotaLabel(quota.key)).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                        Text(quota.limit.map { "\(number(quota.used)) used of \($0.formatted())\(quota.remaining.map { " · \($0.formatted()) remaining" } ?? "")" } ?? "No active allowance reported")
                            .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                        if let resetsAt = quota.resetsAt { Text("Resets \(date(resetsAt))").font(.system(size: 11)).foregroundStyle(theme.textSecondary) }
                    }
                }
            }
        }
    }

    private func detail(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(theme.textSecondary)
            Spacer()
            Text(value).foregroundStyle(theme.text).multilineTextAlignment(.trailing)
        }
        .font(.system(size: 12))
    }

    private func refresh() async {
        let currentRequestID = UUID()
        requestID = currentRequestID
        let requestedScope = scope
        data = nil
        error = ""
        guard model.hasHanasandAuth else {
            error = "Sign in to view subscription information."
            return
        }
        loading = true
        defer { if requestID == currentRequestID { loading = false } }
        do {
            guard let baseURL = URL(string: model.settings.apiBaseURL) else {
                throw AccountSubscriptionClientError.invalidBaseURL
            }
            let client = try AccountSubscriptionClient(baseURL: baseURL, userID: model.userIDForRequests, token: model.authTokenForRequests, impersonationToken: model.settings.impersonationToken)
            let result = try await client.load()
            guard !Task.isCancelled, requestID == currentRequestID, scope == requestedScope else { return }
            data = result
        } catch let cause {
            guard !Task.isCancelled, requestID == currentRequestID, scope == requestedScope else { return }
            error = cause.localizedDescription
        }
    }

    private func openBilling() async {
        guard !openingBilling, model.settings.impersonationToken.isEmpty, model.hasHanasandAuth else { return }
        let currentRequestID = UUID()
        requestID = currentRequestID
        let requestedScope = scope
        openingBilling = true
        error = ""
        defer { if requestID == currentRequestID { openingBilling = false } }
        do {
            guard let baseURL = URL(string: model.settings.apiBaseURL) else {
                throw AccountSubscriptionClientError.invalidBaseURL
            }
            let client = try AccountSubscriptionClient(baseURL: baseURL, userID: model.userIDForRequests, token: model.authTokenForRequests)
            let url = try await client.createBillingPortalURL()
            guard !Task.isCancelled, requestID == currentRequestID, scope == requestedScope else { return }
            if !model.openStripeExternally(url: url.absoluteString, title: "billing portal", source: "Billing") {
                error = "Could not open the secure Stripe page in your default browser."
            }
        } catch {
            if !Task.isCancelled, requestID == currentRequestID, scope == requestedScope {
                self.error = error.localizedDescription
            }
        }
    }

    private func label(_ value: String) -> String {
        value.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.capitalized }.joined(separator: " ")
    }

    private func quotaLabel(_ key: String) -> String {
        ["searchesPerDay": "Daily searches", "watchTerms": "Watch terms", "monitoredTargets": "Monitored targets"][key] ?? label(key)
    }

    private func date(_ value: String?) -> String {
        guard let value, let parsed = ISO8601DateFormatter().date(from: value) else { return "Not reported" }
        return parsed.formatted(date: .abbreviated, time: .shortened)
    }

    private func number(_ value: Int?) -> String { value.map { $0.formatted() } ?? "Unknown" }
}
