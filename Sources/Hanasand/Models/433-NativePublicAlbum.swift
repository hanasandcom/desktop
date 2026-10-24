import Foundation

struct NativePublicAlbumItem: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let type: String
    let uploadedAt: String?
    let photoTakenAt: String?
    let sizeBytes: Int64?

    func validate() throws {
        guard !id.isEmpty, id.utf8.count <= 128,
              name.utf8.count <= 512, type.utf8.count <= 100,
              (uploadedAt?.utf8.count ?? 0) <= 100,
              (photoTakenAt?.utf8.count ?? 0) <= 100,
              (sizeBytes ?? 0) >= 0, (sizeBytes ?? 0) <= 10_000_000_000,
              type.hasPrefix("image/") || type.hasPrefix("video/") else {
            throw NativePublicAlbumError.invalidResponse
        }
    }
}

struct NativePublicAlbumMonth: Decodable, Identifiable, Equatable {
    let monthKey: String
    let photoCount: Int
    var id: String { monthKey }
}

struct NativePublicAlbumPage: Decodable, Equatable {
    let id: String
    let name: String
    let items: [NativePublicAlbumItem]
    let total: Int
    let limit: Int
    let offset: Int
    let timeline: [NativePublicAlbumMonth]
    let month: String

    var nextOffset: Int? { offset + items.count < total ? offset + items.count : nil }
}

enum NativePublicAlbumLimits {
    static let pageSize = 24
    static let maxRows = 100
    static let maxResponseBytes = 2 * 1024 * 1024
    static let maxSearchBytes = 120
    static let maxTimelineRows = 2_000
}

enum NativePublicAlbumError: LocalizedError, Equatable {
    case invalidBaseURL
    case invalidToken
    case invalidSearch
    case invalidMonth
    case invalidPage
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: "Shared albums require a valid HTTPS CDN address."
        case .invalidToken: "This shared album link is invalid or expired."
        case .invalidSearch: "Search is too long."
        case .invalidMonth: "Choose a valid month."
        case .invalidPage: "This shared album page is invalid."
        case .invalidResponse: "The shared album service returned an invalid response."
        case .requestFailed(404): "This shared album link is invalid or expired."
        case .requestFailed: "The shared album is unavailable. Try again later."
        }
    }
}
