import Foundation

enum NativeSharePreview {
    static func target(alias: String?, tree: [NativeShareWorkspaceTreeItem], rootContent: String?, activeContent: String?) -> URL? {
        let content = activeContent.flatMap { $0.isEmpty ? nil : $0 } ?? rootContent ?? ""
        guard hasHTTPSurface(tree: tree, content: content),
              let alias, alias.utf8.count <= 240,
              alias.range(of: #"^[a-z0-9](?:[a-z0-9_-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9_-]{0,61}[a-z0-9])?)*$"#, options: .regularExpression) != nil,
              let url = URL(string: "https://\(alias).hanasand.com/"),
              url.scheme == "https", url.host == "\(alias).hanasand.com", url.port == nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func allowsNavigation(isMainFrame: Bool, hasTargetFrame: Bool, to url: URL?, previewHost: String) -> Bool {
        guard hasTargetFrame else { return false }
        guard isMainFrame else { return true }
        guard let url else { return false }
        return allowsMainFrameNavigation(to: url, previewHost: previewHost)
    }

    static func allowsMainFrameNavigation(to url: URL, previewHost: String) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == previewHost.lowercased()
            && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }

    static func allowsResponse(isForMainFrame: Bool, to url: URL?, previewHost: String) -> Bool {
        guard isForMainFrame else { return true }
        guard let url else { return false }
        return allowsMainFrameNavigation(to: url, previewHost: previewHost)
    }

    private static func hasHTTPSurface(tree: [NativeShareWorkspaceTreeItem], content: String) -> Bool {
        var paths: [String] = []
        func collect(_ items: [NativeShareWorkspaceTreeItem], prefix: String = "", depth: Int = 0) {
            guard depth <= NativeShareWorkspaceLimits.treeDepth else { return }
            for item in items {
                guard paths.count < NativeShareWorkspaceLimits.treeItems else { return }
                let path = prefix.isEmpty ? item.name.lowercased() : "\(prefix)/\(item.name.lowercased())"
                paths.append(path)
                if item.type == "folder" { collect(item.children ?? [], prefix: path, depth: depth + 1) }
            }
        }
        collect(tree)
        let names = paths.map { $0.split(separator: "/").last.map(String.init) ?? $0 }
        let httpFiles: Set<String> = [
            "dockerfile", "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml",
            "package.json", "next.config.js", "next.config.mjs", "next.config.ts", "vite.config.js",
            "vite.config.ts", "astro.config.mjs", "astro.config.ts", "nuxt.config.js", "nuxt.config.ts",
            "svelte.config.js", "index.html",
        ]
        let serverFiles: Set<String> = [
            "server.js", "server.ts", "server.mjs", "app.js", "app.ts", "main.go", "main.py",
            "app.py", "wsgi.py", "asgi.py",
        ]
        let lowerContent = content.lowercased()
        return names.contains(where: { $0 == "dockerfile" || $0.hasPrefix("dockerfile.") })
            || names.contains(where: httpFiles.contains)
            || names.contains(where: serverFiles.contains)
            || paths.contains(where: { $0.contains("/api/") || $0.contains("/routes/") })
            || lowerContent.range(of: #"\b(?:createserver|listenandserve|fastapi|flask|uvicorn|gunicorn|serve|http\.server)\b|(?:express|fastify)\s*\("#, options: .regularExpression) != nil
            || lowerContent.range(of: #""(?:next|vite|astro|nuxt|svelte-kit|express|fastify|@nestjs/core|hono)"\s*:"#, options: .regularExpression) != nil
            || lowerContent.range(of: #"\b(?:expose\s+|port\s*[=:]\s*|listen\s*\(\s*|listenandserve\s*\(\s*["']?:)(\d{2,5})\b"#, options: .regularExpression) != nil
    }
}
