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

struct RecentTestsNativePanel: View {
    @EnvironmentObject var model: DesktopAgentModel
    var initialTestID: String? = nil

    @Environment(\.desktopTheme) var theme

    @State var searchText = ""
    @State var selectedStatus = "all"
    @State var selectedLane: LoadTestingLane = .mine
    @State var selectedScenarioID = LoadTestingScenario.customID
    @State var timeoutDraft = "30"
    @State var stagesDraft = "30s:5, 1m:15"
    @State var targetURL = ""
    @State var lookupID = ""
    @State var permissionConfirmed = false
    @State var myTests: [DashboardRecentTest]?
    @State var recentTests: [DashboardRecentTest]?
    @State var selectedTest: DashboardRecentTest?
    @State var quota: LoadTestingQuota?
    @State var myError: String?
    @State var recentError: String?
    @State var loading = false
    @State var busy = false
    @State var submissionLocked = false
    @State var errorMessage = ""
    @State var noticeMessage = ""
    @State var showStartConfirmation = false
    @State var showRerunConfirmation = false
}
