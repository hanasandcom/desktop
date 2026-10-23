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

struct DashboardProfileIdentityUpdatePayload: Encodable {
    let name: String
    let username: String

    init(name: String, username: String) throws {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !cleanName.isEmpty, cleanName.count <= 100 else {
            throw DashboardProfileIdentityValidationError.invalidName
        }
        guard cleanUsername.range(of: #"^[a-z0-9][a-z0-9._-]{2,39}$"#, options: .regularExpression) != nil else {
            throw DashboardProfileIdentityValidationError.invalidUsername
        }

        self.name = cleanName
        self.username = cleanUsername
    }
}

enum DashboardProfileIdentityValidationError: LocalizedError {
    case invalidName
    case invalidUsername

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Enter a display name of 1–100 characters."
        case .invalidUsername:
            return "Use 3–40 letters, numbers, dots, underscores or hyphens; start with a letter or number."
        }
    }
}

struct DashboardProfileIdentityUpdateResponse: Decodable {
    let id: String
    let name: String
    let username: String
    let avatar: String?
}

struct DashboardAccountIdentityResponse: Decodable {
    let id: String
    let name: String?
    let username: String?
    let avatar: String?
}

enum DashboardProfileIdentityUpdateError: LocalizedError {
    case accountMismatch

    var errorDescription: String? {
        "The server returned profile details for a different account. Refresh before trying again."
    }
}
