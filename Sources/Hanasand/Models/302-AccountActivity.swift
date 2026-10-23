import Foundation

struct AccountActivityDay: Decodable, Equatable, Identifiable {
    let day: String
    let logins: Int

    var id: String { day }
}

struct AccountActivityStats: Decodable, Equatable {
    // Ignore API workspace counts until the internal-admin VM bypass and unowned article rows are owner-scoped server-side.
    let loginDays: [AccountActivityDay]

    private enum CodingKeys: String, CodingKey { case loginDays }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let days = try container.decode([AccountActivityDay].self, forKey: .loginDays)
        guard days.count <= 4_000,
              Set(days.map(\.day)).count == days.count,
              days.allSatisfy({ Self.isValidDay($0.day) && $0.logins > 0 && $0.logins <= 1_000_000 }) else {
            throw DecodingError.dataCorruptedError(forKey: .loginDays, in: container, debugDescription: "Invalid or unbounded account activity.")
        }
        self.loginDays = days.sorted { $0.day < $1.day }
    }

    private static func isValidDay(_ value: String) -> Bool {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let date = ISO8601DateFormatter().date(from: value + "T00:00:00Z") else { return false }
        return ISO8601DateFormatter().string(from: date).hasPrefix(value)
    }
}
