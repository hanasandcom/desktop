import CryptoKit
import Foundation
import Security

struct NativeAuthenticatorEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var label: String
    var issuer: String?
    var account: String?
    var secret: String
    var digits: Int
    var period: Int
    var algorithm: NativeAuthenticatorAlgorithm

    init(id: UUID = UUID(), label: String, issuer: String? = nil, account: String? = nil,
         secret: String, digits: Int = 6, period: Int = 30,
         algorithm: NativeAuthenticatorAlgorithm = .sha1) {
        self.id = id
        self.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        self.issuer = issuer
        self.account = account
        self.secret = secret.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        self.digits = digits
        self.period = period
        self.algorithm = algorithm
    }
}

enum NativeAuthenticatorAlgorithm: String, Codable, CaseIterable {
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"
}

enum NativeAuthenticatorError: LocalizedError, Equatable {
    case invalidURI
    case invalidSecret
    case invalidConfiguration
    case keychain(OSStatus)
    case imageHasNoQRCode

    var errorDescription: String? {
        switch self {
        case .invalidURI: "Enter a valid otpauth TOTP URI."
        case .invalidSecret: "Enter a valid Base32 secret."
        case .invalidConfiguration: "This TOTP entry has unsupported digits or period settings."
        case .keychain(let status): "Authenticator data could not be saved in Keychain (error \(status))."
        case .imageHasNoQRCode: "The selected image does not contain a TOTP QR code."
        }
    }
}

protocol NativeAuthenticatorVault {
    func read() throws -> [NativeAuthenticatorEntry]
    func save(_ entries: [NativeAuthenticatorEntry]) throws
}

struct KeychainNativeAuthenticatorVault: NativeAuthenticatorVault {
    private static let service = "com.hanasand.desktop.authenticator"
    private static let account = "totp-entries-v1"

    func read() throws -> [NativeAuthenticatorEntry] {
        var query = Self.baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else {
            throw NativeAuthenticatorError.keychain(status)
        }
        return try JSONDecoder().decode([NativeAuthenticatorEntry].self, from: data)
    }

    func save(_ entries: [NativeAuthenticatorEntry]) throws {
        let data = try JSONEncoder().encode(entries)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(Self.baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw NativeAuthenticatorError.keychain(status) }
        var insert = Self.baseQuery
        attributes.forEach { insert[$0.key] = $0.value }
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw NativeAuthenticatorError.keychain(addStatus) }
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

enum NativeAuthenticator {
    static func parse(_ uri: String) throws -> NativeAuthenticatorEntry {
        guard let components = URLComponents(string: uri.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "otpauth",
              components.host?.lowercased() == "totp",
              let rawPath = components.percentEncodedPath.removingPercentEncoding,
              !rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty else {
            throw NativeAuthenticatorError.invalidURI
        }
        let pathLabel = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = pathLabel.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let labelIssuer = parts.count == 2 ? parts[0] : nil
        let account = parts.count == 2 ? parts[1] : parts[0]
        let query = Dictionary(components.queryItems?.map { ($0.name.lowercased(), $0.value ?? "") } ?? [], uniquingKeysWith: { _, last in last })
        guard let secret = query["secret"], !secret.isEmpty else { throw NativeAuthenticatorError.invalidURI }
        let decodedIssuer = query["issuer"]?.removingPercentEncoding ?? query["issuer"]
        let issuer = decodedIssuer?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? labelIssuer?.nilIfEmpty
        let digits = Int(query["digits"] ?? "6") ?? 0
        let period = Int(query["period"] ?? "30") ?? 0
        let algorithm = NativeAuthenticatorAlgorithm(rawValue: (query["algorithm"] ?? "SHA1").uppercased())
        guard let algorithm else { throw NativeAuthenticatorError.invalidConfiguration }
        let display = [issuer, account.nilIfEmpty].compactMap { $0 }.joined(separator: " · ")
        let entry = NativeAuthenticatorEntry(label: display.nilIfEmpty ?? "Authenticator code", issuer: issuer,
                                             account: account.nilIfEmpty, secret: secret, digits: digits,
                                             period: period, algorithm: algorithm)
        try validate(entry)
        return entry
    }

    static func validate(_ entry: NativeAuthenticatorEntry) throws {
        guard (entry.digits == 6 || entry.digits == 8), (entry.period >= 1 && entry.period <= 300),
              !entry.label.isEmpty else { throw NativeAuthenticatorError.invalidConfiguration }
        guard decodeBase32(entry.secret) != nil else { throw NativeAuthenticatorError.invalidSecret }
    }

    static func code(for entry: NativeAuthenticatorEntry, at date: Date = Date()) throws -> String {
        try validate(entry)
        let secret = try decodeBase32(entry.secret).unwrap(or: NativeAuthenticatorError.invalidSecret)
        let counter = UInt64(max(0, floor(date.timeIntervalSince1970 / Double(entry.period))))
        var movingFactor = counter.bigEndian
        let message = withUnsafeBytes(of: &movingFactor) { Data($0) }
        let digest: Data
        switch entry.algorithm {
        case .sha1: digest = Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: secret)))
        case .sha256: digest = Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: secret)))
        case .sha512: digest = Data(HMAC<SHA512>.authenticationCode(for: message, using: SymmetricKey(data: secret)))
        }
        let offset = Int(digest[digest.count - 1] & 0x0f)
        let binary = (UInt32(digest[offset] & 0x7f) << 24)
            | (UInt32(digest[offset + 1]) << 16)
            | (UInt32(digest[offset + 2]) << 8)
            | UInt32(digest[offset + 3])
        let modulus = (0..<entry.digits).reduce(UInt64(1)) { value, _ in value * 10 }
        return String(format: "%0*llu", entry.digits, UInt64(binary) % modulus)
    }

    static func remainingSeconds(for entry: NativeAuthenticatorEntry, at date: Date = Date()) -> Int {
        let period = max(1, entry.period)
        return period - Int(max(0, date.timeIntervalSince1970).rounded(.down).truncatingRemainder(dividingBy: Double(period)))
    }

    static func upsert(_ entry: NativeAuthenticatorEntry, into entries: [NativeAuthenticatorEntry]) -> [NativeAuthenticatorEntry] {
        var next = entries.filter { $0.secret != entry.secret }
        if let existing = entries.first(where: { $0.secret == entry.secret }) {
            var replacement = entry
            replacement.id = existing.id
            next.insert(replacement, at: 0)
        } else {
            next.insert(entry, at: 0)
        }
        return next
    }

    private static func decodeBase32(_ value: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        let normalized = value.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        let secret = String(normalized.prefix { $0 != "=" })
        let padding = normalized.dropFirst(secret.count)
        guard padding.allSatisfy({ $0 == "=" }) else { return nil }
        let expectedPadding: Int
        switch secret.count % 8 {
        case 0: expectedPadding = 0
        case 2: expectedPadding = 6
        case 4: expectedPadding = 4
        case 5: expectedPadding = 3
        case 7: expectedPadding = 1
        default: return nil
        }
        guard padding.isEmpty || padding.count == expectedPadding else { return nil }
        var buffer: UInt64 = 0
        var bits = 0
        var bytes = [UInt8]()
        for character in secret {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | UInt64(index)
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((buffer >> bits) & 0xff))
            }
        }
        guard bytes.count >= 10, buffer & ((UInt64(1) << bits) - 1) == 0 else { return nil }
        return Data(bytes)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension Optional {
    func unwrap(or error: Error) throws -> Wrapped {
        guard let value = self else { throw error }
        return value
    }
}
