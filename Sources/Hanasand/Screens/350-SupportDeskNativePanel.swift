import SwiftUI

struct SupportDeskNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var snapshot: SupportDeskSnapshot?
    @State private var filters = SupportDeskFilters()
    @State private var pendingFilters = SupportDeskFilters()
    @State private var messages: [SupportDeskMessage] = []
    @State private var selectedID = ""
    @State private var draft = ""
    @State private var creatingTicket = false
    @State private var createSubject = ""
    @State private var feedbackRating = 5
    @State private var feedbackComment = ""
    @State private var searchOpen = false
    @State private var accountOpen = false
    @State private var password = ""
    @State private var email = ""
    @State private var busy = false
    @State private var revision = 0
    @State private var error = ""
    @State private var notice = ""
    @State private var refreshRequired = false
    @State private var pendingAction: PendingAction?

    private var ticket: SupportDeskTicket? { snapshot?.tickets.first(where: { $0.id == selectedID }) }
    private var canWrite: Bool {
        guard let snapshot, let client = try? makeClient() else { return false }
        return snapshot.scope == client.scope && client.canMutate && !busy && !refreshRequired
    }
    private var isSupport: Bool { snapshot?.isSupport == true }
    private var canReplyToSelected: Bool {
        guard let ticket, let snapshot else { return false }
        return canWrite && ticket.status == "open" && (snapshot.isSupport || ticket.userID == model.userIDForRequests)
    }
    private var visibleTickets: [SupportDeskTicket] {
        (snapshot?.tickets ?? []).filter { item in
            filters.status == .all || (filters.status == .resolved ? item.status == "closed" : item.status != "closed")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NativeGroupPanel(title: isSupport ? "Support Desk" : "Support", subtitle: isSupport ? "Customer conversations · latest 100 maximum" : "Your support conversations", fillsAvailableWidth: true) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { supportActions }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 8) { supportActions }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if snapshot != nil {
                    Text("Refresh to check for new messages or conversations.")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
                }
                if !error.isEmpty { Text(error).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.danger).textSelection(.enabled) }
                if !notice.isEmpty { NativeNotice(message: notice) }
                if refreshRequired { NativeNotice(message: "Refresh and review this conversation before another change. The previous operation may have completed.") }
                if !canWrite && snapshot?.isSupport == true {
                    NativeNotice(message: model.settings.impersonationToken.isEmpty && model.settings.impersonatingUserID.isEmpty
                        ? "Support changes are locked until access is refreshed."
                        : "Read-only while impersonating. Return to your own account before changing conversations.")
                }
            }

            if searchOpen && isSupport { filtersPanel }

            if busy && snapshot == nil { NativeEmptyState(title: "Loading Support", message: "Checking the signed-in account’s support access.") }
            else if creatingTicket && !isSupport { newTicketComposer }
            else if let snapshot, !snapshot.isSupport, let ticket {
                selfServiceConversation(ticket, snapshot: snapshot)
            } else if let snapshot, !snapshot.isSupport {
                selfServiceList(snapshot)
            } else if let ticket {
                conversation(ticket)
            } else if let snapshot {
                NativeGroupPanel(title: "Conversations · \(visibleTickets.count)", subtitle: "\(snapshot.tickets.count) returned by Support") {
                    if visibleTickets.isEmpty { NativeEmptyState(title: "No conversations found", message: "No conversations match this status filter.") }
                    ForEach(visibleTickets) { row in ticketRow(row) }
                }
            } else if !busy {
                NativeEmptyState(title: model.hasHanasandAuth ? "Support unavailable" : "Sign in required", message: model.hasHanasandAuth ? "Refresh to try loading the Support queue." : "Sign in to review Support conversations.")
            }
        }
        .task(id: "\(model.userIDForRequests):\(model.authTokenForRequests):\(model.settings.impersonatingUserID):\(revision)") { await load() }
        .confirmationDialog(pendingAction?.title ?? "Confirm Support action", isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), titleVisibility: .visible) {
            if let pendingAction {
                Button(pendingAction.confirmTitle, role: pendingAction.destructive ? .destructive : nil) { Task { await perform(pendingAction) } }
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: { Text(pendingAction?.message ?? "") }
    }

    @ViewBuilder
    private var supportActions: some View {
        ActionButton(title: busy ? "Working…" : "Refresh", icon: "arrow.clockwise") { revision += 1 }.disabled(busy)
        if isSupport { ActionButton(title: searchOpen ? "Hide filters" : "Find conversations", icon: "line.3.horizontal.decrease.circle") { searchOpen.toggle() }.disabled(busy) }
        else { ActionButton(title: "New support ticket", icon: "plus") { creatingTicket = true; createSubject = ""; draft = ""; selectedID = ""; messages = [] }.disabled(busy || !canWrite) }
        if !selectedID.isEmpty || creatingTicket { ActionButton(title: isSupport ? "Back to queue" : "Back to conversations", icon: "list.bullet") { selectedID = ""; creatingTicket = false; messages = []; accountOpen = false }.disabled(busy) }
    }

    private var filtersPanel: some View {
        NativeGroupPanel(title: "Find conversations", subtitle: "Search, dates and feedback filters are applied on the server.") {
            TextField("Search support conversations", text: $pendingFilters.search).textFieldStyle(.roundedBorder).disabled(busy)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { supportDateFilters }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(spacing: 8) { supportDateFilters }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Picker("Rating", selection: $pendingFilters.stars) { ForEach(SupportDeskStarsFilter.allCases) { Text($0.title).tag($0) } }.disabled(busy)
            Picker("Feedback", selection: $pendingFilters.feedback) { ForEach(SupportDeskFeedbackFilter.allCases) { Text($0.title).tag($0) } }.disabled(busy)
            Picker("Status", selection: $pendingFilters.status) { ForEach(SupportDeskStatusFilter.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).disabled(busy)
            HStack(spacing: 8) {
                ActionButton(title: "Apply filters", icon: "checkmark") { applyFilters() }.disabled(busy)
                ActionButton(title: "Clear filters", icon: "xmark") { pendingFilters = SupportDeskFilters(); applyFilters() }.disabled(busy)
            }
        }
    }

    @ViewBuilder
    private var supportDateFilters: some View {
        TextField("Created from · YYYY-MM-DD", text: $pendingFilters.from).textFieldStyle(.roundedBorder).disabled(busy)
        TextField("Created through · YYYY-MM-DD", text: $pendingFilters.to).textFieldStyle(.roundedBorder).disabled(busy)
    }

    private var newTicketComposer: some View {
        NativeGroupPanel(title: "New support ticket", subtitle: "Your message is sent to the Hanasand Support team.") {
            TextField("Subject", text: $createSubject).textFieldStyle(.roundedBorder).disabled(busy || !canWrite)
            TextField("How can we help?", text: $draft, axis: .vertical).lineLimit(5...12).textFieldStyle(.roundedBorder).disabled(busy || !canWrite)
            ActionButton(title: "Review and send ticket", icon: "paperplane") {
                pendingAction = PendingAction(kind: .create, ticket: nil, body: draft, subject: createSubject)
            }.disabled(!canWrite || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder private func selfServiceList(_ snapshot: SupportDeskSnapshot) -> some View {
        NativeGroupPanel(title: "Your conversations · \(visibleTickets.count)", subtitle: "Only tickets owned by your account are shown.") {
            Picker("Status", selection: $filters.status) { ForEach(SupportDeskStatusFilter.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).disabled(busy)
            if visibleTickets.isEmpty {
                NativeEmptyState(title: "No support conversations", message: "Create a ticket and the Support team will reply here.")
            }
            ForEach(visibleTickets) { row in selfServiceTicketRow(row) }
        }
    }

    private func selfServiceTicketRow(_ row: SupportDeskTicket) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(row.subject).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
            Text("\(row.status == "closed" ? "Resolved" : "Open") · updated \(date(row.updatedAt))")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
            if let last = row.lastMessage, !last.isEmpty { Text(last).font(.system(size: 11)).foregroundStyle(theme.textTertiary).lineLimit(2) }
            ActionButton(title: "Open conversation", icon: "bubble.left.and.bubble.right") {
                selectedID = row.id; draft = ""; feedbackComment = ""; messages = []; Task { await loadMessages(row.id) }
            }.disabled(busy)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(theme.card, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private func selfServiceConversation(_ ticket: SupportDeskTicket, snapshot: SupportDeskSnapshot) -> some View {
        NativeGroupPanel(title: ticket.subject, subtitle: "Your conversation · \(ticket.status == "closed" ? "resolved" : "open") · updated \(date(ticket.updatedAt))") {
            if messages.isEmpty && !busy { NativeEmptyState(title: "No messages returned", message: "Refresh to check this conversation again.") }
            ForEach(messages) { item in
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.senderName).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                    Text(item.body).font(.system(size: 12)).foregroundStyle(theme.textSecondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text(date(item.createdAt)).font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(theme.card, in: RoundedRectangle(cornerRadius: 8))
            }
            if ticket.status == "open" {
                TextField("Write a reply", text: $draft, axis: .vertical).lineLimit(3...8).textFieldStyle(.roundedBorder).disabled(!canReplyToSelected)
                ActionButton(title: "Review and send reply", icon: "paperplane") {
                    pendingAction = PendingAction(kind: .reply, ticket: ticket, body: draft)
                }.disabled(!canReplyToSelected || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else if let rating = ticket.feedbackRating {
                Text("You rated this support conversation \(rating)/5.").font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                if let comment = ticket.feedbackComment, !comment.isEmpty { Text(comment).font(.system(size: 11)).foregroundStyle(theme.textTertiary).textSelection(.enabled) }
            } else if ticket.resolutionVersion != nil {
                Text("How was your support experience?").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                Picker("Rating", selection: $feedbackRating) { ForEach(1...5, id: \.self) { Text("\($0) stars").tag($0) } }.disabled(!canWrite)
                if feedbackRating <= 3 { TextField("Optional feedback", text: $feedbackComment, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder).disabled(!canWrite) }
                ActionButton(title: "Review feedback", icon: "star") {
                    pendingAction = PendingAction(kind: .feedback(feedbackRating), ticket: ticket, body: feedbackComment)
                }.disabled(!canWrite)
            }
            if ticket.status == "closed" {
                ActionButton(title: "New support ticket", icon: "plus") { creatingTicket = true; createSubject = ""; draft = ""; selectedID = ""; messages = [] }.disabled(!canWrite)
            }
        }
    }

    @ViewBuilder private func ticketRow(_ row: SupportDeskTicket) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(row.subject).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
            Text("\(row.userName ?? row.userID ?? "Visitor") · \(row.status == "closed" ? "Resolved" : row.status.capitalized) · \(date(row.updatedAt))")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
            if let last = row.lastMessage, !last.isEmpty { Text(last).font(.system(size: 11)).foregroundStyle(theme.textTertiary).lineLimit(2) }
            ActionButton(title: "Open conversation", icon: "bubble.left.and.bubble.right") { selectedID = row.id; draft = ""; messages = []; accountOpen = false; Task { await loadMessages(row.id) } }.disabled(busy)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(theme.card, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private func conversation(_ ticket: SupportDeskTicket) -> some View {
        NativeGroupPanel(title: ticket.subject, subtitle: "\(ticket.userName ?? ticket.userID ?? "Visitor") · \(ticket.channel ?? "Channel not supplied") · updated \(date(ticket.updatedAt))") {
            if let rating = ticket.feedbackRating { Text("Customer feedback: \(rating)/5\(ticket.feedbackComment.map { $0.isEmpty ? "" : " · \($0)" } ?? "")").font(.system(size: 11)).foregroundStyle(theme.textSecondary) }
            ActionButton(title: ticket.status == "closed" ? "Reopen conversation" : "Resolve conversation", icon: ticket.status == "closed" ? "arrow.uturn.backward" : "checkmark.circle") {
                pendingAction = PendingAction(kind: .status(ticket.status == "closed" ? "open" : "closed"), ticket: ticket)
            }.disabled(!canWrite)

            if messages.isEmpty && !busy { NativeEmptyState(title: "No messages returned", message: "Refresh to check this conversation again.") }
            ForEach(messages) { item in
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.senderName).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                    Text(item.body).font(.system(size: 12)).foregroundStyle(theme.textSecondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text(date(item.createdAt)).font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(theme.card, in: RoundedRectangle(cornerRadius: 8))
            }
            TextField("Reply to customer", text: $draft, axis: .vertical).lineLimit(3...8).textFieldStyle(.roundedBorder).disabled(!canWrite || ticket.status == "closed")
            ActionButton(title: "Review and send reply", icon: "paperplane") {
                pendingAction = PendingAction(kind: .reply, ticket: ticket, body: draft)
            }.disabled(!canWrite || ticket.status == "closed" || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if ticket.userID != nil && ticket.channel == "human" {
                ActionButton(title: accountOpen ? "Hide account changes" : "Customer account changes", icon: "person.crop.circle") { accountOpen.toggle() }.disabled(!canWrite)
                if accountOpen {
                    SecureField("New password · 16 characters minimum", text: $password).textFieldStyle(.roundedBorder).disabled(!canWrite)
                    ActionButton(title: "Review password change", icon: "key") { pendingAction = PendingAction(kind: .account(.password), ticket: ticket, body: password) }.disabled(!canWrite || password.isEmpty)
                    TextField("New email address", text: $email).textFieldStyle(.roundedBorder).disabled(!canWrite)
                    ActionButton(title: "Review email change", icon: "envelope") { pendingAction = PendingAction(kind: .account(.email), ticket: ticket, body: email) }.disabled(!canWrite || email.isEmpty)
                }
            }
        }
    }

    private func applyFilters() {
        do { _ = try SupportDeskClient.filterQuery(pendingFilters); filters = pendingFilters; searchOpen = false; selectedID = ""; messages = []; revision += 1 }
        catch { self.error = error.localizedDescription }
    }

    @MainActor private func load() async {
        guard model.hasHanasandAuth else { snapshot = nil; return }
        busy = true; error = ""; notice = ""; defer { busy = false }
        do {
            let client = try makeClient()
            let next = try await client.loadForCurrentUser(filters: filters)
            guard !Task.isCancelled else { return }
            snapshot = next
            if !next.isSupport && creatingTicket { return }
            if !selectedID.isEmpty && !next.tickets.contains(where: { $0.id == selectedID }) { selectedID = ""; messages = [] }
            if !selectedID.isEmpty { await loadMessages(selectedID) }
            guard !Task.isCancelled else { return }
            refreshRequired = false
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    @MainActor private func loadMessages(_ id: String) async {
        do {
            let client = try makeClient()
            let loaded: [SupportDeskMessage]
            if let snapshot, !snapshot.isSupport, let ticket = snapshot.tickets.first(where: { $0.id == id }) {
                loaded = try await client.ownMessages(snapshot: snapshot, ticket: ticket)
            } else { loaded = try await client.messages(ticketID: id) }
            guard !Task.isCancelled, selectedID == id else { return }
            messages = loaded; error = ""
        } catch { if !Task.isCancelled, selectedID == id { self.error = error.localizedDescription } }
    }

    @MainActor private func perform(_ action: PendingAction) async {
        pendingAction = nil; busy = true; error = ""; notice = ""; defer { busy = false }
        do {
            let client = try makeClient()
            guard let snapshot else { throw SupportDeskClientError.readOnly }
            switch action.kind {
            case .create:
                _ = try await client.createTicket(subject: action.subject, message: action.body)
                creatingTicket = false; createSubject = ""; draft = ""; selectedID = ""
                notice = "Support ticket created. Refresh to review the conversation."
            case .feedback(let rating):
                guard let selected = action.ticket, let current = snapshot.tickets.first(where: { $0 == selected }) else { throw SupportDeskClientError.readOnly }
                try await client.submitFeedback(snapshot: snapshot, ticket: current, rating: rating, comment: action.body)
                notice = "Feedback sent. Thank you."
            case .reply:
                guard let selected = action.ticket, let current = snapshot.tickets.first(where: { $0 == selected }) else { throw SupportDeskClientError.readOnly }
                let requestID = UUID().uuidString.lowercased()
                _ = try await client.reply(snapshot: snapshot, ticket: current, body: action.body, requestID: requestID)
                draft = ""; notice = "Reply sent."
            case .status(let status):
                guard let selected = action.ticket, let current = snapshot.tickets.first(where: { $0 == selected }) else { throw SupportDeskClientError.readOnly }
                try await client.setStatus(snapshot: snapshot, ticket: current, status: status)
                notice = status == "closed" ? "Conversation resolved." : "Conversation reopened."
            case .account(let field):
                guard let selected = action.ticket, let current = snapshot.tickets.first(where: { $0 == selected }) else { throw SupportDeskClientError.readOnly }
                try await client.changeAccount(snapshot: snapshot, ticket: current, field: field, value: action.body)
                if field == .password { password = ""; notice = "Password changed. Existing customer sessions were revoked." }
                else { email = ""; notice = "Customer email address changed." }
            }
            revision += 1
        } catch { self.error = error.localizedDescription; refreshRequired = true }
    }

    private func makeClient() throws -> SupportDeskClient {
        guard let site = URL(string: model.settings.websiteBaseURL) else { throw SupportDeskClientError.invalidServiceURL }
        return try SupportDeskClient(siteBaseURL: site, userID: model.userIDForRequests, token: model.authTokenForRequests,
            organizationID: model.selectedOrganizationID, impersonationToken: model.settings.impersonationToken,
            impersonatingUserID: model.settings.impersonatingUserID)
    }

    private func date(_ value: String) -> String {
        guard let parsed = ISO8601DateFormatter().date(from: value) else { return "Date unavailable" }
        return parsed.formatted(date: .abbreviated, time: .shortened)
    }

    private struct PendingAction: Identifiable {
        enum Kind { case create, reply, status(String), account(SupportDeskAccountField), feedback(Int) }
        let id = UUID()
        let kind: Kind
        let ticket: SupportDeskTicket?
        var body = ""
        var subject = ""
        var title: String {
            switch kind { case .create: "Create support ticket?"; case .reply: "Send support reply?"; case .status("closed"): "Resolve conversation?"; case .status: "Reopen conversation?"; case .account(.password): "Change customer password?"; case .account(.email): "Change customer email?"; case .feedback: "Send support feedback?" }
        }
        var confirmTitle: String {
            switch kind { case .create: "Create ticket"; case .reply: "Send reply"; case .status("closed"): "Resolve"; case .status: "Reopen"; case .account(.password): "Change password"; case .account(.email): "Change email"; case .feedback: "Send feedback" }
        }
        var destructive: Bool { if case .status("closed") = kind { true } else { false } }
        var message: String {
            switch kind {
            case .create: "Send “\(subject.isEmpty ? "Support question" : subject)” to Hanasand Support?"
            case .reply: "Send this reply in “\(ticket?.subject ?? "your conversation")”?"
            case .status(let status): "\(status == "closed" ? "Resolve" : "Reopen") “\(ticket?.subject ?? "this conversation")” for \(ticket?.userName ?? "this customer")?"
            case .account(.password): "Change the password for \(ticket?.userName ?? ticket?.userID ?? "this customer")? Existing sessions will be revoked."
            case .account(.email): "Change the email for \(ticket?.userName ?? ticket?.userID ?? "this customer") to \(body)?"
            case .feedback(let rating): "Send a rating of \(rating)/5 to Hanasand Support?"
            }
        }
    }
}
