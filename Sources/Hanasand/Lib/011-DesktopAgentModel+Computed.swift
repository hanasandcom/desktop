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

extension DesktopAgentModel {
    var effectiveInstalledVersion: String {
        backgroundInstalledUpdateVersion.isNewerVersion(than: Self.appVersion) ? backgroundInstalledUpdateVersion : Self.appVersion
    }

    var isServerBusy: Bool {
        isCheckingServerReachability || isRunningServerAction
    }

    var remoteDesktopProtocolLabel: String {
        (RemoteDesktopProtocol(rawValue: settings.remoteDesktopProtocol) ?? .screenSharing).label
    }

    var remoteDesktopProtocolIcon: String {
        (RemoteDesktopProtocol(rawValue: settings.remoteDesktopProtocol) ?? .screenSharing).icon
    }

    var selectedMailMessage: MailOverviewEnvelope.Message? {
        mailOverview?.selectedMessage
            ?? mailOverview?.messages.first(where: { $0.id == selectedMailMessageID })
            ?? mailOverview?.messages.first
    }

    var hasDiscardedImages: Bool {
        imageReviewDecisions.values.contains(.discard)
    }

    var hasHanasandAuth: Bool {
        !authTokenForRequests.isEmpty && !userIDForRequests.isEmpty
    }

    var selectedOrganizationID: String {
        guard hasHanasandAuth,
              !settings.selectedOrganizationID.isEmpty,
              settings.selectedOrganizationUserID == userIDForRequests,
              settings.impersonationToken.isEmpty,
              settings.impersonatingUserID.isEmpty else { return "" }
        return settings.selectedOrganizationID
    }

    var dashboardActions: [DesktopAction] {
        [
            .route("Overview", "Service and account overview.", "gauge.with.dots.needle", "/dashboard"),
            .route("Monitoring cases", "Review health checks and cases.", "tray.full", "/cases"),
            .route("Threat intelligence", "Search actors and vulnerabilities.", "magnifyingglass", "/ti"),
            .route("Watchlists", "Manage threat watch terms.", "list.bullet.rectangle", "/watchlists"),
            .route("Delivery History", "Review organization alert delivery attempts.", "paperplane", "/dashboard/delivery-history"),
            .route("Recent Traffic", "Browse retained HTTP requests.", "arrow.left.arrow.right", "/traffic/recent"),
            .route("Organization Privacy", "Review retention and privacy history.", "hand.raised", "/organization-privacy"),
            .route("Subscription", "View plan, access, and allowances.", "creditcard", "/subscription"),
            .route("Findings", "Investigate source-backed alerts and evidence.", "scope", "/findings"),
            .route("Match Rules", "Manage matching rules for monitored activity.", "line.3.horizontal.decrease.circle", "/rules/match"),
            .route("Analysis Rules", "Review analysis and retention rules.", "function", "/rules/analysis"),
            .route("Detection Rules", "Manage detection and response rules.", "shield.lefthalf.filled", "/rules/detection"),
            .route("Rule Tuning", "Preview and tune rule matches.", "slider.horizontal.3", "/rules/tuning"),
            .route("Organization API keys", "Create and revoke API keys.", "key.horizontal", "/organization-api-keys"),
            .route("Integrations", "Manage organization webhook destinations.", "point.3.connected.trianglepath.dotted", "/integrations"),
            .route("Service Accounts", "Manage scoped organization service accounts.", "person.badge.key", "/dashboard/management/service-accounts"),
            .route("API Reference", "Search endpoint and schema docs.", "doc.text.magnifyingglass", "/api"),
            .route("Hosts", "Host health and SSH access.", "server.rack", "/system/hosts"),
            .route("Host Updates", "View automatic update history.", "arrow.down.circle", "/system/updates"),
            .route("Mail", "Open Mail.", "envelope", "/mail"),
            .route("Automations", "Manage scheduled agent runs.", "alarm.waves.left.and.right", "/dashboard/automations"),
            .route("Notes", "Open shared notes.", "note.text", "/notes"),
            .route("Traffic", "Inspect live traffic and maps.", "point.3.connected.trianglepath.dotted", "/traffic"),
            .route("AI Metrics", "View AI model and usage metrics.", "sparkles", "/system/ai"),
            .route("Rate Limits", "Manage traffic policies and keys.", "gauge.with.needle", "/system/rates"),
            .route("Cron Jobs", "Check scheduled host jobs.", "calendar.badge.clock", "/system/cron"),
            .route("System", "Manage infrastructure and VMs.", "gearshape.2", "/system"),
            .route("VMs", "Manage remote machines.", "display.2", "/vms"),
            .route("Shares", "Manage shares and hosted files.", "folder.badge.gearshape", "/s"),
            .route("Links", "Create and inspect shortcuts.", "link", "/g"),
            .route("Load Tests", "Review public load-test runs.", "speedometer", "/dashboard/tests"),
            .route("Articles", "Draft and publish articles.", "text.alignleft", "/content/articles"),
            .route("Thoughts", "Work with ideas and drafts.", "brain.head.profile", "/content/thoughts"),
            .route("Profile", "Manage your account and sessions.", "person.crop.circle", "/profile"),
        ]
    }

    var adminActions: [DesktopAction] {
        [
            .route("Logs", "Search logs and diagnostics.", "exclamationmark.triangle", "/logs"),
            .route("Database", "Inspect database and operations.", "externaldrive.connected.to.line.below", "/db"),
            .route("Backups", "View database backup status.", "externaldrive.badge.timemachine", "/db/backups"),
            .route("Restore", "Browse and restore backups.", "arrow.counterclockwise.circle", "/db/restore"),
            .route("Vulnerabilities", "Review scan findings.", "shield.lefthalf.filled.badge.checkmark", "/vulnerabilities"),
            .route("Management", "Admin management console.", "checkmark.shield", "/management"),
            .route("Users", "Manage user accounts.", "person.2", "/users"),
            .route("Roles", "Manage user roles.", "person.badge.key", "/role"),
            .route("Organizations", "Browse and switch organizations.", "building.2", "/organizations"),
        ]
    }
}
