import Foundation

struct PublicStatusSnapshotStore {
    static let maximumSnapshotBytes = 2 * 1024 * 1024
    private static let storageKey = "hanasand.public-status.verified-snapshot.v1"

    private let readData: () -> Data?
    private let writeData: (Data?) -> Void

    init(defaults: UserDefaults = .standard) {
        readData = { defaults.data(forKey: Self.storageKey) }
        writeData = { data in
            if let data { defaults.set(data, forKey: Self.storageKey) }
            else { defaults.removeObject(forKey: Self.storageKey) }
        }
    }

    init(readData: @escaping () -> Data?, writeData: @escaping (Data?) -> Void) {
        self.readData = readData
        self.writeData = writeData
    }

    func load() -> PublicStatusPayload? {
        guard let data = readData() else { return nil }
        guard data.count <= Self.maximumSnapshotBytes,
              let payload = try? JSONDecoder().decode(PublicStatusPayload.self, from: data),
              Self.isVerifiedSnapshot(payload) else {
            writeData(nil)
            return nil
        }
        return payload
    }

    func save(_ payload: PublicStatusPayload) {
        guard Self.isVerifiedSnapshot(payload),
              let data = try? JSONEncoder().encode(payload),
              data.count <= Self.maximumSnapshotBytes,
              let restored = try? JSONDecoder().decode(PublicStatusPayload.self, from: data),
              Self.isVerifiedSnapshot(restored) else { return }
        writeData(data)
    }

    private static func isVerifiedSnapshot(_ payload: PublicStatusPayload) -> Bool {
        guard let timestamp = payload.lastVerifiedAt,
              !payload.checks.isEmpty,
              payload.monitoring != "unavailable" else { return false }
        return ISO8601DateFormatter().date(from: timestamp) != nil
    }
}
