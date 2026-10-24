import Combine
import Foundation

@MainActor
final class AIMetricsClient: ObservableObject {
    @Published private(set) var state = AIMetricsSnapshot()
    @Published private(set) var promptPhase: AIMetricPromptPhase = .ready
    @Published private(set) var promptOutput = ""
    @Published private(set) var promptMessages: [AIMetricPromptMessage] = []
    @Published private(set) var selectedClient = ""
    @Published private(set) var promptError = ""
    private var settings: HanasandDesktopSettings
    private var scope: String
    private var socket: URLSessionWebSocketTask?
    private var promptSocket: URLSessionWebSocketTask?
    private var timer: Timer?
    private var readTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var promptTask: Task<Void, Never>?
    private var conversationID = UUID().uuidString
    private var snapshotSeen = false
    private var promptSent = false
    private var manualReviewPassed = false
    private var reviewGate = AIMetricReviewGate()

    init(settings: HanasandDesktopSettings) {
        self.settings = settings; self.scope = Self.scopeKey(settings)
    }
    deinit { timer?.invalidate(); socket?.cancel(with: .goingAway, reason: nil) }
    static func scopeKey(_ settings: HanasandDesktopSettings) -> String {
        [settings.apiBaseURL, settings.websiteBaseURL, settings.userID, settings.authToken,
         settings.impersonationToken, settings.impersonatingUserID, settings.selectedOrganizationID].joined(separator: "\u{1f}")
    }
    func update(settings: HanasandDesktopSettings) {
        let next = Self.scopeKey(settings)
        guard scope != next else { self.settings = settings; return }
        stop(); self.settings = settings; scope = next; state = AIMetricsSnapshot(); clearPrompt(); reviewGate.resetScope()
        start()
    }
    func start() {
        guard timer == nil else { return }
        refresh(manual: false); connect()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh(manual: false) } }
    }
    func stop() {
        timer?.invalidate(); timer = nil; readTask?.cancel(); readTask = nil
        receiveTask?.cancel(); receiveTask = nil; promptTask?.cancel(); promptTask = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil; promptSocket?.cancel(with: .goingAway, reason: nil); promptSocket = nil; snapshotSeen = false
        if promptSent { reviewGate.markUncertain(); promptPhase = .uncertain; promptError = "The test may have been submitted. Refresh and review before another test." }
        state.liveState = "Disconnected"
    }
    func refresh(manual: Bool) {
        if AIMetricLiveRecovery.shouldReconnect(onManualRefresh: manual, liveState: state.liveState, promptPhase: promptPhase) {
            snapshotSeen = false
            if promptPhase == .uncertain { manualReviewPassed = false }
            receiveTask?.cancel(); receiveTask = nil; socket?.cancel(with: .goingAway, reason: nil); socket = nil; connect()
        }
        readTask?.cancel(); let capturedScope = scope, current = settings
        state.loading = true
        readTask = Task { [weak self] in
            guard let self else { return }
            async let models = self.get("ai/models", settings: current)
            async let economics = self.getSite("api/backend/ai/economics?days=30", settings: current)
            async let docker = self.get("docker", settings: current)
            let modelResult = await models, economicsResult = await economics, dockerResult = await docker
            guard !Task.isCancelled, capturedScope == self.scope else { return }
            var errors: [String] = []
            do { self.state.clients = try self.parseClients(modelResult.get()) } catch { errors.append("Models: \(error.localizedDescription)") }
            do { self.state.economics = try self.parseEconomics(economicsResult.get()) } catch { self.state.economics = nil; errors.append("Economics: \(error.localizedDescription)") }
            do { self.state.containers = try self.parseContainers(dockerResult.get()) } catch { self.state.containers = nil; errors.append("Containers: \(error.localizedDescription)") }
            self.state.errors = errors; self.state.lastRead = Date.now.formatted(date: .omitted, time: .shortened); self.state.loading = false
            if manual && errors.isEmpty { self.manualReviewPassed = true; self.reviewGate.markManualHTTPReview(succeeded: true); self.clearUncertainIfReviewed() }
        }
    }
    func endpoint(_ base: String, _ path: String) throws -> URL {
        guard let baseURL = URL(string: base), baseURL.scheme == "https", baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil, let host = baseURL.host else { throw AIMetricsError.unavailable("Configure a secure API address before loading AI telemetry.") }
        var root = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        root.path = root.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = root.path.isEmpty ? "" : "/\(root.path)"
        root.path = prefix + "/" + parts[0]
        if parts.count > 1 { root.percentEncodedQuery = String(parts[1]) }
        guard let url = root.url, url.host == host else { throw AIMetricsError.unavailable("Invalid AI telemetry address.") }
        return url
    }
    func request(_ url: URL, settings: HanasandDesktopSettings) throws -> URLRequest {
        guard !settings.authToken.isEmpty, !settings.userID.isEmpty else { throw AIMetricsError.http(401) }
        var request = URLRequest(url: url, timeoutInterval: 20); request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept"); request.setValue("Bearer \(settings.authToken)", forHTTPHeaderField: "Authorization"); request.setValue(settings.userID, forHTTPHeaderField: "id")
        if !settings.impersonationToken.isEmpty { request.setValue(settings.impersonationToken, forHTTPHeaderField: "x-impersonation-token") }
        if !settings.selectedOrganizationID.isEmpty && settings.selectedOrganizationID != "personal" { request.setValue(settings.selectedOrganizationID, forHTTPHeaderField: "x-organization-id") }
        return request
    }
    private func get(_ path: String, settings: HanasandDesktopSettings) async -> Result<Data, Error> {
        do { return .success(try await load(request(try endpoint(settings.apiBaseURL, path), settings: settings))) } catch { return .failure(error) }
    }
    private func getSite(_ path: String, settings: HanasandDesktopSettings) async -> Result<Data, Error> {
        do { return .success(try await load(request(try endpoint(settings.websiteBaseURL, path), settings: settings))) } catch { return .failure(error) }
    }
    private func load(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AIMetricsError.unavailable("AI telemetry returned no HTTP response.") }
        guard (200..<300).contains(response.statusCode) else { throw AIMetricsError.http(response.statusCode) }
        _ = try AIMetricsValidation.boundedJSON(data); return data
    }
    func parseClients(_ data: Data) throws -> [AIMetricClient] {
        let root = try AIMetricsValidation.record(AIMetricsValidation.boundedJSON(data))
        guard let rows = root["connected"] as? [Any], rows.count <= 512 else { throw AIMetricsError.invalid("Model discovery response is invalid.") }
        return try rows.map { row in
            var enriched = AIMetricsValidation.record(row)
            // The HTTP model list is intentionally sparse; live updates supply sensor and lane fields.
            if enriched["power"] == nil { enriched["power"] = [:] }
            ["ram", "cpu", "gpu", "lanes"].forEach { key in if enriched[key] == nil { enriched[key] = NSNull() } }
            return try AIMetricsValidation.client(enriched)
        }
    }
    func parseEconomics(_ data: Data) throws -> AIMetricEconomics {
        let root = AIMetricsValidation.record(try AIMetricsValidation.boundedJSON(data)), reliability = AIMetricsValidation.record(root["reliability"]), timing = AIMetricsValidation.record(reliability["promptTiming"])
        guard let queue = reliability["queueDepth"] as? [[String: Any]], queue.count <= 10_000 else { throw AIMetricsError.invalid("Queue telemetry is unavailable. Refresh to try again.") }
        let rows = queue.map { AIMetricQueueRow(lane: AIMetricsValidation.text($0["lane"]), model: AIMetricsValidation.text($0["model"]), kind: AIMetricsValidation.text($0["kind"]), status: AIMetricsValidation.text($0["status"]), count: AIMetricsValidation.number($0["count"])) }
        return AIMetricEconomics(windowDays: AIMetricsValidation.number(root["windowDays"]), firstOutputP50: AIMetricsValidation.number(timing["p50FirstUsefulOutputMs"]), firstOutputP95: AIMetricsValidation.number(timing["p95FirstUsefulOutputMs"]), sampleCount: AIMetricsValidation.number(timing["sampleCount"]), queue: rows)
    }
    func parseContainers(_ data: Data) throws -> AIMetricContainers {
        let outer = AIMetricsValidation.record(try AIMetricsValidation.boundedJSON(data)), nested = AIMetricsValidation.record(outer["data"]), row = nested.isEmpty ? outer : nested
        let rows = (outer["data"] as? [[String: Any]]) ?? (row["containers"] as? [[String: Any]])
        guard let rows, rows.count <= 10_000 else { throw AIMetricsError.invalid("Container telemetry is unavailable. Refresh to try again.") }
        let items = rows.map { item -> AIMetricContainer in let name = AIMetricsValidation.text(item["name"]); let image = AIMetricsValidation.text(item["image"]); return AIMetricContainer(name: name, image: image, status: AIMetricsValidation.text(item["status"]), health: AIMetricsValidation.text(item["health"]).isEmpty ? AIMetricsValidation.text(item["state"]) : AIMetricsValidation.text(item["health"])) }.filter { "\($0.name) \($0.image)".range(of: "(^|_)ai(_|$)|model|parser|gpt", options: [.regularExpression, .caseInsensitive]) != nil }
        return AIMetricContainers(generatedAt: AIMetricsValidation.text(row["generated_at"]), unavailable: AIMetricsValidation.text(row["unavailable_reason"]), items: items)
    }
    private func connect() {
        do {
            let url = try endpoint(settings.apiBaseURL, "client/ws/gpt"); guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
            parts.scheme = "wss"; guard let wsURL = parts.url else { return }
            var req = try request(wsURL, settings: settings); req.timeoutInterval = 20
            let task = URLSession.shared.webSocketTask(with: req); socket = task; state.liveState = "Connecting"; task.resume()
            receiveTask = Task { [weak self, weak task] in
                guard let self, let task else { return }
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive(); let data: Data
                        switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: continue }
                        guard data.count <= AIMetricsValidation.maxBytes else { throw AIMetricsError.invalid("Live AI event exceeded its 2 MiB size limit.") }
                        self.consume(try AIMetricsValidation.event(data))
                    }
                } catch { if !Task.isCancelled { self.state.liveState = "Disconnected"; self.state.errors.append("Live AI telemetry disconnected. HTTP snapshots remain separate.") } }
            }
        } catch { state.errors.append(error.localizedDescription) }
    }
    private func consume(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        switch type {
        case "snapshot":
            if let rows = event["clients"] as? [Any], rows.count <= 512, let values = try? rows.map(AIMetricsValidation.client) { state.clients = values }
            state.participants = AIMetricsValidation.integer(AIMetricsValidation.number(event["participants"])); snapshotSeen = true; state.liveState = "Connected"; reviewGate.markFreshLiveSnapshot(); clearUncertainIfReviewed()
        case "update":
            if let value = event["client"], let client = try? AIMetricsValidation.client(value) { state.clients.removeAll { $0.name == client.name }; state.clients.append(client); state.clients = Array(state.clients.suffix(512)) }
            state.participants = AIMetricsValidation.integer(AIMetricsValidation.number(event["participants"]))
        case "join": state.participants = AIMetricsValidation.integer(AIMetricsValidation.number(event["participants"])); state.liveState = "Connected"
        case "prompt_started", "prompt_delta", "prompt_complete", "prompt_error":
            guard let conversation = event["conversationId"] as? String, conversation == conversationID,
                  (event["clientName"] as? String).map({ $0 == selectedClient }) ?? true else { return }
            if type == "prompt_started" { promptPhase = .running }
            if type == "prompt_delta", let content = event["content"] as? String, promptOutput.utf8.count + content.utf8.count <= AIMetricsValidation.maxBytes { promptOutput += content }
            if type == "prompt_complete" { promptPhase = .completed; promptSent = false; if !promptOutput.isEmpty { promptMessages.append(.init(role: "assistant", content: promptOutput)) } }
            if type == "prompt_error" { promptPhase = .uncertain; promptError = "The submitted prompt returned an error. Refresh and review before another test." }
        default: break
        }
    }
    func select(_ name: String) { guard promptPhase != .connecting && promptPhase != .running && promptPhase != .uncertain else { return }; selectedClient = name; clearPrompt(); conversationID = UUID().uuidString }
    @discardableResult func send(_ text: String) -> Bool {
        guard AIMetricsValidation.canTestPrompt(settings: settings, selectedClient: selectedClient, liveClients: state.clients, hasFreshSnapshot: snapshotSeen && state.liveState == "Connected", requiresReview: reviewGate.requiresReview),
              promptPhase == .ready || promptPhase == .completed else { promptError = "Return to your own account, select a live client, and refresh telemetry before testing."; return false }
        do {
            let messages = try AIMetricsValidation.prompt(text, history: promptMessages)
            let body = try AIMetricsValidation.promptRequest(clientName: selectedClient, conversationID: conversationID, messages: messages)
            let data = try JSONSerialization.data(withJSONObject: body); guard data.count <= 64 * 1024 else { throw AIMetricsError.invalid("Prompt request is too large.") }
            promptMessages = messages; promptOutput = ""; promptError = ""; promptPhase = .connecting; promptSent = false; manualReviewPassed = false
            promptTask = Task { [weak self] in
                guard let self else { return }
                var submitted = false
                var timedOut = false
                var timeoutTask: Task<Void, Never>?
                var testSocket: URLSessionWebSocketTask?
                defer { timeoutTask?.cancel(); testSocket?.cancel(with: .goingAway, reason: nil); self.promptSocket = nil }
                do {
                    let https = try self.endpoint(self.settings.apiBaseURL, "client/ws/gpt")
                    var components = URLComponents(url: https, resolvingAgainstBaseURL: false)!; components.scheme = "wss"
                    guard let wsURL = components.url else { throw AIMetricsError.unavailable("Invalid live AI address.") }
                    let request = try self.request(wsURL, settings: self.settings)
                    let task = URLSession.shared.webSocketTask(with: request); testSocket = task; self.promptSocket = task; task.resume()
                    timeoutTask = AIMetricSocketDeadline.schedule(after: .seconds(15)) { timedOut = true; task.cancel(with: .goingAway, reason: nil) }
                    while !Task.isCancelled {
                        let received = try await task.receive()
                        let eventData: Data
                        switch received { case .data(let value): eventData = value; case .string(let value): eventData = Data(value.utf8); @unknown default: continue }
                        let event = try AIMetricsValidation.event(eventData)
                        guard let type = event["type"] as? String else { continue }
                        if type == "snapshot" && !submitted {
                            let rows = event["clients"] as? [Any] ?? []
                            guard rows.count <= 512 else { throw AIMetricsError.invalid("Live AI snapshot contains too many clients.") }
                            let live = try rows.map(AIMetricsValidation.client)
                            guard live.contains(where: { $0.name == self.selectedClient }) else { throw AIMetricsError.unavailable("Selected model is no longer live; no prompt was sent.") }
                            try Task.checkCancellation()
                            timeoutTask?.cancel()
                            timedOut = false
                            timeoutTask = AIMetricSocketDeadline.schedule(after: .seconds(120)) { timedOut = true; task.cancel(with: .goingAway, reason: nil) }
                            submitted = true; self.promptSent = true
                            try await task.send(.data(data)); self.promptPhase = .running
                            continue
                        }
                        guard submitted, event["conversationId"] as? String == self.conversationID,
                              (event["clientName"] as? String).map({ $0 == self.selectedClient }) ?? true else { continue }
                        if type == "prompt_started" { self.promptPhase = .running }
                        if type == "prompt_delta" || type == "prompt_complete" {
                            let full = event["content"] as? String
                            let next = (full?.isEmpty == false) ? full! : self.promptOutput + (event["delta"] as? String ?? "")
                            guard next.utf8.count <= AIMetricsValidation.maxBytes else { throw AIMetricsError.invalid("Model response exceeded its 2 MiB size limit.") }
                            self.promptOutput = next
                            if type == "prompt_complete" { guard !next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIMetricsError.unavailable("Model completed without text. Refresh before another test.") }; self.promptPhase = .completed; self.promptSent = false; self.reviewGate.resetScope(); self.promptMessages.append(.init(role: "assistant", content: next)); return }
                        }
                        if type == "prompt_error" { throw AIMetricsError.unavailable("Selected model reported an error. Refresh and review before another test.") }
                    }
                    if timedOut && submitted { throw AIMetricsError.unavailable("The submitted test timed out and may still be running. Refresh and review before another test.") }
                    if timedOut { throw AIMetricsError.unavailable("The live model connection timed out before submission; no prompt was sent.") }
                    throw AIMetricsError.unavailable("Live model connection ended before submission; no prompt was sent.")
                } catch {
                    if Task.isCancelled && !submitted { self.promptPhase = .ready; self.promptError = "Test cancelled before submission; no prompt was sent." }
                    else if timedOut && !submitted { self.promptPhase = .failed; self.promptError = "The live model connection timed out before submission; no prompt was sent." }
                    else if submitted { self.reviewGate.markUncertain(); self.promptPhase = .uncertain; self.promptError = timedOut ? "The submitted test timed out and may still be running. Refresh and review before another test." : "The test may have been submitted. Refresh and review before another test." }
                    else { self.promptPhase = .failed; self.promptError = error.localizedDescription }
                }
            }
            return true
        } catch { promptError = error.localizedDescription; return false }
    }
    func cancelPrompt() { if promptSent { reviewGate.markUncertain(); promptPhase = .uncertain; promptError = "The submitted test may still be running. Refresh and review before another test." }; promptTask?.cancel(); promptSocket?.cancel(with: .goingAway, reason: nil) }
    private func clearPrompt() { promptMessages = []; promptOutput = ""; promptError = ""; promptPhase = .ready; promptSent = false }
    private func clearUncertainIfReviewed() { if promptPhase == .uncertain && manualReviewPassed && snapshotSeen { promptPhase = .ready; promptError = ""; promptSent = false; manualReviewPassed = false; reviewGate.resetScope() } }
}
