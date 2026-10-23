import Foundation

enum NotesSearch {
    static func filter(_ notes: [DashboardNote], query: String) -> [DashboardNote] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return notes }

        return notes.filter { note in
            note.title.localizedCaseInsensitiveContains(needle)
                || note.content.localizedCaseInsensitiveContains(needle)
        }
    }
}
