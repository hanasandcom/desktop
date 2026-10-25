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

struct DesktopImageReviewItem: Identifiable, Hashable {
    let id = UUID()
    var url: URL
    var image: NSImage

    var title: String { url.lastPathComponent }
    var sizeLabel: String {
        "\(Int(image.size.width))x\(Int(image.size.height))"
    }
}

struct ImageReviewTrashOutcome: Equatable {
    let movedIDs: Set<UUID>
    let failedTitles: [String]

    static func moveToTrash(
        _ items: [DesktopImageReviewItem],
        using move: (URL) throws -> Void
    ) -> Self {
        var movedIDs = Set<UUID>()
        var failedTitles: [String] = []
        for item in items {
            do {
                try move(item.url)
                movedIDs.insert(item.id)
            } catch {
                failedTitles.append(item.title)
            }
        }
        return Self(movedIDs: movedIDs, failedTitles: failedTitles)
    }
}
