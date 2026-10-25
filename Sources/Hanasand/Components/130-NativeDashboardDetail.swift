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

enum NativeAutomationRoute: Equatable {
    case overview(initialAutomationID: String?, startsInCreate: Bool)
    case health(initialAutomationID: String?, startsInCreate: Bool)
    case personalCron
    case systemCron

    static func resolve(path: String, query: [String: String]) -> NativeAutomationRoute? {
        let initialID = query["monitor"]
        let startsInCreate = query["setup"] == "dwm"
        switch path {
        case "/dashboard/automations", "/dashboard/automation": return .overview(initialAutomationID: initialID, startsInCreate: startsInCreate)
        case "/automation/health": return .health(initialAutomationID: initialID, startsInCreate: startsInCreate)
        case "/automation/cron": return query["scope"] == "system" ? .systemCron : .personalCron
        case "/system/cron": return .systemCron
        default: return nil
        }
    }
}

struct NativeDashboardDetail: View {
    @EnvironmentObject var model: DesktopAgentModel
    @Environment(\.desktopTheme) var theme

    static func hasNativePanel(for path: String) -> Bool {
        if path == "/authenticator" || path == "/findings/actions" { return true }
        switch path {
        case "/", "/about", "/contact", "/faq", "/cookies", "/cookie-settings", "/privacy", "/terms", "/reserved-usernames", "/pricing", "/solutions/scanner", "/solutions/security-monitoring", "/security.txt",
             "/dashboard", "/cases", "/cases/intelligence", "/documents/scanner", "/status", "/monitor", "/ti/darkweb/index", "/activity", "/ai/workspace", "/organization-workspace", "/organizations/settings", "/organizations/events", "/organizations/activity", "/organizations", "/organizations/team", "/ti", "/ti/overview", "/ti/workbench", "/ti/enrichment", "/ti/activity", "/ti/profiles", "/ti/sources", "/ti/runs", "/ti/captures", "/ti/timeliness", "/watchlists", "/organization-api-keys", "/api", "/api/openapi", "/developers", "/public-profile", "/sandbox", "/sandbox/result", "/sandbox/report", "/pwned", "/support", "/thesis", "/tools", "/authenticator", "/traffic/map", "/images/library", "/cdn/files", "/shared/album", "/scanner", "/dashboard/scanner", "/organization-privacy", "/dashboard/delivery-history", "/traffic/recent", "/subscription", "/findings", "/rules/match", "/rules/detail", "/rules/analysis", "/rules/detection", "/rules/tuning", "/integrations", "/dashboard/management/service-accounts", "/system/hosts", "/system/updates", "/g", "/dashboard/tests", "/load-testing", "/test", "/dashboard/automations", "/dashboard/automation", "/automation/health", "/automation/cron", "/system/cron", "/mail", "/system", "/system/containers", "/traffic/blocklist", "/vms", "/vms/console", "/logs", "/logs/realtime", "/logs/search", "/logs/errors", "/system/ai", "/system/rates", "/profile", "/management", "/users", "/role", "/s", "/repositories", "/content/articles", "/content/thoughts", "/public-articles", "/public-article", "/notes", "/db", "/db/backups", "/db/restore", "/vulnerability-findings", "/traffic", "/upload", "/dashboard/files":
            return true
        default:
            return false
        }
    }

    var body: some View {
        FeatureWorkspace(
            title: model.selectedDashboardTitle,
            subtitle: statusSubtitle,
            contentMaxWidth: NativePublicInfoPage.resolve(model.selectedDashboardPath ?? "") == nil ? 1040 : 1280,
            initialScrollTarget: model.selectedDashboardPath == "/profile" ? model.selectedNativeDashboardQuery["section"] : nil
        ) {
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
            let path = model.selectedDashboardPath ?? ""
            let ownedByPanel = ["/activity", "/ai/workspace", "/sandbox/result", "/sandbox/report", "/images/library", "/cdn/files", "/shared/album"].contains(path)
                || (path == "/s" && !model.selectedNativeDashboardDetailID.isEmpty)
                || path == "/public-articles" || path == "/public-article"
            guard !ownedByPanel else { return }
            await model.loadNativeDashboardData()
        }
    }

    private var hasPanelRefresh: Bool {
        ["/dashboard", "/dashboard/automations", "/dashboard/automation", "/automation/health", "/automation/cron", "/dashboard/tests", "/system/cron", "/api", "/api/openapi", "/sandbox", "/sandbox/result", "/sandbox/report", "/activity", "/ai/workspace", "/monitor", "/pwned", "/support", "/thesis", "/tools", "/mail", "/traffic", "/traffic/map", "/traffic/blocklist", "/system/containers", "/images/library", "/cdn/files", "/shared/album", "/organization-api-keys", "/organization-privacy", "/organizations", "/organization-workspace", "/organizations/team", "/organizations/settings", "/organizations/events", "/organizations/activity", "/cases", "/cases/intelligence", "/documents/scanner", "/status", "/watchlists", "/dashboard/delivery-history", "/traffic/recent", "/subscription", "/system", "/system/hosts", "/system/updates", "/system/rates", "/vms", "/vms/console", "/logs", "/logs/realtime", "/logs/search", "/logs/errors", "/findings", "/rules/match", "/rules/detail", "/rules/analysis", "/rules/detection", "/rules/tuning", "/integrations", "/dashboard/management/service-accounts", "/scanner", "/dashboard/scanner", "/load-testing", "/test", "/role", "/content/articles", "/content/thoughts", "/public-articles", "/public-article", "/s", "/repositories", "/ti/overview", "/ti/workbench", "/ti/enrichment", "/ti/activity", "/ti/profiles", "/ti/sources", "/ti/runs", "/ti/captures", "/ti/timeliness", "/vulnerability-findings", "/db/backups"].contains(model.selectedDashboardPath ?? "")
    }

    private var statusSubtitle: String {
        ["Ready", "Native controls"].contains(model.nativeDashboardStatus) ? "" : model.nativeDashboardStatus
    }

    private func publicArticlePanel(articleID: String?) -> some View {
        PublicArticleNativePanel(
            articleID: articleID,
            onBrowseArticles: { model.openNativeDashboard(path: "/public-articles", label: "Articles") },
            onOpenArticle: { id in model.openNativeDashboard(path: "/public-article", label: "Article", detailID: id) }
        )
        .environment(\.openURL, OpenURLAction { url in
            model.openURL(url.absoluteString, label: "Article link")
            return .handled
        })
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
            CasesWorkspaceNativePanel(initialCaseID: model.selectedNativeDashboardDetailID)
        case "/cases/intelligence":
            IntelligenceCasesNativePanel(initialCaseID: model.selectedNativeDashboardDetailID)
        case "/documents/scanner":
            DocumentScannerNativePanel()
        case "/monitor":
            NativeDomainMonitorPanel()
        case "/status":
            PublicStatusNativePanel(
                incidentID: model.selectedNativeDashboardDetailID.isEmpty ? nil : model.selectedNativeDashboardDetailID,
                selectedSection: model.selectedNativeDashboardQuery["section"]
            )
        case "/", "/about", "/contact", "/faq", "/cookies", "/cookie-settings", "/privacy", "/terms", "/reserved-usernames", "/pricing", "/solutions/scanner", "/solutions/security-monitoring", "/security.txt":
            if let page = NativePublicInfoPage.resolve(model.selectedDashboardPath ?? "/") {
                NativePublicInfoPanel(page: page) { route in
                    let base = model.settings.websiteBaseURL.normalizedBaseURL
                    let destination = URL(string: route, relativeTo: base)?.absoluteURL.absoluteString ?? route
                    model.openURL(destination, label: page.title)
                }
            } else {
                NativeRouteFallbackPanel()
            }
        case "/ti/darkweb/index":
            NativeTIDarkwebIndexNativePanel()
        case "/activity":
            PublicExposureActivityNativePanel()
        case "/ai/workspace":
            DesktopAIWorkspaceNativePanel(
                conversationID: model.selectedNativeDashboardDetailID.isEmpty ? nil : model.selectedNativeDashboardDetailID,
                shareID: model.selectedNativeDashboardQuery["shareID"],
                shareFileID: model.selectedNativeDashboardQuery["file"],
                shareFilePath: model.selectedNativeDashboardQuery["filePath"],
                createShareConversation: model.selectedNativeDashboardQuery["new"] == "1"
            )
        case "/organization-workspace":
            OrganizationWorkspaceNativePanel()
        case "/organizations/settings":
            OrganizationWorkspaceNativePanel(section: .settings)
        case "/organizations/events":
            OrganizationWorkspaceNativePanel(section: .events)
        case "/organizations/activity":
            OrganizationWorkspaceNativePanel(section: .activity)
        case "/organizations":
            OrganizationDirectoryNativePanel()
        case "/organizations/team":
            OrganizationMembersNativePanel()
        case "/ti":
            ThreatIntelligenceNativePanel(initialQuery: model.selectedNativeDashboardDetailID)
        case "/ti/overview":
            ThreatIntelligenceOverviewNativePanel(onOpenRoute: { path in
                guard let route = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com\(path)") else { return }
                _ = model.openNativeHanasandRoute(route)
            })
        case "/ti/workbench":
            ThreatIntelligenceWorkbenchNativePanel()
        case "/ti/enrichment":
            ActorEnrichmentNativePanel(section: .enrichment)
        case "/ti/activity":
            ActorEnrichmentNativePanel(section: .activity)
        case "/ti/profiles":
            ThreatIntelligenceOperationsNativePanel(
                section: .profiles,
                initialQuery: model.selectedNativeDashboardDetailID,
                initialOrganizationID: model.selectedNativeDashboardQuery["organizationId"]
            )
        case "/ti/sources":
            ThreatIntelligenceOperationsNativePanel(
                section: .sources,
                initialQuery: model.selectedNativeDashboardDetailID,
                selectedSourceID: model.selectedNativeDashboardDetailID,
                initialOrganizationID: model.selectedNativeDashboardQuery["organizationId"]
                    ?? model.selectedNativeDashboardQuery["org"]
                    ?? model.selectedNativeDashboardQuery["orgId"]
            )
        case "/ti/runs":
            ThreatIntelligenceOperationsNativePanel(section: .sources, initialSourceView: .runs, initialQuery: model.selectedNativeDashboardDetailID)
        case "/ti/captures":
            ThreatIntelligenceOperationsNativePanel(section: .sources, initialSourceView: .captures, initialQuery: model.selectedNativeDashboardDetailID)
        case "/ti/timeliness":
            ThreatIntelligenceOperationsNativePanel(section: .timeliness)
        case "/watchlists":
            OrganizationWatchlistsNativePanel(
                initialOrganizationID: model.selectedNativeDashboardQuery["organizationId"]
                    ?? model.selectedNativeDashboardQuery["org"]
                    ?? model.selectedNativeDashboardQuery["orgId"]
            )
        case "/organization-api-keys":
            OrganizationApiKeysNativePanel()
        case "/api":
            APIReferenceNativePanel()
        case "/api/openapi":
            APIReferenceNativePanel(initialSection: .json)
        case "/developers":
            NativeDeveloperOnboardingPanel()
        case "/public-profile":
            NativePublicProfilePanel(userID: model.selectedNativeDashboardDetailID)
        case "/sandbox":
            VStack(alignment: .leading, spacing: 14) {
                SandboxLiveWorkspaceNativePanel()
                SandboxHistoryNativePanel(initialRunID: model.selectedNativeDashboardDetailID)
            }
        case "/sandbox/result":
            SandboxStoredReportNativePanel(resultID: model.selectedNativeDashboardDetailID, reportToken: model.selectedNativeDashboardQuery["token"], selectedRunID: model.selectedNativeDashboardQuery["run"])
        case "/sandbox/report":
            SandboxStoredReportNativePanel(runID: model.selectedNativeDashboardDetailID, reportToken: model.selectedNativeDashboardQuery["token"])
        case "/pwned":
            PasswordCheckNativePanel()
        case "/support":
            SupportDeskNativePanel()
        case "/thesis":
            ThesisNativePanel()
        case "/tools":
            NativeToolsExplorePanel()
        case "/authenticator":
            NativeAuthenticatorPanel()
        case "/traffic/map":
            TrafficMapNativePanel()
        case "/images/library":
            ImagesJourneyNativePanel(initialSection: model.selectedNativeDashboardQuery["section"])
        case "/cdn/files":
            NativeCDNFilePreviewPanel(fileID: model.selectedNativeDashboardDetailID)
        case "/shared/album":
            NativePublicAlbumPanel(token: model.selectedNativeDashboardDetailID)
        case "/scanner", "/dashboard/scanner":
            SecurityScannerNativePanel()
        case "/organization-privacy":
            OrganizationPrivacyNativePanel()
        case "/dashboard/delivery-history":
            ThreatDeliveryHistoryNativePanel(initialOrganizationID: model.selectedNativeDashboardQuery["org"] ?? model.selectedNativeDashboardQuery["organizationId"] ?? model.selectedNativeDashboardQuery["orgId"])
        case "/traffic/recent":
            TrafficRecentNativePanel()
        case "/subscription":
            SubscriptionNativePanel()
        case "/findings":
            ThreatFindingsNativePanel()
        case "/rules/match":
            ThreatRulesNativePanel(category: "match", initialRuleID: model.selectedNativeDashboardDetailID.isEmpty ? nil : model.selectedNativeDashboardDetailID)
        case "/rules/detail":
            ThreatRulesNativePanel(category: "match", initialRuleID: model.selectedNativeDashboardDetailID)
        case "/rules/analysis":
            ThreatRulesNativePanel(category: "analysis", initialRuleID: model.selectedNativeDashboardDetailID.isEmpty ? nil : model.selectedNativeDashboardDetailID)
        case "/rules/detection":
            ThreatRulesNativePanel(category: "detection", initialRuleID: model.selectedNativeDashboardDetailID.isEmpty ? nil : model.selectedNativeDashboardDetailID)
        case "/rules/tuning":
            ThreatRuleTuningNativePanel()
        case "/findings/actions":
            NativeFindingsActionsPanel()
        case "/integrations":
            IntegrationsNativePanel(initialOrganizationID: model.selectedNativeDashboardQuery["org"] ?? model.selectedNativeDashboardQuery["organizationId"] ?? model.selectedNativeDashboardQuery["orgId"])
        case "/dashboard/management/service-accounts":
            ServiceAccountsNativePanel()
        case "/system/hosts":
            HostsNativePanel(initialConsoleHostID: model.selectedNativeDashboardDetailID)
        case "/system/updates":
            HostUpdatesNativePanel()
        case "/g":
            LinksNativePanel()
        case "/dashboard/tests", "/load-testing", "/test":
            RecentTestsNativePanel(initialTestID: model.selectedNativeDashboardDetailID.isEmpty ? nil : model.selectedNativeDashboardDetailID)
        case "/dashboard/automations", "/dashboard/automation", "/automation/health", "/automation/cron", "/system/cron":
            switch NativeAutomationRoute.resolve(path: model.selectedDashboardPath ?? "", query: model.selectedNativeDashboardQuery) {
            case .overview(let id, let startsInCreate):
                AutomationsNativePanel(initialAutomationID: id, startsInCreate: startsInCreate)
            case .health(let id, let startsInCreate):
                AutomationsNativePanel(scope: .health, initialAutomationID: id, startsInCreate: startsInCreate)
            case .personalCron:
                AutomationsNativePanel(scope: .personalCron)
            case .systemCron:
                SystemCronNativePanel()
            case nil:
                NativeRouteFallbackPanel()
            }
        case "/mail":
            MailNativePanel()
        case "/system":
            SystemNativePanel()
        case "/system/containers":
            InfrastructureContainersNativePanel()
        case "/traffic/blocklist":
            InfrastructureBlocklistNativePanel()
        case "/vms":
            VMsNativePanel(initialVMID: model.selectedNativeDashboardDetailID.isEmpty ? nil : model.selectedNativeDashboardDetailID)
        case "/vms/console":
            NativeVMConsolePanel(
                vmName: model.selectedNativeDashboardDetailID,
                apiBaseURL: model.settings.apiBaseURL,
                userID: model.userIDForRequests,
                token: model.authTokenForRequests,
                isImpersonating: !model.settings.impersonationToken.isEmpty || !model.settings.impersonatingUserID.isEmpty,
                provisioningFlow: model.selectedNativeDashboardQuery["provisioning"] == "1"
            )
        case "/logs":
            LogsNativePanel(initialServiceFilter: model.selectedNativeDashboardQuery["service"])
        case "/logs/realtime":
            LogsRealtimeNativePanel()
        case "/logs/search":
            LogsSearchNativePanel()
        case "/logs/errors":
            LogErrorsNativePanel()
        case "/system/ai":
            AIModelsNativePanel()
        case "/system/rates":
            RateLimitsNativePanel()
        case "/profile":
            switch NativeProfileRoutePolicy.destination(
                requestedUserID: model.selectedNativeDashboardDetailID,
                authenticatedUserID: model.userIDForRequests
            ) {
            case .signedInAccount:
                ProfileNativePanel()
            case let .publicProfile(userID):
                NativePublicProfilePanel(userID: userID)
            }
        case "/management", "/users":
            UsersNativePanel()
        case "/role":
            RolesNativePanel()
        case "/s":
            if model.selectedNativeDashboardDetailID.isEmpty {
                SharesNativePanel()
            } else {
                NativeShareWorkspacePanel(
                    alias: model.selectedNativeDashboardDetailID,
                    fileID: model.selectedNativeDashboardQuery["file"],
                    initialPath: NativeShareWorkspaceRouteSelection.initialPath(
                        explicitFileID: model.selectedNativeDashboardQuery["file"],
                        routeSection: model.selectedNativeDashboardQuery["section"]
                    ),
                    isProject: model.selectedNativeDashboardQuery["workspace"] == "project",
                    initialChatOpen: model.selectedNativeDashboardQuery["chat"] == "1",
                    createIfMissing: model.selectedNativeDashboardQuery["new"] == "1",
                    onOpenChat: {
                        var query = ["shareID": model.selectedNativeDashboardDetailID, "new": "1"]
                        if let fileID = model.selectedNativeDashboardQuery["file"] { query["file"] = fileID }
                        model.openNativeDashboard(
                            path: "/ai/workspace",
                            label: "Share chat",
                            query: query
                        )
                    }
                )
            }
        case "/repositories":
            RepositoryWorkspaceNativePanel()
        case "/content/articles":
            ArticlesNativePanel()
        case "/public-articles":
            publicArticlePanel(articleID: nil)
        case "/public-article":
            publicArticlePanel(articleID: model.selectedNativeDashboardDetailID)
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
        case "/vulnerability-findings":
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
