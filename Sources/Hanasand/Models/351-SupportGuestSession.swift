import Foundation
import Security

struct SupportGuestSession: Codable, Equatable {
    static let lifetime: TimeInterval = 60 * 60 * 24 * 30

    let token: String
    let expiresAt: Date

    var isValid: Bool {
        token.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }

    static func loadOrRefresh(
        storedValue: String?,
        now: Date = Date(),
        makeToken: () throws -> String = randomToken
    ) throws -> (session: SupportGuestSession, encodedValue: String) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stored = storedValue.flatMap { try? decoder.decode(SupportGuestSession.self, from: Data($0.utf8)) }
        let session: SupportGuestSession
        if let stored, stored.isValid, stored.expiresAt > now {
            // The website renews its HttpOnly cookie when support is opened.
            session = SupportGuestSession(token: stored.token, expiresAt: now.addingTimeInterval(lifetime))
        } else {
            let token = try makeToken()
            guard token.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
                throw SupportGuestSessionError.invalidToken
            }
            session = SupportGuestSession(token: token, expiresAt: now.addingTimeInterval(lifetime))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)
        guard let value = String(data: data, encoding: .utf8) else { throw SupportGuestSessionError.invalidStorage }
        return (session, value)
    }

    static func loadFromKeychain(now: Date = Date()) throws -> SupportGuestSession {
        let stored = try DesktopCredentialStore.read(.supportGuestSession)
        let result = try loadOrRefresh(storedValue: stored, now: now)
        try DesktopCredentialStore.write(result.encodedValue, for: .supportGuestSession)
        return result.session
    }

    private static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw SupportGuestSessionError.randomGenerationFailed
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

enum SupportGuestSessionError: LocalizedError {
    case invalidToken, invalidStorage, randomGenerationFailed

    var errorDescription: String? {
        switch self {
        case .invalidToken, .invalidStorage: "A new guest support session could not be saved."
        case .randomGenerationFailed: "A secure guest support session could not be created."
        }
    }
}
