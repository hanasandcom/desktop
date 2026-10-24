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

        let markdown = thoughtEditTitle
        guard !selectedThoughtID.isEmpty else {
            nativeDashboardStatus = "Select a thought first."
            return
        }
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            nativeDashboardStatus = "Thought Markdown cannot be empty."
            return
        }
        guard !thoughtMutationNeedsRefresh else {
            nativeDashboardStatus = "Refresh Thoughts and review the list before retrying this save."
            return
        }
        isLoadingNativeDashboard = true
        nativeDashboardStatus = "Saving thought"
        defer { isLoadingNativeDashboard = false }

        do {
            let client = try thoughtsClient()
            _ = try await client.update(id: selectedThoughtID, markdown: markdown)
            nativeDashboardStatus = "Saved thought"
            append(meta: "Thought saved", body: selectedThoughtID, kind: .change)
            await loadNativeDashboardData()
        } catch {
            thoughtMutationSafety.recordFailure(error, action: "update", id: selectedThoughtID, markdown: markdown)
            nativeDashboardStatus = error.localizedDescription
            append(meta: "Thought save failed", body: error.localizedDescription, kind: .error)
        }
    }

    func deleteSelectedThought(_ thought: DashboardThought) async {
        guard hasHanasandAuth else {
            nativeDashboardStatus = "Hanasand session is not ready. Log in again if this persists."
            return
        }
        guard !thoughtMutationNeedsRefresh else {
            nativeDashboardStatus = "Refresh Thoughts and review the earlier operation before deleting."
            return
        }

        isLoadingNativeDashboard = true
        nativeDashboardStatus = "Deleting thought"
        defer { isLoadingNativeDashboard = false }

        do {
            try await thoughtsClient().delete(id: thought.id)
            if selectedThoughtID == thought.id {
                selectedThoughtID = ""
                thoughtEditTitle = ""
            }
            nativeDashboardStatus = "Deleted thought"
            append(meta: "Thought deleted", body: thought.id, kind: .change)
            await loadNativeDashboardData()
        } catch {
            thoughtMutationSafety.recordFailure(error, action: "delete", id: thought.id)
            nativeDashboardStatus = error.localizedDescription
            append(meta: "Thought delete failed", body: error.localizedDescription, kind: .error)
        }
    }

}
