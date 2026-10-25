import CryptoKit
import Foundation
import XCTest
@testable import Hanasand

final class DesktopDeviceProofTests: XCTestCase {
    func testEnrichCreatesVerifiableProofWithNormalizedRequestContext() throws {
        let signer = try EphemeralCryptoKitSigner()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let token = "desktop-session-token"
        var request = URLRequest(url: URL(string: "https://api.hanasand.com/api/activity/?page=2#ignored")!)
        request.httpMethod = "post"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let enriched = try DesktopDeviceProof.enrich(
            request, sessionToken: token, signer: signer, date: date,
            jti: "f42c1742-8f64-4a7c-9d99-7f4c5d3c8221"
        )

        XCTAssertEqual(enriched.value(forHTTPHeaderField: "x-device-proof-url"), "https://api.hanasand.com/api/activity")
        XCTAssertEqual(enriched.value(forHTTPHeaderField: "x-device-proof-method"), "POST")
        let publicJWKData = try XCTUnwrap(enriched.value(forHTTPHeaderField: "x-device-public-jwk").flatMap { $0.data(using: .utf8) })
        let publicJWK = try XCTUnwrap(JSONSerialization.jsonObject(with: publicJWKData) as? [String: String])
        XCTAssertEqual(publicJWK["kty"], "EC")
        XCTAssertEqual(publicJWK["crv"], "P-256")
        XCTAssertNil(publicJWK["d"])

        let proof = try XCTUnwrap(enriched.value(forHTTPHeaderField: "dpop"))
        let parts = proof.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        let header = try XCTUnwrap(try json(parts[0]) as? [String: Any])
        XCTAssertEqual(header["typ"] as? String, "dpop+jwt")
        XCTAssertEqual(header["alg"] as? String, "ES256")
        XCTAssertEqual(header["jwk"] as? [String: String], publicJWK)

        let claims = try XCTUnwrap(try json(parts[1]) as? [String: Any])
        XCTAssertEqual(claims["htm"] as? String, "POST")
        XCTAssertEqual(claims["htu"] as? String, "https://api.hanasand.com/api/activity")
        XCTAssertEqual(claims["iat"] as? Int, 1_800_000_000)
        XCTAssertEqual(claims["jti"] as? String, "f42c1742-8f64-4a7c-9d99-7f4c5d3c8221")
        XCTAssertEqual(claims["ath"] as? String, base64URL(Data(SHA256.hash(data: Data(token.utf8)))))

        let signatureData = try XCTUnwrap(decodeBase64URL(parts[2]))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
        XCTAssertTrue(signer.privateKey.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    func testCustomAllowlistedHostCanBeSigned() throws {
        let signer = try EphemeralCryptoKitSigner()
        var request = URLRequest(url: URL(string: "https://staging.example.test/api/session")!)
        request.setValue("Bearer user-session", forHTTPHeaderField: "Authorization")
        let enriched = try DesktopDeviceProof.enrich(
            request, sessionToken: "user-session", customAllowedHosts: ["staging.example.test"],
            signer: signer, date: Date(timeIntervalSince1970: 1_800_000_000),
            jti: "f42c1742-8f64-4a7c-9d99-7f4c5d3c8221"
        )
        XCTAssertNotNil(enriched.value(forHTTPHeaderField: "dpop"))
    }

    func testSharedAuthenticatedRequestPolicySignsConfiguredAPIHost() throws {
        let signer = try EphemeralCryptoKitSigner()
        let token = "desktop-session"
        var request = URLRequest(url: URL(string: "https://staging.example.test/api/hosts")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let enriched = try DesktopAuthenticatedRequestProof.enrichIfAuthenticated(
            request, authenticated: true, sessionToken: token,
            configuredAPIBaseURL: "https://staging.example.test/api", signer: signer
        )

        XCTAssertNotNil(enriched.value(forHTTPHeaderField: "x-device-public-jwk"))
        XCTAssertNotNil(enriched.value(forHTTPHeaderField: "dpop"))
        XCTAssertEqual(enriched.value(forHTTPHeaderField: "x-device-proof-url"), "https://staging.example.test/api/hosts")
        XCTAssertEqual(enriched.value(forHTTPHeaderField: "x-device-proof-method"), "GET")
        let parts = try XCTUnwrap(enriched.value(forHTTPHeaderField: "dpop")).split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        let claims = try XCTUnwrap(try json(parts[1]) as? [String: Any])
        XCTAssertEqual(claims["htm"] as? String, "GET")
        XCTAssertEqual(claims["htu"] as? String, "https://staging.example.test/api/hosts")
        XCTAssertEqual(claims["ath"] as? String, base64URL(Data(SHA256.hash(data: Data(token.utf8)))))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: XCTUnwrap(decodeBase64URL(parts[2])))
        XCTAssertTrue(signer.privateKey.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    func testSharedAuthenticatedRequestPolicyPreservesPublicAndRejectsUntrustedOrServiceCredentials() throws {
        let signer = try EphemeralCryptoKitSigner()
        let publicRequest = URLRequest(url: URL(string: "https://public.example.test/status")!)
        let unchanged = try DesktopAuthenticatedRequestProof.enrichIfAuthenticated(
            publicRequest, authenticated: false, sessionToken: "",
            configuredAPIBaseURL: "https://api.example.test/api", signer: signer
        )
        XCTAssertEqual(unchanged.allHTTPHeaderFields, publicRequest.allHTTPHeaderFields)
        XCTAssertNil(unchanged.value(forHTTPHeaderField: "dpop"))

        let token = "desktop-session"
        var foreignRequest = URLRequest(url: URL(string: "https://attacker.example.test/api/hosts")!)
        foreignRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        XCTAssertThrowsError(try DesktopAuthenticatedRequestProof.enrichIfAuthenticated(
            foreignRequest, authenticated: true, sessionToken: token,
            configuredAPIBaseURL: "https://api.example.test/api", signer: signer
        ))

        var foreignPortRequest = URLRequest(url: URL(string: "https://api.example.test:8443/api/hosts")!)
        foreignPortRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        XCTAssertThrowsError(try DesktopAuthenticatedRequestProof.enrichIfAuthenticated(
            foreignPortRequest, authenticated: true, sessionToken: token,
            configuredAPIBaseURL: "https://api.example.test/api", signer: signer
        ))

        let serviceKey = "hsk_0123456789ab_\(String(repeating: "a", count: 48))"
        var serviceRequest = URLRequest(url: URL(string: "https://api.example.test/api/hosts")!)
        serviceRequest.setValue("Bearer \(serviceKey)", forHTTPHeaderField: "Authorization")
        XCTAssertThrowsError(try DesktopAuthenticatedRequestProof.enrichIfAuthenticated(
            serviceRequest, authenticated: true, sessionToken: serviceKey,
            configuredAPIBaseURL: "https://api.example.test/api", signer: signer
        ))
    }

    func testUntrustedTargetsAndServiceAccountCredentialsAreRejected() throws {
        let signer = try EphemeralCryptoKitSigner()
        let jti = "f42c1742-8f64-4a7c-9d99-7f4c5d3c8221"
        for target in ["http://api.hanasand.com/api/me", "https://attacker.test/api/me", "https://user@api.hanasand.com/api/me"] {
            var request = URLRequest(url: URL(string: target)!)
            request.setValue("Bearer user-session", forHTTPHeaderField: "Authorization")
            XCTAssertThrowsError(try DesktopDeviceProof.enrich(
                request, sessionToken: "user-session", signer: signer,
                date: Date(timeIntervalSince1970: 1_800_000_000), jti: jti
            ))
        }

        let serviceKey = "hsk_0123456789ab_\(String(repeating: "a", count: 48))"
        var request = URLRequest(url: URL(string: "https://api.hanasand.com/api/me")!)
        request.setValue("Bearer \(serviceKey)", forHTTPHeaderField: "Authorization")
        XCTAssertThrowsError(try DesktopDeviceProof.enrich(
            request, sessionToken: serviceKey, signer: signer,
            date: Date(timeIntervalSince1970: 1_800_000_000), jti: jti
        ))
    }

    private func json(_ value: String) throws -> Any {
        let data = try XCTUnwrap(decodeBase64URL(value))
        return try JSONSerialization.jsonObject(with: data)
    }

    private func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

private struct EphemeralCryptoKitSigner: DesktopDeviceProofSigning {
    let privateKey: P256.Signing.PrivateKey

    init() throws {
        privateKey = P256.Signing.PrivateKey()
    }

    var publicJWK: [String: String] {
        get throws {
            let point = privateKey.publicKey.x963Representation
            guard point.count == 65, point.first == 0x04 else { throw DesktopDeviceProofError.keyUnavailable }
            return [
                "kty": "EC",
                "crv": "P-256",
                "x": Self.base64URL(point.subdata(in: 1..<33)),
                "y": Self.base64URL(point.subdata(in: 33..<65)),
            ]
        }
    }

    func signES256(_ message: Data) throws -> Data {
        try privateKey.signature(for: message).rawRepresentation
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
