import SwiftUI

struct NativeDeveloperOnboardingPanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var showKeys = false
    @State private var showReference = true
    @State private var referenceDetails: DeveloperAPIReferenceDetails?
    @State private var isLoadingOnboarding = false
    @State private var onboardingUnavailable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NativeGroupPanel(title: "Build with the Hanasand API", subtitle: "Native developer setup") {
                Text("Create an organization API key, send an authenticated request, then inspect the live API contract below.")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        onboardingSteps
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        onboardingSteps
                    }
                }
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textSecondary)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        apiKeyActions
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        apiKeyActions
                    }
                }
                Text("Organization keys created here are scoped to event intake (POST /mill). Treat the secret like a password; it is shown once when created.")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary)
            }
            NativeGroupPanel(title: "First request", subtitle: "Send a real JSON event using the organization key") {
                if let referenceDetails, let command = NativeDeveloperOnboardingContent.eventIntakeCommand(details: referenceDetails) {
                    developerCode(command)
                    Text("Set HANASAND_EVENT_JSON to a JSON event produced by your integration. The organization key grants POST /mill event-intake access; it does not grant GET /actors access.")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                } else {
                    onboardingContractStatus
                }
                Text("The key secret is never inserted into this example or logged by the app. Keep it in your environment as HANASAND_API_KEY.")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                ActionButton(title: showReference ? "Hide API reference" : "Show API reference", icon: "doc.text.magnifyingglass") {
                    showReference.toggle()
                }
            }
            NativeGroupPanel(title: "Generate API types", subtitle: "Create TypeScript types from the published OpenAPI contract") {
                if let referenceDetails {
                    developerCode(NativeDeveloperOnboardingContent.typeGenerationCommand(details: referenceDetails))
                } else {
                    onboardingContractStatus
                }
            }
            NativeGroupPanel(title: "Typed TypeScript client", subtitle: "Install openapi-fetch and use the documented user session contract") {
                developerCode(NativeDeveloperOnboardingContent.clientInstallCommand)
                if let referenceDetails {
                    developerCode(NativeDeveloperOnboardingContent.typedClientExample(details: referenceDetails))
                    Text("This GET example uses the contract's Hanasand user-session requirements, not the organization event-ingest key. Set HANASAND_SESSION_BEARER and HANASAND_SESSION_ID in your own runtime; the app never inserts its live session credentials here.")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                } else {
                    onboardingContractStatus
                }
            }
            NativeGroupPanel(title: "Pagination", subtitle: "Follow the response until there are no more pages") {
                Text(NativeDeveloperOnboardingContent.paginationGuidance)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if showKeys { OrganizationApiKeysNativePanel() }
            if showReference { APIReferenceNativePanel() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await loadOnboardingContract() }
    }

    private var onboardingSteps: some View {
        Group {
            Label("1 · Choose an organization", systemImage: "building.2")
            Label("2 · Create and copy a key", systemImage: "key")
            Label("3 · Make your first request", systemImage: "terminal")
        }
    }

    @ViewBuilder
    private var apiKeyActions: some View {
        ActionButton(title: showKeys ? "Hide API key manager" : "Create or manage API keys", icon: "key.horizontal") {
            showKeys.toggle()
        }
        ActionButton(title: "Choose organization", icon: "building.2") {
            model.openNativeDashboard(path: "/organizations", label: "Organizations")
        }
    }

    @ViewBuilder
    private var onboardingContractStatus: some View {
        if isLoadingOnboarding {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading the published API contract…").font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
            }
        } else if onboardingUnavailable {
            VStack(alignment: .leading, spacing: 8) {
                Text("The published API contract is unavailable. Retry to load current setup details.")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                ActionButton(title: "Retry", icon: "arrow.clockwise") {
                    onboardingUnavailable = false
                    Task { await loadOnboardingContract() }
                }
                .disabled(isLoadingOnboarding)
            }
        } else {
            Text("Loading the published API contract…")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
        }
    }

    private func loadOnboardingContract() async {
        guard referenceDetails == nil else { return }
        isLoadingOnboarding = true
        defer { isLoadingOnboarding = false }
        do {
            let client = DeveloperAPIReferenceClient()
            referenceDetails = try await client.load(websiteBaseURL: model.settings.websiteBaseURL)
        } catch {
            onboardingUnavailable = true
        }
    }

    private func developerCode(_ source: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(source)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
