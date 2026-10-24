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
    private(set) var revision = 0

    var pageCount: Int { pages.count }
    var isEmpty: Bool { pages.isEmpty }

    mutating func append(_ page: DocumentScanPage) {
        pages.append(page)
        revision += 1
    }

    mutating func remove(_ id: DocumentScanPage.ID) {
        let count = pages.count
        pages.removeAll { $0.id == id }
        if pages.count != count { revision += 1 }
    }

    mutating func move(_ id: DocumentScanPage.ID, by offset: Int) {
        guard let source = pages.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard pages.indices.contains(destination) else { return }
        let page = pages.remove(at: source)
        pages.insert(page, at: destination)
        revision += 1
    }

    mutating func clear() {
        guard !pages.isEmpty else { return }
        pages.removeAll()
        revision += 1
    }
}
