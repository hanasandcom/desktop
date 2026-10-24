import Foundation

enum NativeUploadPreviewKind: Equatable {
    case image
    case video
    case other

    private static let imageExtensions: Set<String> = [
        "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp"
    ]
    private static let videoExtensions: Set<String> = [
        "avi", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "webm", "wmv"
    ]

    init(fileExtension: String) {
        let normalized = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()

        // Use a deterministic preview allowlist. UTType(filenameExtension:) can
        // depend on Launch Services registration, which is unavailable in some
        // app and test-host contexts.
        if Self.imageExtensions.contains(normalized) {
            self = .image
        } else if Self.videoExtensions.contains(normalized) {
            self = .video
        } else {
            self = .other
        }
    }

    func canPreview(fileSize: Int) -> Bool {
        self != .other && fileSize > 0 && fileSize <= NativePublicMediaImportLimits.maxBytes
    }
}
