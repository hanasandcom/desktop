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

    func updateSelectedThought() async {
        guard hasHanasandAuth else {
            nativeDashboardStatus = "Hanasand session is not ready. Log in again if this persists."
            return
        }

        let title = thoughtEditTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedThoughtID.isEmpty else {
            nativeDashboardStatus = "Select a thought first."
            return
        }
        guard !title.isEmpty else {
            nativeDashboardStatus = "Thought title cannot be empty."
            return
        }

        let body = (try? JSONEncoder().encode(["title": title])) ?? Data("{}".utf8)
        isLoadingNativeDashboard = true
        nativeDashboardStatus = "Saving thought"
        defer { isLoadingNativeDashboard = false }

        do {
            _ = try await requestPrettyText(
                settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("thought/\(selectedThoughtID)"),
                method: "PUT",
                body: body,
                authenticated: true
            )
            nativeDashboardStatus = "Saved thought"
            append(meta: "Thought saved", body: selectedThoughtID, kind: .change)
            await loadNativeDashboardData()
        } catch {
            nativeDashboardStatus = error.localizedDescription
            append(meta: "Thought save failed", body: error.localizedDescription, kind: .error)
        }
    }

    func deleteSelectedThought(_ thought: DashboardThought) async {
        guard hasHanasandAuth else {
            nativeDashboardStatus = "Hanasand session is not ready. Log in again if this persists."
            return
        }

        isLoadingNativeDashboard = true
        nativeDashboardStatus = "Deleting thought"
        defer { isLoadingNativeDashboard = false }

        do {
            _ = try await requestPrettyText(
                settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("thought/\(thought.id)"),
                method: "DELETE",
                authenticated: true
            )
            if selectedThoughtID == thought.id {
                selectedThoughtID = ""
                thoughtEditTitle = ""
            }
            nativeDashboardStatus = "Deleted thought"
            append(meta: "Thought deleted", body: thought.id, kind: .change)
            await loadNativeDashboardData()
        } catch {
            nativeDashboardStatus = error.localizedDescription
            append(meta: "Thought delete failed", body: error.localizedDescription, kind: .error)
        }
    }

}
