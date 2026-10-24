import SwiftUI

private struct NativePublicProfile: Decodable {
    let id: String
    let name: String?
    let username: String?
    let avatar: String?
    let email: String?
    let active: Bool?
    let createdAt: String?
    let memberships: [Membership]?

    struct Membership: Decodable, Identifiable {
        let id: String
        let name: String
        let slug: String?
        let status: String?
    }

    enum CodingKeys: String, CodingKey {
        case id, name, username, avatar, email, active
        case createdAt = "created_at"
        case memberships = "organization_memberships"
    }
}

struct NativePublicProfilePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    let userID: String
    @State private var profile: NativePublicProfile?
    @State private var error = ""
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isLoading {
                ProgressView("Loading profile…")
            } else if let profile {
                NativeGroupPanel(title: profile.name?.isEmpty == false ? profile.name! : profile.id,
                                 subtitle: "@\(profile.username ?? profile.id)") {
                    if let email = profile.email, !email.isEmpty {
                        Text(email).font(.system(size: 12)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                    }
                    Text("User ID: \(profile.id)").font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.textTertiary).textSelection(.enabled)
                    if profile.active == false { NativeNotice(message: "Inactive account", tone: .info) }
                    if let createdAt = profile.createdAt, !createdAt.isEmpty {
                        Text("Member since \(createdAt)").font(.system(size: 11)).foregroundStyle(theme.textTertiary)
                    }
                }
                if let memberships = profile.memberships, !memberships.isEmpty {
                    NativeGroupPanel(title: "Organization memberships", subtitle: "Public profile") {
                        ForEach(memberships) { membership in
                            HStack {
                                Text(membership.name).font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Text(membership.status ?? "Member").font(.system(size: 11)).foregroundStyle(theme.textTertiary)
                            }
                        }
                    }
                }
            } else {
                NativeEmptyState(title: "Profile unavailable", message: error.isEmpty ? "This profile could not be loaded." : error)
            }
        }
        .task(id: userID) { await load() }
    }

    @MainActor private func load() async {
        guard !userID.isEmpty, model.hasHanasandAuth else {
            error = "Sign in to view this profile."
            profile = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let url = model.settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("user").appendingPathComponent(userID)
            profile = try await model.requestJSON(url, authenticated: true)
            error = ""
        } catch {
            profile = nil
            self.error = error.localizedDescription
        }
    }
}
