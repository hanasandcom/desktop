import AppKit
import SwiftUI

struct SupportDeskNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var live = SupportLiveSession()
    @State private var isVisible = false
    @State private var snapshot: SupportDeskSnapshot?
    @State private var guestConversation: SupportGuestConversation?
    @State private var guestSession: SupportGuestSession?
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
    @State private var discordLinkCode: SupportDiscordLinkCode?
    @State private var discordLinkCodeBusy = false
    @State private var discordLinkCodeError = ""
    @State private var discordLinkCodeCopied = false
    @State private var discordLinkAttemptID = 0
    @State private var pendingAction: PendingAction?
    @State private var pendingGuestResolve = false
    @State private var guestFeedbackRating = 5
    @State private var guestFeedbackComment = ""
    @State private var guestCloseFeedbackFound: Bool? = nil
    @State private var guestCloseFeedbackReason = ""
    @State private var guestRetry: (requestID: String, message: String, handoff: Bool)?
    @State private var guestRefreshPending = false

    private var ticket: SupportDeskTicket? { snapshot?.tickets.first(where: { $0.id == selectedID }) }
    private var canWrite: Bool {
        guard let snapshot, let client = try? makeClient() else { return false }
        return snapshot.scope == client.scope && client.canMutate && !busy && !refreshRequired
    }
    private var isSupport: Bool { snapshot?.isSupport == true }
    private var discordLinkScope: String {
        [SupportDeskClient.defaultBaseURL.absoluteString, model.settings.websiteBaseURL,
         model.userIDForRequests, model.authTokenForRequests, model.settings.impersonationToken,
         model.settings.impersonatingUserID, model.selectedOrganizationID].joined(separator: "\n")
    }
    private var canCreateDiscordLinkCode: Bool {
        model.hasHanasandAuth && model.settings.impersonationToken.isEmpty && model.settings.impersonatingUserID.isEmpty
    }
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
        Group {
            if model.hasHanasandAuth { authenticatedWorkspace }
            else { guestWorkspace }
        }
    }

    private var guestWorkspace: some View {
        VStack(alignment: .leading, spacing: 14) {
            NativeGroupPanel(title: "Guest support chat", subtitle: "Ask a question or continue a conversation.", fillsAvailableWidth: true) {
                Text("This guest session is stored in this Mac’s Keychain and expires after 30 days without use. If it expires or is removed, its conversations cannot be recovered.")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                if let guestSession {
                    Text("Session expires \(guestSession.expiresAt.formatted(date: .abbreviated, time: .shortened)).")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary)
                    Text(live.status.title).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { guestActions }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 8) { guestActions }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !error.isEmpty { Text(error).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.danger).textSelection(.enabled) }
                if !notice.isEmpty { NativeNotice(message: notice) }
                if busy && guestConversation == nil { NativeEmptyState(title: "Loading Support", message: "Opening the guest support session.") }
            }

            if let guestConversation {
                if !guestConversation.tickets.isEmpty {
                    NativeGroupPanel(title: "Your conversations · \(guestConversation.tickets.count)", subtitle: "Only conversations saved with this guest session are shown.") {
                        ForEach(guestConversation.tickets) { row in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(row.subject).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                                Text("\(row.status == "closed" ? "Resolved" : "Open") · updated \(date(row.updatedAt))")
                                    .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
                                if let last = row.lastMessage, !last.isEmpty { Text(last).font(.system(size: 11)).foregroundStyle(theme.textTertiary).lineLimit(2) }
                                ActionButton(title: "Open conversation", icon: "bubble.left.and.bubble.right") {
                                    selectedID = row.id; guestFeedbackRating = 5; guestFeedbackComment = ""
                                    guestCloseFeedbackFound = nil; guestCloseFeedbackReason = ""; guestRetry = nil; revision += 1
                                }.disabled(busy)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(theme.card, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                guestConversationPanel(guestConversation)
            } else if !busy {
                NativeEmptyState(title: "Guest support unavailable", message: "Refresh to open a new guest session.")
            }
        }
        .task(id: revision) { await loadGuest() }
        .onAppear { isVisible = true; updateGuestLive() }
        .onDisappear { isVisible = false; live.stop() }
        .onChange(of: scenePhase) { _, _ in updateGuestLive() }
        .confirmationDialog("Resolve this conversation?", isPresented: $pendingGuestResolve, titleVisibility: .visible) {
            Button("Resolve conversation", role: .destructive) { Task { await resolveGuestConversation() } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("You can still review this conversation and leave feedback after it is resolved.") }
    }

    @ViewBuilder private var guestActions: some View {
        ActionButton(title: busy ? "Working…" : "Refresh", icon: "arrow.clockwise") { revision += 1 }.disabled(busy)
        ActionButton(title: "New chat", icon: "plus") {
            selectedID = UUID().uuidString.lowercased(); draft = ""; guestRetry = nil
            guestFeedbackRating = 5; guestFeedbackComment = ""; guestCloseFeedbackFound = nil; guestCloseFeedbackReason = ""; revision += 1
        }.disabled(busy)
    }

    @ViewBuilder private func guestConversationPanel(_ conversation: SupportGuestConversation) -> some View {
        let activeTicket = conversation.tickets.first(where: { $0.id == selectedID })
        let isSelected = conversation.id == selectedID
        NativeGroupPanel(title: activeTicket?.subject ?? "New conversation", subtitle: activeTicket.map { "Guest conversation · \($0.status == "closed" ? "resolved" : "open") · updated \(date($0.updatedAt))" } ?? "Your message starts a new guest conversation.") {
            if isSelected {
                ForEach(conversation.messages) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.senderName).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                        Text(item.body).font(.system(size: 12)).foregroundStyle(theme.textSecondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Text(date(item.createdAt)).font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(theme.card, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            if activeTicket?.status != "closed" {
                TextField("Write a message", text: $draft, axis: .vertical).lineLimit(3...8).textFieldStyle(.roundedBorder).disabled(busy)
                ActionButton(title: busy ? "Sending…" : "Send message", icon: "paperplane") { Task { await sendGuestMessage(handoff: false) } }
                    .disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                ActionButton(title: "Talk to a person", icon: "person.crop.circle.badge.questionmark") { Task { await sendGuestMessage(handoff: true) } }.disabled(busy)
                if activeTicket != nil {
                    ActionButton(title: "Resolve conversation", icon: "checkmark.circle") { pendingGuestResolve = true }.disabled(busy)
                }
            } else if let activeTicket, let version = activeTicket.resolutionVersion {
                if activeTicket.feedbackRating != nil {
                    Text("Thank you for your feedback.").font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                } else {
                    Text("How was your support experience?").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                    Picker("Rating", selection: $guestFeedbackRating) { ForEach(1...5, id: \.self) { Text("\($0) stars").tag($0) } }
                    if guestFeedbackRating <= 4 { TextField("Optional feedback", text: $guestFeedbackComment, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder) }
                    ActionButton(title: "Send rating", icon: "star") { Task { await submitGuestRating(ticket: activeTicket, version: version) } }.disabled(busy)
                }
                if conversation.closeFeedbackFound == nil {
                    Picker("Did you find what you needed?", selection: $guestCloseFeedbackFound) {
                        Text("Choose an answer").tag(Optional<Bool>.none)
                        Text("Yes").tag(Optional(true)); Text("No").tag(Optional(false))
                    }
                    TextField("Optional note", text: $guestCloseFeedbackReason, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
                    ActionButton(title: "Send answer", icon: "checkmark") { Task { await submitGuestCloseFeedback(ticket: activeTicket, version: version) } }
                        .disabled(busy || guestCloseFeedbackFound == nil)
                }
                ActionButton(title: "New chat", icon: "plus") {
                    selectedID = UUID().uuidString.lowercased(); draft = ""; guestRetry = nil
                    guestFeedbackRating = 5; guestFeedbackComment = ""; guestCloseFeedbackFound = nil; guestCloseFeedbackReason = ""; revision += 1
                }.disabled(busy)
            }
        }
    }

    private var authenticatedWorkspace: some View {
        VStack(alignment: .leading, spacing: 14) {
            NativeGroupPanel(title: isSupport ? "Support Desk" : "Support", subtitle: isSupport ? "Customer conversations · latest 100 maximum" : "Your support conversations", fillsAvailableWidth: true) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { supportActions }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 8) { supportActions }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if snapshot != nil {
                    Text(snapshot?.realtime == true ? live.status.title : "Live updates are not enabled for this Support queue.")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
                }
                if discordLinkCodeBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Creating a Discord link code…").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
                    }
                }
                if let discordLinkCode {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("In Discord, run /tickets, choose Link account, then enter this code.")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) { discordLinkCodeValue(discordLinkCode) }
                                .fixedSize(horizontal: true, vertical: false)
                            VStack(alignment: .leading, spacing: 8) { discordLinkCodeValue(discordLinkCode) }
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text("Code expires \(discordLinkCode.expiresAt.formatted(date: .abbreviated, time: .shortened)).")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !discordLinkCodeError.isEmpty {
                    NativeNotice(message: discordLinkCodeError, title: "Discord account linking", tone: .error)
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
        .task(id: "\(model.settings.websiteBaseURL):\(model.userIDForRequests):\(model.authTokenForRequests):\(model.settings.impersonationToken):\(model.settings.impersonatingUserID):\(revision)") { await load() }
        .onAppear { isVisible = true; updateLive() }
        .onDisappear { isVisible = false; live.stop() }
        .onChange(of: scenePhase) { _, _ in updateLive() }
        .onChange(of: discordLinkScope) { _, _ in clearDiscordLinkState() }
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
        ActionButton(title: discordLinkCodeBusy ? "Creating code…" : "Connect Discord", icon: "bubble.left.and.bubble.right") {
            createDiscordLinkCode()
        }.disabled(!canCreateDiscordLinkCode || discordLinkCodeBusy)
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

    @MainActor private func loadGuest(keepingLive: Bool = false) async {
        if !keepingLive { live.stop() }
        busy = true; error = ""; notice = ""
        defer {
            busy = false
            if guestRefreshPending {
                guestRefreshPending = false
                refreshGuestFromLive()
            }
        }
        do {
            let previousToken = guestSession?.token
            let session = try SupportGuestSession.loadFromKeychain()
            guestSession = session
            if let previousToken, previousToken != session.token {
                notice = "The previous guest session expired. Its conversations cannot be recovered; this is a new chat history."
                selectedID = ""
            }
            let conversation = try await makeGuestClient(session: session).load(conversationID: selectedID.isEmpty ? nil : selectedID)
            guard !Task.isCancelled else { return }
            guestConversation = conversation
            if selectedID.isEmpty {
                selectedID = conversation.id ?? UUID().uuidString.lowercased()
            } else if conversation.id == nil && !conversation.tickets.contains(where: { $0.id == selectedID }) {
                // Keep a locally selected, not-yet-created chat ID for the first message.
            }
            if !keepingLive { updateGuestLive() }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func refreshGuestFromLive() {
        guard isVisible else { return }
        guard !busy else { guestRefreshPending = true; return }
        Task { await loadGuest(keepingLive: true) }
    }

    private func updateGuestLive() {
        guard isVisible, scenePhase == .active, !model.hasHanasandAuth,
              let guestSession, let client = try? makeGuestClient(session: guestSession) else {
            live.stop()
            return
        }
        live.startGuest(apiBaseURL: SupportGuestChatClient.defaultBaseURL.absoluteString,
                        websiteBaseURL: model.settings.websiteBaseURL,
                        connectTicket: { try await client.connectTicket() }) {
            refreshGuestFromLive()
        }
    }

    @MainActor private func sendGuestMessage(handoff: Bool) async {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let retry = guestRetry.flatMap { $0.message == message && $0.handoff == handoff ? $0 : nil }
        let requestID = retry?.requestID ?? UUID().uuidString.lowercased()
        guestRetry = (requestID, message, handoff)
        busy = true; error = ""; notice = ""; defer { busy = false }
        do {
            guard let guestSession else { throw SupportGuestSessionError.invalidStorage }
            let client = try makeGuestClient(session: guestSession)
            let result = try await client.sendMessage(message, requestID: requestID, conversationID: selectedID, handoff: handoff)
            guard !Task.isCancelled else { return }
            if result.accepted == false {
                guestConversation = try await client.load(conversationID: selectedID)
                error = "Support is still preparing a reply. Refresh before trying again."
                return
            }
            if let returnedID = result.id { selectedID = returnedID }
            guestConversation = try await client.load(conversationID: selectedID)
            draft = ""; guestRetry = nil
            notice = handoff ? "Your request for a person was sent." : "Message sent."
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func resolveGuestConversation() async {
        pendingGuestResolve = false; busy = true; error = ""; notice = ""; defer { busy = false }
        do {
            guard let guestSession else { throw SupportGuestSessionError.invalidStorage }
            let client = try makeGuestClient(session: guestSession)
            try await client.resolve(conversationID: selectedID)
            guestConversation = try await client.load(conversationID: selectedID)
            notice = "Conversation resolved. You can leave feedback here."
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func submitGuestRating(ticket: SupportDeskTicket, version: Int) async {
        busy = true; error = ""; notice = ""; defer { busy = false }
        do {
            guard let guestSession else { throw SupportGuestSessionError.invalidStorage }
            let client = try makeGuestClient(session: guestSession)
            try await client.submitFeedback(conversationID: ticket.id, resolutionVersion: version,
                                            rating: guestFeedbackRating, comment: guestFeedbackComment)
            guestConversation = try await client.load(conversationID: ticket.id)
            notice = "Feedback sent. Thank you."
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func submitGuestCloseFeedback(ticket: SupportDeskTicket, version: Int) async {
        busy = true; error = ""; notice = ""; defer { busy = false }
        do {
            guard let guestSession, let answer = guestCloseFeedbackFound else { throw SupportGuestSessionError.invalidStorage }
            let client = try makeGuestClient(session: guestSession)
            try await client.submitCloseFeedback(conversationID: ticket.id, resolutionVersion: version,
                                                 foundWhatLookingFor: answer, reason: guestCloseFeedbackReason)
            guestConversation = try await client.load(conversationID: ticket.id)
            notice = "Your answer was sent."
        } catch { self.error = error.localizedDescription }
    }

    private func makeGuestClient(session: SupportGuestSession) throws -> SupportGuestChatClient {
        try SupportGuestChatClient(token: session.token)
    }

    @MainActor private func load() async {
        await load(keepingLive: false)
    }

    @MainActor private func load(keepingLive: Bool) async {
        if !keepingLive { live.stop() }
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
            if !keepingLive { updateLive() }
            else if !next.realtime { live.stop() }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func refreshFromLive() {
        guard !busy, !refreshRequired else { return }
        Task { await load(keepingLive: true) }
    }

    private func updateLive() {
        guard isVisible, scenePhase == .active, model.hasHanasandAuth,
              let snapshot, snapshot.realtime else { live.stop(); return }
        live.start(apiBaseURL: SupportDeskClient.defaultBaseURL.absoluteString,
                   websiteBaseURL: model.settings.websiteBaseURL,
                   userID: model.userIDForRequests, token: model.authTokenForRequests,
                   impersonationToken: model.settings.impersonationToken) {
            refreshFromLive()
        }
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

    @ViewBuilder private func discordLinkCodeValue(_ value: SupportDiscordLinkCode) -> some View {
        Text(value.code)
            .font(.system(size: 14, weight: .bold, design: .monospaced))
            .foregroundStyle(theme.text)
            .textSelection(.enabled)
            .fixedSize(horizontal: true, vertical: false)
        ActionButton(title: discordLinkCodeCopied ? "Copied" : "Copy code", icon: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            discordLinkCodeCopied = NSPasteboard.general.setString(value.code, forType: .string)
            if !discordLinkCodeCopied { discordLinkCodeError = "The code could not be copied. Select the code and copy it manually." }
        }
    }

    @MainActor private func createDiscordLinkCode() {
        guard !discordLinkCodeBusy, canCreateDiscordLinkCode else { return }
        discordLinkAttemptID += 1
        let attemptID = discordLinkAttemptID
        let scope = discordLinkScope
        discordLinkCode = nil
        discordLinkCodeError = ""
        discordLinkCodeCopied = false
        discordLinkCodeBusy = true

        Task { @MainActor in
            defer {
                if attemptID == discordLinkAttemptID { discordLinkCodeBusy = false }
            }
            do {
                let client = try makeClient()
                guard client.canMutate, client.scope == scope else { throw SupportDeskClientError.readOnly }
                let code = try await client.createDiscordLinkCode()
                guard attemptID == discordLinkAttemptID, discordLinkScope == scope, model.hasHanasandAuth else { return }
                discordLinkCode = code
            } catch {
                guard attemptID == discordLinkAttemptID, discordLinkScope == scope else { return }
                discordLinkCodeError = error.localizedDescription
            }
        }
    }

    @MainActor private func clearDiscordLinkState() {
        discordLinkAttemptID += 1
        discordLinkCode = nil
        discordLinkCodeBusy = false
        discordLinkCodeError = ""
        discordLinkCodeCopied = false
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
