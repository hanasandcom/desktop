import AppKit
import SwiftUI
import XCTest
@testable import Hanasand

private struct DashboardVisualFixtureRoute: Hashable {
    let path: String
    var detailID = ""
    var query: [String: String] = [:]

    var identity: String {
        let queryIdentity = query.keys.sorted().map { "\($0)=\(query[$0] ?? "")" }.joined(separator: "&")
        return [path, detailID, queryIdentity].joined(separator: "|")
    }

    var fileLabel: String {
        var value = path == "/" ? "home" : path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        value = value.replacingOccurrences(of: "/", with: "-")
        if !detailID.isEmpty { value += "-detail" }
        for key in query.keys.sorted() {
            value += "-\(key)-\((query[key] ?? "").replacingOccurrences(of: "/", with: "-"))"
        }
        let safe = value.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
        return String(safe.prefix(140))
    }
}

private final class AuthVisualFixtureActivitySender: @unchecked Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url, url.host == "hanasand.com", url.path == "/api/public/exposure-queue",
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
            throw URLError(.unsupportedURL)
        }
        return (Self.payload, response)
    }

    private static let payload = Data(#"{"generatedAt":"2026-10-25T10:00:00Z","status":"live","freshness":{"latestClaimAt":"2026-10-25T09:30:00Z","latestCollectedAt":"2026-10-25T09:31:00Z","ageMinutes":30,"collectionAgeMinutes":29,"maxLiveAgeMinutes":120},"counts":{"visible":1,"total":1,"needsReview":1,"metadataOnly":0},"page":{"limit":50,"offset":0,"total":1,"nextOffset":null,"hasMore":false},"items":[{"id":"fixture-report-1","actor":"Example Research Group","company":"Northstar Analytics","claimedData":"Employee email addresses","claimedDataSize":"Metadata only","country":"NO","claimTime":"2026-10-25T09:30:00Z","collectedAt":"2026-10-25T09:31:00Z","status":"needs_review","confidence":0.82,"sourceName":"Synthetic visual fixture"}]}"#.utf8)
}

private struct DashboardVisualFixtureAIWorkspace: View {
    @FocusState private var commandFocused: Bool

    var body: some View {
        AIWorkspace(commandFocused: $commandFocused)
    }
}

@MainActor
final class AuthenticatedNativeDashboardVisualFixtureTests: XCTestCase {
    private var cookieDefaultsSuites: [String] = []

    private let websiteDestinationPaths = [
        "/about", "/account-pending-deletion", "/activity", "/ai", "/ai/workspace", "/api", "/api/openapi",
        "/public-articles", "/public-article", "/contact", "/cookie-settings", "/cookies", "/dashboard",
        "/content/articles", "/automation/cron", "/automation/health", "/dashboard/automation", "/db/backups",
        "/cases", "/db", "/db/restore", "/findings", "/integrations", "/dashboard/delivery-history",
        "/ti/profiles", "/watchlists", "/ti/sources", "/load-testing", "/logs", "/logs/errors", "/logs/realtime",
        "/logs/search", "/mail", "/management", "/vms", "/organizations", "/dashboard/management/service-accounts",
        "/users", "/notes", "/repositories", "/rules/match", "/rules/detail", "/rules/analysis", "/rules/detection",
        "/rules/tuning", "/scanner", "/subscription", "/system", "/system/containers", "/system/ai", "/system/hosts",
        "/system/rates", "/profile", "/system/updates", "/thesis", "/content/thoughts", "/ti/overview", "/ti/activity",
        "/ti/runs", "/ti/enrichment", "/ti/timeliness", "/ti/workbench", "/traffic", "/traffic/blocklist", "/traffic/map",
        "/traffic/recent", "/vms/console", "/developers", "/faq", "/g", "/images/library", "/login", "/logout",
        "/monitor", "/organizations/events", "/organizations/activity", "/organizations/settings", "/organizations/team",
        "/organization-api-keys", "/organization-privacy", "/s", "/", "/pricing", "/privacy", "/pwned", "/register",
        "/signup", "/reserved-usernames", "/reset-password", "/reset-password-again", "/sandbox", "/sandbox/result",
        "/sandbox/report", "/secure-account", "/solutions/scanner", "/solutions/security-monitoring", "/status", "/support",
        "/switch-account", "/terms", "/test", "/ti", "/ti/darkweb/index", "/upload",
    ]

    private let expoDestinationPaths = ["/scan"]

    // These are the unique native destination values in WebsitePageRouteCoverageTests.
    // Context variants are appended below when they materially change the destination panel.
    private var routes: [DashboardVisualFixtureRoute] {
        let safeDestinations = websiteDestinationPaths.filter { $0 != "/switch-account" }
        var routes = (safeDestinations + expoDestinationPaths).map { DashboardVisualFixtureRoute(path: $0) }
        routes.append(contentsOf: [
            .init(path: "/cases", detailID: "HA-2042"),
            .init(path: "/status", query: ["section": "incidents"]),
            .init(path: "/profile", detailID: "fixture-public-user"),
            .init(path: "/vms", detailID: "fixture-vm"),
            .init(path: "/vms/console", detailID: "fixture-vm", query: ["provisioning": "1"]),
            .init(path: "/dashboard/automation", query: ["setup": "dwm"]),
            .init(path: "/automation/cron", query: ["scope": "system"]),
            .init(path: "/ti/sources", query: ["available": "true", "page": "2", "family": "ransomware"]),
            .init(path: "/dashboard/delivery-history", query: ["orgId": "fixture-org"]),
            .init(path: "/test", detailID: "fixture-test"),
            .init(path: "/logs", query: ["service": "api"]),
            .init(path: "/public-article", detailID: "fixture-article"),
            .init(path: "/sandbox/report", detailID: "fixture-run"),
            .init(path: "/s", detailID: "fixture-share"),
            .init(path: "/s", detailID: "fixture-share", query: ["search": "1"]),
            .init(path: "/s", detailID: "fixture-share", query: ["terminal": "1"]),
            .init(path: "/s", detailID: "fixture-project", query: ["workspace": "project"]),
            .init(path: "/images/library", query: ["section": "albums"]),
            .init(path: "/images/library", query: ["section": "upload"]),
            .init(path: "/images/library", query: ["section": "deviceReview"]),
        ])
        return routes
    }

    func testRenderEveryUniqueWebsiteDestinationAndContextVariantAtReferenceWidths() throws {
        cookieDefaultsSuites = []
        defer {
            for suite in cookieDefaultsSuites {
                UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            }
        }

        let output = URL(fileURLWithPath: "/private/tmp/hanasand-desktop-auth-visual-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for oldFile in try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: oldFile)
        }

        XCTAssertEqual(Set(websiteDestinationPaths).count, websiteDestinationPaths.count, "The copied website crosswalk destination list must stay deduplicated.")
        XCTAssertEqual(websiteDestinationPaths.count, 104, "Update this fixture when the website destination crosswalk changes.")
        XCTAssertTrue(websiteDestinationPaths.contains("/switch-account"))
        XCTAssertFalse(routes.contains { $0.path == "/switch-account" }, "Saved account profiles are Keychain-backed and must not be read by this fixture.")
        XCTAssertEqual(routes.count, 124, "Update this fixture when unique website/Expo destinations or meaningful native route contexts change.")
        XCTAssertEqual(Set(routes.map(\.identity)).count, routes.count, "Every base destination and route-context variant must render once per width.")
        XCTAssertEqual(Set(routes.map(\.path)), Set(websiteDestinationPaths.filter { $0 != "/switch-account" } + expoDestinationPaths))

        for route in routes {
            if route.path == "/ai" { continue }
            if NativePublicInfoPage.resolve(route.path) != nil { continue }
            if NativeAccountRoutePanel.supports(path: route.path) { continue }
            XCTAssertTrue(NativeDashboardDetail.hasNativePanel(for: route.path), "No safe native renderer is registered for \(route.path).")
        }

        for width in [1080, 1512] {
            for route in routes {
                let model = DesktopAgentModel(visualFixture: ())
                model.selectedSection = .dashboard
                model.selectedDashboardPath = route.path
                let fixtureURL = URL(string: route.path, relativeTo: URL(string: model.settings.websiteBaseURL))?.absoluteString
                model.selectedDashboardTitle = route.path == "/" ? "Hanasand" :
                    fixtureURL.flatMap { BrowserWorkspaceModel.nativeRoute(for: $0, configuredWebsiteBaseURL: model.settings.websiteBaseURL)?.label } ?? route.path
                model.selectedNativeDashboardDetailID = route.detailID
                model.selectedNativeDashboardQuery = route.query

                XCTAssertTrue(model.settings.authToken.isEmpty, "Visual fixtures must never carry an authentication token.")
                XCTAssertTrue(model.settings.userID.isEmpty, "Visual fixtures must never carry a customer identity.")
                XCTAssertEqual(URL(string: model.settings.apiBaseURL)?.host, "visual-fixture.invalid")
                XCTAssertEqual(URL(string: model.settings.websiteBaseURL)?.host, "visual-fixture.invalid")

                let view = try fixtureView(for: route, model: model)
                try render(view, label: route.fileLabel, width: width, output: output, model: model)
            }
        }

        let screenshots = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }
        XCTAssertEqual(screenshots.count, routes.count * 2)
        XCTAssertEqual(Set(screenshots.map(\.lastPathComponent)).count, routes.count * 2)
        let representativeImages = try ["dashboard", "traffic-map", "logs-realtime", "cases"].map { label in
            try Data(contentsOf: output.appendingPathComponent("\(label)-1080.png"))
        }
        XCTAssertEqual(Set(representativeImages).count, representativeImages.count,
                       "The offscreen renderer must include each route's distinct panel content.")
    }

    private func fixtureView(for route: DashboardVisualFixtureRoute, model: DesktopAgentModel) throws -> AnyView {
        let content: AnyView
        if route.path == "/ai" {
            return AnyView(DashboardVisualFixtureAIWorkspace())
        } else if let page = NativePublicInfoPage.resolve(route.path) {
            let suite = "hanasand.auth-visual-fixture.\(route.fileLabel)"
            guard let defaults = UserDefaults(suiteName: suite) else { throw NSError(domain: "VisualFixture", code: 1) }
            defaults.removePersistentDomain(forName: suite)
            cookieDefaultsSuites.append(suite)
            content = AnyView(NativePublicInfoPanel(
                page: page,
                onNavigate: { _ in },
                homeActivityViewModel: page.kind == .home
                    ? PublicExposureActivityViewModel(client: PublicExposureActivityClient(send: { request in try await AuthVisualFixtureActivitySender().send(request) }))
                    : nil,
                initialFAQFeedback: [:],
                cookieSettingsDefaults: defaults
            ))
        } else if NativeAccountRoutePanel.supports(path: route.path) {
            return AnyView(NativeAccountRoutePanel(path: route.path, query: route.query))
        } else {
            XCTAssertTrue(NativeDashboardDetail.hasNativePanel(for: route.path))
            return AnyView(NativeDashboardDetail())
        }

        let maximumWidth: CGFloat = NativePublicInfoPage.resolve(route.path) == nil ? 1040 : 1280
        let title = NativePublicInfoPage.resolve(route.path) != nil ? "" : (route.path == "/" ? "" : route.path)
        return AnyView(FeatureWorkspace(title: title, subtitle: "", contentMaxWidth: maximumWidth) { content })
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
        // Attach the view to a never-ordered window so ScrollViewReader, SwiftUI
        // tasks and AppKit text controls receive a real host. The window is always
        // checked invisible and cannot cover or activate over the user's app.
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
            XCTFail("Could not allocate screenshot for \(label) at \(width)pt")
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
