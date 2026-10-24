import SwiftUI
import WebKit

struct NativeSharePreviewView: View {
    let target: URL
    @Environment(\.desktopTheme) private var theme
    @State private var notice = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !notice.isEmpty {
                NativeNotice(message: notice, title: "Preview navigation blocked", tone: .info)
            }
            NativeSharePreviewWebView(target: target) { message in
                notice = message
            }
            .frame(minHeight: 360)
            .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .id(target.absoluteString)
    }
}

struct NativeSharePreviewWebView: NSViewRepresentable {
    let target: URL
    let onBlockedNavigation: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(target: target, onBlockedNavigation: onBlockedNavigation)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: Self.configuration())
        webView.navigationDelegate = context.coordinator
        context.coordinator.load(target, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onBlockedNavigation = onBlockedNavigation
        context.coordinator.load(target, in: webView)
    }

    static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return configuration
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        private var loadedTarget: URL?
        private let previewHost: String
        var onBlockedNavigation: (String) -> Void

        init(target: URL, onBlockedNavigation: @escaping (String) -> Void) {
            previewHost = target.host?.lowercased() ?? ""
            self.onBlockedNavigation = onBlockedNavigation
        }

        func load(_ target: URL, in webView: WKWebView) {
            guard loadedTarget != target else { return }
            loadedTarget = target
            var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.httpShouldHandleCookies = false
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            webView.load(request)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url,
                  NativeSharePreview.allowsMainFrameNavigation(to: url, previewHost: previewHost) else {
                onBlockedNavigation("The preview stays on its own secure Hanasand hostname.")
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            guard NativeSharePreview.allowsMainFrameNavigation(to: navigationResponse.response.url ?? URL(fileURLWithPath: "/"),
                                                               previewHost: previewHost) else {
                onBlockedNavigation("The preview redirected outside its secure Hanasand hostname.")
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onBlockedNavigation("The preview could not load. Check the share alias and try again.")
        }
    }
}
