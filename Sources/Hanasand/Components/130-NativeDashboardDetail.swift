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

struct NativeDashboardDetail: View {
    @EnvironmentObject var model: DesktopAgentModel
    @Environment(\.desktopTheme) var theme

    var body: some View {
        FeatureWorkspace(title: model.selectedDashboardTitle, subtitle: statusSubtitle) {
            HStack(spacing: 8) {
                detailToolbarButton(title: "Back", icon: "chevron.left") {
                    model.closeNativeDashboardPage()
                }
                if !hasPanelRefresh {
                    detailToolbarButton(title: "Refresh", icon: "arrow.clockwise") {
                        Task { await model.loadNativeDashboardData() }
                    }
                }
                if model.isLoadingNativeDashboard {
                    ProgressView()
                        .scaleEffect(0.70)
                }
            }

            nativeDashboardBody
        }
        .task(id: model.selectedDashboardPath) {
            await model.loadNativeDashboardData()
        }
    }

    private var hasPanelRefresh: Bool {
        ["/dashboard/automations", "/dashboard/automation", "/system/cron", "/api", "/pwned", "/support", "/thesis", "/tools", "/traffic/map", "/images/library", "/organization-api-keys", "/organization-privacy", "/organizations", "/watchlists", "/dashboard/delivery-history", "/traffic/recent", "/subscription", "/system/hosts", "/system/updates", "/findings", "/rules/match", "/rules/analysis", "/rules/detection", "/rules/tuning", "/integrations", "/dashboard/management/service-accounts"].contains(model.selectedDashboardPath ?? "")
    }

    private var statusSubtitle: String {
        ["Ready", "Native controls"].contains(model.nativeDashboardStatus) ? "" : model.nativeDashboardStatus
    }

    private func detailToolbarButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    var nativeDashboardBody: some View {
        switch model.selectedDashboardPath {
        case "/dashboard":
            DashboardOverviewNativePanel()
        case "/cases":
            MonitoringCasesNativePanel()
        case "/organizations":
            OrganizationDirectoryNativePanel()
        case "/ti":
            ThreatIntelligenceNativePanel()
        case "/watchlists":
            OrganizationWatchlistsNativePanel()
        case "/organization-api-keys":
            OrganizationApiKeysNativePanel()
        case "/api":
            APIReferenceNativePanel()
        case "/pwned":
            PasswordCheckNativePanel()
        case "/support":
            SupportDeskNativePanel()
        case "/thesis":
            ThesisNativePanel()
        case "/tools":
            NativeToolsExplorePanel()
        case "/traffic/map":
            TrafficMapNativePanel()
        case "/images/library":
            GalleryLibraryNativePanel()
        case "/organization-privacy":
            OrganizationPrivacyNativePanel()
        case "/dashboard/delivery-history":
            ThreatDeliveryHistoryNativePanel()
        case "/traffic/recent":
            TrafficRecentNativePanel()
        case "/subscription":
            SubscriptionNativePanel()
        case "/findings":
            ThreatFindingsNativePanel()
        case "/rules/match":
            ThreatRulesNativePanel(category: "match")
        case "/rules/analysis":
            ThreatRulesNativePanel(category: "analysis")
        case "/rules/detection":
            ThreatRulesNativePanel(category: "detection")
        case "/rules/tuning":
            ThreatRuleTuningNativePanel()
        case "/integrations":
            IntegrationsNativePanel()
        case "/dashboard/management/service-accounts":
            ServiceAccountsNativePanel()
        case "/system/hosts":
            HostsNativePanel()
        case "/system/updates":
            HostUpdatesNativePanel()
        case "/g":
            LinksNativePanel()
        case "/dashboard/tests":
            RecentTestsNativePanel()
        case "/dashboard/automations", "/dashboard/automation":
            AutomationsNativePanel()
        case "/system/cron":
            SystemCronNativePanel()
        case "/mail":
            MailNativePanel()
        case "/system":
            SystemNativePanel()
        case "/vms":
            VMsNativePanel()
        case "/logs":
            LogsNativePanel()
        case "/system/ai":
            AIModelsNativePanel()
        case "/system/rates":
            RateLimitsNativePanel()
        case "/profile":
            ProfileNativePanel()
        case "/management", "/users":
            UsersNativePanel()
        case "/role":
            RolesNativePanel()
        case "/s":
            SharesNativePanel()
        case "/content/articles":
            ArticlesNativePanel()
        case "/content/thoughts":
            ThoughtsNativePanel()
        case "/notes":
            NotesNativePanel()
        case "/db":
            DatabaseNativePanel()
        case "/db/backups":
            BackupNativePanel()
        case "/db/restore":
            RestoreNativePanel()
        case "/vulnerabilities":
            VulnerabilityNativePanel()
        case "/traffic":
            TrafficNativePanel()
        case "/upload", "/dashboard/files":
            UploadNativePanel()
        default:
            NativeRouteFallbackPanel()
        }
    }
}
