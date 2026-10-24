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

struct SettingsValidationPanel: View {
    @Environment(\.desktopTheme) var theme
    let settings: HanasandDesktopSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: settings.hasValidEndpoints ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(settings.hasValidEndpoints ? theme.green : theme.danger)
                Text(settings.hasValidEndpoints ? "Endpoints look valid" : "Endpoint issues")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(theme.text)
                Spacer()
                Text("Session managed")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.green)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(theme.field)
                    .clipShape(Capsule())
            }

            if settings.endpointValidationMessages.isEmpty {
                Text("Site, API, internal API, AI, CDN, Desktop, and server URLs all include valid schemes and hosts.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(settings.endpointValidationMessages, id: \.self) { message in
                    Label(message, systemImage: "xmark.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(settings.hasValidEndpoints ? theme.accentSoft.opacity(0.55) : theme.danger.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
