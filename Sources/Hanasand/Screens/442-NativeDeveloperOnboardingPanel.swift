import SwiftUI

struct NativeDeveloperOnboardingPanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var showKeys = false
    @State private var showReference = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NativeGroupPanel(title: "Build with the Hanasand API", subtitle: "Native developer setup") {
                Text("Create an organization API key, send an authenticated request, then inspect the live API contract below.")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                HStack(spacing: 8) {
                    Label("1 · Choose an organization", systemImage: "building.2")
                    Label("2 · Create and copy a key", systemImage: "key")
                    Label("3 · Make your first request", systemImage: "terminal")
                }
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textSecondary)
                HStack(spacing: 8) {
                    ActionButton(title: showKeys ? "Hide API key manager" : "Create or manage API keys", icon: "key.horizontal") {
                        showKeys.toggle()
                    }
                    ActionButton(title: "Choose organization", icon: "building.2") {
                        model.openNativeDashboard(path: "/organizations", label: "Organizations")
                    }
                }
                Text("Treat a new key like a password. The secret is shown once when it is created.")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary)
            }
            NativeGroupPanel(title: "First request", subtitle: "Replace the endpoint and key with values from your workspace") {
                Text("curl 'https://api.hanasand.com/api/v1/actors?page=1&limit=20' -H 'X-API-Key: YOUR_API_KEY'")
                    .font(.system(size: 11, weight: .medium, design: .monospaced)).textSelection(.enabled)
                Text("This request lists public actor records using an organization API key granted the GET /actors scope. Pagination uses page and limit; responses include request and quota headers.")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                ActionButton(title: showReference ? "Hide API reference" : "Show API reference", icon: "doc.text.magnifyingglass") {
                    showReference.toggle()
                }
            }
            if showKeys { OrganizationApiKeysNativePanel() }
            if showReference { APIReferenceNativePanel() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
