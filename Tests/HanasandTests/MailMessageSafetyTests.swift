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

    func testAttachmentURLEncodesEverySegmentAndRequiresSecureTransport() throws {
        let url = try MailMessageSafety.makeAttachmentURL(
            baseURL: URL(string: "https://api.example.test/api/")!,
            mailboxUser: "person/name@example.test",
            blobID: "blob?one",
            name: "logo #1.png"
        )
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
                       "/api/mail/blob/person%2Fname%40example.test/blob%3Fone/logo%20%231.png")
        XCTAssertThrowsError(try MailMessageSafety.makeAttachmentURL(
            baseURL: URL(string: "http://api.example.test")!, mailboxUser: "person", blobID: "blob", name: "logo.png"
        ))
    }

    func testInlineAttachmentsRequireCIDKnownClearReputationAndRasterType() {
        let clear = reputation(status: "known", flagged: 0)
        let attachments = [
            attachment(blobID: "clear", cid: "clear", type: "image/png", size: 10),
            attachment(blobID: "flagged", cid: "flagged", type: "image/png", size: 10),
            attachment(blobID: "unknown", cid: "unknown", type: "image/png", size: 10),
            attachment(blobID: "svg", cid: "svg", type: "image/svg+xml", size: 10),
            attachment(blobID: "no-cid", cid: nil, type: "image/jpeg", size: 10),
        ]
        let verdicts = [
            attachmentReputation(blobID: "clear", reputation: clear),
            attachmentReputation(blobID: "flagged", reputation: reputation(status: "known", flagged: 2)),
            attachmentReputation(blobID: "unknown", reputation: reputation(status: "unknown", flagged: nil)),
            attachmentReputation(blobID: "svg", reputation: clear),
        ]

        XCTAssertEqual(MailMessageSafety.eligibleInlineAttachments(attachments, reputations: verdicts).map(\.blobId), ["clear"])
        XCTAssertNil(MailMessageSafety.inlineImageURL(token: "../other"))
        XCTAssertEqual(MailMessageSafety.inlineImageURL(token: "0"), "hanasand-mail-image://inline/0")
    }

    func testInlineImageRequiresMatchingRasterMIMEAndSignature() {
        let samples: [(String, [UInt8])] = [
            ("image/png", [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
            ("image/jpeg", [0xff, 0xd8, 0xff]),
            ("image/gif", Array("GIF89a".utf8)),
            ("image/webp", Array("RIFF0000WEBP".utf8)),
        ]
        for (mimeType, bytes) in samples {
            XCTAssertEqual(MailMessageSafety.validatedInlineImage(
                data: Data(bytes), declaredType: mimeType, responseType: "\(mimeType); charset=binary"
            )?.mimeType, mimeType)
        }
        XCTAssertNil(MailMessageSafety.validatedInlineImage(data: Data("<svg/>".utf8), declaredType: "image/svg+xml", responseType: "image/svg+xml"))
        XCTAssertNil(MailMessageSafety.validatedInlineImage(data: Data([0x89, 0x50, 0x4e, 0x47]), declaredType: "image/png", responseType: "image/png"))
        XCTAssertNil(MailMessageSafety.validatedInlineImage(data: Data([0xff, 0xd8, 0xff]), declaredType: "image/png", responseType: "image/jpeg"))
    }

    func testCIDRenderingUsesOnlyOpaqueLocalImageURLs() {
        let html = #"<img src="cid:logo"><img src='cid:<logo>'><img src="cid:blocked">"#
        let rendered = MailMessageSafety.replacingInlineContentIDs(in: html, tokensByCID: ["logo": "0"])

        XCTAssertEqual(rendered.components(separatedBy: "hanasand-mail-image://inline/0").count - 1, 2)
        XCTAssertFalse(rendered.contains("cid:"))
        XCTAssertFalse(rendered.contains("/mail/blob/"))
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
        XCTAssertTrue(blocked.contains("default-src 'none'; img-src data: blob: hanasand-mail-image:"))
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
        XCTAssertTrue(secured.contains("img-src data: blob: hanasand-mail-image:"))
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

    private func attachment(blobID: String, cid: String?, type: String, size: Int) -> MailOverviewEnvelope.Attachment {
        MailOverviewEnvelope.Attachment(blobId: blobID, name: "\(blobID).png", type: type, size: size, disposition: "inline", cid: cid, isInline: true)
    }

    private func reputation(status: String, flagged: Int?) -> MailResourceReputation {
        MailResourceReputation(provider: "virustotal", status: status, flagged: flagged, total: nil, checkedAt: nil, reportUrl: nil)
    }

    private func attachmentReputation(blobID: String, reputation: MailResourceReputation) -> MailAttachmentReputation {
        MailAttachmentReputation(blobId: blobID, name: "\(blobID).png", size: 10, reputation: reputation)
    }
}
