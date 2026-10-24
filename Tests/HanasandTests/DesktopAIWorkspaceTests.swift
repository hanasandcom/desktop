import Foundation
import XCTest
@testable import Hanasand

private actor DesktopAIWorkspaceTransport {
    private var responses: [(Data, Int)]
    private var requestsValue: [URLRequest] = []
    init(_ responses: [(Data, Int)]) { self.responses = responses }
    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        requestsValue.append(request)
        let value = responses.isEmpty ? (Data("{}".utf8), 200) : responses.removeFirst()
        return (value.0, HTTPURLResponse(url: request.url!, statusCode: value.1, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
    func requests() -> [URLRequest] { requestsValue }
}

private actor DesktopAIWorkspaceSocketTransport {
    private(set) var request: URLRequest?
    private(set) var payload: [String: Any]?

    func exchange(_ request: URLRequest, _ payload: String) throws -> String {
        self.request = request
        self.payload = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        return "Model reply"
    }
}

final class DesktopAIWorkspaceTests: XCTestCase {
    private let workspaceJSON = Data(#"{"conversations":[{"id":"chat-1","ownerId":"user-1","title":"Incident review","preferredModel":"model-a","activeModel":"model-a","modelStrategy":"pinned","workspaceId":null,"workspaceKind":null,"shareIds":[],"workspaceMeta":{},"messages":[{"id":"m1","role":"user","content":"Review this alert","createdAt":"2026-10-23T09:00:00Z"},{"id":"m2","role":"assistant","content":"I will review it.","pending":false,"metadata":{"artifacts":[{"kind":"link","title":"Details"}]},"createdAt":"2026-10-23T09:01:00Z"}],"collaboration":{"role":"reviewer","canInvite":false,"seatLimit":5,"seatCount":1,"remainingSeats":4,"collaborators":[]},"archivedAt":null,"createdAt":"2026-10-23T08:00:00Z","updatedAt":"2026-10-23T09:01:00Z"}],"repositories":[{"id":"repo-1","name":"desktop","fullName":"hanasandcom/desktop","branch":"main","sourceUrl":"https://github.com/hanasandcom/desktop","syncStatus":"ready"}],"deployments":[],"releases":[],"runtimeState":{"connectedClientCount":1}}"#.utf8)

    func testWorkspaceDecodesRouteConversationMessagesAndReadOnlyRole() throws {
        let workspace = try JSONDecoder().decode(DesktopAIWorkspace.self, from: workspaceJSON)
        let conversation = try XCTUnwrap(workspace.conversations.first)
        XCTAssertEqual(conversation.id, "chat-1")
        XCTAssertEqual(conversation.title, "Incident review")
        XCTAssertEqual(conversation.messages.count, 2)
        XCTAssertEqual(conversation.messages.last?.role, "assistant")
        XCTAssertFalse(conversation.canWrite)
        XCTAssertEqual(workspace.repositories.first?.fullName, "hanasandcom/desktop")
        XCTAssertEqual(workspace.connectedModelNames, [])
    }

    func testWorkspaceDecodesLiveConnectedModels() throws {
        let data = Data(#"{"conversations":[],"repositories":[],"runtimeState":{"connectedModelNames":["model-b","model-a","",4]}}"#.utf8)
        let workspace = try JSONDecoder().decode(DesktopAIWorkspace.self, from: data)
        XCTAssertEqual(workspace.connectedModelNames, ["model-a", "model-b"])
    }

    func testWorkspaceRequestUsesAuthenticatedAIAPIContractAndNoCookies() async throws {
        let transport = DesktopAIWorkspaceTransport([(workspaceJSON, 200)])
        let client = try DesktopAIWorkspaceClient(settings: settings(), send: { request in try await transport.send(request) })
        let workspace = try await client.loadWorkspace()
        XCTAssertEqual(workspace.conversations.first?.id, "chat-1")

        let sent = await transport.requests()
        let request = try XCTUnwrap(sent.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.host, "api.hanasand.com")
        XCTAssertEqual(request.url?.path, "/api/ai/workspace")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "id"), "user-1")
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    func testConversationUpdateAndMessageWritesUseWebsiteRESTPaths() async throws {
        let transport = DesktopAIWorkspaceTransport([(Data("{}".utf8), 200), (Data("{}".utf8), 200)])
        let client = try DesktopAIWorkspaceClient(settings: settings(), send: { request in try await transport.send(request) })
        var conversation = DesktopAIConversation(id: "chat-1", ownerId: "user-1", title: "Updated title")
        conversation.archivedAt = "2026-10-24T10:00:00Z"
        try await client.updateConversation(conversation)
        let message = DesktopAIMessage(id: "m3", role: "assistant", content: "Saved reply")
        try await client.saveMessage(message, conversationID: conversation.id)

        let requests = await transport.requests()
        XCTAssertEqual(requests.map(\.httpMethod), ["PUT", "PUT"])
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/ai/conversations/chat-1", "/api/ai/conversations/chat-1/messages"])
        let body = try XCTUnwrap(requests.first?.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["title"] as? String, "Updated title")
        XCTAssertEqual(object["archivedAt"] as? String, "2026-10-24T10:00:00Z")
    }

    func testNativeReplyUsesConfiguredTextEndpointAndPersistsContextFields() async throws {
        let reply = Data(#"{"status":"ok","message":"Here is the analysis."}"#.utf8)
        let transport = DesktopAIWorkspaceTransport([(reply, 200)])
        let client = try DesktopAIWorkspaceClient(settings: settings(), send: { request in try await transport.send(request) })
        let answer = try await client.respond(prompt: "Summarize the incident", context: "user: Service is down")
        XCTAssertEqual(answer, "Here is the analysis.")
        let requests = await transport.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/tools/ai")
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(payload["prompt"], "Summarize the incident")
        XCTAssertEqual(payload["context"], "user: Service is down")
    }

    func testSharePickerSourceUsesWebsiteUserShareEndpoint() async throws {
        let shares = Data(#"[{"id":"share-a","path":"/docs/guide.md","alias":"guide","locked":false}]"#.utf8)
        let transport = DesktopAIWorkspaceTransport([(shares, 200)])
        let client = try DesktopAIWorkspaceClient(settings: settings(), send: { request in try await transport.send(request) })
        let result = try await client.loadShares()
        XCTAssertEqual(result.map(\.id), ["share-a"])
        XCTAssertEqual(result.first?.displayName, "/docs/guide.md")
        let requests = await transport.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/api/share/user/user-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
    }

    func testConnectedModelPromptUsesWebsiteSocketMessageContract() async throws {
        let transport = DesktopAIWorkspaceSocketTransport()
        let client = try DesktopAIWorkspaceClient(
            settings: settings(),
            send: { request in try await DesktopAIWorkspaceTransport([]).send(request) },
            socketResponder: { request, payload in try await transport.exchange(request, payload) }
        )
        let answer = try await client.completePrompt(
            conversationID: "chat-1",
            modelName: "model-a",
            messages: [["role": "system", "content": "Use repository context"], ["role": "user", "content": "Review it"]]
        )
        XCTAssertEqual(answer, "Model reply")
        let capturedRequest = await transport.request
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.scheme, "wss")
        XCTAssertEqual(request.url?.host, "api.hanasand.com")
        XCTAssertEqual(request.url?.path, "/api/client/ws/gpt")
        XCTAssertEqual(request.value(forHTTPHeaderField: "id"), "user-1")
        let capturedPayload = await transport.payload
        let payload = try XCTUnwrap(capturedPayload)
        XCTAssertEqual(payload["type"] as? String, "prompt_request")
        XCTAssertEqual(payload["conversationId"] as? String, "chat-1")
        XCTAssertEqual(payload["clientName"] as? String, "model-a")
        XCTAssertEqual(payload["maxTokens"] as? Int, 1024)
        XCTAssertEqual(payload["temperature"] as? Double, 0.35)
    }

    func testDeploymentStatusRequestsUseWebsitePathsAndConversationFilter() async throws {
        let targets = Data(#"{"targets":[{"id":"vm-1","name":"build-vm"}]}"#.utf8)
        let deployments = Data(#"{"deployments":[],"quota":{"used":2,"limit":8,"remaining":6,"windowMinutes":60,"resetsAt":"2026-10-24T12:00:00Z","activeRunning":1,"maxRunning":3,"runningRemaining":2,"sharedAcrossCollaborators":true}}"#.utf8)
        let releases = Data(#"{"releases":[]}"#.utf8)
        let transport = DesktopAIWorkspaceTransport([(targets, 200), (deployments, 200), (releases, 200)])
        let client = try DesktopAIWorkspaceClient(settings: settings(), send: { request in try await transport.send(request) })

        let loadedTargets = try await client.loadDeploymentTargets()
        let deploymentSnapshot = try await client.loadDeployments(conversationID: "chat 1")
        let releaseSnapshot = try await client.loadReleases(conversationID: "chat 1")

        XCTAssertEqual(loadedTargets.map(\.name), ["build-vm"])
        XCTAssertEqual(deploymentSnapshot.quota?.remaining, 6)
        XCTAssertTrue(deploymentSnapshot.quota?.sharedAcrossCollaborators == true)
        XCTAssertTrue(releaseSnapshot.releases.isEmpty)
        let requests = await transport.requests()
        XCTAssertEqual(requests[0].url?.path, "/api/vms/agent/targets")
        XCTAssertEqual(requests[1].url?.path, "/api/ai/deployments")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(requests[1].url), resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "conversationId", value: "chat 1")])
        XCTAssertEqual(requests[2].url?.path, "/api/ai/releases")
    }

    func testStartDeploymentUsesWebsiteRequestBodyAndSurfacesQuotaRejection() async throws {
        let accepted = Data(#"{"deployment":{"id":"deploy-1","ownerId":"user-1","conversationId":"chat-1","vmName":"build-vm","serviceName":"web","stackType":"nextjs_docker","accessPolicy":"owner_only","status":"running","events":[{"stage":"healthcheck","message":"ready","timestamp":"2026-10-24T10:00:00Z"}],"createdAt":"2026-10-24T09:59:00Z","updatedAt":"2026-10-24T10:00:00Z"}}"#.utf8)
        let rejected = Data(#"{"error":"Launch check quota reached.","quota":{"used":8,"limit":8,"remaining":0,"windowMinutes":60,"resetsAt":"2026-10-24T12:00:00Z","activeRunning":2,"maxRunning":3,"runningRemaining":1,"sharedAcrossCollaborators":false}}"#.utf8)
        let transport = DesktopAIWorkspaceTransport([(accepted, 202), (rejected, 429)])
        let client = try DesktopAIWorkspaceClient(settings: settings(), send: { request in try await transport.send(request) })

        let started = try await client.startDeployment(conversationID: "chat-1", vmName: "build-vm", port: 3000,
            healthPath: "/ready", accessPolicy: "collaborators", environment: "staging")
        XCTAssertEqual(started.response.deployment?.status, "running")
        XCTAssertEqual(started.statusCode, 202)
        let quotaFailure = try await client.startDeployment(conversationID: "chat-1", vmName: "build-vm", port: 3000,
            healthPath: "/ready", accessPolicy: "owner_only", environment: "production")
        XCTAssertEqual(quotaFailure.statusCode, 429)
        XCTAssertEqual(quotaFailure.response.error, "Launch check quota reached.")
        XCTAssertEqual(quotaFailure.response.quota?.remaining, 0)

        let requests = await transport.requests()
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "POST"])
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/ai/deployments", "/api/ai/deployments"])
        let body = try XCTUnwrap(requests.first?.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["conversationId"] as? String, "chat-1")
        XCTAssertEqual(payload["vmName"] as? String, "build-vm")
        XCTAssertEqual(payload["port"] as? String, "3000")
        XCTAssertEqual(payload["healthPath"] as? String, "/ready")
        XCTAssertEqual(payload["accessPolicy"] as? String, "collaborators")
        XCTAssertEqual(payload["environment"] as? String, "staging")
    }

    func testRollbackAndSupportBundleUseWebsiteReleaseEndpoints() async throws {
        let rollback = Data(#"{"release":{"id":"release-1","ownerId":"user-1","conversationId":"chat-1","vmName":"build-vm","stackType":"nextjs_docker","accessPolicy":"owner_only","status":"rollback_target","createdAt":"2026-10-24T09:00:00Z","updatedAt":"2026-10-24T10:00:00Z"}}"#.utf8)
        let bundle = Data(#"{"bundle":{"id":"bundle-1","generatedAt":"2026-10-24T10:00:00Z","requestIds":[],"exports":{"zipLabel":"ZIP"}}}"#.utf8)
        let transport = DesktopAIWorkspaceTransport([(rollback, 200), (bundle, 200)])
        let client = try DesktopAIWorkspaceClient(settings: settings(), send: { request in try await transport.send(request) })
        let updated = try await client.markRollbackTarget(releaseID: "release-1")
        let supportBundle = try await client.loadReleaseSupportBundle(releaseID: "release-1")
        XCTAssertEqual(updated.release?.status, "rollback_target")
        XCTAssertNotNil(supportBundle.bundle)
        let requests = await transport.requests()
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].url?.path, "/api/ai/releases/release-1/rollback")
        XCTAssertEqual(requests[1].httpMethod, "GET")
        XCTAssertEqual(requests[1].url?.path, "/api/ai/releases/release-1/support-bundle")
    }

    func testToolTagParserSeparatesPresentationFromApprovedActions() throws {
        let response = "Inspect it.\n<hanasand-tool>{\"action\":\"read_share\"}</hanasand-tool>\n<hanasand-tool>{\"action\":\"update_share\",\"path\":\"app/page.tsx\",\"content\":\"new file\"}</hanasand-tool>"
        let calls = DesktopAIWorkspaceToolCall.parse(from: response)
        XCTAssertEqual(calls.map(\.action), ["read_share", "update_share"])
        XCTAssertFalse(calls[0].requiresConfirmation)
        XCTAssertTrue(calls[1].requiresConfirmation)
        XCTAssertEqual(calls[1].confirmationSummary, "Replace the contents of app/page.tsx.")
        XCTAssertEqual(DesktopAIWorkspaceToolCall.stripTags(from: response), "Inspect it.")
        XCTAssertTrue(DesktopAIWorkspaceToolCall.parse(from: #"<hanasand-tool>{"action":"unknown"}</hanasand-tool>"#).isEmpty)
    }

    func testShareEditToolRequiresConfirmationAndUsesAuthenticatedShareAPI() async throws {
        let currentFile = Data(#"{"id":"file-1","path":"app/page.tsx","content":"old","locked":false}"#.utf8)
        let updatedFile = Data(#"{"id":"file-1","path":"app/page.tsx","content":"new","locked":false}"#.utf8)
        let transport = DesktopAIWorkspaceTransport([(currentFile, 200), (updatedFile, 200)])
        let client = try DesktopAIWorkspaceClient(settings: settings(), send: { request in try await transport.send(request) })
        let call = try XCTUnwrap(DesktopAIWorkspaceToolCall.parse(from: #"<hanasand-tool>{"action":"update_share","shareId":"file-1","path":"app/page.tsx","content":"new"}</hanasand-tool>"#).first)
        let conversation = DesktopAIConversation(id: "chat-1", ownerId: "user-1")

        let denied = try await client.executeTool(call, conversation: conversation, shares: [], confirmed: false)
        XCTAssertFalse(denied.ok)
        let deniedRequests = await transport.requests()
        XCTAssertTrue(deniedRequests.isEmpty)
        let accepted = try await client.executeTool(call, conversation: conversation, shares: [], confirmed: true)
        XCTAssertTrue(accepted.ok)
        let requests = await transport.requests()
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "PUT"])
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/share/file-1", "/api/share/file-1"])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests.last?.httpBody)) as? [String: Any])
        XCTAssertEqual(payload["path"] as? String, "app/page.tsx")
        XCTAssertEqual(payload["content"] as? String, "new")
    }

    func testHTTPAndBrowserToolsUseWebsiteAIContracts() async throws {
        let httpResponse = Data(#"{"status":200,"ok":true,"body":"ready"}"#.utf8)
        let browserResponse = Data(#"{"ok":true,"url":"https://example.com","title":"Example","textExcerpt":"Hello","screenshotPath":null,"consoleMessages":["No JS"],"pageErrors":[]}"#.utf8)
        let transport = DesktopAIWorkspaceTransport([(httpResponse, 200), (browserResponse, 200)])
        let client = try DesktopAIWorkspaceClient(settings: settings(), send: { request in try await transport.send(request) })
        let conversation = DesktopAIConversation(id: "chat-1", ownerId: "user-1")
        let httpCall = try XCTUnwrap(DesktopAIWorkspaceToolCall.parse(from: #"<hanasand-tool>{"action":"http_request","url":"https://example.com/health","method":"GET","headers":{"Accept":"application/json"}}</hanasand-tool>"#).first)
        let browserCall = try XCTUnwrap(DesktopAIWorkspaceToolCall.parse(from: #"<hanasand-tool>{"action":"browser_task","url":"https://example.com","timeoutMs":5000}</hanasand-tool>"#).first)
        let httpResult = try await client.executeTool(httpCall, conversation: conversation, shares: [], confirmed: false)
        let browserResult = try await client.executeTool(browserCall, conversation: conversation, shares: [], confirmed: false)
        XCTAssertTrue(httpResult.ok)
        XCTAssertTrue(browserResult.ok)
        XCTAssertEqual(browserResult.artifacts.first?.url, "https://example.com")
        let requests = await transport.requests()
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/tools/http/request", "/api/tools/browser/task"])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[0].httpBody)) as? [String: Any])
        XCTAssertEqual(payload["url"] as? String, "https://example.com/health")
        XCTAssertEqual(payload["method"] as? String, "GET")
        XCTAssertEqual((payload["headers"] as? [String: String])?["Accept"], "application/json")
    }

    func testVMAndProjectToolMutationsRequireConfirmationAndMockAllRequests() async throws {
        let vmResponse = Data(#"{"name":"sample-app","status":"creating"}"#.utf8)
        let transport = DesktopAIWorkspaceTransport([(vmResponse, 201)])
        let client = try DesktopAIWorkspaceClient(settings: settings(), send: { request in try await transport.send(request) })
        let conversation = DesktopAIConversation(id: "chat-1", ownerId: "user-1", title: "Sample App")
        let createVM = try XCTUnwrap(DesktopAIWorkspaceToolCall.parse(from: #"<hanasand-tool>{"action":"create_vm","vmName":"sample-app"}</hanasand-tool>"#).first)
        XCTAssertTrue(createVM.requiresConfirmation)
        let denied = try await client.executeTool(createVM, conversation: conversation, shares: [], confirmed: false)
        XCTAssertFalse(denied.ok)
        let deniedRequests = await transport.requests()
        XCTAssertTrue(deniedRequests.isEmpty)
        let created = try await client.executeTool(createVM, conversation: conversation, shares: [], confirmed: true)
        XCTAssertTrue(created.ok)
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].url?.path, "/api/vm")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[0].httpBody)) as? [String: String])
        XCTAssertEqual(payload["name"], "sample-app")
    }

    func testCreateProjectPollsProvisioningAndReturnsNativePreviewArtifact() async throws {
        let package = #"{"name":"sample-app","dependencies":{"next":"16.2.3","react":"19.2.5","react-dom":"19.2.5"},"scripts":{"build":"next build","start":"next start --hostname 0.0.0.0 --port 3000"}}"#
        let toolData = try JSONSerialization.data(withJSONObject: [
            "action": "create_project", "projectName": "Sample App", "vmName": "sample-app",
            "projectFiles": [["path": "package.json", "content": package], ["path": "app/page.tsx", "content": "export default function Page() { return <main>Hi</main> }"]],
        ])
        let tag = "<hanasand-tool>\(String(decoding: toolData, as: UTF8.self))</hanasand-tool>"
        let call = try XCTUnwrap(DesktopAIWorkspaceToolCall.parse(from: tag).first)
        let status = Data(#"[{"status":"Running","status_reason":"Ready"}]"#.utf8)
        let services = Data(#"{"services":[{"port":3000}],"portAlias":"<port>-sample-app.hanasand.com"}"#.utf8)
        let transport = DesktopAIWorkspaceTransport([
            (Data("{}".utf8), 200), (Data("{}".utf8), 200), (Data("{}".utf8), 200),
            (Data("{}".utf8), 200), (Data("{}".utf8), 200), (status, 200), (services, 200),
        ])
        let client = try DesktopAIWorkspaceClient(settings: settings(), send: { request in try await transport.send(request) }, toolDelay: { _ in })
        let conversation = DesktopAIConversation(id: "chat-1", ownerId: "user-1", title: "Sample App")
        let result = try await client.executeTool(call, conversation: conversation, shares: [], confirmed: true)
        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.message.contains("Preview: http://3000-sample-app.hanasand.com"))
        XCTAssertEqual(result.artifacts.last?.url, "http://3000-sample-app.hanasand.com")
        let requests = await transport.requests()
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/api/share", "/api/share", "/api/share", "/api/share", "/api/vm", "/api/vm/sample-app", "/api/vm/sample-app/public-services",
        ])
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "POST", "POST", "POST", "POST", "GET", "GET"])
        let vmBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[4].httpBody)) as? [String: Any])
        XCTAssertEqual(vmBody["os"] as? String, "ubuntu-24.04")
        XCTAssertEqual(vmBody["services"] as? [String], ["nodejs"])
        XCTAssertEqual((vmBody["resources"] as? [String: String])?["memory"], "4GiB")
    }

    func testHttpCheckpointPayloadCarriesExplicitApprovalAndSurfacesBackendDecision() async throws {
        let decision = Data(#"{"error":"HTTP POST can mutate remote state and needs explicit approval.","decision":{"status":"checkpoint_required","risk":"high","requiredApproval":"explicit_user_checkpoint","reason":"HTTP POST can mutate remote state and needs explicit approval."}}"#.utf8)
        let transport = DesktopAIWorkspaceTransport([(decision, 409)])
        let client = try DesktopAIWorkspaceClient(settings: settings(), send: { request in try await transport.send(request) })
        let call = try XCTUnwrap(DesktopAIWorkspaceToolCall.parse(from: #"<hanasand-tool>{"action":"http_request","url":"https://example.com/items","method":"POST","body":"{}"}</hanasand-tool>"#).first)
        let result = try await client.executeTool(call, conversation: DesktopAIConversation(id: "chat-1", ownerId: "user-1"), shares: [], confirmed: true)
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.message.contains("checkpoint_required"))
        let requests = await transport.requests()
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests.first?.httpBody)) as? [String: Any])
        XCTAssertEqual(payload["approved"] as? Bool, true)
        XCTAssertNil(payload["approvalId"])
    }

    func testScaffoldToolCreatesAndAttachesNextjsDockerWorkspaceWithoutVM() async throws {
        let transport = DesktopAIWorkspaceTransport(Array(repeating: (Data("{}".utf8), 200), count: 20))
        let client = try DesktopAIWorkspaceClient(settings: settings(), send: { request in try await transport.send(request) })
        let call = try XCTUnwrap(DesktopAIWorkspaceToolCall.parse(from: #"<hanasand-tool>{"action":"scaffold_nextjs_docker","projectName":"Northstar Admin"}</hanasand-tool>"#).first)
        let conversation = DesktopAIConversation(id: "chat-1", ownerId: "user-1", title: "Workspace")
        let result = try await client.executeTool(call, conversation: conversation, shares: [], confirmed: true)
        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.message.contains("Next.js + Docker repository `northstar-admin`"))
        let requests = await transport.requests()
        XCTAssertFalse(requests.contains { $0.url?.path == "/api/vm" })
        XCTAssertEqual(requests.last?.httpMethod, "PUT")
        XCTAssertEqual(requests.last?.url?.path, "/api/ai/conversations/chat-1")
        let conversationBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests.last?.httpBody)) as? [String: Any])
        XCTAssertEqual(conversationBody["workspaceKind"] as? String, "share")
        XCTAssertNotNil(conversationBody["workspaceId"] as? String)
        XCTAssertTrue((conversationBody["shareIds"] as? [String])?.contains(conversationBody["workspaceId"] as? String ?? "") == true)
        let packageRequest = try XCTUnwrap(requests.first { request in
            guard let body = request.httpBody,
                  let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
            return payload["name"] as? String == "package.json"
        })
        let packageBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(packageRequest.httpBody)) as? [String: Any])
        XCTAssertTrue((packageBody["content"] as? String)?.contains("next start --hostname 0.0.0.0 --port 3000") == true)
    }

    func testCollaboratorEndpointsMatchWebsiteMethodsAndBody() async throws {
        let added = Data(#"{"conversation":{"id":"chat-1","ownerId":"user-1","collaboration":{"role":"owner","canInvite":true,"seatLimit":5,"seatCount":2,"remainingSeats":3,"collaborators":[{"userId":"user-2","name":"Reviewer","role":"reviewer"}]}}}"#.utf8)
        let removed = Data(#"{"ok":true,"conversation":{"id":"chat-1","ownerId":"user-1","collaboration":{"role":"owner","canInvite":true,"seatLimit":5,"seatCount":1,"remainingSeats":4,"collaborators":[]}}}"#.utf8)
        let transport = DesktopAIWorkspaceTransport([(added, 200), (removed, 200)])
        let client = try DesktopAIWorkspaceClient(settings: settings(), send: { request in try await transport.send(request) })
        let invited = try await client.inviteCollaborator(conversationID: "chat-1", userID: "user-2", role: "reviewer")
        let deleted = try await client.removeCollaborator(conversationID: "chat-1", userID: "user-2")
        XCTAssertEqual(invited.collaboration.collaborators.first?.userId, "user-2")
        XCTAssertEqual(deleted.ok, true)
        let requests = await transport.requests()
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "DELETE"])
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/ai/conversations/chat-1/collaborators", "/api/ai/conversations/chat-1/collaborators/user-2"])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[0].httpBody)) as? [String: String])
        XCTAssertEqual(payload["userId"], "user-2")
        XCTAssertEqual(payload["role"], "reviewer")
    }

    @MainActor
    func testViewModelPersistsModelAndStrategyPreferences() async throws {
        let transport = DesktopAIWorkspaceTransport([(Data("{}".utf8), 200), (Data("{}".utf8), 200)])
        let client = try DesktopAIWorkspaceClient(settings: settings(), send: { request in try await transport.send(request) })
        let conversation = DesktopAIConversation(id: "chat-1", ownerId: "user-1")
        let viewModel = DesktopAIWorkspaceViewModel(client: client, ownerID: "user-1", conversations: [conversation], availableModelNames: ["model-a"])
        await viewModel.setPreferredModel("model-a")
        await viewModel.setModelStrategy("pinned")

        XCTAssertEqual(viewModel.selectedConversation?.preferredModel, "model-a")
        XCTAssertEqual(viewModel.selectedConversation?.modelStrategy, "pinned")
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
        let savedBodies = try requests.map { request -> [String: Any] in
            let body = try XCTUnwrap(request.httpBody)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        }
        XCTAssertEqual(savedBodies.last?["preferredModel"] as? String, "model-a")
        XCTAssertEqual(savedBodies.last?["modelStrategy"] as? String, "pinned")
    }

    @MainActor
    func testReviewerCannotChangeModelPreferences() async throws {
        let transport = DesktopAIWorkspaceTransport([])
        let client = try DesktopAIWorkspaceClient(settings: settings(), send: { request in try await transport.send(request) })
        let json = try JSONDecoder().decode(DesktopAIConversation.self, from: Data(#"{"id":"chat-1","ownerId":"user-1","collaboration":{"role":"reviewer"}}"#.utf8))
        let viewModel = DesktopAIWorkspaceViewModel(client: client, ownerID: "user-1", conversations: [json], availableModelNames: ["model-a"])
        await viewModel.setPreferredModel("model-a")
        await viewModel.setModelStrategy("pinned")
        XCTAssertNil(viewModel.selectedConversation?.preferredModel)
        XCTAssertEqual(viewModel.selectedConversation?.modelStrategy, "auto")
        let requests = await transport.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testImpersonationIsRejectedAndPermissionErrorsAreReadable() async throws {
        var impersonated = settings(); impersonated.impersonationToken = "other-user"
        XCTAssertThrowsError(try DesktopAIWorkspaceClient(settings: impersonated))

        let transport = DesktopAIWorkspaceTransport([(Data("{}".utf8), 403)])
        let client = try DesktopAIWorkspaceClient(settings: settings(), send: { request in try await transport.send(request) })
        do {
            _ = try await client.loadWorkspace()
            XCTFail("Expected permission error")
        } catch let error as DesktopAIWorkspaceClient.ClientError {
            XCTAssertEqual(error.errorDescription, "Your session cannot access the AI workspace. Sign in again or check your account permissions.")
        }
    }

    private func settings() -> HanasandDesktopSettings {
        var value = HanasandDesktopSettings()
        value.apiBaseURL = "https://api.hanasand.com/api"
        value.userID = "user-1"
        value.authToken = "test-token"
        value.aiAPIURL = "https://api.hanasand.com/api/tools/ai"
        return value
    }
}
