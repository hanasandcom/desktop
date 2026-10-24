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

struct BrowserWorkspace: View {
    @EnvironmentObject var model: DesktopAgentModel

    @Environment(\.desktopTheme) var theme

    @StateObject var workspace = BrowserWorkspaceModel(); @FocusState var addressFocused: Bool
    @State var browserUsageState: BrowserUsageLoadState = .loading
    @State var browserGlobalStatsState: BrowserGlobalStatsLoadState = .loading

    var browserUsageCredentialKey: String {
        var hasher = Hasher()
        hasher.combine(model.settings.apiBaseURL)
        hasher.combine(model.userIDForRequests)
        hasher.combine(model.authTokenForRequests)
        hasher.combine(model.settings.impersonationToken)
        hasher.combine(model.settings.impersonatingUserID)
        return String(hasher.finalize())
    }
}
