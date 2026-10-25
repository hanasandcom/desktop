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

struct MailHTMLBodyView: NSViewRepresentable {
    let html: String
    let configuredWebsiteBaseURL: String
    let onOpenURL: (String) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(html, baseURL: nil)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.configuredWebsiteBaseURL = configuredWebsiteBaseURL
        context.coordinator.onOpenURL = onOpenURL
        nsView.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(configuredWebsiteBaseURL: configuredWebsiteBaseURL, onOpenURL: onOpenURL)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var configuredWebsiteBaseURL: String
        var onOpenURL: (String) -> Void

        init(configuredWebsiteBaseURL: String, onOpenURL: @escaping (String) -> Void) {
            self.configuredWebsiteBaseURL = configuredWebsiteBaseURL
            self.onOpenURL = onOpenURL
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if BrowserWorkspaceModel.isHanasandOwnedURL(url.absoluteString, configuredWebsiteBaseURL: configuredWebsiteBaseURL) {
                onOpenURL(url.absoluteString)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
