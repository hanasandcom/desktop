import CryptoKit
import Foundation
import Security

enum DesktopDeviceProofError: Error, Equatable {
    case invalidRequest
    case untrustedTarget
    case invalidSessionCredential
    case keyUnavailable
    case signingFailed
}

protocol DesktopDeviceProofSigning {
    var publicJWK: [String: String] { get throws }
    func signES256(_ message: Data) throws -> Data
}

struct KeychainDesktopDeviceProofSigner: DesktopDeviceProofSigning {
    private static let applicationTag = Data("com.hanasand.desktop.device-proof.p256".utf8)
    private let privateKey: SecKey

    init(privateKey: SecKey) {
        self.privateKey = privateKey
    }

    static func persistent() throws -> KeychainDesktopDeviceProofSigner {
        let key: SecKey
        do {
            key = try loadOrCreate()
        } catch {
            throw DesktopDeviceProofError.keyUnavailable
        }
        return KeychainDesktopDeviceProofSigner(privateKey: key)
    }

    var publicJWK: [String: String] {
        get throws {
            guard let publicKey = SecKeyCopyPublicKey(privateKey),
                  let representation = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
                  representation.count == 65, representation.first == 0x04 else {
                throw DesktopDeviceProofError.keyUnavailable
            }
            return [
                "kty": "EC",
                "crv": "P-256",
                "x": Self.base64URL(representation.subdata(in: 1..<33)),
                "y": Self.base64URL(representation.subdata(in: 33..<65)),
            ]
        }
    }

    func signES256(_ message: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let der = SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256,
                                              message as CFData, &error) as Data?,
              let jose = Self.joseSignature(fromDER: der) else {
            throw DesktopDeviceProofError.signingFailed
        }
        return jose
    }

    private static func loadOrCreate() throws -> SecKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag as String: applicationTag,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let key = key(from: result) { return key }
        guard status == errSecItemNotFound else { throw DesktopDeviceProofError.keyUnavailable }

        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage],
            &accessError
        ) else { throw DesktopDeviceProofError.keyUnavailable }

        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: applicationTag,
            kSecAttrAccessControl as String: access,
        ]
        // Secure Enclave is preferred when this Mac supports P-256 key generation there.
        attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
        var generationError: Unmanaged<CFError>?
        if let key = SecKeyCreateRandomKey(attributes as CFDictionary, &generationError) {
            return key
        }

        // Macs without a usable Secure Enclave retain the same device-only Keychain policy.
        attributes.removeValue(forKey: kSecAttrTokenID as String)
        generationError = nil
        if let key = SecKeyCreateRandomKey(attributes as CFDictionary, &generationError) {
            return key
        }
        // A concurrent creator may have inserted the permanent key after our first lookup.
        result = nil
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let key = key(from: result) {
            return key
        }
        throw DesktopDeviceProofError.keyUnavailable
    }

    private static func key(from result: CFTypeRef?) -> SecKey? {
        guard let result, CFGetTypeID(result) == SecKeyGetTypeID() else { return nil }
        return unsafeBitCast(result, to: SecKey.self)
    }

    private static func joseSignature(fromDER data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0] == 0x30 else { return nil }
        var index = 1
        guard let sequenceLength = readDERLength(bytes, index: &index),
              sequenceLength == bytes.count - index,
              index < bytes.count, bytes[index] == 0x02 else { return nil }
        index += 1
        guard let rLength = readDERLength(bytes, index: &index), rLength > 0,
              index + rLength < bytes.count else { return nil }
        let r = Array(bytes[index..<(index + rLength)])
        index += rLength
        guard bytes[index] == 0x02 else { return nil }
        index += 1
        guard let sLength = readDERLength(bytes, index: &index), sLength > 0,
              index + sLength == bytes.count else { return nil }
        let s = Array(bytes[index..<(index + sLength)])
        guard let fixedR = fixedWidthInteger(r), let fixedS = lowS(fixedWidthInteger: s) else { return nil }
        return Data(fixedR + fixedS)
    }

    private static func lowS(fixedWidthInteger encoded: [UInt8]) -> [UInt8]? {
        guard let value = fixedWidthInteger(encoded), value.count == 32 else { return nil }
        let order: [UInt8] = [
            0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
            0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
            0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84,
            0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51,
        ]
        var halfOrder = order
        var carry: UInt8 = 0
        for index in halfOrder.indices {
            let nextCarry = halfOrder[index] & 1
            halfOrder[index] = (halfOrder[index] >> 1) | (carry << 7)
            carry = nextCarry
        }
        guard lexicographicallyGreater(value, than: order) == false else { return nil }
        guard lexicographicallyGreater(value, than: halfOrder) else { return subtract(value, from: order) }
        return value
    }

    private static func lexicographicallyGreater(_ left: [UInt8], than right: [UInt8]) -> Bool {
        for (lhs, rhs) in zip(left, right) where lhs != rhs { return lhs > rhs }
        return false
    }

    private static func subtract(_ value: [UInt8], from minuend: [UInt8]) -> [UInt8] {
        var result = Array(repeating: UInt8(0), count: minuend.count)
        var borrow = 0
        for index in minuend.indices.reversed() {
            var difference = Int(minuend[index]) - Int(value[index]) - borrow
            borrow = difference < 0 ? 1 : 0
            if borrow == 1 { difference += 256 }
            result[index] = UInt8(difference)
        }
        return result
    }

    private static func readDERLength(_ bytes: [UInt8], index: inout Int) -> Int? {
        guard index < bytes.count else { return nil }
        let first = Int(bytes[index]); index += 1
        if first < 0x80 { return first }
        let count = first & 0x7f
        guard count > 0, count <= 2, index + count <= bytes.count,
              bytes[index] != 0 else { return nil }
        var length = 0
        for byte in bytes[index..<(index + count)] { length = (length << 8) | Int(byte) }
        index += count
        guard length >= 0x80 else { return nil }
        return length
    }

    private static func fixedWidthInteger(_ integer: [UInt8]) -> [UInt8]? {
        var magnitude = integer
        while magnitude.count > 1, magnitude.first == 0 { magnitude.removeFirst() }
        guard magnitude.count <= 32 else { return nil }
        return Array(repeating: 0, count: 32 - magnitude.count) + magnitude
    }

    fileprivate static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum DesktopDeviceProof {
    static func attachingPublicJWK(
        _ request: URLRequest,
        configuredOrigins: [URL] = [],
        signer: (any DesktopDeviceProofSigning)? = nil
    ) throws -> URLRequest {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), !host.isEmpty,
              isTrustedPublicJWKOrigin(url, host: host, configuredOrigins: configuredOrigins) else {
            throw DesktopDeviceProofError.untrustedTarget
        }
        let selectedSigner: any DesktopDeviceProofSigning
        if let signer {
            selectedSigner = signer
        } else {
            selectedSigner = try KeychainDesktopDeviceProofSigner.persistent()
        }
        let jwk = try selectedSigner.publicJWK
        guard jwk["kty"] == "EC", jwk["crv"] == "P-256",
              let x = jwk["x"], x.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              let y = jwk["y"], y.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              jwk["d"] == nil else { throw DesktopDeviceProofError.keyUnavailable }
        let data = try JSONSerialization.data(withJSONObject: jwk, options: [.sortedKeys])
        guard let header = String(data: data, encoding: .utf8) else { throw DesktopDeviceProofError.keyUnavailable }
        var enriched = request
        enriched.setValue(header, forHTTPHeaderField: "x-device-public-jwk")
        return enriched
    }

    static func enrich(
        _ request: URLRequest,
        sessionToken: String,
        customAllowedHosts: Set<String> = []
    ) throws -> URLRequest {
        try enrich(request, sessionToken: sessionToken, customAllowedHosts: customAllowedHosts,
                   signer: KeychainDesktopDeviceProofSigner.persistent(), date: Date(), jti: UUID().uuidString)
    }

    static func enrich(
        _ request: URLRequest,
        sessionToken: String,
        customAllowedHosts: Set<String> = [],
        signer: any DesktopDeviceProofSigning,
        date: Date = Date(),
        jti: String = UUID().uuidString
    ) throws -> URLRequest {
        guard let url = request.url, isAllowedHTTPS(url, customAllowedHosts: customAllowedHosts) else {
            throw DesktopDeviceProofError.untrustedTarget
        }
        let token = sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token == sessionToken, !token.isEmpty, !isServiceCredential(token),
              request.value(forHTTPHeaderField: "Authorization") == "Bearer \(sessionToken)" else {
            throw DesktopDeviceProofError.invalidSessionCredential
        }
        let method = (request.httpMethod ?? "GET").uppercased()
        let timestamp = date.timeIntervalSince1970
        guard !method.isEmpty, method.utf8.count <= 16,
              timestamp.isFinite, timestamp >= 0, timestamp < Double(Int.max),
              let target = normalizedTarget(url), jti.range(of: "^[A-Za-z0-9_-]{16,128}$", options: .regularExpression) != nil else {
            throw DesktopDeviceProofError.invalidRequest
        }
        let jwk = try signer.publicJWK
        guard jwk["kty"] == "EC", jwk["crv"] == "P-256",
              let x = jwk["x"], x.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              let y = jwk["y"], y.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              jwk["d"] == nil else { throw DesktopDeviceProofError.keyUnavailable }

        let header: [String: Any] = ["typ": "dpop+jwt", "alg": "ES256", "jwk": jwk]
        let claims: [String: Any] = [
            "htm": method,
            "htu": target,
            "iat": Int(timestamp),
            "jti": jti,
            "ath": KeychainDesktopDeviceProofSigner.base64URL(Data(SHA256.hash(data: Data(token.utf8)))),
        ]
        let headerPart = try jsonPart(header)
        let claimsPart = try jsonPart(claims)
        let signingInput = "\(headerPart).\(claimsPart)"
        let signature = try signer.signES256(Data(signingInput.utf8))
        guard signature.count == 64 else { throw DesktopDeviceProofError.signingFailed }

        var enriched = request
        let publicJWKData = try JSONSerialization.data(withJSONObject: jwk, options: [.sortedKeys])
        guard let publicJWKHeader = String(data: publicJWKData, encoding: .utf8) else {
            throw DesktopDeviceProofError.keyUnavailable
        }
        enriched.setValue(publicJWKHeader, forHTTPHeaderField: "x-device-public-jwk")
        enriched.setValue("\(signingInput).\(KeychainDesktopDeviceProofSigner.base64URL(signature))",
                          forHTTPHeaderField: "dpop")
        enriched.setValue(target, forHTTPHeaderField: "x-device-proof-url")
        enriched.setValue(method, forHTTPHeaderField: "x-device-proof-method")
        return enriched
    }

    static func normalizedTarget(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.host != nil else { return nil }
        components.host = components.host?.lowercased()
        if components.port == 443 { components.port = nil }
        components.query = nil
        components.fragment = nil
        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path
        guard let absolute = components.string else { return nil }
        return absolute.hasSuffix("/") ? String(absolute.dropLast()) : absolute
    }

    private static func isTrustedPublicJWKOrigin(_ url: URL, host: String, configuredOrigins: [URL]) -> Bool {
        let port = effectiveHTTPSPort(url)
        if (host == "hanasand.com" || host.hasSuffix(".hanasand.com")) && port == 443 {
            return true
        }
        return configuredOrigins.contains { origin in
            origin.scheme?.lowercased() == "https"
                && origin.user == nil && origin.password == nil
                && origin.host?.lowercased() == host
                && effectiveHTTPSPort(origin) == port
        }
    }

    private static func effectiveHTTPSPort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : nil)
    }

    private static func isAllowedHTTPS(_ url: URL, customAllowedHosts: Set<String>) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let rawHost = url.host?.lowercased(), !rawHost.isEmpty else { return false }
        if rawHost == "hanasand.com" || rawHost.hasSuffix(".hanasand.com") {
            return url.port == nil || url.port == 443
        }
        return customAllowedHosts.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == rawHost }
    }

    private static func isServiceCredential(_ token: String) -> Bool {
        token.range(of: "^hsk_[a-f0-9]{12}_[a-f0-9]{48}$", options: .regularExpression) != nil
            || token.hasPrefix("svc_")
    }

    private static func jsonPart(_ value: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return KeychainDesktopDeviceProofSigner.base64URL(data)
    }
}
