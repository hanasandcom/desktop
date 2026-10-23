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

extension DesktopAgentModel {
    var canEditProfileIdentity: Bool {
        guard hasHanasandAuth,
              settings.impersonationToken.isEmpty,
              settings.impersonatingUserID.isEmpty,
              profileIdentityLoaded,
              let profile else { return false }
        return profile.id == userIDForRequests
    }

    var isProfileIdentityImpersonating: Bool {
        !settings.impersonationToken.isEmpty || !settings.impersonatingUserID.isEmpty
    }

    var canSaveProfileIdentity: Bool {
        guard canEditProfileIdentity, !isSavingProfileIdentity,
              let payload = try? DashboardProfileIdentityUpdatePayload(name: profileEditName, username: profileEditUsername) else {
            return false
        }
        return payload.name != profileIdentityOriginalName || payload.username != profileIdentityOriginalUsername
    }

    func loadProfileIdentity() async {
        guard hasHanasandAuth, let profile else {
            profileIdentityLoaded = false
            profileIdentityError = "Hanasand session is not ready. Log in again to load profile details."
            return
        }

        isLoadingProfileIdentity = true
        profileIdentityLoaded = false
        profileIdentityError = nil
        defer { isLoadingProfileIdentity = false }

        do {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            guard let encodedID = profile.id.addingPercentEncoding(withAllowedCharacters: allowed), !encodedID.isEmpty else {
                throw DashboardProfileIdentityUpdateError.accountMismatch
            }
            let identity: DashboardAccountIdentityResponse = try await requestJSON(
                settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("user/\(encodedID)"),
                authenticated: true
            )
            guard identity.id == profile.id else {
                throw DashboardProfileIdentityUpdateError.accountMismatch
            }
            let name = identity.name ?? ""
            let username = identity.username ?? identity.id
            profileEditName = name
            profileEditUsername = username
            profileIdentityOriginalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            profileIdentityOriginalUsername = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            self.profile = DashboardProfile(
                id: profile.id,
                name: name,
                username: username,
                avatar: identity.avatar ?? profile.avatar,
                active: profile.active,
                roles: profile.roles,
                token: profile.token,
                expiresAt: profile.expiresAt
            )
            profileIdentityLoaded = true
        } catch {
            profileIdentityError = error.localizedDescription
        }
    }

    func updateProfileIdentity() async {
        guard canEditProfileIdentity else {
            profileIdentityError = "Return to your own account to edit profile details."
            profileIdentityNotice = nil
            return
        }

        let payload: DashboardProfileIdentityUpdatePayload
        do {
            payload = try DashboardProfileIdentityUpdatePayload(name: profileEditName, username: profileEditUsername)
        } catch {
            profileIdentityError = error.localizedDescription
            profileIdentityNotice = nil
            return
        }

        isSavingProfileIdentity = true
        profileIdentityError = nil
        profileIdentityNotice = nil
        defer { isSavingProfileIdentity = false }

        do {
            let body = try JSONEncoder().encode(payload)
            let updated: DashboardProfileIdentityUpdateResponse = try await requestJSON(
                settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("user/self"),
                method: "PUT",
                body: body,
                authenticated: true
            )
            guard updated.id == userIDForRequests, let profile, updated.id == profile.id else {
                throw DashboardProfileIdentityUpdateError.accountMismatch
            }

            self.profile = DashboardProfile(
                id: profile.id,
                name: updated.name,
                username: updated.username,
                avatar: updated.avatar ?? profile.avatar,
                active: profile.active,
                roles: profile.roles,
                token: profile.token,
                expiresAt: profile.expiresAt
            )
            profileEditName = updated.name
            profileEditUsername = updated.username
            profileIdentityOriginalName = updated.name.trimmingCharacters(in: .whitespacesAndNewlines)
            profileIdentityOriginalUsername = updated.username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            profileIdentityLoaded = true
            profileIdentityNotice = "Your display name and username were saved."
            nativeDashboardStatus = "Profile updated"
            append(meta: "Profile updated", body: "Display name and username saved.", kind: .change)
        } catch {
            if case DashboardRequestError.httpStatus(409) = error {
                profileIdentityError = "That username is already taken. Choose another one."
            } else if case DashboardRequestError.httpStatus(403) = error {
                profileIdentityError = "Return to your own account before editing profile details."
            } else if case DashboardRequestError.httpStatus(400) = error {
                profileIdentityError = "The name or username was rejected. Check the values and try again."
            } else {
                profileIdentityError = error.localizedDescription
            }
            profileIdentityNotice = nil
            nativeDashboardStatus = profileIdentityError ?? "Profile update failed"
            append(meta: "Profile update failed", body: nativeDashboardStatus, kind: .error)
        }
    }
}
