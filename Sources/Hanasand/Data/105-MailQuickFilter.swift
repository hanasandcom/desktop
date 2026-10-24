import Foundation

enum MailQuickFilter: String, CaseIterable, Identifiable {
    case all
    case unread
    case starred
    case attachments

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .unread: "Unread"
        case .starred: "Starred"
        case .attachments: "Attachments"
        }
    }

    var symbol: String {
        switch self {
        case .all: "tray.full"
        case .unread: "envelope.badge"
        case .starred: "star"
        case .attachments: "paperclip"
        }
    }

    func matches(isRead: Bool?, isFlagged: Bool?, hasAttachment: Bool) -> Bool {
        switch self {
        case .all: true
        case .unread: isRead != true
        case .starred: isFlagged == true
        case .attachments: hasAttachment
        }
    }
}
