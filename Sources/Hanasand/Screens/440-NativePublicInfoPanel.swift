import AppKit
import SwiftUI

struct NativePublicInfoPanel: View {
    let page: NativePublicInfoPage
    let onNavigate: (String) -> Void

    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var cookieSettings: NativeCookieSettingsSnapshot?
    @State private var consentMessage = ""
    @State private var draftClearMessage = ""
    @State private var confirmClearLocalDrafts = false
    @State private var contactName = ""
    @State private var contactEmail = ""
    @State private var contactCompany = ""
    @State private var contactSubject = ""
    @State private var contactMessage = ""
    @State private var contactStatus = ""
    @State private var contactError = ""
    @State private var contactTicket = ""
    @State private var isSubmitting = false
    @State private var search = ""
    @State private var selectedFAQCategory = "All"

    private var filteredFAQs: [NativePublicInfoFAQ] {
        NativePublicInfoPage.faqItems.filter { item in
            (selectedFAQCategory == "All" || item.category == selectedFAQCategory)
                && (search.isEmpty || "\(item.question) \(item.answer)".localizedCaseInsensitiveContains(search))
        }
    }

    private var faqCategories: [String] {
        ["All"] + Array(Set(NativePublicInfoPage.faqItems.map(\.category))).sorted()
    }

    private var heroTitleSize: CGFloat {
        switch page.kind {
        case .pricing: 28
        case .scannerSolution, .monitoringSolution: 34
        default: 24
        }
    }

    var body: some View {
        Group {
            if page.kind == .about {
                aboutContent
            } else {
                standardContent
            }
        }
        .task(id: page.kind) {
            if page.kind == .cookieSettings { refreshCookieSettings() }
        }
        .confirmationDialog("Clear local IDE drafts?", isPresented: $confirmClearLocalDrafts, titleVisibility: .visible) {
            Button("Clear IDE drafts", role: .destructive) { clearLocalDrafts() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes only allowlisted local IDE drafts from this Mac. Notes drafts, Keychain credentials, settings, appearance, identity, and workspace session preferences are kept.")
        }
    }

    @ViewBuilder private var standardContent: some View {
        if page.kind == .contact {
            contactContent
        } else {
            standardContentBody
        }
    }

    private var standardContentBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            NativeGroupPanel(title: page.eyebrow, subtitle: "", fillsAvailableWidth: true) {
                VStack(alignment: page.kind == .pricing ? .center : .leading, spacing: 8) {
                    Text(page.title)
                        .font(.system(size: heroTitleSize, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(page.kind == .pricing ? .center : .leading)
                        .textSelection(.enabled)
                    Text(page.intro)
                        .font(.system(size: 14))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(page.kind == .pricing ? .center : .leading)
                        .textSelection(.enabled)
                    if page.kind == .scannerSolution || page.kind == .monitoringSolution {
                        solutionActions
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: page.kind == .pricing ? 760 : .infinity)
                .frame(maxWidth: .infinity, alignment: page.kind == .pricing ? .center : .leading)
                if page.kind == .home { homeSearch }
                if page.kind == .faq { faqControls }
                if page.kind == .cookieSettings { cookieSettingsControls }
            }

            if page.kind == .faq {
                faqContent
            } else if page.kind == .reservedUsernames {
                reservedUsernameContent
            } else if page.kind == .pricing {
                pricingContent
            } else if page.kind == .scannerSolution || page.kind == .monitoringSolution {
                solutionContent
            } else {
                ForEach(page.sections) { section in
                    NativeGroupPanel(title: section.title, subtitle: "") {
                        ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                            Text(paragraph)
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        if !section.bullets.isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(section.bullets, id: \.self) { bullet in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "circle.fill")
                                            .font(.system(size: 4))
                                            .foregroundStyle(theme.accent)
                                            .padding(.top, 6)
                                        Text(bullet)
                                            .font(.system(size: 12))
                                            .foregroundStyle(theme.textSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if page.kind == .home {
                PublicExposureActivityNativePanel()
            }

            if !page.links.isEmpty && page.kind != .scannerSolution && page.kind != .monitoringSolution {
                NativeGroupPanel(title: page.kind == .home ? "Explore Hanasand" : "Related", subtitle: "") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), alignment: .leading)], alignment: .leading, spacing: 8) {
                        ForEach(page.links) { link in
                            Button { open(link.route) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(link.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                                    if !link.detail.isEmpty {
                                        Text(link.detail).font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                                .padding(9)
                                .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens the native \(link.title) page")
                        }
                    }
                }
            }
        }
    }

    private var contactContent: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 18) {
                contactIntroduction
                    .frame(minWidth: 210, maxWidth: 330, alignment: .topLeading)
                contactFormPanel
                    .frame(minWidth: 360, maxWidth: .infinity, alignment: .topLeading)
            }
            VStack(alignment: .leading, spacing: 14) {
                contactIntroduction
                contactFormPanel
            }
        }
        .frame(maxWidth: 1100, alignment: .leading)
    }

    private var contactIntroduction: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(page.title)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(page.intro)
                .font(.system(size: 14))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let emailLink = page.links.first(where: { $0.route.hasPrefix("mailto:") }) {
                Button { open(emailLink.route) } label: {
                    Label(emailLink.title.replacingOccurrences(of: "Email ", with: ""), systemImage: "envelope")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var contactFormPanel: some View {
        NativeGroupPanel(title: page.eyebrow, subtitle: "") {
            contactForm
        }
    }

    private var aboutContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), alignment: .top)], alignment: .leading, spacing: 14) {
                aboutCompanyPanel
                aboutFocusPanel
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), alignment: .top)], alignment: .leading, spacing: 14) {
                aboutPrinciplePanels
            }
        }
    }

    private var aboutCompanyPanel: some View {
        NativeGroupPanel(title: page.eyebrow, subtitle: "", fillsAvailableWidth: true) {
            Text(page.title)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text(page.intro)
                .font(.system(size: 14))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { aboutLinks }
                VStack(alignment: .leading, spacing: 8) { aboutLinks }
            }
        }
    }

    private var aboutFocusPanel: some View {
        let focus = page.sections.first
        return NativeGroupPanel(title: focus?.title ?? "Current product focus", subtitle: "", fillsAvailableWidth: true) {
            if let focus {
                ForEach(focus.paragraphs, id: \.self) { paragraph in
                    Text(paragraph)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(focus.bullets, id: \.self) { bullet in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.green)
                            .padding(.top, 2)
                        Text(bullet)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder private var aboutLinks: some View {
        ForEach(Array(page.links.enumerated()), id: \.element.id) { index, link in
            let isPrimary = index == 0
            Button { open(link.route) } label: {
                HStack(spacing: 7) {
                    Text(link.title).font(.system(size: 12, weight: .semibold))
                    if link.route == "/ti" { Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)) }
                }
                .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                .padding(.horizontal, 12)
                .foregroundStyle(isPrimary ? theme.background : theme.text)
                .background(isPrimary ? theme.text : theme.cardRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(isPrimary ? Color.clear : theme.divider, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the native \(link.title) page")
        }
    }

    @ViewBuilder private var aboutPrinciplePanels: some View {
        ForEach(Array(page.sections.dropFirst())) { section in
            NativeGroupPanel(title: section.title, subtitle: "", fillsAvailableWidth: true) {
                let symbol = section.title.hasPrefix("Direct") ? "dot.radiowaves.left.and.right"
                    : section.title.hasPrefix("Clean") ? "point.3.connected.trianglepath.dotted"
                    : "checkmark.shield"
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.accent)
                ForEach(section.paragraphs, id: \.self) { paragraph in
                    Text(paragraph)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var homeSearch: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                searchField
                searchButton
            }
            VStack(alignment: .leading, spacing: 8) {
                searchField
                searchButton
            }
        }
    }

    private var searchField: some View {
        TextField("Search a company, vendor, or domain", text: $search)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 240, maxWidth: .infinity)
            .onSubmit { submitSearch() }
    }

    private var searchButton: some View {
        ActionButton(title: "Search", icon: "magnifyingglass") { submitSearch() }
    }

    private var faqControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search questions", text: $search).textFieldStyle(.roundedBorder)
            ViewThatFits(in: .horizontal) {
                Picker("Category", selection: $selectedFAQCategory) {
                    ForEach(faqCategories, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Category", selection: $selectedFAQCategory) {
                    ForEach(faqCategories, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private var faqContent: some View {
        NativeGroupPanel(title: "Frequently asked questions", subtitle: "\(filteredFAQs.count) answers") {
            if filteredFAQs.isEmpty {
                NativeEmptyState(title: "No matching answers", message: "Try a different search or category.")
            } else {
                ForEach(filteredFAQs) { item in
                    DisclosureGroup {
                        Text(item.answer)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.question).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                            Text(item.category.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(theme.textTertiary)
                        }
                    }
                    .padding(.vertical, 5)
                    if item.id != filteredFAQs.last?.id { Divider().overlay(theme.divider) }
                }
            }
        }
    }

    private var reservedUsernameContent: some View {
        NativeGroupPanel(title: "Protected usernames", subtitle: "\(NativePublicInfoPage.reservedNames.count) exact names, plus lookalike patterns") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 7) {
                ForEach(NativePublicInfoPage.reservedNames, id: \.self) { username in
                    Text(username)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var pricingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 260), alignment: .top), count: 4), alignment: .leading, spacing: 12) {
                    pricingPlanCards
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 260), alignment: .top), count: 2), alignment: .leading, spacing: 12) {
                    pricingPlanCards
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(page.sections) { section in
                NativeGroupPanel(title: section.title, subtitle: "", fillsAvailableWidth: true) {
                    ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph).font(.system(size: 12)).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    ActionButton(title: "Manage a container", icon: "shippingbox") { open("/vms") }
                }
            }
            Text("Secure checkout is handled by Stripe.")
                .font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var pricingPlanCards: some View {
        ForEach(NativePublicInfoPage.plans) { plan in
            NativeGroupPanel(title: plan.name, subtitle: plan.quota, fillsAvailableWidth: true) {
                Text(plan.summary).font(.system(size: 12)).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                Text("\(plan.priceNok) NOK / month").font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.accent)
                ForEach(plan.features, id: \.self) { feature in
                    Label(feature, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                }
                ActionButton(title: "Open plan in Hanasand", icon: "arrow.up.right") {
                    open("/subscription")
                }
            }
        }
    }

    @ViewBuilder private var solutionActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { solutionActionButtons }
            VStack(alignment: .leading, spacing: 8) { solutionActionButtons }
        }
    }

    @ViewBuilder private var solutionActionButtons: some View {
        ForEach(page.links) { link in
            ActionButton(title: link.title, icon: "arrow.right") { open(link.route) }
        }
    }

    private var solutionContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 220), alignment: .top), count: 3), alignment: .leading, spacing: 14) {
                ForEach(Array(page.sections.prefix(3))) { section in
                    NativeGroupPanel(title: section.title, subtitle: "", fillsAvailableWidth: true) {
                        ForEach(section.paragraphs, id: \.self) { paragraph in
                            Text(paragraph)
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if page.kind == .monitoringSolution {
                monitoringDetails
            }
        }
    }

    private var monitoringDetails: some View {
        let event = page.sections.first(where: { $0.title == "Send an event" })
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                sendEventPanel(event).frame(maxWidth: .infinity, alignment: .topLeading)
                monitoringScopePanel.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            VStack(alignment: .leading, spacing: 14) {
                sendEventPanel(event)
                monitoringScopePanel
            }
        }
    }

    private func sendEventPanel(_ section: NativePublicInfoSection?) -> some View {
        NativeGroupPanel(title: "Send an event", subtitle: "", fillsAvailableWidth: true) {
            if let sample = section?.paragraphs.first {
                Text(sample)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private var monitoringScopePanel: some View {
        NativeGroupPanel(title: "Security Monitoring scope", subtitle: "", fillsAvailableWidth: true) {
            Text("A working MDR starting point, not a generic log dump.")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text("Security Monitoring is built on the existing Hanasand organization, API-key, tenant, and analyst process. The API keeps one stable endpoint while vendor adapters and broader rule families feed the same event model.")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(["Suspicious login findings", "Impossible-travel evidence", "Organization-specific raw and normalized events", "Extensible path for Sigma and Hanasand rules"], id: \.self) { item in
                Label(item, systemImage: "circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    private var cookieSettingsControls: some View {
        let snapshot = cookieSettings ?? NativeCookieSettingsPolicy.snapshot(
            sessionToken: model.authTokenForRequests,
            impersonationToken: model.settings.impersonationToken
        )
        return VStack(alignment: .leading, spacing: 12) {
            NativeGroupPanel(title: "Consent", subtitle: snapshot.consent.title) {
                Text("Required account and security functions remain enabled. Optional measurement consent applies to this Desktop app.")
                    .font(.system(size: 12)).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                Text(consentUpdatedLabel(snapshot.consentUpdatedAt))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { consentActions }
                    VStack(alignment: .leading, spacing: 8) { consentActions }
                }
                if !consentMessage.isEmpty { NativeNotice(message: consentMessage, tone: .success) }
            }

            NativeGroupPanel(title: "Account tokens", subtitle: "Presence only · token values are never shown") {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        presenceCard(title: "Session token", present: snapshot.hasSessionToken, icon: "key")
                        presenceCard(title: "Impersonation token", present: snapshot.hasImpersonationToken, icon: "person.crop.circle.badge.checkmark")
                    }
                    VStack(spacing: 8) {
                        presenceCard(title: "Session token", present: snapshot.hasSessionToken, icon: "key")
                        presenceCard(title: "Impersonation token", present: snapshot.hasImpersonationToken, icon: "person.crop.circle.badge.checkmark")
                    }
                }
                ActionButton(title: "Open native sign out", icon: "rectangle.portrait.and.arrow.right") {
                    model.openNativeDashboard(path: "/logout", label: "Sign out")
                }
            }

            NativeGroupPanel(title: "Local Hanasand drafts", subtitle: "Saved only on this Mac") {
                Text("This removes allowlisted local IDE drafts from this Mac. Notes drafts are preserved and managed from the Notes route.")
                    .font(.system(size: 12)).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                if snapshot.storedDraftKinds.isEmpty {
                    NativeEmptyState(title: "No local IDE drafts found", message: "No allowlisted IDE draft data is stored.")
                } else {
                    ForEach(snapshot.storedDraftKinds) { kind in
                        Label(kind.title, systemImage: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.textSecondary)
                    }
                }
                NativeNotice(message: "Notes drafts are preserved. Manage them from the Notes route.", title: "Notes drafts are not cleared here", tone: .info)
                if !draftClearMessage.isEmpty { NativeNotice(message: draftClearMessage, tone: .success) }
                if model.pendingIDEEdit != nil {
                    NativeNotice(message: "Finish or discard the pending IDE edit before clearing local drafts.", title: "Draft clearing paused", tone: .info)
                } else if model.articleMutationSafety.isBlocked {
                    NativeNotice(message: "Resolve the pending safety review before clearing local drafts.", title: "Draft clearing paused", tone: .info)
                } else if !model.settings.impersonationToken.isEmpty || !model.settings.impersonatingUserID.isEmpty {
                    NativeNotice(message: "Return to your own account before clearing account-scoped drafts.", title: "Draft clearing paused", tone: .info)
                }
                ActionButton(title: "Clear local drafts", icon: "trash", tone: .danger) {
                    confirmClearLocalDrafts = true
                }
                .disabled(!snapshot.storedDraftKinds.contains(.ide) || !mayClearLocalDrafts)
            }
        }
    }

    @ViewBuilder private var consentActions: some View {
        ActionButton(title: "Allow optional", icon: "checkmark.circle") { updateConsent(.optional) }
        ActionButton(title: "Essential only", icon: "lock.shield") { updateConsent(.essential) }
        ActionButton(title: "Reset choice", icon: "arrow.counterclockwise") { updateConsent(.unset) }
    }

    private var mayClearLocalDrafts: Bool {
        model.selectedSection != .ide
            && model.pendingIDEEdit == nil
            && !model.articleMutationSafety.isBlocked
            && model.settings.impersonationToken.isEmpty
            && model.settings.impersonatingUserID.isEmpty
    }

    private func presenceCard(title: String, present: Bool, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(present ? theme.accent : theme.textTertiary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textSecondary)
                Text(present ? "Present" : "Not present").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func updateConsent(_ choice: NativeCookieSettingsSnapshot.Consent) {
        NativeCookieSettingsPolicy.saveConsent(choice)
        refreshCookieSettings()
        consentMessage = choice == .unset ? "Consent choice reset." : "Consent choice saved."
    }

    private func consentUpdatedLabel(_ date: Date?) -> String {
        guard let date else { return "No consent choice has been saved." }
        return "Updated \(ISO8601DateFormatter().string(from: date))"
    }

    private func refreshCookieSettings() {
        cookieSettings = NativeCookieSettingsPolicy.snapshot(
            sessionToken: model.authTokenForRequests,
            impersonationToken: model.settings.impersonationToken
        )
    }

    private func clearLocalDrafts() {
        guard mayClearLocalDrafts else { return }
        let cleared = NativeCookieSettingsPolicy.clearSafeDrafts(
            mayClearIDE: mayClearLocalDrafts
        )
        draftClearMessage = cleared.isEmpty ? "No IDE drafts were cleared." : "Cleared local IDE drafts."
        refreshCookieSettings()
    }

    private var contactForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            contactField("Name", text: $contactName)
            contactField("Email", text: $contactEmail)
            contactField("Company or team (optional)", text: $contactCompany)
            contactField("Subject", text: $contactSubject)
            VStack(alignment: .leading, spacing: 4) {
                Text("Message").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textSecondary)
                TextEditor(text: $contactMessage)
                    .frame(minHeight: 130)
                    .padding(5)
                    .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if !contactError.isEmpty { NativeNotice(message: contactError) }
            if !contactStatus.isEmpty {
                NativeNotice(message: contactStatus + (contactTicket.isEmpty ? "" : " Ticket \(contactTicket)."), tone: .success)
            }
            ActionButton(title: isSubmitting ? "Sending…" : "Send request", icon: isSubmitting ? "hourglass" : "paperplane") {
                Task { await submitContactRequest() }
            }
            .disabled(isSubmitting || !contactFormIsValid)
        }
    }

    private var contactFormIsValid: Bool {
        let emailParts = contactEmail.split(separator: "@")
        return !contactName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && emailParts.count == 2 && emailParts[1].contains(".")
            && contactSubject.trimmingCharacters(in: .whitespacesAndNewlines).count >= 5
            && contactMessage.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20
    }

    private func contactField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textSecondary)
            TextField(title, text: text).textFieldStyle(.roundedBorder)
        }
    }

    @MainActor private func submitContactRequest() async {
        guard contactFormIsValid, !isSubmitting else { return }
        isSubmitting = true
        contactError = ""
        contactStatus = ""
        defer { isSubmitting = false }
        do {
            let client = try NativePublicInfoClient(apiBaseURL: model.settings.apiBaseURL.normalizedBaseURL.absoluteString)
            let response = try await client.submit(NativePublicContactRequest(
                name: contactName.trimmingCharacters(in: .whitespacesAndNewlines),
                email: contactEmail.trimmingCharacters(in: .whitespacesAndNewlines),
                company: contactCompany.trimmingCharacters(in: .whitespacesAndNewlines),
                subject: contactSubject.trimmingCharacters(in: .whitespacesAndNewlines),
                message: contactMessage.trimmingCharacters(in: .whitespacesAndNewlines),
                source: page.route
            ))
            contactTicket = response.ticketID ?? "received"
            contactStatus = response.nextStep ?? "We received your request and will reply by email."
        } catch {
            contactError = (error as? LocalizedError)?.errorDescription ?? "Unable to send the request right now."
        }
    }

    private func submitSearch() {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        var components = URLComponents()
        components.path = "/ti"
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        open(components.string ?? "/ti")
    }

    private func open(_ route: String) {
        if route.hasPrefix("mailto:"), let url = URL(string: route) {
            NSWorkspace.shared.open(url)
        } else {
            onNavigate(route)
        }
    }
}
