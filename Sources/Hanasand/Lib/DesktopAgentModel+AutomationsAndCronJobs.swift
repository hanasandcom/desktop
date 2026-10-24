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
    private func desktopAutomationClient() throws -> AutomationClient {
        var authenticatedSettings = settings
        authenticatedSettings.userID = userIDForRequests
        authenticatedSettings.authToken = authTokenForRequests
        return try AutomationClient(settings: authenticatedSettings)
    }

    func fetchDesktopAutomations(scope: String? = nil) async throws -> [DesktopAutomation] {
        try await desktopAutomationClient().list(scope: scope).automations
    }

    func fetchDesktopAutomationOverview(scope: String? = nil) async throws -> DesktopAutomationEnvelope {
        try await desktopAutomationClient().list(scope: scope)
    }

    func fetchDesktopAutomationDetail(_ id: String, page: Int = 1, from: Date? = nil, to: Date? = nil) async throws -> DesktopAutomationDetailEnvelope {
        try await desktopAutomationClient().detail(id: id, page: page, from: from, to: to)
    }

    func saveDesktopAutomation(_ payload: DesktopAutomationPayload, id: String? = nil) async throws -> DesktopAutomation {
        let envelope = try await desktopAutomationClient().save(payload, id: id)
        return envelope.automation
    }

    func setDesktopAutomationStatus(_ id: String, status: String) async throws {
        _ = try await desktopAutomationClient().setStatus(id, status: status)
    }

    func deleteDesktopAutomation(_ id: String) async throws {
        _ = try await desktopAutomationClient().delete(id)
    }

    func runDesktopAutomation(_ id: String) async throws -> String {
        let envelope = try await desktopAutomationClient().run(id)
        return envelope.message ?? "Run started."
    }

    func createDesktopAutomationSenderKey(_ id: String) async throws -> DesktopAutomationSenderKeyEnvelope {
        try await desktopAutomationClient().createSenderKey(id)
    }

    func fetchDesktopCronJobs() async throws -> DesktopCronJobsEnvelope {
        try await requestJSON(
            settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("system/cron"),
            authenticated: true
        )
    }

    func updateDesktopCronJob(_ id: String, payload: DesktopCronUpdatePayload) async throws -> DesktopCronJobsEnvelope {
        let safeID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let body = try JSONEncoder().encode(payload)
        let envelope: DesktopCronUpdateEnvelope = try await requestJSON(
            settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("system/cron/\(safeID)"),
            method: "PUT",
            body: body,
            authenticated: true
        )
        return DesktopCronJobsEnvelope(jobs: envelope.jobs, ready: true)
    }
}

struct DesktopAutomationMutationEnvelope: Decodable {
    let automation: DesktopAutomation
}

struct DesktopAutomationStatusPayload: Encodable {
    let status: String
}

struct DesktopAutomationRunNowEnvelope: Decodable {
    let message: String?
}

struct DesktopAutomationSenderKeyEnvelope: Decodable {
    let secret: String
    let endpoint: String
}

struct DesktopCronUpdateEnvelope: Decodable {
    let job: DesktopCronJob
    let jobs: [DesktopCronJob]
}
