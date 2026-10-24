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

struct NativeBrowserView: NSViewRepresentable {
    @ObservedObject var tab: BrowserTabState
    var onOpenNativeHanasandRoute: ((String) -> Bool)? = nil
    var configuredWebsiteBaseURL: String? = nil

    func makeNSView(context: Context) -> WKWebView {
        tab.onOpenNativeHanasandRoute = onOpenNativeHanasandRoute
        tab.configuredWebsiteBaseURL = configuredWebsiteBaseURL
        return tab.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        tab.onOpenNativeHanasandRoute = onOpenNativeHanasandRoute
        tab.configuredWebsiteBaseURL = configuredWebsiteBaseURL
    }
}
