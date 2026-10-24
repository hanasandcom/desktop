import AVKit
import SwiftUI

struct NativeVideoPreview: View {
    let id: String
    let data: Data
    let fileExtension: String

    @State private var player: AVPlayer?
    @State private var temporaryURL: URL?
    @State private var error = ""

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .accessibilityLabel("Video preview")
            } else if !error.isEmpty {
                NativeEmptyState(title: "Video preview unavailable", message: error)
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Preparing video preview…") }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .task(id: "\(id)|\(data.count)") { prepare() }
        .onDisappear {
            player?.pause()
            player = nil
            if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
            temporaryURL = nil
        }
    }

    @MainActor private func prepare() {
        player?.pause()
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
        player = nil
        error = ""
        let ext = fileExtension.range(of: "^[A-Za-z0-9]{1,8}$", options: .regularExpression) == nil ? "media" : fileExtension
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hanasand-preview-\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: url, options: .atomic)
            temporaryURL = url
            player = AVPlayer(url: url)
        } catch {
            self.error = "Could not prepare this video for playback. You can save a local copy instead."
        }
    }
}
