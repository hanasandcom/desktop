import AppKit
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

    var displayName: String {
        NativeProfilePresentation.displayName(name: name, username: username, id: id, active: active)
    }
}

struct NativePublicProfilePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    let userID: String
    @State private var profile: NativePublicProfile?
    @State private var error = ""
    @State private var isLoading = false
    @State private var profileLinkCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isLoading {
                ProgressView("Loading profile…")
            } else if let profile {
                NativeGroupPanel(title: profile.displayName,
                                 subtitle: "@\(profile.username ?? profile.id)") {
                    HStack(alignment: .center, spacing: 12) {
                        profileAvatar(profile)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.displayName)
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("@\(profile.username ?? profile.id)")
                                .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: 0)
                    }
                    if let email = profile.email, !email.isEmpty {
                        Text(email).font(.system(size: 12)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                    }
                    Text("User ID: \(profile.id)").font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.textTertiary).textSelection(.enabled)
                    if profile.active == false { NativeNotice(message: "Inactive account", tone: .info) }
                    if let createdAt = profile.createdAt, !createdAt.isEmpty {
                        Text("Member since \(createdAt)").font(.system(size: 11)).foregroundStyle(theme.textTertiary)
                    }
                    ViewThatFits(in: .horizontal) {
                        profileLinkActions(profile, horizontal: true)
                        profileLinkActions(profile, horizontal: false)
                    }
                    if profileLinkCopied {
                        Text("Profile link copied to clipboard.")
                            .font(.system(size: 10)).foregroundStyle(theme.textTertiary)
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

    @ViewBuilder private func profileAvatar(_ profile: NativePublicProfile) -> some View {
        let displayName = profile.displayName
        let initials = displayName.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        if profile.active != false, let url = avatarURL(profile.avatar) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    avatarPlaceholder(initials)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(Circle())
            .overlay(Circle().stroke(theme.divider, lineWidth: 1))
            .accessibilityLabel("\(displayName)'s avatar")
        } else {
            avatarPlaceholder(initials)
        }
    }

    private func avatarPlaceholder(_ initials: String) -> some View {
        Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(theme.accent)
            .frame(width: 64, height: 64)
            .background(theme.cardRaised, in: Circle())
            .overlay(Circle().stroke(theme.divider, lineWidth: 1))
            .accessibilityLabel("Profile initials")
    }

    private func avatarURL(_ value: String?) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        let website = model.settings.websiteBaseURL.normalizedBaseURL
        let url = value.hasPrefix("/") && !value.hasPrefix("//")
            ? URL(string: value, relativeTo: website)?.absoluteURL
            : URL(string: value)
        guard let url, url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    private func profileLinkText(_ profile: NativePublicProfile) -> String {
        "\(model.settings.websiteBaseURL.normalizedBaseURL.host ?? "hanasand.com")/profile/\(profile.username ?? profile.id)"
    }

    @ViewBuilder private func profileLinkActions(_ profile: NativePublicProfile, horizontal: Bool) -> some View {
        if horizontal {
            HStack(alignment: .center, spacing: 10) {
                profileLinkLabel(profile)
                copyProfileButton(profile)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                profileLinkLabel(profile)
                copyProfileButton(profile)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func profileLinkLabel(_ profile: NativePublicProfile) -> some View {
        Text(profileLinkText(profile))
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.textSecondary)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copyProfileButton(_ profile: NativePublicProfile) -> some View {
        ActionButton(title: profileLinkCopied ? "Link copied" : "Copy profile link",
                     icon: profileLinkCopied ? "checkmark" : "doc.on.doc") {
            copyProfileLink(profile)
        }
    }

    private func copyProfileLink(_ profile: NativePublicProfile) {
        let identifier = profile.username ?? profile.id
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encoded = identifier.addingPercentEncoding(withAllowedCharacters: allowed),
              var components = URLComponents(url: model.settings.websiteBaseURL.normalizedBaseURL, resolvingAgainstBaseURL: false) else {
            profileLinkCopied = false
            return
        }
        components.percentEncodedPath = "/profile/\(encoded)"
        guard let url = components.url else {
            profileLinkCopied = false
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        profileLinkCopied = true
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
