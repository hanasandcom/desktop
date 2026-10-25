import XCTest
@testable import Hanasand

final class NativeAuthenticatorTests: XCTestCase {
    private let rfcSecret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

    func testRFC4226TOTPAppendixB_SHA1EightDigitVector() throws {
        let entry = NativeAuthenticatorEntry(label: "RFC", secret: rfcSecret, digits: 8)
        XCTAssertEqual(try NativeAuthenticator.code(for: entry, at: Date(timeIntervalSince1970: 59)), "94287082")
        XCTAssertEqual(try NativeAuthenticator.code(for: entry, at: Date(timeIntervalSince1970: 1_111_111_109)), "07081804")
    }

    func testParsesPercentEncodedOtpauthURIAndAlgorithmSettings() throws {
        let entry = try NativeAuthenticator.parse("otpauth://totp/Example%20Issuer:alice%40example.com?secret=gez dgNbvgy3tqojqgezdgnbvg y3tqojq&issuer=Example%20Issuer&algorithm=SHA1&digits=8&period=45")
        XCTAssertEqual(entry.issuer, "Example Issuer")
        XCTAssertEqual(entry.account, "alice@example.com")
        XCTAssertEqual(entry.label, "Example Issuer · alice@example.com")
        XCTAssertEqual(entry.secret, rfcSecret)
        XCTAssertEqual(entry.digits, 8)
        XCTAssertEqual(entry.period, 45)
        XCTAssertEqual(entry.algorithm, .sha1)
    }

    func testDefaultsMissingTOTPOptionsAndRejectsHOTP() throws {
        let parsed = try NativeAuthenticator.parse("otpauth://totp/alice?secret=\(rfcSecret)")
        XCTAssertEqual(parsed.digits, 6)
        XCTAssertEqual(parsed.period, 30)
        XCTAssertThrowsError(try NativeAuthenticator.parse("otpauth://hotp/alice?secret=\(rfcSecret)&counter=1"))
    }

    func testLiveQRScanAcceptsOnlyTOTPAuthenticatorURIs() {
        XCTAssertTrue(NativeAuthenticatorQRScan.isTOTPURI("otpauth://totp/alice?secret=\(rfcSecret)"))
        XCTAssertTrue(NativeAuthenticatorQRScan.isTOTPURI("OTPAUTH://TOTP/alice?secret=\(rfcSecret)"))
        XCTAssertFalse(NativeAuthenticatorQRScan.isTOTPURI("otpauth://hotp/alice?secret=\(rfcSecret)&counter=1"))
        XCTAssertFalse(NativeAuthenticatorQRScan.isTOTPURI("https://example.com"))
        XCTAssertFalse(NativeAuthenticatorQRScan.isTOTPURI("otpauth://totp/"))
        XCTAssertFalse(NativeAuthenticatorQRScan.isTOTPURI("otpauth://totp:443/alice?secret=\(rfcSecret)"))
        XCTAssertFalse(NativeAuthenticatorQRScan.isTOTPURI("otpauth://totp/alice?secret=abc\n"))
    }

    func testRejectsBadSecretDigitsAndPeriod() {
        XCTAssertThrowsError(try NativeAuthenticator.validate(NativeAuthenticatorEntry(label: "bad", secret: "abc123")))
        XCTAssertThrowsError(try NativeAuthenticator.validate(NativeAuthenticatorEntry(label: "bad", secret: rfcSecret, digits: 7)))
        XCTAssertThrowsError(try NativeAuthenticator.validate(NativeAuthenticatorEntry(label: "bad", secret: rfcSecret, period: 0)))
    }

    func testCountdownRollsAtTOTPPeriodBoundary() {
        let entry = NativeAuthenticatorEntry(label: "RFC", secret: rfcSecret, period: 30)
        XCTAssertEqual(NativeAuthenticator.remainingSeconds(for: entry, at: Date(timeIntervalSince1970: 59)), 1)
        XCTAssertEqual(NativeAuthenticator.remainingSeconds(for: entry, at: Date(timeIntervalSince1970: 60)), 30)
    }

    func testUpsertKeepsStableIdentityAndReplacesDuplicateSecret() throws {
        let first = NativeAuthenticatorEntry(label: "Old", secret: rfcSecret)
        let updated = NativeAuthenticatorEntry(label: "New", secret: rfcSecret)
        let next = NativeAuthenticator.upsert(updated, into: [first])
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next.first?.id, first.id)
        XCTAssertEqual(next.first?.label, "New")
    }

    func testVaultReloadAndDeleteLifecycleKeepsSecretsInInjectedVault() throws {
        let vault = MemoryAuthenticatorVault()
        let entry = NativeAuthenticatorEntry(label: "Local test", secret: rfcSecret)
        try vault.save([entry])
        XCTAssertEqual(try vault.read(), [entry])
        try vault.save(try vault.read().filter { $0.id != entry.id })
        XCTAssertTrue(try vault.read().isEmpty)
    }
}

private final class MemoryAuthenticatorVault: NativeAuthenticatorVault {
    private var entries: [NativeAuthenticatorEntry] = []
    func read() throws -> [NativeAuthenticatorEntry] { entries }
    func save(_ entries: [NativeAuthenticatorEntry]) throws { self.entries = entries }
}
