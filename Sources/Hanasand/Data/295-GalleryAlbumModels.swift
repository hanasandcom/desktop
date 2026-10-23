import Foundation

struct GalleryAlbum: Decodable, Identifiable, Hashable {
    let id: String
    var name: String
    let owner: String
    let isPublic: Bool
    let photoCount: Int?
    let memberRole: String?
}

struct GalleryAlbumItem: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    let type: String
    let owner: String?
    let addedBy: String?
}

struct GalleryAlbumMember: Decodable, Identifiable, Hashable {
    let userId: String
    let role: String
    var id: String { userId }
}

struct GalleryAlbumDetail: Decodable, Identifiable, Hashable {
    let id: String
    var name: String
    let owner: String
    let isPublic: Bool
    let role: String
    let items: [GalleryAlbumItem]
    let total: Int
    let limit: Int
    let offset: Int
    let members: [GalleryAlbumMember]?
}

struct GalleryLibraryItem: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    let type: String
}

struct GalleryAlbumMutationReceipt: Decodable {
    let added: Int?
    let requested: Int?
    let removed: String?
    let deleted: String?
    let userId: String?
    let role: String?
}

struct GalleryAlbumNamePayload: Encodable {
    let name: String
}

struct GalleryAlbumItemsPayload: Encodable {
    let fileIds: [String]
}

struct GalleryAlbumMemberPayload: Encodable {
    let userId: String
    let role: String
}

enum GalleryAlbumAccess {
    static func canManage(_ album: GalleryAlbumDetail, currentUserId: String) -> Bool {
        album.role == "owner" && album.owner == currentUserId
    }

    static func canAddItems(_ album: GalleryAlbumDetail) -> Bool {
        album.role == "owner" || album.role == "contributor"
    }

    static func canRemove(_ item: GalleryAlbumItem, album: GalleryAlbumDetail, currentUserId: String) -> Bool {
        album.role == "owner" || (album.role == "contributor" && item.addedBy == currentUserId)
    }
}
