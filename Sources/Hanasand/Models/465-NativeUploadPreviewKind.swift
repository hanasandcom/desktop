import UniformTypeIdentifiers

enum NativeUploadPreviewKind: Equatable {
    case image
    case video
    case other

    init(fileExtension: String) {
        let normalized = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let type = UTType(filenameExtension: normalized) else {
            self = .other
            return
        }

        if type.conforms(to: .image) {
            self = .image
        } else if type.conforms(to: .movie) {
            self = .video
        } else {
            self = .other
        }
    }

    func canPreview(fileSize: Int) -> Bool {
        self != .other && fileSize > 0 && fileSize <= NativePublicMediaImportLimits.maxBytes
    }
}
