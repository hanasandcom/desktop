import Foundation

struct GalleryPhotoUpload: Sendable {
    let name: String
    let type: String
    let data: Data
}

struct GalleryPhotoBatchResult<Item> {
    let completedCount: Int
    let pending: [Item]
    let stopped: Bool
    let error: String?
}

enum GalleryPhotoUploadQueue {
    @MainActor
    static func run<Item>(
        _ items: [Item],
        shouldStop: () -> Bool,
        upload: (Item) async throws -> Void
    ) async -> GalleryPhotoBatchResult<Item> {
        var completed = 0
        for index in items.indices {
            if shouldStop() {
                return GalleryPhotoBatchResult(completedCount: completed, pending: Array(items[index...]), stopped: true, error: nil)
            }
            do {
                try await upload(items[index])
                completed += 1
            } catch {
                return GalleryPhotoBatchResult(completedCount: completed, pending: Array(items[index...]), stopped: false, error: error.localizedDescription)
            }
        }
        return GalleryPhotoBatchResult(completedCount: completed, pending: [], stopped: false, error: nil)
    }
}
