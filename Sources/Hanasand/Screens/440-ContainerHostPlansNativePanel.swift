import SwiftUI

struct NativeContainerHostPlansPanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    let onNavigate: (String) -> Void

    @State private var snapshot: NativeContainerBillingSnapshot?
    @State private var selectedContainer = ""
    @State private var isLoading = true
    @State private var isBuying = false
    @State private var status = ""

    private var requestScope: String {
        [model.settings.userID, model.settings.authToken, model.settings.apiBaseURL,
         model.settings.selectedOrganizationID, model.settings.impersonationToken].joined(separator: "|")
    }

    private var selected: NativeContainerPurchase? {
        snapshot?.containers.first { $0.name == selectedContainer }
    }

    var body: some View {
        NativeGroupPanel(title: "Container host options", subtitle: "VM creation is free. Automatic failover is an optional upgrade.", fillsAvailableWidth: true) {
            Text("Automatic failover")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
            Text("Keep a standby copy so the host can move between OVHcloud and Inspur.")
                .font(.system(size: 12)).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            Text("\(snapshot?.plans.first(where: { $0.id == "failover" })?.priceNok ?? 49) NOK / month per container")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accent)
            if !model.hasHanasandAuth {
                Text("Sign in to choose a container and add automatic failover.")
                    .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                ActionButton(title: "Sign in to choose a container", icon: "person.crop.circle", expands: true) {
                    onNavigate("/login?next=%2Fpricing")
                }
            } else if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading your containers…").font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let snapshot {
                if snapshot.containers.isEmpty {
                    Text("Create a container to add host options.")
                        .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                    ActionButton(title: "Create a container", icon: "shippingbox", expands: true) {
                        onNavigate("/vms")
                    }
                } else if snapshot.plans.contains(where: { $0.id == "failover" }) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Container", selection: $selectedContainer) {
                            ForEach(snapshot.containers) { container in
                                Text(container.name).tag(container.name)
                            }
                        }
                        .disabled(isBuying)
                        ActionButton(
                            title: selected?.failoverPremium == true ? "Already purchased" : (isBuying ? "Opening checkout…" : "Buy optional failover"),
                            icon: selected?.failoverPremium == true ? "checkmark.circle" : "cart",
                            expands: true
                        ) {
                            Task { await buyFailover() }
                        }
                        .disabled(selected == nil || selected?.failoverPremium == true || isBuying || !canBuy)
                    }
                }
            } else {
                Text(status.isEmpty ? "Container options could not be loaded. Refresh to try again." : status)
                    .font(.system(size: 12)).foregroundStyle(theme.danger).fixedSize(horizontal: false, vertical: true)
                ActionButton(title: "Retry", icon: "arrow.clockwise", expands: true) {
                    Task { await load() }
                }
                .disabled(isLoading)
            }

            if !status.isEmpty, snapshot != nil {
                Text(status).font(.system(size: 11))
                    .foregroundStyle(status.localizedCaseInsensitiveContains("could not") || status.localizedCaseInsensitiveContains("failed") ? theme.danger : theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.settings.impersonationToken.isEmpty {
                Text("Return to your own account to manage container billing.")
                    .font(.system(size: 11)).foregroundStyle(theme.textTertiary)
            }
        }
        .task(id: requestScope) { await load() }
    }

    private var canBuy: Bool {
        model.settings.impersonationToken.isEmpty && model.settings.impersonatingUserID.isEmpty
    }

    @MainActor
    private func load() async {
        guard model.hasHanasandAuth else {
            snapshot = nil
            isLoading = false
            status = ""
            return
        }
        isLoading = true
        status = ""
        defer { isLoading = false }
        do {
            let loaded = try await makeClient().loadContainerBillingSnapshot()
            guard requestScope == [model.settings.userID, model.settings.authToken, model.settings.apiBaseURL,
                                   model.settings.selectedOrganizationID, model.settings.impersonationToken].joined(separator: "|") else { return }
            snapshot = loaded
            if !loaded.containers.contains(where: { $0.name == selectedContainer }) {
                selectedContainer = loaded.containers.first?.name ?? ""
            }
        } catch {
            snapshot = nil
            status = (error as? LocalizedError)?.errorDescription ?? "Container options could not be loaded. Refresh to try again."
        }
    }

    @MainActor
    private func buyFailover() async {
        guard !isBuying, let selected, !selected.failoverPremium, canBuy else { return }
        isBuying = true
        status = ""
        defer { isBuying = false }
        do {
            let checkout = try await makeClient().loadFailoverCheckoutURL(for: selected.name)
            let didOpen = model.openStripeInAppBrowser(url: checkout.absoluteString, title: "checkout", source: "Pricing · \(selected.name)")
            status = didOpen ? "Secure Stripe checkout opened in the built-in browser." : "Could not open secure Stripe checkout in the built-in browser."
        } catch {
            status = (error as? LocalizedError)?.errorDescription ?? "Checkout could not be opened."
        }
    }

    private func makeClient() throws -> NativeVMAccessClient {
        guard let baseURL = URL(string: model.settings.apiBaseURL) else { throw NativeVMAccessError.invalidEndpoint }
        return try NativeVMAccessClient(
            apiBaseURL: baseURL,
            userID: model.settings.userID,
            token: model.authTokenForRequests,
            organizationID: model.selectedOrganizationID.isEmpty || model.selectedOrganizationID == "personal" ? nil : model.selectedOrganizationID,
            impersonationToken: model.settings.impersonationToken,
            impersonatingUserID: model.settings.impersonatingUserID
        )
    }
}
