import CryptoKit
import Foundation

struct DashboardNoteDraft: Codable, Equatable, Identifiable {
    let noteID: String
    var title: String
    var content: String
    var baseUpdatedAt: String?
    var savedAt: Date

    var id: String { noteID }
}

struct DashboardNoteDraftStore {
    static let newNoteID = "local:new"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func drafts(for userID: String) -> [DashboardNoteDraft] {
        guard let data = defaults.data(forKey: storageKey(for: userID)),
              let drafts = try? JSONDecoder().decode([DashboardNoteDraft].self, from: data) else {
            return []
        }
        return drafts.sorted { $0.savedAt > $1.savedAt }
    }

    func draft(noteID: String, for userID: String) -> DashboardNoteDraft? {
        drafts(for: userID).first { $0.noteID == noteID }
    }

    func save(_ draft: DashboardNoteDraft, for userID: String) {
        guard !userID.isEmpty else { return }
        let updated = [draft] + drafts(for: userID).filter { $0.noteID != draft.noteID }
        guard let data = try? JSONEncoder().encode(updated) else { return }
        defaults.set(data, forKey: storageKey(for: userID))
    }

    func remove(noteID: String, for userID: String) {
        guard !userID.isEmpty else { return }
        let remaining = drafts(for: userID).filter { $0.noteID != noteID }
        guard let data = try? JSONEncoder().encode(remaining) else { return }
        defaults.set(data, forKey: storageKey(for: userID))
    }

    private func storageKey(for userID: String) -> String {
        let digest = SHA256.hash(data: Data(userID.utf8))
        let accountKey = digest.map { String(format: "%02x", $0) }.joined()
        return "hanasand.desktop.notes.drafts.\(accountKey)"
    }
}
