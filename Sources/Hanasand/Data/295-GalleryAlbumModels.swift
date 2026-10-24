import Foundation

struct GalleryAlbum: Decodable, Identifiable, Hashable {
    let id: String
    var name: String
    let owner: String
    let isPublic: Bool
    let publicToken: String?
    let photoCount: Int?
    let memberRole: String?
}

struct GalleryAlbumItem: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    let type: String
    let owner: String?
    let addedBy: String?
    let isFavorite: Bool?
    let uploadedAt: String?
    let sizeBytes: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, type, owner, addedBy, isFavorite, uploadedAt, sizeBytes
    }

    init(id: String, name: String?, type: String, owner: String?, addedBy: String?, isFavorite: Bool? = nil,
         uploadedAt: String? = nil, sizeBytes: Int? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.owner = owner
        self.addedBy = addedBy
        self.isFavorite = isFavorite
        self.uploadedAt = uploadedAt
        self.sizeBytes = sizeBytes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        type = try values.decode(String.self, forKey: .type)
        owner = try values.decodeIfPresent(String.self, forKey: .owner)
        addedBy = try values.decodeIfPresent(String.self, forKey: .addedBy)
        isFavorite = try values.decodeIfPresent(Bool.self, forKey: .isFavorite)
        uploadedAt = try values.decodeIfPresent(String.self, forKey: .uploadedAt)
        sizeBytes = (try? values.decodeIfPresent(Int.self, forKey: .sizeBytes))
            ?? (try? values.decodeIfPresent(String.self, forKey: .sizeBytes).flatMap(Int.init))
    }
}

struct GalleryAlbumMember: Decodable, Identifiable, Hashable {
    let userId: String
    let role: String
    var id: String { userId }
}

struct GalleryAlbumMonth: Decodable, Identifiable, Hashable {
    let monthKey: String
    let photoCount: Int
    var id: String { monthKey }
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
    let timeline: [GalleryAlbumMonth]
    let month: String

    init(id: String, name: String, owner: String, isPublic: Bool, role: String, items: [GalleryAlbumItem],
         total: Int, limit: Int, offset: Int, members: [GalleryAlbumMember]?,
         timeline: [GalleryAlbumMonth] = [], month: String = "") {
        self.id = id
        self.name = name
        self.owner = owner
        self.isPublic = isPublic
        self.role = role
        self.items = items
        self.total = total
        self.limit = limit
        self.offset = offset
        self.members = members
        self.timeline = timeline
        self.month = month
    }

    enum CodingKeys: String, CodingKey {
        case id, name, owner, isPublic, role, items, total, limit, offset, members, timeline, month
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        owner = try values.decode(String.self, forKey: .owner)
        isPublic = try values.decode(Bool.self, forKey: .isPublic)
        role = try values.decode(String.self, forKey: .role)
        items = try values.decode([GalleryAlbumItem].self, forKey: .items)
        total = try values.decode(Int.self, forKey: .total)
        limit = try values.decode(Int.self, forKey: .limit)
        offset = try values.decode(Int.self, forKey: .offset)
        members = try values.decodeIfPresent([GalleryAlbumMember].self, forKey: .members)
        timeline = try values.decodeIfPresent([GalleryAlbumMonth].self, forKey: .timeline) ?? []
        month = try values.decodeIfPresent(String.self, forKey: .month) ?? ""
    }
}

struct GalleryAlbumSharingResult: Equatable {
    let isPublic: Bool
    let shareURL: URL?
}

struct GalleryLibraryItem: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    let type: String
    let isFavorite: Bool?
    let uploadedAt: String?
    let sizeBytes: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, type, isFavorite, uploadedAt, sizeBytes
    }

    init(id: String, name: String?, type: String, isFavorite: Bool?, uploadedAt: String? = nil, sizeBytes: Int? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.isFavorite = isFavorite
        self.uploadedAt = uploadedAt
        self.sizeBytes = sizeBytes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        type = try values.decode(String.self, forKey: .type)
        isFavorite = try values.decodeIfPresent(Bool.self, forKey: .isFavorite)
        uploadedAt = try values.decodeIfPresent(String.self, forKey: .uploadedAt)
        sizeBytes = (try? values.decodeIfPresent(Int.self, forKey: .sizeBytes))
            ?? (try? values.decodeIfPresent(String.self, forKey: .sizeBytes).flatMap(Int.init))
    }
}

struct GalleryLibraryPage: Equatable {
    let items: [GalleryLibraryItem]
    let nextOffset: Int
    let hasMore: Bool
    var timeline: [GalleryAlbumMonth] = []
}

struct GalleryFavoriteReceipt: Decodable {
    let id: String
    let favorite: Bool
}

struct GalleryFavoritePayload: Encodable {
    let favorite: Bool
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

struct GalleryAlbumPublicPayload: Encodable {
    let isPublic: Bool
}

struct GalleryAlbumItemsPayload: Encodable {
    let fileIds: [String]
}

struct GalleryAlbumMemberPayload: Encodable {
    let userId: String
    let role: String
}

enum GalleryAlbumListPresentation {
    static func shouldShowEmptyState(albumCount: Int, isLoading: Bool, error: String) -> Bool {
        albumCount == 0 && !isLoading && error.isEmpty
    }
}

enum GalleryAlbumAddFeedback {
    static func message(added: Int, requested: Int) -> String {
        guard added < requested else { return "Added all \(added) selected photos." }
        let skipped = max(0, requested - added)
        return "Added \(added) of \(requested) selected photos. \(skipped) skipped because they were already in the album or unavailable to this account."
    }
}

enum GalleryAlbumAccess {
    static func canManage(_ album: GalleryAlbumDetail, currentUserId: String) -> Bool {
        album.role == "owner" && album.owner == currentUserId
    }

    static func canAddItems(_ album: GalleryAlbumDetail) -> Bool {
        album.role == "owner" || album.role == "contributor"
    }

    static func canLeave(_ album: GalleryAlbumDetail, currentUserId: String) -> Bool {
        album.owner != currentUserId && ["viewer", "contributor"].contains(album.role)
    }

    static func canRemove(_ item: GalleryAlbumItem, album: GalleryAlbumDetail, currentUserId: String) -> Bool {
        album.role == "owner" || (album.role == "contributor" && item.addedBy == currentUserId)
    }
}
