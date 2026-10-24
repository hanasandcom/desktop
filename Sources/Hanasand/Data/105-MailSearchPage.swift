import Foundation

struct MailSearchPage: Decodable {
    let messages: [MailOverviewEnvelope.Message]
    let nextCursor: String?
}

struct MailOverviewPage: Decodable {
    let messages: [MailOverviewEnvelope.Message]
    let nextCursor: String?
}

enum MailSearchRequest {
    static let maximumQueryLength = 200

    static func makeURL(
        baseURL: String,
        mailboxUser: String,
        mailboxID: String,
        query: String,
        after: String? = nil
    ) throws -> URL {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty, normalizedQuery.count <= maximumQueryLength else {
            throw MailSearchError.invalidQuery
        }
        guard !mailboxID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MailSearchError.missingMailbox
        }
        if let after, after.isEmpty || after.count > 1024 {
            throw MailSearchError.invalidCursor
        }

        var components = URLComponents(
            url: baseURL.normalizedBaseURL.appendingAPIPath("mail/search"),
            resolvingAgainstBaseURL: false
        )
        var items = [
            URLQueryItem(name: "mailboxUser", value: mailboxUser),
            URLQueryItem(name: "mailboxId", value: mailboxID),
            URLQueryItem(name: "query", value: normalizedQuery),
        ]
        if let after {
            items.append(URLQueryItem(name: "after", value: after))
        }
        components?.queryItems = items
        guard let url = components?.url else { throw MailSearchError.invalidURL }
        return url
    }
}

enum MailSearchError: LocalizedError {
    case invalidQuery
    case missingMailbox
    case invalidCursor
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .invalidQuery:
            return "Enter a search term of 1 to 200 characters."
        case .missingMailbox:
            return "Select a mailbox before searching."
        case .invalidCursor:
            return "The next page could not be loaded. Search again to continue."
        case .invalidURL:
            return "Unable to create the mailbox search request."
        }
    }
}
