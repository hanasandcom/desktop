import AppKit
import ApplicationServices
import Combine
import CryptoKit
import Darwin
import Foundation
import Network
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct ProfileSshKey: Decodable, Identifiable {
    let id: Int
    let name: String
    let fingerprint: String
    let keyType: String
    let addedAt: String?
    let lastUsedAt: String?
    let lastUsedServer: String?
    let lastUsedIp: String?
    let lastUsedUserAgent: String?
}

struct ProfileSshKeyList: Decodable {
    let keys: [ProfileSshKey]
}

struct ProfileSshKeyEnvelope: Decodable {
    let key: ProfileSshKey
}

struct ProfileSshKeyPayload: Encodable {
    let name: String
    let publicKey: String

    init(name: String, publicKey: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 100, !trimmedKey.isEmpty else {
            throw ProfileSshKeyPayloadError.invalidInput
        }
        self.name = trimmedName
        self.publicKey = trimmedKey
    }
}

enum ProfileSshKeyPayloadError: LocalizedError {
    case invalidInput

    var errorDescription: String? {
        "Enter a key name (up to 100 characters) and a public key."
    }
}
