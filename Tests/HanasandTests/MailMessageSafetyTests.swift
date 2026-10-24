import XCTest
@testable import Hanasand

final class MailMessageSafetyTests: XCTestCase {
    func testReputationRequestUsesMessagePathSegmentAndMailboxQuery() throws {
        let url = try MailMessageSafety.makeRequestURL(
            baseURL: URL(string: "https://api.example.test/api/")!,
            mailboxUser: "person@example.test",
            messageID: "message/with?delimiters"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.percentEncodedPath, "/api/mail/message/message%2Fwith%3Fdelimiters/reputation")
        XCTAssertEqual(components.queryItems?.map(\.name), ["mailboxUser"])
        XCTAssertEqual(components.queryItems?.map(\.value), ["person@example.test"])
        XCTAssertThrowsError(try MailMessageSafety.makeRequestURL(baseURL: URL(string: "https://api.example.test")!, mailboxUser: " ", messageID: "id"))
    }

    func testValidatedReputationIsMessageScopedAndOnlyMatchesActualImageSources() throws {
        let html = #"<IMG src='https://images.example.test/safe.png#fragment'><img src="https://images.example.test/other.png"><img src="https://user:secret@images.example.test/private.png"><img src="cid:logo">"#
        let safeURL = "https://images.example.test/safe.png"
        let otherURL = "https://images.example.test/unlisted.png"
        let safeImage = remote(id: MailMessageSafety.sha256(safeURL), url: safeURL, flagged: 0)
        let unlisted = remote(id: MailMessageSafety.sha256(otherURL), url: otherURL, flagged: 0)
        let badDigest = remote(id: String(repeating: "0", count: 64), url: "https://images.example.test/other.png", flagged: 0)
        let untrustedProvider = MailRemoteResourceReputation(
            id: MailMessageSafety.sha256("https://images.example.test/other.png"),
            url: "https://images.example.test/other.png",
            reputation: MailResourceReputation(provider: "other", status: "known", flagged: 0, total: 10, checkedAt: nil, reportUrl: nil)
        )
        let attachment = MailAttachmentReputation(blobId: "blob-safe", name: "image.png", size: 20,
                                                  reputation: MailResourceReputation(provider: "virustotal", status: "known", flagged: 0, total: 60, checkedAt: nil, reportUrl: nil))
        let mismatchedAttachment = MailAttachmentReputation(blobId: "other-blob", name: "other.png", size: 20, reputation: attachment.reputation)
        let response = MailMessageReputationEnvelope(messageId: "message-1",
                                                      remoteUrls: [safeImage, unlisted, badDigest, untrustedProvider],
                                                      attachments: [attachment, mismatchedAttachment])

        let validated = try MailMessageSafety.validated(response, expectedMessageID: "message-1", html: html, attachmentIDs: ["blob-safe"])
        XCTAssertEqual(validated.remoteUrls.map(\.url), [safeURL])
        XCTAssertEqual(validated.attachments.map(\.blobId), ["blob-safe"])
        XCTAssertThrowsError(try MailMessageSafety.validated(response, expectedMessageID: "another-message", html: html, attachmentIDs: ["blob-safe"]))
    }

    func testUnknownOrFlaggedReputationsAreNotClear() {
        let clear = MailResourceReputation(provider: "virustotal", status: "known", flagged: 0, total: 60, checkedAt: nil, reportUrl: nil)
        let flagged = MailResourceReputation(provider: "virustotal", status: "known", flagged: 1, total: 60, checkedAt: nil, reportUrl: nil)
        let unknown = MailResourceReputation(provider: "virustotal", status: "unknown", flagged: nil, total: nil, checkedAt: nil, reportUrl: nil)
        let unavailable = MailResourceReputation(provider: "virustotal", status: "unavailable", flagged: nil, total: nil, checkedAt: nil, reportUrl: nil)
        XCTAssertTrue(clear.isKnownClear)
        XCTAssertFalse(flagged.isKnownClear)
        XCTAssertFalse(unknown.isKnownClear)
        XCTAssertFalse(unavailable.isKnownClear)
    }

    func testRemoteImageCSPBlocksByDefaultAndAddsOnlyCanonicalApprovedImagePath() {
        let blocked = MailMessageSafety.contentSecurityPolicy(approvedRemoteURLs: [])
        XCTAssertTrue(blocked.contains("default-src 'none'; img-src data: blob:"))
        XCTAssertFalse(blocked.contains("images.example.test"))

        let allowed = MailMessageSafety.contentSecurityPolicy(approvedRemoteURLs: [
            "https://images.example.test/mail/photo.png?tracking=1",
            "javascript://attacker.example/",
            "https://user@images.example.test/secret.png",
        ])
        XCTAssertTrue(allowed.contains("https://images.example.test/mail/photo.png"))
        XCTAssertFalse(allowed.contains("tracking=1"))
        XCTAssertFalse(allowed.contains("attacker.example"))
        XCTAssertFalse(allowed.contains("secret.png"))
    }

    func testFrameInstallsPolicyBeforeEmailBody() throws {
        let html = "<html><head></head><body><img src=\"https://tracker.example/pixel\"></body></html>"
        let secured = MailMessageSafety.frameHTML(html, approvedRemoteURLs: [])
        let policyIndex = try XCTUnwrap(secured.range(of: "Content-Security-Policy")).lowerBound
        let bodyIndex = try XCTUnwrap(secured.range(of: "<body>")).lowerBound
        XCTAssertLessThan(policyIndex, bodyIndex)
        XCTAssertTrue(secured.contains("img-src data: blob:"))
    }

    func testMailLayoutPreservesThreePaneOnlyWhenWideEnough() {
        XCTAssertEqual(MailNativePanelLayout.mode(contentWidth: 500), .stacked)
        XCTAssertEqual(MailNativePanelLayout.mode(contentWidth: 1080), .compact)
        XCTAssertEqual(MailNativePanelLayout.mode(contentWidth: 1280), .expanded)
        XCTAssertGreaterThanOrEqual(MailNativePanelLayout.compactSidebarWidth(contentWidth: 1080), 170)
    }

    private func remote(id: String, url: String, flagged: Int) -> MailRemoteResourceReputation {
        MailRemoteResourceReputation(
            id: id,
            url: url,
            reputation: MailResourceReputation(provider: "virustotal", status: "known", flagged: flagged, total: 60, checkedAt: nil, reportUrl: nil)
        )
    }
}
