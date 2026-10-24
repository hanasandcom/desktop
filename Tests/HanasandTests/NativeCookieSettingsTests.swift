import XCTest
@testable import Hanasand

final class NativeCookieSettingsTests: XCTestCase {
    func testAllowlistContainsOnlyIDEProductDraftKey() throws {
        let defaults = try makeDefaults()
        let preservedKeys = [
            "hanasand.desktop.ide.session",
            "hanasand.desktop.notes.drafts.account-42",
            "hanasand.desktop.settings",
            "hanasand.desktop.appearancePreference",
            "hanasand.desktop.articleMutationSafety",
            "hanasand.desktop.controlRunHistory",
            "hanasand.share.workspace.v1",
            "unrelated.product.data",
        ]
        defaults.set(["draft": "local"], forKey: NativeCookieSettingsPolicy.ideDraftsKey)
        for key in preservedKeys { defaults.set(Data("keep".utf8), forKey: key) }

        XCTAssertEqual(NativeCookieSettingsPolicy.safeDraftKeys(defaults: defaults), [NativeCookieSettingsPolicy.ideDraftsKey])
    }

    func testClearRemovesOnlyIDEKeyWhenCallerAllowsIt() throws {
        let defaults = try makeDefaults()
        let preservedKeys = [
            "hanasand.desktop.ide.session",
            "hanasand.desktop.notes.drafts.account-42",
            "hanasand.desktop.settings",
            "hanasand.desktop.appearancePreference",
            "hanasand.desktop.articleMutationSafety",
            "hanasand.desktop.controlRunHistory",
            "hanasand.share.workspace.v1",
            "unrelated.product.data",
        ]
        defaults.set(Data("ide".utf8), forKey: NativeCookieSettingsPolicy.ideDraftsKey)
        for key in preservedKeys { defaults.set(Data("keep".utf8), forKey: key) }

        XCTAssertEqual(NativeCookieSettingsPolicy.clearSafeDrafts(defaults: defaults, mayClearIDE: false), [])
        XCTAssertNotNil(defaults.object(forKey: NativeCookieSettingsPolicy.ideDraftsKey))

        XCTAssertEqual(NativeCookieSettingsPolicy.clearSafeDrafts(defaults: defaults, mayClearIDE: true), [.ide])
        XCTAssertNil(defaults.object(forKey: NativeCookieSettingsPolicy.ideDraftsKey))
        for key in preservedKeys { XCTAssertNotNil(defaults.object(forKey: key), "Unexpectedly cleared \(key)") }
    }

    func testConsentTimestampIsSavedAndResetAlongWithChoice() throws {
        let defaults = try makeDefaults()
        let savedAt = Date(timeIntervalSince1970: 1_798_000_000)

        NativeCookieSettingsPolicy.saveConsent(.essential, at: savedAt, defaults: defaults)
        var snapshot = NativeCookieSettingsPolicy.snapshot(defaults: defaults, sessionToken: "", impersonationToken: "")
        XCTAssertEqual(snapshot.consent, .essential)
        XCTAssertEqual(snapshot.consentUpdatedAt, savedAt)

        NativeCookieSettingsPolicy.saveConsent(.unset, at: savedAt, defaults: defaults)
        snapshot = NativeCookieSettingsPolicy.snapshot(defaults: defaults, sessionToken: "", impersonationToken: "")
        XCTAssertEqual(snapshot.consent, .unset)
        XCTAssertNil(snapshot.consentUpdatedAt)
    }

    func testSnapshotExposesOnlyCredentialPresence() throws {
        let snapshot = NativeCookieSettingsPolicy.snapshot(
            defaults: try makeDefaults(),
            sessionToken: "secret-session-value",
            impersonationToken: "secret-impersonation-value"
        )

        XCTAssertTrue(snapshot.hasSessionToken)
        XCTAssertTrue(snapshot.hasImpersonationToken)
        XCTAssertFalse(String(describing: snapshot).contains("secret-session-value"))
        XCTAssertFalse(String(describing: snapshot).contains("secret-impersonation-value"))
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "NativeCookieSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
