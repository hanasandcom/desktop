import Foundation
import Combine

private final class DesktopAIWorkspaceRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum DesktopAIWorkspaceSession {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        return URLSession(configuration: config, delegate: DesktopAIWorkspaceRedirectBlocker(), delegateQueue: nil)
    }()
}

struct DesktopAIWorkspaceClient {
    typealias Sender = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    typealias SocketResponder = @Sendable (URLRequest, String) async throws -> String
    typealias ToolSocketResponder = @Sendable (URL, String, Int) async throws -> String
    typealias ToolDelay = @Sendable (Int) async -> Void

    enum ClientError: LocalizedError {
        case signInRequired, impersonationUnsupported, invalidBaseURL, invalidIdentifier, invalidResponse, httpStatus(Int), socketUnavailable(String)
        var errorDescription: String? {
            switch self {
            case .signInRequired: return "Sign in to load your Hanasand AI conversations."
            case .impersonationUnsupported: return "AI conversations are disabled during account impersonation."
            case .invalidBaseURL: return "The configured API endpoint is invalid."
            case .invalidIdentifier: return "The conversation identifier is invalid."
            case .invalidResponse: return "The AI workspace returned an invalid response."
            case .httpStatus(let status): return status == 401 || status == 403 ? "Your session cannot access the AI workspace. Sign in again or check your account permissions." : "The AI workspace returned HTTP \(status)."
            case .socketUnavailable(let message): return message
            }
        }
    }

    private let baseURL: URL
    private let promptURL: URL
    private let userID: String
    private let token: String
    private let send: Sender
    private let socketResponder: SocketResponder?
    private let toolSocketResponder: ToolSocketResponder?
    private let toolDelay: ToolDelay

    init(settings: HanasandDesktopSettings, send: Sender? = nil, socketResponder: SocketResponder? = nil,
         toolSocketResponder: ToolSocketResponder? = nil, toolDelay: ToolDelay? = nil) throws {
        guard settings.impersonationToken.isEmpty, settings.impersonatingUserID.isEmpty else { throw ClientError.impersonationUnsupported }
        let user = settings.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential = settings.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = settings.apiBaseURL.normalizedBaseURL
        let aiEndpoint = settings.resolvedAIEndpoint
        guard !user.isEmpty, !credential.isEmpty else { throw ClientError.signInRequired }
        guard base.scheme?.lowercased() == "https", base.host != nil, base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil,
              aiEndpoint.scheme?.lowercased() == "https", aiEndpoint.host == base.host,
              aiEndpoint.user == nil, aiEndpoint.password == nil,
              user.range(of: #"^[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil,
              credential.range(of: #"^[A-Za-z0-9._~-]{1,4096}$"#, options: .regularExpression) != nil else {
            throw ClientError.invalidBaseURL
        }
        baseURL = base; promptURL = aiEndpoint; userID = user; token = credential
        self.send = send ?? { request in try await DesktopAIWorkspaceSession.shared.data(for: request) }
        self.socketResponder = socketResponder
        self.toolSocketResponder = toolSocketResponder
        self.toolDelay = toolDelay ?? { milliseconds in
            try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
        }
    }

    func loadWorkspace() async throws -> DesktopAIWorkspace {
        try await request("ai/workspace", method: "GET", body: nil)
    }

    func loadShares() async throws -> [DesktopAIShare] {
        do {
            return try await request("share/user/\(segment(userID))", method: "GET", body: nil)
        } catch ClientError.httpStatus(404) {
            return []
        }
    }

    func loadDeploymentTargets() async throws -> [DesktopAIVMTarget] {
        let payload: TargetEnvelope = try await request("vms/agent/targets", method: "GET", body: nil)
        return Array(payload.targets.prefix(50))
    }

    func loadDeployments(conversationID: String) async throws -> DesktopAIDeploymentSnapshot {
        try await requestWithQuery("ai/deployments", query: [URLQueryItem(name: "conversationId", value: conversationID)])
    }

    func loadReleases(conversationID: String) async throws -> DesktopAIReleaseSnapshot {
        try await requestWithQuery("ai/releases", query: [URLQueryItem(name: "conversationId", value: conversationID)])
    }

    func startDeployment(conversationID: String, vmName: String, port: Int, healthPath: String,
                         accessPolicy: String, environment: String) async throws -> DesktopAIStartDeploymentResult {
        let body: [String: DesktopAIJSONValue] = [
            "conversationId": .string(conversationID),
            "vmName": .string(vmName),
            "port": .string(String(port)),
            "healthPath": .string(healthPath),
            "accessPolicy": .string(accessPolicy),
            "environment": .string(environment),
        ]
        let (data, statusCode) = try await performRequest(
            url: baseURL.appendingAPIPath("ai/deployments"), method: "POST", body: body
        )
        let response = try decode(DesktopAIStartDeploymentResponse.self, from: data)
        if !(200..<300).contains(statusCode), response.deployment == nil, response.error == nil {
            throw ClientError.httpStatus(statusCode)
        }
        return DesktopAIStartDeploymentResult(response: response, statusCode: statusCode)
    }

    func markRollbackTarget(releaseID: String) async throws -> DesktopAIRollbackResponse {
        try await request("ai/releases/\(segment(releaseID))/rollback", method: "POST", body: nil)
    }

    func loadReleaseSupportBundle(releaseID: String) async throws -> DesktopAIReleaseSupportBundleResponse {
        try await request("ai/releases/\(segment(releaseID))/support-bundle", method: "GET", body: nil)
    }

    func executeTool(_ call: DesktopAIWorkspaceToolCall, conversation: DesktopAIConversation,
                     shares: [DesktopAIShare], confirmed: Bool) async throws -> DesktopAIWorkspaceToolResult {
        if call.requiresConfirmation && !confirmed {
            return DesktopAIWorkspaceToolResult(ok: false, message: "This action requires your confirmation before it can run.")
        }
        switch call.action {
        case "read_share":
            let id = call.shareId ?? conversation.workspaceId ?? conversation.shareIds.first
            guard let id else { return DesktopAIWorkspaceToolResult(ok: false, message: "No repository file is attached to this conversation.") }
            let file: DesktopAIWorkspaceToolShareFile = try await request("share/\(segment(id))", method: "GET", body: nil)
            return DesktopAIWorkspaceToolResult(ok: true,
                message: "Read repository file \(file.path ?? file.name ?? id).\n\n\(String((file.content ?? "").prefix(12_000)))")
        case "update_share":
            let id = call.shareId ?? conversation.workspaceId ?? conversation.shareIds.first
            guard let id, let content = call.content else {
                return DesktopAIWorkspaceToolResult(ok: false, message: "update_share requires a file identifier and file content.")
            }
            let current: DesktopAIWorkspaceToolShareFile = try await request("share/\(segment(id))", method: "GET", body: nil)
            guard current.locked != true else {
                return DesktopAIWorkspaceToolResult(ok: false, message: "This repository file is locked and cannot be updated.")
            }
            let body: [String: DesktopAIJSONValue] = [
                "content": .string(content),
                "path": call.path.map(DesktopAIJSONValue.string) ?? .null,
            ]
            let _: DesktopAIWorkspaceToolShareFile = try await request("share/\(segment(id))", method: "PUT", body: body)
            return DesktopAIWorkspaceToolResult(ok: true, message: "Updated repository file \(call.path ?? id).")
        case "http_request":
            guard let rawURL = call.url, let target = URL(string: rawURL),
                  ["http", "https"].contains(target.scheme?.lowercased() ?? ""), target.host != nil,
                  target.user == nil, target.password == nil else {
                return DesktopAIWorkspaceToolResult(ok: false, message: "http_request requires an HTTP or HTTPS URL without embedded credentials.")
            }
            let method = (call.method ?? "GET").uppercased()
            guard ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"].contains(method) else {
                return DesktopAIWorkspaceToolResult(ok: false, message: "The HTTP method is not supported.")
            }
            let payload: [String: DesktopAIJSONValue] = [
                "url": .string(target.absoluteString), "method": .string(method),
                "headers": .object((call.headers ?? [:]).mapValues(DesktopAIJSONValue.string)),
                "body": call.body.map(DesktopAIJSONValue.string) ?? .null,
                "approved": .bool(confirmed),
            ]
            let (data, statusCode) = try await performRequest(url: baseURL.appendingAPIPath("tools/http/request"), method: "POST", body: payload)
            let responseText = String(decoding: data.prefix(12_000), as: UTF8.self)
            return DesktopAIWorkspaceToolResult(ok: (200..<300).contains(statusCode),
                message: "HTTP \(method) \(target.absoluteString)\nStatus: \(statusCode)\n\n\(responseText)",
                artifacts: [DesktopAIWorkspaceToolArtifact(kind: "http", title: "HTTP \(statusCode)", path: nil, url: target.absoluteString, content: responseText)])
        case "browser_task":
            guard let rawURL = call.url, let target = URL(string: rawURL),
                  ["http", "https"].contains(target.scheme?.lowercased() ?? ""), target.host != nil,
                  target.user == nil, target.password == nil else {
                return DesktopAIWorkspaceToolResult(ok: false, message: "browser_task requires an HTTP or HTTPS URL without embedded credentials.")
            }
            let payload: [String: DesktopAIJSONValue] = [
                "url": .string(target.absoluteString),
                "timeoutMs": .number(Double(min(max(call.timeoutMs ?? 12_000, 1_000), 30_000))),
                "captureScreenshot": .bool(call.captureScreenshot ?? false),
            ]
            let (data, statusCode) = try await performRequest(url: baseURL.appendingAPIPath("tools/browser/task"), method: "POST", body: payload)
            let responseText = String(decoding: data.prefix(12_000), as: UTF8.self)
            let result = try? JSONDecoder().decode(DesktopAIWorkspaceBrowserResult.self, from: data)
            let message = [
                "Browser task for \(result?.url ?? target.absoluteString)",
                "Title: \(result?.title ?? "<none>")",
                "Screenshot: \(result?.screenshotPath ?? "not available")",
                "Text excerpt: \(result?.textExcerpt ?? result?.error ?? responseText)",
                "Page errors: \(result?.pageErrors?.joined(separator: "\\n") ?? "<none>")",
                "Console: \(result?.consoleMessages?.joined(separator: "\\n") ?? "<none>")",
            ].joined(separator: "\n\n")
            let ok = (200..<300).contains(statusCode) && result?.ok != false
            return DesktopAIWorkspaceToolResult(ok: ok, message: message,
                artifacts: [DesktopAIWorkspaceToolArtifact(kind: "link", title: result?.title ?? "Browser target", path: nil, url: result?.url ?? target.absoluteString, content: result?.textExcerpt)])
        case "run_terminal_command":
            let id = call.shareId ?? conversation.workspaceId ?? conversation.shareIds.first
            guard let id, let command = call.command, !command.contains("\n"), !command.contains("\r") else {
                return DesktopAIWorkspaceToolResult(ok: false, message: "run_terminal_command requires one command and an attached repository.")
            }
            guard let share = shares.first(where: { $0.id == id }), let alias = share.alias, !alias.isEmpty else {
                return DesktopAIWorkspaceToolResult(ok: false, message: "The attached repository does not have a terminal alias yet.")
            }
            let allowed = ["pwd", "ls", "clear", "help"]
            let program = command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            guard allowed.contains(program) else {
                return DesktopAIWorkspaceToolResult(ok: false, message: "The repository terminal only supports pwd, ls, clear, and help.")
            }
            guard let url = terminalURL(alias: alias) else { throw ClientError.invalidBaseURL }
            let output: String
            if let toolSocketResponder {
                output = try await toolSocketResponder(url, command, min(max(call.timeoutMs ?? 20_000, 1_000), 60_000))
            } else {
                output = try await runTerminalSocket(url: url, command: command,
                    timeoutMilliseconds: min(max(call.timeoutMs ?? 20_000, 1_000), 60_000))
            }
            return DesktopAIWorkspaceToolResult(ok: true, message: "Ran terminal command in repository \(id).\n\nCommand: \(command)\n\nOutput:\n\(String(output.prefix(12_000)))",
                artifacts: [DesktopAIWorkspaceToolArtifact(kind: "command", title: command, path: nil, url: nil, content: output)])
        case "create_vm":
            let name = Self.slugify(call.vmName ?? call.projectName ?? conversation.title)
            let (data, statusCode) = try await performRequest(url: baseURL.appendingAPIPath("vm"), method: "POST", body: ["name": .string(name)])
            let response = try? JSONDecoder().decode(DesktopAIWorkspaceVMCreateResponse.self, from: data)
            let message = response?.error ?? "Created VM \(name) (HTTP \(statusCode))."
            return DesktopAIWorkspaceToolResult(ok: (200..<300).contains(statusCode), message: message)
        case "create_project":
            return try await createProject(call)
        case "scaffold_nextjs_docker":
            return try await scaffoldNextjsDocker(call, conversation: conversation)
        default:
            return DesktopAIWorkspaceToolResult(ok: false, message: "Unsupported tool action \(call.action).")
        }
    }

    private func terminalURL(alias: String) -> URL? {
        guard Self.validPathComponent(alias), Self.validPathComponent(userID),
              let session = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).description.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              var components = URLComponents(url: baseURL.appendingAPIPath("ws/share/\(alias)/shell/\(userID)/\(session)"), resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "wss"
        guard components.host == baseURL.host else { return nil }
        return components.url
    }

    private func createProject(_ call: DesktopAIWorkspaceToolCall) async throws -> DesktopAIWorkspaceToolResult {
        guard let files = call.projectFiles, !files.isEmpty, files.count <= 96,
              Self.validateNextjsProjectFiles(files) else {
            return DesktopAIWorkspaceToolResult(ok: false,
                message: "Project creation needs 1–96 safe files, including package.json with the supported Next.js build/start scripts. No repository or VM was created.")
        }
        let rootName = Self.slugify(call.projectName ?? "hanasand-project")
        let rootID = String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12))
        let rootBody: [String: DesktopAIJSONValue] = [
            "id": .string(rootID), "includeTree": .bool(true), "content": .string(""),
            "name": .string(rootName), "path": .string(rootName), "type": .string("folder"),
        ]
        let (_, rootStatus) = try await performRequest(url: baseURL.appendingAPIPath("share"), method: "POST", body: rootBody)
        guard (200..<300).contains(rootStatus) else {
            return DesktopAIWorkspaceToolResult(ok: false, message: "Could not create project repository `\(rootName)` (HTTP \(rootStatus)).")
        }
        var folders: [String: String] = ["": rootID]
        for file in files {
            let parts = file.path.split(separator: "/").map(String.init)
            var prefix = ""
            var parent = rootID
            for component in parts.dropLast() {
                prefix = prefix.isEmpty ? component : "\(prefix)/\(component)"
                if let existing = folders[prefix] { parent = existing; continue }
                let folderID = Self.randomShareID()
                let folderBody: [String: DesktopAIJSONValue] = [
                    "id": .string(folderID), "includeTree": .bool(false), "content": .string(""),
                    "name": .string(component), "parent": .string(parent), "type": .string("folder"),
                ]
                let (_, status) = try await performRequest(url: baseURL.appendingAPIPath("share"), method: "POST", body: folderBody)
                guard (200..<300).contains(status) else {
                    return DesktopAIWorkspaceToolResult(ok: false, message: "Created project repository `\(rootName)`, but could not create folder `\(prefix)` (HTTP \(status)). No VM was started.")
                }
                folders[prefix] = folderID
                parent = folderID
            }
            guard let name = parts.last else { continue }
            let fileBody: [String: DesktopAIJSONValue] = [
                "id": .string(Self.randomShareID()), "includeTree": .bool(false),
                "content": .string(file.content), "name": .string(name), "parent": .string(parent), "type": .string("file"),
            ]
            let (_, status) = try await performRequest(url: baseURL.appendingAPIPath("share"), method: "POST", body: fileBody)
            guard (200..<300).contains(status) else {
                return DesktopAIWorkspaceToolResult(ok: false, message: "Created repository `\(rootName)`, but could not write `\(file.path)` (HTTP \(status)). No VM was started.")
            }
        }
        let vmName = Self.slugify(call.vmName ?? rootName)
        let projectFiles = files.map { file in DesktopAIJSONValue.object(["path": .string(file.path), "content": .string(file.content)]) }
        let vmBody: [String: DesktopAIJSONValue] = [
            "name": .string(vmName), "os": .string("ubuntu-24.04"),
            "resources": .object(["cpu": .string("2"), "memory": .string("4GiB"), "disk": .string("20GiB")]),
            "services": .array([.string("nodejs")]), "project_files": .array(projectFiles),
        ]
        let (vmData, vmStatus) = try await performRequest(url: baseURL.appendingAPIPath("vm"), method: "POST", body: vmBody)
        let vmResponse = try? JSONDecoder().decode(DesktopAIWorkspaceVMCreateResponse.self, from: vmData)
        guard (200..<300).contains(vmStatus) else {
            return DesktopAIWorkspaceToolResult(ok: false, message: "Created repository `\(rootName)`, but VM `\(vmName)` provisioning could not start: \(vmResponse?.error ?? "HTTP \(vmStatus)").")
        }
        for attempt in 0..<36 {
            if let (data, status) = try? await performRequest(url: baseURL.appendingAPIPath("vm/\(segment(vmName))"), method: "GET", body: nil),
               (200..<300).contains(status),
               let vms = try? JSONDecoder().decode([DesktopAIWorkspaceProjectVM].self, from: data),
               let vm = vms.first {
                let state = vm.status?.lowercased() ?? ""
                if state == "running" {
                    if let (serviceData, serviceStatus) = try? await performRequest(url: baseURL.appendingAPIPath("vm/\(segment(vmName))/public-services"), method: "GET", body: nil),
                       (200..<300).contains(serviceStatus),
                       let services = try? JSONDecoder().decode(DesktopAIWorkspacePublicServices.self, from: serviceData) {
                        let previewHost = services.portAlias.replacingOccurrences(of: "<port>", with: "3000")
                        let previewURL = "http://\(previewHost)"
                        return DesktopAIWorkspaceToolResult(ok: true,
                            message: "Created \(rootName), installed its dependencies, built it, and confirmed the app responds on the VM. Preview: \(previewURL)",
                            artifacts: [
                                DesktopAIWorkspaceToolArtifact(kind: "file", title: rootName, path: rootName, url: nil, content: "\(files.count) project files"),
                                DesktopAIWorkspaceToolArtifact(kind: "link", title: "Project preview", path: nil, url: previewURL, content: nil),
                            ])
                    }
                    return DesktopAIWorkspaceToolResult(ok: false,
                        message: "Created \(rootName) and confirmed the VM is running, but its public preview address could not be read. Check VM \(vmName)'s public services.")
                }
                if state == "error" || state == "offline" {
                    return DesktopAIWorkspaceToolResult(ok: false,
                        message: "Created \(rootName), but VM \(vmName) setup failed: \(vm.status_reason ?? state).")
                }
            }
            if attempt < 35 { await toolDelay(5_000) }
        }
        return DesktopAIWorkspaceToolResult(ok: false,
            message: "Created \(rootName) and started VM \(vmName), but the build is still in progress after 180 seconds. Check VM \(vmName)'s provisioning status.")
    }

    private func scaffoldNextjsDocker(_ call: DesktopAIWorkspaceToolCall, conversation: DesktopAIConversation) async throws -> DesktopAIWorkspaceToolResult {
        let projectName = Self.slugify(call.projectName ?? conversation.title)
        let title = projectName.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
        let package: [String: Any] = [
            "name": projectName, "version": "0.1.0", "private": true,
            "scripts": ["dev": "next dev --hostname 0.0.0.0 --port 3000", "build": "next build", "start": "next start --hostname 0.0.0.0 --port 3000", "lint": "next lint"],
            "dependencies": ["next": "16.2.3", "react": "19.2.5", "react-dom": "19.2.5"],
            "devDependencies": ["@types/node": "^24.0.0", "@types/react": "^19.0.0", "@types/react-dom": "^19.0.0", "eslint": "^9.0.0", "eslint-config-next": "16.2.3", "typescript": "^5.0.0"],
        ]
        let tsconfig: [String: Any] = ["compilerOptions": ["target": "ES2017", "lib": ["dom", "dom.iterable", "esnext"], "allowJs": false, "skipLibCheck": true, "strict": true, "noEmit": true, "esModuleInterop": true, "module": "esnext", "moduleResolution": "bundler", "resolveJsonModule": true, "isolatedModules": true, "jsx": "preserve", "incremental": true, "plugins": [["name": "next"]], "paths": ["@/*": ["./*"]]], "include": ["next-env.d.ts", "**/*.ts", "**/*.tsx", ".next/types/**/*.ts"], "exclude": ["node_modules"]]
        let files: [(String, String)] = [
            ("package.json", Self.prettyJSON(package)),
            ("tsconfig.json", Self.prettyJSON(tsconfig)),
            ("next-env.d.ts", "/// <reference types=\"next\" />\n/// <reference types=\"next/image-types/global\" />\n\n// This file is auto-generated by Next.js.\n"),
            ("next.config.ts", "import type { NextConfig } from 'next'\n\nconst nextConfig: NextConfig = {\n  output: 'standalone',\n}\n\nexport default nextConfig\n"),
            (".gitignore", "node_modules\n.next\nout\ncoverage\n.env*\nnpm-debug.log*\nyarn-debug.log*\nyarn-error.log*\npnpm-debug.log*\n.DS_Store\n"),
            (".dockerignore", "node_modules\n.next\n.git\nnpm-debug.log\nDockerfile*\ndocker-compose*.yml\nREADME.md\n"),
            ("Dockerfile", "FROM node:20-alpine AS deps\nWORKDIR /app\nCOPY package.json package-lock.json* ./\nRUN npm install\n\nFROM node:20-alpine AS builder\nWORKDIR /app\nCOPY --from=deps /app/node_modules ./node_modules\nCOPY . .\nRUN npm run build\n\nFROM node:20-alpine AS runner\nWORKDIR /app\nENV NODE_ENV=production\nCOPY --from=builder /app/.next/standalone ./\nCOPY --from=builder /app/.next/static ./.next/static\nCOPY --from=builder /app/public ./public\nEXPOSE 3000\nCMD [\"node\", \"server.js\"]\n"),
            ("docker-compose.yml", "services:\n  web:\n    build:\n      context: .\n      dockerfile: Dockerfile\n    ports:\n      - \"${HOST_PORT:-3000}:3000\"\n    environment:\n      NODE_ENV: production\n    restart: unless-stopped\n"),
            ("app/layout.tsx", "import './globals.css'\nimport type { Metadata } from 'next'\nimport type { ReactNode } from 'react'\n\nexport const metadata: Metadata = {\n  title: '\(title)',\n  description: 'A Next.js workspace scaffolded by Hanasand AI.',\n}\n\nexport default function RootLayout({ children }: { children: ReactNode }) {\n  return (\n    <html lang=\"en\">\n      <body>{children}</body>\n    </html>\n  )\n}\n"),
            ("app/page.tsx", "const features = [\n  'Next.js App Router with TypeScript',\n  'Standalone Docker image build',\n  'docker-compose ready for local orchestration',\n]\n\nexport default function HomePage() {\n  return (\n    <main className=\"page-shell\">\n      <section className=\"hero-card\">\n        <span className=\"eyebrow\">Hanasand AI Workspace</span>\n        <h1>\(title)</h1>\n        <p>\n          This starter is ready for npm install, local development, and Docker-based deployment.\n          Use it as a base for a richer product app, admin dashboard, or full-stack workflow.\n        </p>\n        <div className=\"actions\">\n          <a className=\"primary\" href=\"https://nextjs.org/docs\">Read the docs</a>\n          <a className=\"secondary\" href=\"#stack\">Inspect the stack</a>\n        </div>\n      </section>\n      <section id=\"stack\" className=\"stack-grid\">\n        {features.map((feature) => (\n          <article key={feature} className=\"stack-card\">\n            <h2>{feature}</h2>\n            <p>Extend this workspace from the browser, then deploy it through the same share-backed flow.</p>\n          </article>\n        ))}\n      </section>\n    </main>\n  )\n}\n"),
            ("app/globals.css", ":root {\n  color-scheme: dark;\n  --bg: #07111f;\n  --panel: rgba(10, 23, 39, 0.78);\n  --panel-border: rgba(148, 163, 184, 0.2);\n  --text: #f8fafc;\n  --muted: rgba(226, 232, 240, 0.72);\n  --accent: #f97316;\n  --accent-soft: rgba(249, 115, 22, 0.2);\n}\n\n* { box-sizing: border-box; }\nhtml, body { margin: 0; min-height: 100%; background: radial-gradient(circle at top, rgba(249, 115, 22, 0.24), transparent 32%), linear-gradient(180deg, #08101c 0%, #07111f 48%, #030712 100%); color: var(--text); font-family: Georgia, 'Times New Roman', serif; }\nbody { min-height: 100vh; }\na { color: inherit; text-decoration: none; }\n.page-shell { min-height: 100vh; padding: 48px 20px; }\n.hero-card, .stack-card { backdrop-filter: blur(18px); background: var(--panel); border: 1px solid var(--panel-border); border-radius: 28px; box-shadow: 0 30px 90px rgba(2, 8, 23, 0.38); }\n.hero-card { max-width: 960px; margin: 0 auto; padding: 32px; }\n.eyebrow { display: inline-flex; margin-bottom: 16px; padding: 8px 12px; border-radius: 999px; background: var(--accent-soft); color: #fed7aa; font-size: 12px; letter-spacing: 0.16em; text-transform: uppercase; }\n.hero-card h1 { margin: 0; font-size: clamp(2.5rem, 8vw, 5rem); line-height: 0.96; }\n.hero-card p { max-width: 42rem; color: var(--muted); font-size: 1.05rem; line-height: 1.8; }\n.actions { display: flex; flex-wrap: wrap; gap: 14px; margin-top: 28px; }\n.primary, .secondary { display: inline-flex; align-items: center; justify-content: center; min-height: 46px; padding: 0 18px; border-radius: 999px; font-weight: 600; }\n.primary { background: var(--accent); color: #111827; }\n.secondary { border: 1px solid rgba(248, 250, 252, 0.14); color: var(--text); }\n.stack-grid { display: grid; gap: 18px; max-width: 960px; margin: 24px auto 0; }\n.stack-card { padding: 22px; }\n.stack-card h2 { margin: 0 0 10px; font-size: 1.1rem; }\n.stack-card p { margin: 0; color: var(--muted); line-height: 1.7; }\n@media (min-width: 820px) { .stack-grid { grid-template-columns: repeat(3, minmax(0, 1fr)); } .hero-card { padding: 44px; } }\n"),
            ("public/.gitkeep", ""),
            ("README.md", "# \(title)\n\nScaffolded by Hanasand AI as a browser-native coding workspace.\n\n## Quick start\n\n```bash\nnpm install\nnpm run dev\n```\n\nOpen [http://localhost:3000](http://localhost:3000).\n\n## Docker\n\n```bash\nHOST_PORT=3200 docker compose up --build\n```\n\n## What is included\n\n- Next.js App Router with TypeScript\n- Production-ready standalone Dockerfile\n- `docker-compose.yml` for local orchestration\n- A polished landing page starter for further iteration\n"),
        ]
        let rootID = Self.randomShareID()
        let rootBody: [String: DesktopAIJSONValue] = ["id": .string(rootID), "includeTree": .bool(true), "content": .string(""), "name": .string(projectName), "path": .string(projectName), "type": .string("folder")]
        let (_, rootStatus) = try await performRequest(url: baseURL.appendingAPIPath("share"), method: "POST", body: rootBody)
        guard (200..<300).contains(rootStatus) else { return DesktopAIWorkspaceToolResult(ok: false, message: "Could not create Next.js + Docker repository `\(projectName)` (HTTP \(rootStatus)).") }
        var folders: [String: String] = ["": rootID]
        for (path, content) in files {
            let parts = path.split(separator: "/").map(String.init)
            var parent = rootID
            var prefix = ""
            for component in parts.dropLast() {
                prefix = prefix.isEmpty ? component : "\(prefix)/\(component)"
                if let existing = folders[prefix] { parent = existing; continue }
                let id = Self.randomShareID()
                let body: [String: DesktopAIJSONValue] = ["id": .string(id), "includeTree": .bool(false), "content": .string(""), "name": .string(component), "parent": .string(parent), "type": .string("folder")]
                let (_, status) = try await performRequest(url: baseURL.appendingAPIPath("share"), method: "POST", body: body)
                guard (200..<300).contains(status) else { return DesktopAIWorkspaceToolResult(ok: false, message: "Created the repository but could not create folder `\(prefix)` (HTTP \(status)).") }
                folders[prefix] = id
                parent = id
            }
            guard let name = parts.last else { continue }
            let body: [String: DesktopAIJSONValue] = ["id": .string(Self.randomShareID()), "includeTree": .bool(false), "content": .string(content), "name": .string(name), "parent": .string(parent), "type": .string("file")]
            let (_, status) = try await performRequest(url: baseURL.appendingAPIPath("share"), method: "POST", body: body)
            guard (200..<300).contains(status) else { return DesktopAIWorkspaceToolResult(ok: false, message: "Created the repository but could not write `\(path)` (HTTP \(status)).") }
        }
        var attachedConversation = conversation
        attachedConversation.workspaceKind = "share"
        attachedConversation.workspaceId = rootID
        attachedConversation.shareIds = Array(Set(conversation.shareIds + [rootID])).sorted()
        do { try await updateConversation(attachedConversation) }
        catch { return DesktopAIWorkspaceToolResult(ok: false, message: "Created repository `\(projectName)` with \(files.count) files, but could not attach it to the conversation: \(error.localizedDescription)") }
        return DesktopAIWorkspaceToolResult(ok: true, message: "Created and attached Next.js + Docker repository `\(projectName)` with \(files.count) files.",
            artifacts: [DesktopAIWorkspaceToolArtifact(kind: "file", title: projectName, path: projectName, url: nil, content: "Next.js App Router, TypeScript, standalone Dockerfile, docker-compose.yml")])
    }

    private static func prettyJSON(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return "{}\n" }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private func runTerminalSocket(url: URL, command: String, timeoutMilliseconds: Int) async throws -> String {
        let socket = DesktopAIWorkspaceSession.shared.webSocketTask(with: URLRequest(url: url, timeoutInterval: Double(timeoutMilliseconds) / 1_000))
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let payload = try JSONSerialization.data(withJSONObject: ["type": "terminalInput", "content": command + "\n"])
        try await socket.send(.string(String(decoding: payload, as: UTF8.self)))
        let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1_000)
        while Date() < deadline {
            let remaining = max(1, Int(deadline.timeIntervalSinceNow * 1_000))
            let frame = try await receiveTerminalFrame(socket, timeoutMilliseconds: remaining)
            let text: String
            switch frame {
            case .string(let value): text = value
            case .data(let data): text = String(decoding: data, as: UTF8.self)
            @unknown default: continue
            }
            guard let bytes = text.data(using: .utf8),
                  let event = try? JSONDecoder().decode(DesktopAITerminalEvent.self, from: bytes),
                  event.type == "update", let output = event.content else { continue }
            if output.hasPrefix("\(command)\r\n") { return output }
        }
        throw ClientError.socketUnavailable("The repository terminal timed out.")
    }

    private func receiveTerminalFrame(_ socket: URLSessionWebSocketTask, timeoutMilliseconds: Int) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await socket.receive() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutMilliseconds) * 1_000_000)
                throw ClientError.socketUnavailable("The repository terminal timed out.")
            }
            guard let first = try await group.next() else { throw ClientError.invalidResponse }
            group.cancelAll()
            return first
        }
    }

    private static func validPathComponent(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 200
            && value.range(of: #"^[A-Za-z0-9._~-]+$"#, options: .regularExpression) != nil
    }

    private static func randomShareID() -> String {
        String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12))
    }

    private static func validateNextjsProjectFiles(_ files: [DesktopAIWorkspaceToolCall.ProjectFile]) -> Bool {
        var total = 0
        var paths = Set<String>()
        for file in files {
            let path = file.path
            let bytes = file.content.utf8.count
            total += bytes
            guard !path.isEmpty, path.count <= 180, path.range(of: #"^[A-Za-z0-9_.@/-]+$"#, options: .regularExpression) != nil,
                  !path.hasPrefix("/"), !path.contains("\\"), !path.split(separator: "/").contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  !path.split(separator: "/").contains(where: { $0.lowercased() == ".env" || $0.lowercased().hasPrefix(".env.") || ["node_modules", ".next", ".git"].contains($0.lowercased()) }),
                  bytes <= 48 * 1024, total <= 120 * 1024, paths.insert(path).inserted else { return false }
        }
        guard let package = files.first(where: { $0.path == "package.json" }),
              let data = package.content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: Any] else { return false }
        let dependencies = (json["dependencies"] as? [String: Any] ?? [:])
            .merging(json["devDependencies"] as? [String: Any] ?? [:], uniquingKeysWith: { _, second in second })
        return dependencies["next"] != nil && dependencies["react"] != nil && dependencies["react-dom"] != nil
            && scripts["build"] as? String == "next build"
            && scripts["start"] as? String == "next start --hostname 0.0.0.0 --port 3000"
            && !["prebuild", "postbuild", "prestart", "poststart"].contains(where: { scripts[$0] != nil })
    }

    private static func slugify(_ value: String) -> String {
        let slug = value.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String((slug.isEmpty ? "hanasand-project" : slug).prefix(48))
    }

    func completePrompt(conversationID: String, modelName: String, messages: [[String: String]]) async throws -> String {
        let requestPayload: [String: Any] = [
            "type": "prompt_request",
            "conversationId": conversationID,
            "clientName": modelName,
            "messages": messages,
            "maxTokens": 1024,
            "temperature": 0.35,
        ]
        let body = try JSONSerialization.data(withJSONObject: requestPayload)
        guard let payload = String(data: body, encoding: .utf8),
              var components = URLComponents(url: baseURL.appendingAPIPath("client/ws/gpt"), resolvingAgainstBaseURL: false) else {
            throw ClientError.invalidBaseURL
        }
        components.scheme = "wss"
        guard let url = components.url, url.host == baseURL.host else { throw ClientError.invalidBaseURL }
        var socketRequest = URLRequest(url: url, timeoutInterval: 120)
        socketRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        socketRequest.setValue(userID, forHTTPHeaderField: "id")
        if let socketResponder { return try await socketResponder(socketRequest, payload) }

        let socket = DesktopAIWorkspaceSession.shared.webSocketTask(with: socketRequest)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        try await socket.send(.string(payload))
        while true {
            let frame = try await socket.receive()
            let text: String
            switch frame {
            case .string(let value): text = value
            case .data(let data): text = String(decoding: data, as: UTF8.self)
            @unknown default: continue
            }
            guard let data = text.data(using: .utf8), let event = try? JSONDecoder().decode(DesktopAISocketEvent.self, from: data),
                  event.conversationId == conversationID else { continue }
            if event.type == "prompt_error" {
                throw ClientError.socketUnavailable(event.error ?? "The connected AI model could not complete this prompt.")
            }
            if event.type == "prompt_complete" {
                guard let content = event.content, !content.isEmpty else { throw ClientError.invalidResponse }
                return content
            }
        }
    }

    func saveConversation(_ conversation: DesktopAIConversation) async throws {
        guard conversation.ownerId == userID || conversation.ownerId.isEmpty else { throw ClientError.invalidIdentifier }
        let _: EmptyResponse = try await request("ai/conversations", method: "POST", body: conversation.persistencePayload())
    }

    func updateConversation(_ conversation: DesktopAIConversation) async throws {
        let path = "ai/conversations/\(try segment(conversation.id))"
        let _: EmptyResponse = try await request(path, method: "PUT", body: conversation.persistencePayload())
    }

    func deleteConversation(id: String) async throws {
        let _: EmptyResponse = try await request("ai/conversations/\(try segment(id))", method: "DELETE", body: nil)
    }

    func saveMessage(_ message: DesktopAIMessage, conversationID: String) async throws {
        let _: EmptyResponse = try await request("ai/conversations/\(try segment(conversationID))/messages", method: "PUT", body: message.persistencePayload())
    }

    func inviteCollaborator(conversationID: String, userID targetUserID: String, role: String) async throws -> DesktopAIConversation {
        guard ["reviewer", "editor"].contains(role) else { throw ClientError.invalidIdentifier }
        let response: DesktopAIConversationEnvelope = try await request("ai/conversations/\(try segment(conversationID))/collaborators", method: "POST", body: [
            "userId": .string(try segment(targetUserID)), "role": .string(role),
        ])
        guard let conversation = response.conversation else { throw ClientError.invalidResponse }
        return conversation
    }

    func removeCollaborator(conversationID: String, userID targetUserID: String) async throws -> DesktopAIRemoveCollaboratorResponse {
        try await request("ai/conversations/\(try segment(conversationID))/collaborators/\(try segment(targetUserID))", method: "DELETE", body: nil)
    }

    func respond(prompt: String, context: String) async throws -> String {
        var request = URLRequest(url: promptURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
        request.httpMethod = "POST"; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["prompt": prompt, "context": context])
        let (data, response) = try await send(request)
        guard data.count <= 4 * 1024 * 1024, let http = response as? HTTPURLResponse,
              response.url?.scheme?.lowercased() == "https", response.url?.host == promptURL.host else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ClientError.httpStatus(http.statusCode) }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = (payload["message"] as? String) ?? (payload["suggestion"] as? String), !text.isEmpty else {
            throw ClientError.invalidResponse
        }
        return text
    }

    private func requestWithQuery<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> T {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw ClientError.invalidIdentifier }
        var components = URLComponents(url: baseURL.appendingAPIPath(path), resolvingAgainstBaseURL: false)
        components?.queryItems = query
        guard let url = components?.url else { throw ClientError.invalidBaseURL }
        return try await request(url: url, method: "GET", body: nil)
    }

    private func request<T: Decodable>(_ path: String, method: String, body: [String: DesktopAIJSONValue]?) async throws -> T {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw ClientError.invalidIdentifier }
        return try await request(url: baseURL.appendingAPIPath(path), method: method, body: body)
    }

    private func request<T: Decodable>(url: URL, method: String, body: [String: DesktopAIJSONValue]?) async throws -> T {
        let (data, statusCode) = try await performRequest(url: url, method: method, body: body)
        guard (200..<300).contains(statusCode) else { throw ClientError.httpStatus(statusCode) }
        if T.self == EmptyResponse.self { return EmptyResponse() as! T }
        return try decode(T.self, from: data)
    }

    private func performRequest(url: URL, method: String, body: [String: DesktopAIJSONValue]?) async throws -> (Data, Int) {
        guard url.scheme?.lowercased() == "https", url.host == baseURL.host, url.user == nil, url.password == nil else { throw ClientError.invalidBaseURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = method; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await send(request)
        guard data.count <= 16 * 1024 * 1024, let http = response as? HTTPURLResponse,
              response.url?.scheme?.lowercased() == "https", response.url?.host == baseURL.host else { throw ClientError.invalidResponse }
        return (data, http.statusCode)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw ClientError.invalidResponse }
    }

    private func segment(_ value: String) throws -> String {
        guard !value.isEmpty, value.count <= 200,
              value.range(of: #"^[A-Za-z0-9._~-]+$"#, options: .regularExpression) != nil else { throw ClientError.invalidIdentifier }
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) else {
            throw ClientError.invalidIdentifier
        }
        return encoded
    }

    private struct EmptyResponse: Decodable { init() {} }
    private struct TargetEnvelope: Decodable { let targets: [DesktopAIVMTarget] }
}

private struct DesktopAISocketEvent: Decodable {
    let type: String?
    let conversationId: String?
    let content: String?
    let error: String?
}

private struct DesktopAITerminalEvent: Decodable {
    let type: String?
    let content: String?
}

@MainActor
final class DesktopAIWorkspaceViewModel: ObservableObject {
    @Published private(set) var conversations: [DesktopAIConversation] = []
    @Published private(set) var repositories: [DesktopAIRepository] = []
    @Published private(set) var shares: [DesktopAIShare] = []
    @Published private(set) var availableModelNames: [String] = []
    @Published private(set) var shareErrorMessage: String?
    @Published private(set) var deploymentTargets: [DesktopAIVMTarget] = []
    @Published private(set) var deployments: [DesktopAIDeployment] = []
    @Published private(set) var deployQuota: DesktopAIDeployQuota?
    @Published private(set) var releases: [DesktopAIRelease] = []
    @Published private(set) var isRefreshingDeployment = false
    @Published private(set) var isStartingDeployment = false
    @Published private(set) var rollbackPendingID: String?
    @Published private(set) var deploymentNotice: String?
    @Published private(set) var supportBundleText: String?
    @Published private(set) var pendingToolAction: DesktopAIPendingToolAction?
    @Published private(set) var toolActionNotice: String?
    @Published private(set) var isRunningToolAction = false
    @Published private(set) var collaborationErrorMessage: String?
    @Published private(set) var isUpdatingCollaborators = false
    @Published private(set) var selectedConversationID: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isSending = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isUnavailable = false
    @Published private(set) var chatGPTMembership: ChatGPTMembershipStatus = .loading
    @Published private(set) var chatGPTItems: [ChatGPTPromptPortalItem] = []
    @Published private(set) var chatGPTActivityConversationID: String?
    @Published private(set) var chatGPTActivityError: String?
    @Published private(set) var isRefreshingChatGPTActivity = false
    @Published private(set) var isSubmittingChatGPT = false
    @Published private(set) var chatGPTSubmissionUncertain = false

    private var routeConversationID: String?
    private var routeShareID: String?
    private var routeShareFileID: String?
    private var routeShareFilePath: String?
    private var createRouteShareConversation = false
    private var didCreateRouteShareConversation = false
    private var ownerID = ""
    private var settingsSnapshot: HanasandDesktopSettings?
    private var client: DesktopAIWorkspaceClient?
    private var chatGPTClient: ChatGPTPromptPortalClient?
    private var chatGPTPollTask: Task<Void, Never>?
    private var sharePromptContexts: [String: String] = [:]
    private var pendingToolQueue: [DesktopAIPendingToolAction] = []

    var currentOwnerID: String { ownerID }

    init(client: DesktopAIWorkspaceClient? = nil, ownerID: String = "", conversations: [DesktopAIConversation] = [], availableModelNames: [String] = []) {
        self.client = client
        self.ownerID = ownerID
        self.conversations = conversations
        self.availableModelNames = availableModelNames
        self.selectedConversationID = conversations.first?.id
    }

    func configureRoute(conversationID: String?, shareID: String?, shareFileID: String?,
                        shareFilePath: String?, createShareConversation: Bool) {
        if routeShareID != shareID || self.createRouteShareConversation != createShareConversation {
            didCreateRouteShareConversation = false
        }
        if routeConversationID != conversationID, !createShareConversation {
            routeConversationID = conversationID
            selectedConversationID = conversationID
        }
        routeShareID = shareID
        routeShareFileID = shareFileID
        routeShareFilePath = shareFilePath
        createRouteShareConversation = createShareConversation
    }

    deinit { chatGPTPollTask?.cancel() }

    var canUseChatGPT: Bool { chatGPTMembership == .member }

    var chatGPTHistoryReady: Bool {
        guard let selectedConversationID else { return false }
        return chatGPTActivityConversationID == selectedConversationID
    }

    var chatGPTStatusSummary: String? {
        guard !chatGPTItems.isEmpty else { return nil }
        let active = chatGPTItems.filter { $0.status == "queued" || $0.status == "running" }.count
        return active > 0 ? "\(active) ChatGPT request\(active == 1 ? "" : "s") active" : "ChatGPT queue is up to date"
    }

    func startChatGPTPolling() {
        chatGPTPollTask?.cancel()
        guard let id = selectedConversationID, canUseChatGPT, chatGPTClient != nil else { return }
        chatGPTPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.selectedConversationID == id else { return }
                await self.refreshChatGPTActivity(clearUncertain: false)
                let hasActive = self.chatGPTItems.contains { $0.status == "queued" || $0.status == "running" }
                do { try await Task.sleep(nanoseconds: hasActive ? 4_000_000_000 : 15_000_000_000) }
                catch { return }
            }
        }
    }

    func refreshChatGPTActivity(clearUncertain: Bool = true) async {
        guard !isRefreshingChatGPTActivity, let id = selectedConversationID,
              let chatGPTClient, canUseChatGPT else { return }
        isRefreshingChatGPTActivity = true
        defer { isRefreshingChatGPTActivity = false }
        do {
            let items = try await chatGPTClient.loadActivity(conversationID: id)
            guard selectedConversationID == id else { return }
            chatGPTItems = items
            chatGPTActivityConversationID = id
            chatGPTActivityError = nil
            if clearUncertain { chatGPTSubmissionUncertain = false }
        } catch {
            guard selectedConversationID == id else { return }
            chatGPTActivityError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func sendChatGPTPrompt(_ rawPrompt: String) async -> Bool {
        guard !isSubmittingChatGPT, !isSending, canUseChatGPT, chatGPTHistoryReady,
              !chatGPTSubmissionUncertain, let chatGPTClient,
              let conversation = selectedConversation, conversation.canWrite else { return false }
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return false }

        let portalMessages = chatGPTItems.flatMap { item -> [DesktopAIMessage] in
            let isPending = item.status == "queued" || item.status == "running"
            let statusText: String
            switch item.status {
            case "queued": statusText = item.priority == "now" ? "Up next" : "In the queue"
            case "running": statusText = "ChatGPT is working"
            case "error": statusText = "Could not complete"
            default: statusText = "Finished"
            }
            let metadata: [String: DesktopAIJSONValue] = [
                "promptPortalId": .string(item.id), "promptPortalStatus": .string(item.status),
                "threadId": .string(item.threadId ?? ChatGPTPromptPortalClient.threadID(conversation.id)),
                "statusText": .string(statusText),
                "files": .array(item.files.map { .object(["id": .string($0.id), "name": $0.name.map(DesktopAIJSONValue.string) ?? .null]) }),
            ]
            let created = item.createdAt
            let answerDate = item.completedAt ?? item.startedAt ?? item.createdAt
            let resultText = isPending ? "\(statusText)…" : (item.result?.isEmpty == false ? item.result! : item.status == "error" ? "The request could not be completed." : "Completed without a text response.")
            return [
                DesktopAIMessage(id: "\(item.id)-request", role: "user", content: item.prompt, modelName: "ChatGPT", metadata: metadata, createdAt: created),
                DesktopAIMessage(id: "\(item.id)-response", role: "assistant", content: resultText, pending: isPending, error: item.status == "error", modelName: "ChatGPT", metadata: metadata, createdAt: answerDate),
            ]
        }
        let allMessages = (conversation.messages + portalMessages).sorted { $0.createdAt < $1.createdAt }
        let context = allMessages.filter { !$0.pending && !$0.error && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { message in
                let promptID: String? = if case .string(let id)? = message.metadata["promptPortalId"] { id } else { nil }
                let files = promptID.flatMap { promptID in
                    chatGPTItems.first(where: { $0.id == promptID })?.files.map {
                        ChatGPTPromptContextMessage.FileReference(itemId: promptID, fileId: $0.id)
                    }
                }
                return ChatGPTPromptContextMessage(role: message.role == "user" ? "user" : "assistant",
                                                   content: message.content, modelName: message.modelName,
                                                   files: files?.isEmpty == false ? files : nil)
            }

        isSubmittingChatGPT = true
        defer { isSubmittingChatGPT = false }
        errorMessage = nil
        do {
            chatGPTItems = try await chatGPTClient.submit(prompt: prompt, conversationID: conversation.id, context: context)
            chatGPTActivityConversationID = conversation.id
            chatGPTActivityError = nil
            chatGPTSubmissionUncertain = false
            startChatGPTPolling()
            return true
        } catch {
            chatGPTSubmissionUncertain = true
            let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            chatGPTActivityError = "\(description) Refresh the ChatGPT queue to check whether it was accepted before sending again."
            return false
        }
    }

    var selectedConversation: DesktopAIConversation? {
        conversations.first { $0.id == selectedConversationID }
    }

    var routeConversationMissing: Bool {
        guard let routeConversationID, !isLoading else { return false }
        return !conversations.contains(where: { $0.id == routeConversationID })
    }

    func select(_ id: String) {
        selectedConversationID = id
        routeConversationID = id
        chatGPTActivityConversationID = nil
        chatGPTItems = []
        chatGPTActivityError = nil
        chatGPTSubmissionUncertain = false
        startChatGPTPolling()
    }

    func setPreferredModel(_ model: String?) async {
        guard let client, var selected = selectedConversation, selected.canWrite else { return }
        if let model, !availableModelNames.contains(model) {
            errorMessage = "That model is not currently connected. Refresh the workspace and choose an available model."
            return
        }
        let previous = selected
        selected.preferredModel = model
        selected.updatedAt = ISO8601DateFormatter().string(from: Date())
        replace(selected)
        do { try await client.updateConversation(selected); errorMessage = nil }
        catch { replace(previous); errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    func setModelStrategy(_ strategy: String) async {
        guard ["auto", "pinned"].contains(strategy), let client, var selected = selectedConversation, selected.canWrite else { return }
        let previous = selected
        selected.modelStrategy = strategy
        selected.updatedAt = ISO8601DateFormatter().string(from: Date())
        replace(selected)
        do { try await client.updateConversation(selected); errorMessage = nil }
        catch { replace(previous); errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    func attachRepository(_ repository: DesktopAIRepository) async { await attachWorkspace(id: repository.id, kind: "repo") }
    func attachShare(_ share: DesktopAIShare) async { await attachWorkspace(id: share.id, kind: "share") }

    func refreshDeploymentData() async {
        guard let client else { return }
        isRefreshingDeployment = true
        defer { isRefreshingDeployment = false }
        do { deploymentTargets = try await client.loadDeploymentTargets() }
        catch { deploymentNotice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        guard let conversationID = selectedConversationID else { return }
        do {
            let snapshot = try await client.loadDeployments(conversationID: conversationID)
            deployments = snapshot.deployments
            deployQuota = snapshot.quota ?? deployQuota
        } catch {
            deploymentNotice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        do { releases = try await client.loadReleases(conversationID: conversationID).releases }
        catch { deploymentNotice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    func startDeployment(vmName rawName: String, port rawPort: String, healthPath rawHealthPath: String,
                         accessPolicy: String, environment: String) async {
        guard !isStartingDeployment, let client, let conversation = selectedConversation, conversation.canWrite else { return }
        let vmName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let healthPath = rawHealthPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !vmName.isEmpty else { deploymentNotice = "Choose a launch target before starting the check."; return }
        guard let port = Int(rawPort), (1...65_535).contains(port) else { deploymentNotice = "Enter a port from 1 to 65535."; return }
        guard healthPath.hasPrefix("/"), !healthPath.contains("\\") else { deploymentNotice = "The health check path must start with /."; return }
        guard conversation.workspaceKind == "repo", let repositoryID = conversation.workspaceId,
              repositories.contains(where: { $0.id == repositoryID }) else {
            deploymentNotice = "Attach an imported repository before starting a launch check."
            return
        }
        if let deployQuota {
            if deployQuota.remaining <= 0 {
                deploymentNotice = "Launch check quota reached. It resets at \(deployQuota.resetsAt)."
                return
            }
            if deployQuota.runningRemaining <= 0 {
                deploymentNotice = "All preview slots are in use (\(deployQuota.activeRunning)/\(deployQuota.maxRunning)). Wait for one to finish."
                return
            }
        }
        guard ["owner_only", "collaborators", "public_preview"].contains(accessPolicy),
              ["staging", "production"].contains(environment) else {
            deploymentNotice = "Choose a supported preview policy and environment."
            return
        }
        isStartingDeployment = true
        deploymentNotice = "Starting the remote launch check…"
        defer { isStartingDeployment = false }
        do {
            let result = try await client.startDeployment(
                conversationID: conversation.id,
                vmName: vmName,
                port: port,
                healthPath: healthPath,
                accessPolicy: accessPolicy,
                environment: environment
            )
            if let quota = result.response.quota { deployQuota = quota }
            if let deployment = result.response.deployment {
                deployments.removeAll { $0.id == deployment.id }
                deployments.insert(deployment, at: 0)
                deploymentNotice = deployment.status == "running"
                    ? "Launch health check passed. Preview is reachable from the target."
                    : deployment.failureReason ?? "Launch check requires a manual follow-up step."
                await refreshReleaseHistory(conversationID: conversation.id, client: client)
            } else {
                deploymentNotice = result.response.error ?? "The launch check was rejected (HTTP \(result.statusCode))."
            }
        } catch {
            deploymentNotice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func markRollbackTarget(_ release: DesktopAIRelease) async {
        guard rollbackPendingID == nil, let client, release.ownerId == ownerID,
              release.status != "current", release.status != "rollback_target" else { return }
        rollbackPendingID = release.id
        defer { rollbackPendingID = nil }
        do {
            let result = try await client.markRollbackTarget(releaseID: release.id)
            guard let updated = result.release else {
                deploymentNotice = result.error ?? "Could not mark the rollback target."
                return
            }
            releases = releases.map { item in
                guard item.conversationId == updated.conversationId else { return item }
                if item.id == updated.id { return updated }
                if item.status == "current" { var rolledBack = item; rolledBack.status = "rolled_back"; rolledBack.updatedAt = updated.updatedAt; return rolledBack }
                return item
            }
            deploymentNotice = "Previous release marked as the rollback target. The final restore still needs a manual runtime step."
        } catch { deploymentNotice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    func loadSupportBundle(for release: DesktopAIRelease) async {
        guard let client else { return }
        do {
            let response = try await client.loadReleaseSupportBundle(releaseID: release.id)
            guard let bundle = response.bundle else {
                deploymentNotice = response.error ?? "Support bundle is unavailable."
                return
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            supportBundleText = String(decoding: try encoder.encode(bundle), as: UTF8.self)
        } catch { deploymentNotice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    func clearSupportBundle() { supportBundleText = nil }

    func confirmPendingToolAction() async {
        guard let pending = pendingToolAction else { return }
        pendingToolAction = nil
        pendingToolQueue.removeAll { $0.id == pending.id }
        await runToolAction(pending, confirmed: true)
        await continueToolQueue()
    }

    func rejectPendingToolAction() async {
        guard let pending = pendingToolAction else { return }
        pendingToolAction = nil
        pendingToolQueue.removeAll { $0.id == pending.id }
        await saveToolMessage(conversationID: pending.conversationID,
            result: DesktopAIWorkspaceToolResult(ok: false, message: "Cancelled. No changes were made."), action: pending.call.action)
        await continueToolQueue()
    }

    func inviteCollaborator(userID rawUserID: String, role: String) async {
        guard !isUpdatingCollaborators, let client, let selected = selectedConversation,
              selected.collaboration.canInvite else { return }
        let userID = rawUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard userID.range(of: #"^[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil,
              ["reviewer", "editor"].contains(role) else {
            collaborationErrorMessage = "Enter a valid Hanasand user ID and choose reviewer or editor."
            return
        }
        isUpdatingCollaborators = true
        defer { isUpdatingCollaborators = false }
        do {
            let updated = try await client.inviteCollaborator(conversationID: selected.id, userID: userID, role: role)
            replace(updated)
            collaborationErrorMessage = nil
        } catch { collaborationErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    func removeCollaborator(userID: String) async {
        guard !isUpdatingCollaborators, let client, let selected = selectedConversation,
              selected.collaboration.canInvite || userID == ownerID else { return }
        isUpdatingCollaborators = true
        defer { isUpdatingCollaborators = false }
        do {
            let response = try await client.removeCollaborator(conversationID: selected.id, userID: userID)
            guard response.ok == true else {
                collaborationErrorMessage = response.error ?? "Unable to update conversation access."
                return
            }
            if let updated = response.conversation { replace(updated) }
            else if userID == ownerID && selected.collaborationRole != "owner" {
                conversations.removeAll { $0.id == selected.id }
                selectedConversationID = conversations.first(where: { $0.archivedAt == nil })?.id ?? conversations.first?.id
                routeConversationID = selectedConversationID
            } else {
                var updated = selected
                updated.collaboration = DesktopAIConversationCollaboration(
                    role: selected.collaboration.role, canInvite: selected.collaboration.canInvite,
                    seatLimit: selected.collaboration.seatLimit,
                    seatCount: max(selected.collaboration.seatCount - 1, 0),
                    remainingSeats: min(selected.collaboration.remainingSeats + 1, selected.collaboration.seatLimit),
                    collaborators: selected.collaboration.collaborators.filter { $0.userId != userID })
                replace(updated)
            }
            collaborationErrorMessage = nil
        } catch { collaborationErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    private func refreshReleaseHistory(conversationID: String, client: DesktopAIWorkspaceClient) async {
        do { releases = try await client.loadReleases(conversationID: conversationID).releases }
        catch { deploymentNotice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    private func attachWorkspace(id: String, kind: String) async {
        guard let client, let settingsSnapshot, var selected = selectedConversation, selected.canWrite else { return }
        var previous: DesktopAIConversation?
        do {
            let context = try await ShareChatContextClient(settings: settingsSnapshot).load(shareID: id)
            previous = selected
            selected.workspaceId = id
            selected.workspaceKind = kind
            selected.shareIds = context.shareIds
            selected.workspaceMeta["selectedFilePath"] = context.selectedFilePath.map(DesktopAIJSONValue.string) ?? .null
            if kind == "repo", let repository = repositories.first(where: { $0.id == id }) {
                selected.workspaceMeta["repositoryId"] = .string(repository.id)
                selected.workspaceMeta["repositoryName"] = .string(repository.fullName)
                selected.workspaceMeta["repositoryBranch"] = .string(repository.branch)
                selected.workspaceMeta["repositorySourceUrl"] = .string(repository.sourceUrl)
            }
            selected.updatedAt = ISO8601DateFormatter().string(from: Date())
            replace(selected)
            try await client.updateConversation(selected)
            sharePromptContexts[selected.id] = context.promptContext
            errorMessage = nil
        } catch {
            if let previous { replace(previous) }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func refresh(settings: HanasandDesktopSettings) async {
        guard !isLoading else { return }
        isLoading = true; errorMessage = nil; isUnavailable = false
        chatGPTPollTask?.cancel()
        chatGPTClient = nil
        chatGPTMembership = .loading
        chatGPTActivityConversationID = nil
        chatGPTItems = []
        chatGPTActivityError = nil
        chatGPTSubmissionUncertain = false
        defer { isLoading = false }
        do {
            let api = try DesktopAIWorkspaceClient(settings: settings)
            let workspace = try await api.loadWorkspace()
            guard !Task.isCancelled else { return }
            client = api; ownerID = settings.userID; settingsSnapshot = settings
            do {
                let portal = try ChatGPTPromptPortalClient(settings: settings)
                chatGPTClient = portal
                chatGPTMembership = try await portal.hasActiveHanasandMembership() ? .member : .nonmember
            } catch {
                chatGPTClient = nil
                chatGPTMembership = .error((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            conversations = workspace.conversations.sorted { $0.updatedAt > $1.updatedAt }
            repositories = workspace.repositories
            deployments = workspace.deployments
            releases = workspace.releases
            deployQuota = workspace.deployQuota
            do {
                shares = try await api.loadShares()
                shareErrorMessage = nil
            } catch {
                shares = []
                shareErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            availableModelNames = workspace.connectedModelNames
            if let routeConversationID {
                selectedConversationID = routeConversationID
            } else if selectedConversationID == nil || !conversations.contains(where: { $0.id == selectedConversationID }) {
                selectedConversationID = conversations.first(where: { $0.archivedAt == nil })?.id ?? conversations.first?.id
            }
            chatGPTActivityConversationID = nil
            chatGPTItems = []
            chatGPTSubmissionUncertain = false
            startChatGPTPolling()
            await refreshDeploymentData()
            if createRouteShareConversation, !didCreateRouteShareConversation, let routeShareID {
                let shareContext = try await ShareChatContextClient(settings: settings).load(
                    shareID: routeShareID,
                    selectedFileID: routeShareFileID,
                    selectedFilePath: routeShareFilePath
                )
                if let existing = conversations.first(where: {
                    $0.workspaceKind == "share" && $0.workspaceId == routeShareID
                }) {
                    selectedConversationID = existing.id
                    routeConversationID = existing.id
                    sharePromptContexts[existing.id] = shareContext.promptContext
                } else {
                    let conversation = shareContext.makeConversation(ownerID: ownerID)
                    try await api.saveConversation(conversation)
                    conversations.insert(conversation, at: 0)
                    selectedConversationID = conversation.id
                    routeConversationID = conversation.id
                    sharePromptContexts[conversation.id] = shareContext.promptContext
                }
                didCreateRouteShareConversation = true
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isUnavailable = conversations.isEmpty
        }
    }

    func createConversation() async {
        guard let client else { errorMessage = "Refresh the AI workspace before starting a chat."; return }
        let conversation = DesktopAIConversation(ownerId: ownerID)
        do {
            try await client.saveConversation(conversation)
            conversations.insert(conversation, at: 0); selectedConversationID = conversation.id; routeConversationID = conversation.id
            errorMessage = nil
        } catch { errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    func renameSelected(_ title: String) async {
        guard let client, var selected = selectedConversation else { return }
        let clean = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !clean.isEmpty, selected.canWrite else { return }
        let previous = selected
        selected.title = clean; selected.updatedAt = ISO8601DateFormatter().string(from: Date())
        replace(selected)
        do { try await client.updateConversation(selected); errorMessage = nil }
        catch { replace(previous); errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    func setArchived(_ archived: Bool) async {
        guard let client, var selected = selectedConversation, selected.canWrite else { return }
        let previous = selected
        selected.archivedAt = archived ? ISO8601DateFormatter().string(from: Date()) : nil
        selected.updatedAt = ISO8601DateFormatter().string(from: Date()); replace(selected)
        do { try await client.updateConversation(selected); errorMessage = nil }
        catch { replace(previous); errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    func deleteSelected() async {
        guard let client, let selected = selectedConversation, selected.canWrite else { return }
        do {
            try await client.deleteConversation(id: selected.id)
            conversations.removeAll { $0.id == selected.id }
            selectedConversationID = conversations.first(where: { $0.archivedAt == nil })?.id ?? conversations.first?.id
            routeConversationID = selectedConversationID; errorMessage = nil
        } catch { errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    func sendPrompt(_ rawPrompt: String) async -> Bool {
        guard !isSending, let client, var conversation = selectedConversation, conversation.canWrite else { return false }
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return false }
        let modelName: String?
        if conversation.modelStrategy == "pinned" {
            guard let preferred = conversation.preferredModel, availableModelNames.contains(preferred) else {
                errorMessage = "Pinned model is unavailable. Choose a connected model or switch strategy to Automatic."
                return false
            }
            modelName = preferred
        } else {
            modelName = [conversation.preferredModel, conversation.activeModel, availableModelNames.first]
                .compactMap { $0 }.first(where: { availableModelNames.contains($0) })
        }
        let shareContext: String
        do {
            shareContext = try await attachedShareContext(for: conversation)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
        isSending = true; defer { isSending = false }; errorMessage = nil
        let user = DesktopAIMessage(role: "user", content: prompt)
        let assistant = DesktopAIMessage(role: "assistant", content: "", pending: true)
        if conversation.messages.isEmpty { conversation.title = String(prompt.prefix(72)) }
        if let modelName { conversation.activeModel = modelName }
        conversation.messages.append(contentsOf: [user, assistant]); conversation.updatedAt = ISO8601DateFormatter().string(from: Date())
        replace(conversation)
        do {
            try await client.updateConversation(conversation)
            try await client.saveMessage(user, conversationID: conversation.id)
            let context = [shareContext].filter { !$0.isEmpty }.joined(separator: "\n\n")
            let history = conversation.messages.dropLast(2).suffix(20).map { message in
                ["role": message.role == "tool" ? "assistant" : message.role, "content": message.content]
            }
            let response: String
            if let modelName {
                let systemContext = [context, "Conversation strategy: \(conversation.modelStrategy). Preferred model: \(conversation.preferredModel ?? "auto")."]
                    .filter { !$0.isEmpty }.joined(separator: "\n\n")
                response = try await client.completePrompt(
                    conversationID: conversation.id,
                    modelName: modelName,
                    messages: [["role": "system", "content": systemContext]] + history + [["role": "user", "content": prompt]]
                )
            } else {
                let historyText = history.map { "\($0["role"] ?? "assistant"): \($0["content"] ?? "")" }.joined(separator: "\n\n")
                response = try await client.respond(prompt: prompt, context: [context, historyText].filter { !$0.isEmpty }.joined(separator: "\n\n"))
            }
            guard var latest = conversations.first(where: { $0.id == conversation.id }),
                  let index = latest.messages.firstIndex(where: { $0.id == assistant.id }) else { return true }
            let toolCalls = DesktopAIWorkspaceToolCall.parse(from: response)
            latest.messages[index].content = DesktopAIWorkspaceToolCall.stripTags(from: response); latest.messages[index].pending = false
            latest.updatedAt = ISO8601DateFormatter().string(from: Date()); replace(latest)
            try await client.saveMessage(latest.messages[index], conversationID: latest.id)
            try await client.updateConversation(latest)
            if !toolCalls.isEmpty {
                pendingToolQueue.append(contentsOf: toolCalls.map { DesktopAIPendingToolAction(id: UUID().uuidString, conversationID: latest.id, call: $0) })
                await continueToolQueue()
            }
            return true
        } catch {
            if var latest = conversations.first(where: { $0.id == conversation.id }),
               let index = latest.messages.firstIndex(where: { $0.id == assistant.id }) {
                latest.messages[index].pending = false; latest.messages[index].error = true
                latest.messages[index].content = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                replace(latest)
            }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    private func replace(_ conversation: DesktopAIConversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) { conversations[index] = conversation }
    }

    private func continueToolQueue() async {
        guard pendingToolAction == nil else { return }
        while let next = pendingToolQueue.first {
            if next.call.requiresConfirmation {
                pendingToolAction = next
                toolActionNotice = nil
                return
            }
            pendingToolQueue.removeFirst()
            await runToolAction(next, confirmed: false)
        }
    }

    private func runToolAction(_ pending: DesktopAIPendingToolAction, confirmed: Bool) async {
        guard !isRunningToolAction, let client,
              let conversation = conversations.first(where: { $0.id == pending.conversationID }) else { return }
        isRunningToolAction = true
        defer { isRunningToolAction = false }
        do {
            let result = try await client.executeTool(pending.call, conversation: conversation, shares: shares, confirmed: confirmed)
            toolActionNotice = result.message
            await saveToolMessage(conversationID: conversation.id, result: result, action: pending.call.action)
        } catch {
            let result = DesktopAIWorkspaceToolResult(ok: false,
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            toolActionNotice = result.message
            await saveToolMessage(conversationID: conversation.id, result: result, action: pending.call.action)
        }
    }

    private func saveToolMessage(conversationID: String, result: DesktopAIWorkspaceToolResult, action: String) async {
        guard var conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        let artifactValues: [DesktopAIJSONValue] = result.artifacts.map { artifact in
            .object([
                "kind": .string(artifact.kind), "title": .string(artifact.title),
                "path": artifact.path.map(DesktopAIJSONValue.string) ?? .null,
                "url": artifact.url.map(DesktopAIJSONValue.string) ?? .null,
                "content": artifact.content.map(DesktopAIJSONValue.string) ?? .null,
            ])
        }
        let message = DesktopAIMessage(role: "tool", content: result.message, error: !result.ok,
            metadata: ["tool": .string(action), "toolState": .string(result.ok ? "completed" : "error"),
                       "artifacts": .array(artifactValues)])
        conversation.messages.append(message)
        conversation.updatedAt = ISO8601DateFormatter().string(from: Date())
        replace(conversation)
        do {
            try await client?.saveMessage(message, conversationID: conversationID)
            try await client?.updateConversation(conversation)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func attachedShareContext(for conversation: DesktopAIConversation) async throws -> String {
        guard conversation.workspaceKind == "share" || conversation.workspaceKind == "repo" else { return "" }
        if let cached = sharePromptContexts[conversation.id] { return cached }
        guard let settingsSnapshot,
              let shareID = conversation.workspaceId ?? conversation.shareIds.first else {
            throw ShareChatContextClient.ClientError.invalidShareID
        }
        let selectedPath: String?
        if case .string(let value)? = conversation.workspaceMeta["selectedFilePath"] { selectedPath = value }
        else { selectedPath = nil }
        let context = try await ShareChatContextClient(settings: settingsSnapshot).load(
            shareID: shareID,
            selectedFilePath: selectedPath,
            existingShareIDs: conversation.shareIds
        )
        sharePromptContexts[conversation.id] = context.promptContext
        return context.promptContext
    }
}
