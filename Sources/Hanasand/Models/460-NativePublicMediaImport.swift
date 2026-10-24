import Foundation

struct NativePublicMediaImport: Equatable {
    let data: Data
    let fileName: String
    let mediaType: String

    func validate() throws {
        guard !data.isEmpty else { throw NativePublicMediaImportError.emptyMedia }
        guard data.count <= NativePublicMediaImportLimits.maxBytes else { throw NativePublicMediaImportError.tooLarge }
        guard NativePublicMediaImportLimits.mediaTypes.contains(mediaType.lowercased()) else {
            throw NativePublicMediaImportError.unsupportedMediaType
        }
        guard !fileName.isEmpty, fileName.utf8.count <= NativePublicMediaImportLimits.maxFileNameBytes else {
            throw NativePublicMediaImportError.invalidResponse
        }
    }
}

enum NativePublicMediaImportLimits {
    static let maxBytes = 20 * 1024 * 1024
    static let maxURLBytes = 2_048
    static let maxFileNameBytes = 255
    static let responseErrorBytes = 16 * 1024
    static let mediaTypes: Set<String> = [
        "image/jpeg", "image/png", "image/gif", "image/webp", "image/avif",
        "video/mp4", "video/webm", "video/ogg",
    ]
}

enum NativePublicMediaImportError: LocalizedError, Equatable {
    case invalidBaseURL
    case signInRequired
    case invalidCredentials
    case invalidURL
    case urlTooLong
    case invalidResponse
    case emptyMedia
    case unsupportedMediaType
    case tooLarge
    case redirectBlocked
    case requestTimedOut
    case serviceUnavailable
    case uploadUnauthorized
    case uploadRateLimited
    case storageFull
    case pathConflict
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: "Public media import requires a valid first-party HTTPS website URL."
        case .signInRequired, .uploadUnauthorized: "Sign in to upload files."
        case .invalidCredentials: "The current account credentials cannot be used for this upload."
        case .invalidURL: "Use a public HTTP or HTTPS image or video URL."
        case .urlTooLong: "The media URL is too long."
        case .invalidResponse: "The media service returned an invalid response."
        case .emptyMedia: "The remote media file is empty."
        case .unsupportedMediaType: "Choose a supported image or video file."
        case .tooLarge: "Files must be 20 MB or smaller."
        case .redirectBlocked: "The media service redirected the request. Try the URL again."
        case .requestTimedOut: "The remote media request timed out. Try again."
        case .serviceUnavailable: "The sign-in service is unavailable. Try again later."
        case .uploadRateLimited: "Upload limit reached. Try again later."
        case .storageFull: "Uploads are paused because storage is full."
        case .pathConflict: "That public path is already taken. Choose another."
        case .requestFailed(let status): "Upload failed (HTTP \(status)). Try again later."
        }
    }

    static func uploadRecovery(status: Int) -> NativePublicMediaImportError {
        switch status {
        case 401: .uploadUnauthorized
        case 409: .pathConflict
        case 413: .tooLarge
        case 429: .uploadRateLimited
        case 507: .storageFull
        default: .requestFailed(status)
        }
    }
}
