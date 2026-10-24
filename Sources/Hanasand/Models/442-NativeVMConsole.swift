import Foundation

func nativeVMConsoleWebSocketURL(apiBaseURL: String, vmName: String) -> URL? {
    let name = vmName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 200, !name.contains("/"), !name.contains("\\"),
          var components = URLComponents(string: apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
          let scheme = components.scheme?.lowercased(),
          let host = components.host?.lowercased(),
          components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
          scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else { return nil }

    let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let safeName = name.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? ""
    guard !safeName.isEmpty else { return nil }
    components.scheme = scheme == "https" ? "wss" : "ws"
    components.path = "/" + [basePath, "ws", "vm", safeName, "console"].filter { !$0.isEmpty }.joined(separator: "/")
    return components.url
}

func nativeVMConsoleMayOpen(hasAuth: Bool, isImpersonating: Bool, userID: String, token: String) -> Bool {
    hasAuth && !isImpersonating && !userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}
