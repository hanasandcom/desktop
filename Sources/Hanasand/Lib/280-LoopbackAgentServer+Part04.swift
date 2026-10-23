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

extension LoopbackAgentServer {

    static func commandName(from request: String, body: Data) -> String {
        let explicit = commandFromBody(body)
        let rawRequest = (explicit ?? request).trimmingCharacters(in: .whitespacesAndNewlines)
        if rawRequest.hasPrefix("mac_control_type_text:") || rawRequest.lowercased().hasPrefix("mac_control_type_text:") {
            return rawRequest
        }
        if rawRequest.hasPrefix("codex_prompt:") || rawRequest.lowercased().hasPrefix("codex_prompt:") {
            return rawRequest
        }
        if rawRequest.hasPrefix("mac_control_pointer_click_at:") || rawRequest.lowercased().hasPrefix("mac_control_pointer_click_at:") {
            return rawRequest.lowercased()
        }
        let lowercasedRequest = rawRequest.lowercased()
        if lowercasedRequest == "ai_audit_desktop_ui" || lowercasedRequest == "audit_desktop" {
            return "ai_audit_desktop_ui"
        }
        if lowercasedRequest == "ai_train_app_parity" || lowercasedRequest == "app_parity" {
            return "ai_train_app_parity"
        }
        if lowercasedRequest == "ai_reload" || lowercasedRequest == "reload_ai" {
            return "ai_reload"
        }
        if lowercasedRequest == "open_section_command" || lowercasedRequest == "command" || lowercasedRequest == "terminal" {
            return "open_section_command"
        }
        if lowercasedRequest == "open_section_control" || lowercasedRequest == "control" || lowercasedRequest == "control_plane" {
            return "open_section_control"
        }
        if lowercasedRequest == "open_section_dashboard" || lowercasedRequest == "dashboard" {
            return "open_section_dashboard"
        }
        if lowercasedRequest == "open_section_workspace" || lowercasedRequest == "workspace" || lowercasedRequest == "browser" {
            return "open_section_workspace"
        }
        if lowercasedRequest == "browser_mini_fern" || lowercasedRequest == "mini_fern" || lowercasedRequest == "fern_minified" {
            return "browser_mini_fern"
        }
        if lowercasedRequest == "browser_popout_fern" || lowercasedRequest == "popout_fern" || lowercasedRequest == "fern_browser" {
            return "browser_popout_fern"
        }
        if lowercasedRequest == "open_section_ide" || lowercasedRequest == "ide" || lowercasedRequest == "editor" {
            return "open_section_ide"
        }
        if lowercasedRequest == "open_section_mac" || lowercasedRequest == "mac" || lowercasedRequest == "this_mac" {
            return "open_section_mac"
        }
        if lowercasedRequest == "open_section_mail" || lowercasedRequest == "mail_section" {
            return "open_section_mail"
        }
        if lowercasedRequest == "open_section_documents" || lowercasedRequest == "documents" || lowercasedRequest == "docs" || lowercasedRequest == "pdf" {
            return "open_section_documents"
        }
        if lowercasedRequest == "open_section_images" || lowercasedRequest == "images" || lowercasedRequest == "photos" {
            return "open_section_images"
        }
        if lowercasedRequest == "open_section_albums" || lowercasedRequest == "albums" || lowercasedRequest == "gallery albums" {
            return "open_section_albums"
        }
        if lowercasedRequest == "open_section_ai" || lowercasedRequest == "ai" || lowercasedRequest == "hanasand_ai" {
            return "open_section_ai"
        }
        if lowercasedRequest == "open_section_server" || lowercasedRequest == "server" {
            return "open_section_server"
        }
        if lowercasedRequest == "open_section_updates" || lowercasedRequest == "updates" {
            return "open_section_updates"
        }
        if lowercasedRequest == "open_section_settings" || lowercasedRequest == "settings_section" {
            return "open_section_settings"
        }
        if lowercasedRequest == "dashboard_refresh" || lowercasedRequest == "refresh_dashboard" {
            return "dashboard_refresh"
        }
        if lowercasedRequest == "open_dashboard_tools" || lowercasedRequest == "tools" || lowercasedRequest == "explore" {
            return "open_dashboard_tools"
        }
        if lowercasedRequest == "open_dashboard_traffic_map" || lowercasedRequest == "traffic-map" || lowercasedRequest == "open_traffic_map" {
            return "open_dashboard_traffic_map"
        }
        if lowercasedRequest == "open_dashboard_image_library" || lowercasedRequest == "cdn-images" || lowercasedRequest == "image-library" {
            return "open_dashboard_image_library"
        }
        if lowercasedRequest == "open_dashboard_api_reference" || lowercasedRequest == "api_reference" || lowercasedRequest == "api-reference" {
            return "open_dashboard_api_reference"
        }
        if lowercasedRequest == "open_dashboard_openapi_json" || lowercasedRequest == "openapi_json" || lowercasedRequest == "openapi-json" || lowercasedRequest == "api_openapi" {
            return "open_dashboard_openapi_json"
        }
        if lowercasedRequest == "open_dashboard_sandbox_history" || lowercasedRequest == "sandbox_history" || lowercasedRequest == "sandbox-history" {
            return "open_dashboard_sandbox_history"
        }
        if lowercasedRequest == "open_dashboard_password_check" || lowercasedRequest == "pwned" || lowercasedRequest == "password-check" {
            return "open_dashboard_password_check"
        }
        if lowercasedRequest == "open_support_desk" || lowercasedRequest == "support-desk" || lowercasedRequest == "open_support" {
            return "open_support_desk"
        }
        if lowercasedRequest == "open_dashboard_thesis" || lowercasedRequest == "thesis" || lowercasedRequest == "thesis-workspace" {
            return "open_dashboard_thesis"
        }
        if lowercasedRequest == "open_dashboard_organization_api_keys" || lowercasedRequest == "organization_api_keys" || lowercasedRequest == "organization-api-keys" {
            return "open_dashboard_organization_api_keys"
        }
        if lowercasedRequest == "open_dashboard_integrations" || lowercasedRequest == "integrations" || lowercasedRequest == "webhooks" {
            return "open_dashboard_integrations"
        }
        if lowercasedRequest == "open_dashboard_service_accounts" || lowercasedRequest == "service_accounts" || lowercasedRequest == "service-accounts" {
            return "open_dashboard_service_accounts"
        }
        if lowercasedRequest == "open_dashboard_organizations" || lowercasedRequest == "organizations" {
            return "open_dashboard_organizations"
        }
        if lowercasedRequest == "open_dashboard_watchlists" || lowercasedRequest == "watchlists" {
            return "open_dashboard_watchlists"
        }
        if lowercasedRequest == "open_dashboard_delivery_history" || lowercasedRequest == "delivery_history" || lowercasedRequest == "delivery-history" {
            return "open_dashboard_delivery_history"
        }
        if lowercasedRequest == "open_dashboard_recent_traffic" || lowercasedRequest == "recent_traffic" || lowercasedRequest == "traffic-recent" {
            return "open_dashboard_recent_traffic"
        }
        if lowercasedRequest == "open_dashboard_organization_privacy" || lowercasedRequest == "organization_privacy" || lowercasedRequest == "organization-privacy" {
            return "open_dashboard_organization_privacy"
        }
        if lowercasedRequest == "open_dashboard_subscription" || lowercasedRequest == "subscription" || lowercasedRequest == "billing" {
            return "open_dashboard_subscription"
        }
        if lowercasedRequest == "open_dashboard_findings" || lowercasedRequest == "findings" {
            return "open_dashboard_findings"
        }
        if lowercasedRequest == "open_dashboard_match_rules" || lowercasedRequest == "match_rules" || lowercasedRequest == "rules/match" {
            return "open_dashboard_match_rules"
        }
        if lowercasedRequest == "open_dashboard_analysis_rules" || lowercasedRequest == "analysis_rules" || lowercasedRequest == "rules/analysis" {
            return "open_dashboard_analysis_rules"
        }
        if lowercasedRequest == "open_dashboard_detection_rules" || lowercasedRequest == "detection_rules" || lowercasedRequest == "rules/detection" {
            return "open_dashboard_detection_rules"
        }
        if lowercasedRequest == "open_dashboard_rule_tuning" || lowercasedRequest == "rule_tuning" || lowercasedRequest == "rules/tuning" {
            return "open_dashboard_rule_tuning"
        }
        if lowercasedRequest == "open_dashboard_hosts" || lowercasedRequest == "hosts" {
            return "open_dashboard_hosts"
        }
        if lowercasedRequest == "open_dashboard_host_updates" || lowercasedRequest == "host_updates" || lowercasedRequest == "host-updates" {
            return "open_dashboard_host_updates"
        }
        if lowercasedRequest == "open_dashboard_cases" || lowercasedRequest == "monitoring_cases" || lowercasedRequest == "cases" {
            return "open_dashboard_cases"
        }
        if lowercasedRequest == "open_dashboard_mail" || lowercasedRequest == "dashboard_mail" || lowercasedRequest == "mail" {
            return "open_dashboard_mail"
        }
        if lowercasedRequest == "open_dashboard_articles" || lowercasedRequest == "articles" {
            return "open_dashboard_articles"
        }
        if lowercasedRequest == "open_dashboard_thoughts" || lowercasedRequest == "thoughts" {
            return "open_dashboard_thoughts"
        }
        if lowercasedRequest == "open_dashboard_shares" || lowercasedRequest == "shares" {
            return "open_dashboard_shares"
        }
        if lowercasedRequest == "open_dashboard_links" || lowercasedRequest == "links" || lowercasedRequest == "g" {
            return "open_dashboard_links"
        }
        if lowercasedRequest == "open_dashboard_tests" || lowercasedRequest == "tests" || lowercasedRequest == "load_tests" {
            return "open_dashboard_tests"
        }
        if lowercasedRequest == "open_dashboard_profile" || lowercasedRequest == "profile" {
            return "open_dashboard_profile"
        }
        if lowercasedRequest == "open_dashboard_users" || lowercasedRequest == "users" {
            return "open_dashboard_users"
        }
        if lowercasedRequest == "open_dashboard_roles" || lowercasedRequest == "roles" {
            return "open_dashboard_roles"
        }
        if lowercasedRequest == "open_dashboard_logs" || lowercasedRequest == "dashboard_logs" {
            return "open_dashboard_logs"
        }
        if lowercasedRequest == "open_dashboard_realtime_logs" || lowercasedRequest == "realtime_logs" || lowercasedRequest == "logs_realtime" {
            return "open_dashboard_realtime_logs"
        }
        if lowercasedRequest == "open_dashboard_log_search" || lowercasedRequest == "logs_search" || lowercasedRequest == "logs-search" {
            return "open_dashboard_log_search"
        }
        if lowercasedRequest == "open_dashboard_health_checks" || lowercasedRequest == "health_checks" || lowercasedRequest == "automation_health" {
            return "open_dashboard_health_checks"
        }
        if lowercasedRequest == "open_dashboard_personal_cron" || lowercasedRequest == "personal_cron" || lowercasedRequest == "automation_cron" {
            return "open_dashboard_personal_cron"
        }
        if lowercasedRequest == "open_dashboard_organization_settings" || lowercasedRequest == "organization_settings" {
            return "open_dashboard_organization_settings"
        }
        if lowercasedRequest == "open_dashboard_organization_team" || lowercasedRequest == "organization_team" || lowercasedRequest == "organization-team" {
            return "open_dashboard_organization_team"
        }
        if lowercasedRequest == "open_dashboard_organization_events" || lowercasedRequest == "organization_events" {
            return "open_dashboard_organization_events"
        }
        if lowercasedRequest == "open_dashboard_organization_activity" || lowercasedRequest == "organization_activity" {
            return "open_dashboard_organization_activity"
        }
        if lowercasedRequest == "open_dashboard_system" || lowercasedRequest == "system" || lowercasedRequest == "containers" {
            return "open_dashboard_system"
        }
        if lowercasedRequest == "open_dashboard_vms" || lowercasedRequest == "vms" || lowercasedRequest == "machines" {
            return "open_dashboard_vms"
        }
        if lowercasedRequest == "open_dashboard_ai_models" || lowercasedRequest == "ai_models" || lowercasedRequest == "models" {
            return "open_dashboard_ai_models"
        }
        if lowercasedRequest == "open_dashboard_notes" || lowercasedRequest == "notes" {
            return "open_dashboard_notes"
        }
        if lowercasedRequest == "open_dashboard_db" || lowercasedRequest == "db" || lowercasedRequest == "databases" {
            return "open_dashboard_db"
        }
        if lowercasedRequest == "open_dashboard_backups" || lowercasedRequest == "backups" {
            return "open_dashboard_backups"
        }
        if lowercasedRequest == "open_dashboard_restore" || lowercasedRequest == "restore" {
            return "open_dashboard_restore"
        }
        if lowercasedRequest == "open_dashboard_vulnerabilities" || lowercasedRequest == "vulnerabilities" || lowercasedRequest == "vulns" {
            return "open_dashboard_vulnerabilities"
        }
        if lowercasedRequest == "open_dashboard_rate_limits" || lowercasedRequest == "rate_limits" || lowercasedRequest == "rate-limits" || lowercasedRequest == "limits" {
            return "open_dashboard_rate_limits"
        }
        if lowercasedRequest == "open_dashboard_traffic" || lowercasedRequest == "traffic" {
            return "open_dashboard_traffic"
        }
        if lowercasedRequest == "server_logs" || lowercasedRequest == "logs" {
            return "server_logs"
        }
        if lowercasedRequest == "settings_summary" || lowercasedRequest == "settings" {
            return "settings_summary"
        }
        if lowercasedRequest == "remote_desktop_status" || lowercasedRequest == "rdp_status" || lowercasedRequest == "vnc_status" || lowercasedRequest == "screen_status" {
            return "remote_desktop_status"
        }
        if lowercasedRequest == "mac_control_authorize" || lowercasedRequest == "authorize_mac" || lowercasedRequest == "permissions" {
            return "mac_control_authorize"
        }
        if lowercasedRequest.hasPrefix("mac_control_pointer_click_at:") {
            return lowercasedRequest
        }
        if lowercasedRequest == "update" {
            return "update"
        }
        if lowercasedRequest == "status" {
            return "status"
        }
        return "blocked"
    }
}
