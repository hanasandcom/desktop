import AppKit
import SwiftUI
import XCTest
@testable import Hanasand

private final class VisualFixtureRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedURLs: [URL] = []

    func record(_ url: URL) {
        lock.lock()
        storedURLs.append(url)
        lock.unlock()
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storedURLs
    }
}

@MainActor
final class DesktopVisualFixtureRendererTests: XCTestCase {
    func testRenderHomeAndUnauthenticatedAccountRoutesAtReferenceWidths() throws {
        let output = URL(fileURLWithPath: "/private/tmp/hanasand-desktop-visual-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let requestRecorder = VisualFixtureRequestRecorder()
        let activityFixture = Data(#"{"generatedAt":"2026-10-25T10:00:00Z","status":"live","freshness":{"latestClaimAt":"2026-10-25T09:30:00Z","latestCollectedAt":"2026-10-25T09:31:00Z","ageMinutes":30,"collectionAgeMinutes":29,"maxLiveAgeMinutes":120},"counts":{"visible":1,"total":1,"needsReview":1,"metadataOnly":0},"page":{"limit":50,"offset":0,"total":1,"nextOffset":null,"hasMore":false},"items":[{"id":"fixture-report-1","actor":"Example Research Group","company":"Northstar Analytics","claimedData":"Employee email addresses","claimedDataSize":"Metadata only","country":"NO","claimTime":"2026-10-25T09:30:00Z","collectedAt":"2026-10-25T09:31:00Z","status":"needs_review","confidence":0.82,"sourceName":"Synthetic visual fixture"}]}"#.utf8)
        let activityClient = PublicExposureActivityClient(send: { request in
            guard let url = request.url, url.host == "hanasand.com", url.path == "/api/public/exposure-queue",
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
                throw URLError(.unsupportedURL)
            }
            requestRecorder.record(url)
            return (activityFixture, response)
        })

        for width in [1080, 1512] {
            for route in [
                "/", "/about", "/contact", "/faq", "/cookies", "/cookie-settings",
                "/privacy", "/terms", "/reserved-usernames", "/pricing",
                "/solutions/scanner", "/solutions/security-monitoring", "/security.txt",
            ] {
                let page = try XCTUnwrap(NativePublicInfoPage.resolve(route))
                let suiteName = "hanasand.visual-fixture.\(UUID().uuidString)"
                let fixtureDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
                defer { fixtureDefaults.removePersistentDomain(forName: suiteName) }
                let content = NativePublicInfoPanel(
                    page: page,
                    onNavigate: { _ in },
                    homeActivityViewModel: page.kind == .home ? PublicExposureActivityViewModel(client: activityClient) : nil,
                    initialFAQFeedback: [:],
                    cookieSettingsDefaults: fixtureDefaults
                )
                let view = AnyView(FeatureWorkspace(title: "", subtitle: "", contentMaxWidth: 1280) { content })
                try render(view, label: "public\(safeLabel(route))", width: width, output: output,
                           model: DesktopAgentModel(visualFixture: ()))
            }

            try render(
                AnyView(NativeAccountRoutePanel(path: "/login", query: [:])),
                label: "login", width: width, output: output, model: DesktopAgentModel(visualFixture: ())
            )
            try render(
                AnyView(NativeAccountRoutePanel(path: "/signup", query: [:])),
                label: "signup", width: width, output: output, model: DesktopAgentModel(visualFixture: ())
            )
        }

        XCTAssertEqual(requestRecorder.urls.map(\.path), [
            "/api/public/exposure-queue", "/api/public/exposure-queue",
        ])
        XCTAssertTrue(requestRecorder.urls.allSatisfy { $0.host == "hanasand.com" })
    }

    private func safeLabel(_ route: String) -> String {
        route == "/" ? "-home" : route.replacingOccurrences(of: "/", with: "-")
    }

    private func render(
        _ content: AnyView,
        label: String,
        width: Int,
        output: URL,
        model: DesktopAgentModel
    ) throws {
        let theme = DesktopTheme(preference: .light, systemScheme: .light)
        let root = content
            .environmentObject(model)
            .environment(\.desktopTheme, theme)
            .environment(\.displayScale, 1)
            .preferredColorScheme(theme.isLight ? .light : .dark)
            .frame(width: CGFloat(width), height: 900)
            .background(theme.background)
        // A hidden host lets the real SwiftUI view hierarchy settle while keeping
        // the review offscreen. This window is never ordered or activated.
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        XCTAssertFalse(window.isVisible, "Visual review must never order a window on screen.")
        let rect = NSRect(x: 0, y: 0, width: width, height: 900)
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: rect) else {
            window.close()
            XCTFail("Could not render \(label) at \(width)pt")
            return
        }
        hosting.cacheDisplay(in: rect, to: bitmap)
        window.close()
        let normalized = try XCTUnwrap(normalizedBitmap(bitmap, width: width, height: 900))
        let png = try XCTUnwrap(normalized.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_000, "Expected a nonempty \(label) screenshot at \(width)pt")
        XCTAssertEqual(Array(png.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        XCTAssertEqual(pngInteger(png, offset: 16), width)
        XCTAssertEqual(pngInteger(png, offset: 20), 900)
        try png.write(to: output.appendingPathComponent("\(label)-\(width).png"), options: .atomic)
    }

    private func normalizedBitmap(_ source: NSBitmapImageRep, width: Int, height: Int) -> NSBitmapImageRep? {
        guard let image = source.cgImage,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let normalized = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: normalized)
    }

    private func pngInteger(_ data: Data, offset: Int) -> Int {
        data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
    }
}
