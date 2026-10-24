import Foundation

struct NativeCookieSettingsSnapshot: Equatable {
    enum Consent: String, CaseIterable, Identifiable {
        case unset
        case essential
        case optional

        var id: String { rawValue }
        var title: String {
            switch self {
            case .unset: "No preference saved"
            case .essential: "Essential only"
            case .optional: "Optional cookies allowed"
            }
        }
    }

    enum DraftKind: String, CaseIterable, Identifiable {
        case ide

        var id: String { rawValue }
        var title: String { "IDE drafts" }
    }

    let consent: Consent
    let consentUpdatedAt: Date?
    let hasSessionToken: Bool
    let hasImpersonationToken: Bool
    let storedDraftKinds: [DraftKind]
}

enum NativeCookieSettingsPolicy {
    static let consentKey = "hanasand.desktop.optionalCookieConsent"
    static let consentUpdatedAtKey = "hanasand.desktop.optionalCookieConsentUpdatedAt"
    static let ideDraftsKey = "hanasand.desktop.ide.drafts"

    static func snapshot(
        defaults: UserDefaults = .standard,
        sessionToken: String,
        impersonationToken: String
    ) -> NativeCookieSettingsSnapshot {
        let consentRaw = defaults.string(forKey: consentKey) ?? "unset"
        let consent = NativeCookieSettingsSnapshot.Consent(rawValue: consentRaw) ?? .unset
        let storedDraftKinds = storedDrafts(defaults: defaults)
        return NativeCookieSettingsSnapshot(
            consent: consent,
            consentUpdatedAt: parseTimestamp(defaults.string(forKey: consentUpdatedAtKey)),
            hasSessionToken: !sessionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            hasImpersonationToken: !impersonationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            storedDraftKinds: storedDraftKinds
        )
    }

    static func saveConsent(
        _ consent: NativeCookieSettingsSnapshot.Consent,
        at date: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        defaults.set(consent.rawValue, forKey: consentKey)
        if consent == .unset {
            defaults.removeObject(forKey: consentUpdatedAtKey)
        } else {
            defaults.set(ISO8601DateFormatter().string(from: date), forKey: consentUpdatedAtKey)
        }
    }

    static func safeDraftKeys(defaults: UserDefaults) -> [String] {
        defaults.object(forKey: ideDraftsKey) == nil ? [] : [ideDraftsKey]
    }

    @discardableResult
    static func clearSafeDrafts(
        defaults: UserDefaults = .standard,
        mayClearIDE: Bool
    ) -> [NativeCookieSettingsSnapshot.DraftKind] {
        var cleared: [NativeCookieSettingsSnapshot.DraftKind] = []
        if mayClearIDE, defaults.object(forKey: ideDraftsKey) != nil {
            defaults.removeObject(forKey: ideDraftsKey)
            cleared.append(.ide)
        }
        return cleared
    }

    private static func storedDrafts(defaults: UserDefaults) -> [NativeCookieSettingsSnapshot.DraftKind] {
        defaults.object(forKey: ideDraftsKey) == nil ? [] : [.ide]
    }

    private static func parseTimestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: value)
    }
}
