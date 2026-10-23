import Foundation

struct ThesisUndoHistory {
    private(set) var undoCount = 0
    private(set) var redoCount = 0

    private var past: [ThesisDocument] = []
    private var future: [ThesisDocument] = []
    private var lastGroup: String?
    private var lastEdit = 0.0

    mutating func clear() {
        past.removeAll()
        future.removeAll()
        lastGroup = nil
        undoCount = 0
        redoCount = 0
    }

    mutating func remember(_ document: ThesisDocument, group: String? = nil, now: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        if group == nil || group != lastGroup || now - lastEdit > 0.75 || !future.isEmpty {
            past.append(document)
            if past.count > 50 { past.removeFirst(past.count - 50) }
        }
        future.removeAll()
        lastGroup = group
        lastEdit = now
        publishCounts()
    }

    mutating func travel(current: ThesisDocument, redo: Bool) -> ThesisDocument? {
        let source = redo ? future : past
        guard let previous = source.last else { return nil }
        if redo {
            future.removeLast()
            past.append(current)
        } else {
            past.removeLast()
            future.append(current)
        }
        lastGroup = nil
        publishCounts()
        return ThesisDocument(title: previous.title, body: previous.body, revision: current.revision)
    }

    private mutating func publishCounts() {
        undoCount = past.count
        redoCount = future.count
    }
}
