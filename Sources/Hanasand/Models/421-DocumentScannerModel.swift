import AppKit
import Foundation

struct DocumentScanPage: Identifiable, Hashable {
    let id: UUID
    var image: NSImage
    var capturedAt: Date

    init(id: UUID = UUID(), image: NSImage, capturedAt: Date = .now) {
        self.id = id
        self.image = image
        self.capturedAt = capturedAt
    }
}

struct DocumentScanSession {
    private(set) var pages: [DocumentScanPage] = []

    var pageCount: Int { pages.count }
    var isEmpty: Bool { pages.isEmpty }

    mutating func append(_ page: DocumentScanPage) {
        pages.append(page)
    }

    mutating func remove(_ id: DocumentScanPage.ID) {
        pages.removeAll { $0.id == id }
    }

    mutating func move(_ id: DocumentScanPage.ID, by offset: Int) {
        guard let source = pages.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard pages.indices.contains(destination) else { return }
        let page = pages.remove(at: source)
        pages.insert(page, at: destination)
    }

    mutating func clear() {
        pages.removeAll()
    }
}
