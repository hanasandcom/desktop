import Foundation

enum ShortcutLinkValidation {
    static func identifier(_ value: String) -> String? {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("/g/") { candidate.removeFirst(3) }
        else if candidate.hasPrefix("g/") { candidate.removeFirst(2) }
        guard candidate.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else {
            return nil
        }
        return candidate
    }

    static func destination(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace), !trimmed.contains("\0") else {
            return nil
        }

        let hasScheme = trimmed.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil
        let candidate = hasScheme ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "mailto", "tel"].contains(scheme),
              components.user == nil, components.password == nil,
              let url = components.url else { return nil }

        if scheme == "http" || scheme == "https" {
            guard let host = components.host, host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else {
                return nil
            }
        } else if components.path.isEmpty {
            return nil
        }

        return url.absoluteString
    }
}
