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

enum NativeRouteFallbackDetails {
    private static func normalizedRoute(_ path: String?) -> String? {
        let route = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return route.isEmpty ? nil : route
    }

    static func routeName(_ path: String?) -> String {
        normalizedRoute(path) ?? "(no route selected)"
    }

    static func message(for path: String?) -> String {
        guard let route = normalizedRoute(path) else {
            return "Desktop does not have a native screen for this route."
        }
        return "Desktop does not have a native screen for \(route)."
    }
}

struct NativeRouteFallbackPanel: View {
    @EnvironmentObject var model: DesktopAgentModel

    var body: some View {
        NativeGroupPanel(
            title: "Unsupported native route",
            subtitle: NativeRouteFallbackDetails.routeName(model.selectedDashboardPath)
        ) {
            Text(NativeRouteFallbackDetails.message(for: model.selectedDashboardPath))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            ActionButton(title: "Go to Dashboard", icon: "square.grid.2x2") {
                model.openNativeDashboard(path: "/dashboard", label: "Dashboard")
            }
        }
    }
}
