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

extension IDEWorkspace {

    var previewPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            NativeGroupPanel(title: "Native route preview", subtitle: model.selectedFile?.path ?? "Select a Hanasand route") {
                Text("Hanasand pages open in their native Desktop workspace.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let file = model.selectedFile {
                    ActionButton(title: "Open native view", icon: "arrow.right") {
                        openNativeIDEPreview(file)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .background(theme.background)
    }
}
