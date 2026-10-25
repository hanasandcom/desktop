import Foundation

struct NativePublicInfoSection: Identifiable, Hashable {
    let title: String
    let paragraphs: [String]
    var bullets: [String] = []

    var id: String { title }
}

struct NativePublicInfoLink: Identifiable, Hashable {
    let title: String
    let route: String
    var detail: String = ""

    var id: String { route }
}

struct NativePublicInfoFAQ: Identifiable, Hashable {
    let category: String
    let question: String
    let answer: String

    var id: String { question }
}

enum NativeFAQFeedbackVote: String, Codable, Equatable {
    case yes
    case no
}

enum NativeFAQFeedbackStore {
    static let storageKey = "hanasand-faq-feedback"

    static func load(from defaults: UserDefaults = .standard) -> [String: NativeFAQFeedbackVote] {
        guard let data = defaults.data(forKey: storageKey),
              let votes = try? JSONDecoder().decode([String: NativeFAQFeedbackVote].self, from: data) else { return [:] }
        return votes
    }

    static func save(_ vote: NativeFAQFeedbackVote, for question: String, to defaults: UserDefaults = .standard) {
        var votes = load(from: defaults)
        votes[question] = vote
        guard let data = try? JSONEncoder().encode(votes) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

struct NativePublicInfoPlan: Identifiable, Hashable {
    let checkoutPlanID: String
    let name: String
    let priceNok: Int
    let quota: String
    let summary: String
    let features: [String]

    var id: String { name }
}

struct NativePublicInfoPage: Identifiable, Hashable {
    enum Kind: Hashable {
        case home
        case about
        case contact
        case faq
        case cookies
        case cookieSettings
        case privacy
        case terms
        case reservedUsernames
        case pricing
        case scannerSolution
        case monitoringSolution
        case securityContact
    }

    let route: String
    let title: String
    let eyebrow: String
    let intro: String
    let kind: Kind
    var sections: [NativePublicInfoSection] = []
    var links: [NativePublicInfoLink] = []

    var id: String { route }

    static func resolve(_ rawRoute: String) -> NativePublicInfoPage? {
        let path = rawRoute.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawRoute
        return switch path {
        case "/", "/home": home
        case "/about": about
        case "/contact": contact
        case "/faq": faq
        case "/cookies": cookies
        case "/cookie-settings": cookieSettings
        case "/privacy": privacy
        case "/terms": terms
        case "/reserved-usernames": reservedUsernames
        case "/pricing": pricing
        case "/solutions/scanner": scannerSolution
        case "/solutions/security-monitoring": monitoringSolution
        case "/security.txt": securityContact
        default: nil
        }
    }

    static let home = NativePublicInfoPage(
        route: "/",
        title: "Know what’s exposed before it’s too late.",
        eyebrow: "Hanasand threat intelligence",
        intro: "Company monitoring done right. Track company and vendor mentions with source links and context your team can act on.",
        kind: .home,
        sections: [
            .init(title: "Get started", paragraphs: ["Monitor companies, review alerts, search intelligence, or route notifications to your existing tools."]),
            .init(title: "A few useful answers", paragraphs: ["Exposure mentions are signals to review. They do not, by themselves, prove a breach."])
        ],
        links: [
            .init(title: "Monitor companies", route: "/organizations", detail: "Companies, vendors, domains"),
            .init(title: "Review alerts", route: "/findings", detail: "Exposure mentions and next steps"),
            .init(title: "Search intelligence", route: "/ti", detail: "Groups, sources, and activity"),
            .init(title: "Route notifications", route: "/automation?setup=dwm", detail: "Email, webhooks, and API")
        ]
    )

    static let homeSolutions: [NativePublicInfoLink] = [
        .init(title: "Monitoring", route: "/ti"),
        .init(title: "Shared reports", route: "/contact"),
    ]

    static let about = NativePublicInfoPage(
        route: "/about",
        title: "Hanasand monitors company exposure across leak sites and source changes.",
        eyebrow: "Company",
        intro: "The product centers on high-speed, reviewable threat intelligence: recent mentions, group context, company matching, and clean delivery.",
        kind: .about,
        sections: [
            .init(title: "Current product focus", paragraphs: ["Monitoring workflows for buyers who need recent exposure activity."], bullets: [
                "Recent ransomware attacks and leak-site changes",
                "Company, domain, brand, subsidiary, and supplier watchlists",
                "Group overviews shaped for UI navigation and analyst review",
                "Password checks that send only a short hash prefix"
            ]),
            .init(title: "Direct monitoring finds the mention", paragraphs: ["Public indexes help corroborate coverage while direct source checks, freshness logic, and company watchlists create the alert value."]),
            .init(title: "Clean fields make alerts usable", paragraphs: ["Every alert should tell the buyer the group, company, data mentioned, timing, source, sector, country, review status, and delivery history."]),
            .init(title: "Alerts should be fast and usable", paragraphs: ["The goal is alerts a security team can route, review, and act on quickly."])
        ],
        links: [.init(title: "Open intelligence search", route: "/ti"), .init(title: "Contact sales", route: "/contact")]
    )

    static let contact = NativePublicInfoPage(
        route: "/contact", title: "Contact us", eyebrow: "Contact", intro: "Send Hanasand a request and we will reply by email.", kind: .contact,
        sections: [.init(title: "Email", paragraphs: ["contact@hanasand.com"])],
        links: [.init(title: "Email contact@hanasand.com", route: "mailto:contact@hanasand.com")]
    )

    static let faq = NativePublicInfoPage(
        route: "/faq", title: "Answers for security teams evaluating Hanasand.", eyebrow: "FAQ",
        intro: "Short explanations of threat actors, monitoring coverage, alert confidence, routing, and what each signal does or does not prove.",
        kind: .faq,
        links: [.init(title: "Ask a different question", route: "/contact")]
    )

    static let cookies = NativePublicInfoPage(
        route: "/cookies", title: "Cookie policy", eyebrow: "Cookies",
        intro: "Effective July 3, 2026. This policy explains how Hanasand uses cookies and local browser storage across the public website, customer console, API setup flows, and monitoring workflows.",
        kind: .cookies,
        sections: [
            .init(title: "1. What cookies are", paragraphs: ["Cookies are small text values stored by the browser. Similar browser storage, such as local storage, can remember product state without sending every value back to the server on each request. Hanasand uses these technologies to keep the service secure, usable, and consistent."]),
            .init(title: "2. Required cookies", paragraphs: ["Required cookies support login, session continuity, role checks, impersonation safeguards where enabled, CSRF and security behavior, protected route access, and basic routing. These cookies are necessary for account and console use and cannot be disabled from cookie settings without signing out or losing access to protected pages."]),
            .init(title: "3. Preference cookies", paragraphs: ["Preference cookies remember interface choices such as visual theme or similar display state. These choices are controlled from the relevant product interface rather than the cookie settings page so the setting stays close to the feature it changes."]),
            .init(title: "4. Consent and notice cookies", paragraphs: ["Hanasand may store a lightweight consent or notice cookie to remember whether a visitor accepted optional cookies, chose essential-only use, or reset preferences. This avoids asking the same question on every page load."]),
            .init(title: "5. Analytics and product improvement", paragraphs: ["Hanasand may use privacy-conscious analytics or product measurement to understand route health, feature usage, conversion paths, reliability, and error rates. Where required, these cookies or similar technologies are optional and can be changed from cookie settings."]),
            .init(title: "6. Local browser storage", paragraphs: ["Some product flows use browser storage for convenience, such as share workspace state, request drafts, design notes, setup drafts, active conversation identifiers, detached panel state, or load-test client identifiers. These values are kept in the browser and can be cleared from cookie settings or browser settings."]),
            .init(title: "7. Third-party cookies", paragraphs: ["Hanasand may link to or integrate with third-party services such as payment, support, identity, email, webhook destinations, chat, or developer tooling. Those services may set their own cookies when customers interact with them. Hanasand does not control third-party cookie practices outside the Hanasand service."]),
            .init(title: "8. Managing cookies", paragraphs: ["You can manage optional consent and clear product-local browser tokens from Cookie Settings. Browser settings can also delete cookies and storage. Deleting required account cookies will sign you out or interrupt protected console workflows."]),
            .init(title: "9. Changes to this policy", paragraphs: ["Hanasand may update this Cookie Policy as the product, integrations, or legal requirements change. The effective date above shows when the current version took effect."])
        ],
        links: [.init(title: "Open cookie settings", route: "/cookie-settings")]
    )

    static let cookieSettings = NativePublicInfoPage(
        route: "/cookie-settings", title: "Cookie settings", eyebrow: "Settings",
        intro: "Manage optional consent for the desktop app. The desktop app keeps this preference in its own settings and does not expose website cookie or account-token values.",
        kind: .cookieSettings,
        sections: [.init(title: "Desktop app storage", paragraphs: ["The app preference is stored locally. Account credentials and website cookies are managed by their respective native sign-in and browser surfaces."])]
    )

    static let privacy = NativePublicInfoPage(
        route: "/privacy", title: "Privacy policy", eyebrow: "Privacy",
        intro: "Effective July 3, 2026. This policy explains how Hanasand handles customer account data, monitoring inputs, alert records, API activity, webhook configuration, and support information.",
        kind: .privacy,
        sections: [
            .init(title: "1. Who this policy covers", paragraphs: ["This Privacy Policy applies to Hanasand websites, customer consoles, APIs, monitoring products, alert workflows, webhook delivery, support channels, and related services. It applies to visitors, account users, administrators, API users, and customer representatives."]),
            .init(title: "2. Information customers provide", paragraphs: ["Customers and users may provide account details, organization names, administrator and user information, watched terms, domains, vendors, webhook endpoints, notification settings, support requests, billing and commercial information, uploaded notes, and other content submitted through the service."]),
            .init(title: "3. Monitoring inputs and alert data", paragraphs: ["Hanasand processes watchlists, company names, domains, vendor names, actor queries, source selections, alert rules, and related configuration so the service can monitor external risk signals and route alerts.", "Alert records may include source names, timestamps, confidence signals, matched terms, summaries, metadata, status, delivery status, notes, and customer-selected routing information. Customers should review alerts before taking action because monitored sources can be incomplete, unavailable, stale, or disputed."]),
            .init(title: "4. Account, authentication, and console data", paragraphs: ["Hanasand processes account identifiers, organization memberships, session state, access tokens, API keys, audit events, and console activity to authenticate users, enforce permissions, maintain security, support organization owners, and operate protected product pages."]),
            .init(title: "5. API, webhook, and integration data", paragraphs: ["When customers use APIs, webhooks, email, ticketing, chat, SIEM, or other integrations, Hanasand may process request details, endpoint configuration, delivery payloads, response status, retry state, signing or authentication details, and diagnostic logs needed to deliver and verify the integration."]),
            .init(title: "6. Technical and usage information", paragraphs: ["Hanasand collects operational information such as IP address, browser and device details, route accessed, timestamps, request IDs, error messages, latency, feature usage, security events, and service logs. This information helps operate, secure, debug, measure, and improve the service."]),
            .init(title: "7. How Hanasand uses information", paragraphs: ["Hanasand uses information to provide the service, authenticate users, route alerts, deliver webhooks, support customer review steps, maintain source and parsing quality, enforce permissions, prevent abuse, secure infrastructure, troubleshoot incidents, comply with law, bill for services, and communicate about product or account matters."], bullets: ["Deliver alerts, search results, API responses, notifications, and dashboard views requested by the customer.", "Maintain audit trails, security controls, rate limits, fraud prevention, and support workflows.", "Improve reliability, source quality, parsing accuracy, product usability, and operational performance."]),
            .init(title: "8. Legal bases where applicable", paragraphs: ["Where privacy law requires a legal basis, Hanasand relies on performance of a contract, legitimate interests in operating and securing the service, compliance with legal obligations, and consent where the service specifically asks for it. Customers are responsible for having an appropriate basis for the monitoring inputs and contact information they submit."]),
            .init(title: "9. Customer control and administrator responsibility", paragraphs: ["Organization owners control membership, watchlists, monitored terms, integrations, and delivery destinations. Customers are responsible for deciding what information to submit, who may access it, and which downstream systems receive alert or webhook content."]),
            .init(title: "10. Sharing and subprocessors", paragraphs: ["Hanasand may share information with service providers that host, secure, support, analyze, or deliver the service, including cloud infrastructure, email, logging, database, authentication, payment, support, and communications providers. Hanasand does not sell Customer Data as a standalone data feed. Information may also be disclosed when required by law, to protect rights or security, or as part of a corporate transaction."]),
            .init(title: "11. International processing", paragraphs: ["Hanasand may process information in countries where Hanasand, its infrastructure, or service providers operate. Where required, Hanasand uses appropriate transfer mechanisms and contractual controls for international processing."]),
            .init(title: "12. Retention", paragraphs: ["Hanasand keeps information for as long as needed to provide the service, meet contractual commitments, maintain security and audit records, resolve disputes, comply with law, and support business operations. Retention periods vary by data type, customer configuration, legal requirement, and operational need."]),
            .init(title: "13. Security", paragraphs: ["Hanasand uses administrative, technical, and organizational safeguards designed to protect information. These include access controls, authentication, logging, network and application controls, operational review, and limited access based on business need. No system is perfectly secure, and customers should protect their own accounts, webhook endpoints, devices, and downstream tools."]),
            .init(title: "14. Privacy rights", paragraphs: ["Depending on location and role, individuals may have rights to access, correct, delete, export, restrict, or object to certain processing. For information controlled by a Hanasand customer, requests should usually be directed to that customer. Hanasand will assist customers with reasonable privacy requests where required by law or contract."]),
            .init(title: "15. Children", paragraphs: ["Hanasand is a business service and is not intended for children. Customers must not knowingly submit information about children unless they have a lawful basis and the information is necessary for the configured service."]),
            .init(title: "16. Changes to this policy", paragraphs: ["Hanasand may update this Privacy Policy as the service, law, or operating practices change. Material updates will be posted on this page or communicated through reasonable channels. The effective date above shows when the current version took effect."]),
            .init(title: "17. Contact", paragraphs: ["Privacy questions, rights requests, security concerns, and contract notices may be sent through Hanasand support. Please identify the customer organization, the relevant account or integration, and the information involved so Hanasand can route the request correctly."])
        ],
        links: [.init(title: "Contact Hanasand", route: "/contact")]
    )

    static let terms = NativePublicInfoPage(
        route: "/terms", title: "Terms of use", eyebrow: "Terms",
        intro: "Effective July 3, 2026. These terms govern access to Hanasand services, including monitoring, alerting, API, webhook, and customer console features.",
        kind: .terms,
        sections: [
            .init(title: "1. Agreement and order of documents", paragraphs: ["These Terms of Use form a binding agreement between Hanasand and the organization or person accessing the service. If you use Hanasand on behalf of an organization, you confirm you have authority to bind it.", "A signed order form, data processing agreement, security addendum, or other written agreement controls where it expressly conflicts. Otherwise, these Terms apply to all service use."]),
            .init(title: "2. The service", paragraphs: ["Hanasand provides threat intelligence, exposure monitoring, alert routing, API access, webhooks, dashboards, and related operational tools. The service helps customers identify, review, and route external risk signals; it is not legal, incident response, insurance, or law enforcement advice."]),
            .init(title: "3. Customer accounts and administration", paragraphs: ["Customers are responsible for their users, administrators, credentials, API keys, webhook endpoints, watchlists, notification routes, and account configuration. Keep credentials confidential, use reasonable access controls, and promptly notify Hanasand about suspected unauthorized access."], bullets: ["Organization owners may invite members, configure integrations, and remove access.", "You are responsible for activity under your account unless caused by Hanasand's breach of these Terms.", "Hanasand may rely on administrator instructions unless it has reason to believe a request is unauthorized or unlawful."]),
            .init(title: "4. Permitted use", paragraphs: ["Use the service only for lawful security, risk, compliance, fraud, vendor, brand, domain, and operational monitoring. Ensure your use of alerts, exports, watchlists, searches, and integrations complies with applicable laws and policies."]),
            .init(title: "5. Prohibited use", paragraphs: ["Do not misuse the service or create legal, security, or platform risk for Hanasand, other customers, monitored sources, or third parties."], bullets: ["Do not harass, dox, surveil, discriminate against, or unlawfully profile people.", "Do not submit credentials, secrets, malware, exploit payloads, illegal content, or unnecessary sensitive personal data.", "Do not reverse engineer, bypass rate limits, disrupt, scrape, overload, or gain unauthorized access to Hanasand systems.", "Do not use outputs for offensive operations or unauthorized access.", "Do not resell, publish, or redistribute service data as a standalone feed without written agreement."]),
            .init(title: "6. Customer data and monitoring inputs", paragraphs: ["Customer Data includes account details, watch terms, domains, vendors, organizations, webhook endpoints, notes, tickets, API requests, and configuration. You retain ownership. You grant Hanasand the rights needed to host, process, secure, transmit, display, analyze, and support the data for the service. Hanasand may use aggregated or de-identified operational information to maintain, secure, measure, and improve the service, provided it does not identify you or your users."]),
            .init(title: "7. Threat intelligence sources and alert review", paragraphs: ["External sources may change, disappear, become unavailable, or require human review. Alerts may include metadata, source references, confidence signals, summaries, timestamps, and suggested next steps; not every alert will be complete, current, or actionable. Review alerts before acting. Hanasand does not represent that an alert proves compromise, breach, attribution, criminal conduct, sanctions exposure, or legal liability."]),
            .init(title: "8. Integrations, webhooks, and customer systems", paragraphs: ["For Slack, Discord, email, ticketing, SIEM, webhooks, internal tools, or other destinations, you are responsible for those systems and the information sent to them. You must have the right to configure each destination and keep endpoint secrets, signing keys, and credentials secure."]),
            .init(title: "9. API use and rate limits", paragraphs: ["API access is subject to authentication, documented limits, fair use controls, and security review. Hanasand may throttle, suspend, or reject requests that threaten stability, exceed purchased capacity, appear abusive, or violate these Terms."]),
            .init(title: "10. Security", paragraphs: ["Hanasand uses administrative, technical, and organizational safeguards designed to protect the service. No internet service is risk-free. Customers remain responsible for securing their networks, devices, identities, webhook destinations, and downstream systems."]),
            .init(title: "11. Confidentiality", paragraphs: ["Each party must protect non-public business, technical, security, pricing, product, customer, or operational information received from the other with reasonable care, using it only for this relationship. Standard exceptions apply to public, independently developed, lawfully received, or legally required disclosures."]),
            .init(title: "12. Fees, taxes, and renewals", paragraphs: ["Fees, billing periods, usage allowances, payment terms, taxes, renewal terms, and cancellation rights are stated in the applicable order, checkout flow, invoice, or written agreement. Fees are non-refundable except where required by law or where Hanasand materially fails to provide the purchased service and does not cure the failure within a reasonable time."]),
            .init(title: "13. Intellectual property", paragraphs: ["Hanasand and its licensors retain all rights in the service, software, models, designs, workflows, documentation, source connectors, dashboards, APIs, and technology. No rights transfer except the limited right to use the service during the subscription term. Hanasand may use feedback without restriction if it does not disclose your confidential information."]),
            .init(title: "14. Third-party services and materials", paragraphs: ["The service may reference or integrate with third-party sources, infrastructure, APIs, identity providers, messaging systems, or cloud services. Hanasand is not responsible for third-party services outside its control; third-party terms may apply."]),
            .init(title: "15. Beta and preview features", paragraphs: ["Beta, preview, experimental, or limited-availability features may change, be discontinued, have limited support, or produce incomplete results. Unless a written agreement says otherwise, they are provided as-is and should not be used for production-critical decisions without independent review."]),
            .init(title: "16. Suspension", paragraphs: ["Hanasand may suspend access if it reasonably believes continued access may violate law, compromise security, harm the service, expose another customer, exceed purchased rights, or violate these Terms. When practical and lawful, Hanasand will provide notice and an opportunity to resolve the issue."]),
            .init(title: "17. Disclaimers", paragraphs: ["Except as expressly stated in a written agreement, the service is provided as-is and as-available. Hanasand disclaims warranties of merchantability, fitness for a particular purpose, non-infringement, and uninterrupted or error-free operation. Hanasand does not guarantee detection of every source, alert, exposure, credential, actor mention, breach, or operational event."]),
            .init(title: "18. Limitation of liability", paragraphs: ["To the maximum extent permitted by law, neither party is liable for indirect, incidental, special, consequential, exemplary, or punitive damages, lost profits, lost revenue, lost goodwill, business interruption, or loss of data. Except for payment obligations, confidentiality breaches, misuse of intellectual property, or liabilities that cannot legally be limited, total liability is limited to amounts paid or payable for the service during the preceding twelve months."]),
            .init(title: "19. Indemnity", paragraphs: ["You will defend and indemnify Hanasand against third-party claims arising from Customer Data, unlawful service use, integrations, or violation of these Terms. Hanasand will defend and indemnify you against third-party claims alleging the service, as provided and used as permitted, infringes intellectual property rights. Prompt notice, cooperation, and defense control apply; settlements cannot admit fault or impose obligations without consent."]),
            .init(title: "20. Term and termination", paragraphs: ["These Terms apply while you access or use the service. Either party may terminate as stated in the applicable order or written agreement. Hanasand may terminate for material breach not cured within a reasonable period after notice, or immediately when cure is impractical because of legal, security, or abuse risk."]),
            .init(title: "21. Export, sanctions, and restricted parties", paragraphs: ["Comply with applicable export control, sanctions, anti-corruption, and restricted-party rules. Do not use the service where prohibited by law or for a sanctioned person, organization, or jurisdiction."]),
            .init(title: "22. Changes to these Terms", paragraphs: ["Hanasand may update these Terms as the service or law changes. Material changes will be posted here or communicated through reasonable channels and apply prospectively. If a change materially reduces your rights during a paid subscription term, you may stop using the affected service and contact Hanasand to discuss the applicable order."]),
            .init(title: "23. Governing law and disputes", paragraphs: ["Unless a written agreement states otherwise, these Terms are governed by the laws of Norway, without regard to conflict-of-law rules. The parties will first seek good-faith business escalation. Disputes unresolved that way will be heard in Norwegian courts, except either party may seek urgent injunctive relief in a court with jurisdiction."]),
            .init(title: "24. Contact", paragraphs: ["Questions about these Terms, security concerns, account access, or contract notices may be sent through Hanasand support. Identify the customer organization, relevant account or order, and issue requiring review."])
        ],
        links: [.init(title: "Contact support", route: "/contact")]
    )

    static let reservedUsernames = NativePublicInfoPage(
        route: "/reserved-usernames", title: "Reserved usernames", eyebrow: "Account policy",
        intro: "Some account names are protected because they imply system ownership, mail authority, security responsibility, management authority, financial control, or outside-company identity. These names cannot be registered by normal users.",
        kind: .reservedUsernames,
        sections: [
            .init(title: "System and infrastructure", paragraphs: ["Operational names that should only be controlled by Hanasand services."], bullets: ["admin", "administrator", "root", "sysadmin", "hanasand", "noreply"]),
            .init(title: "Mail and abuse handling", paragraphs: ["Addresses used for mail delivery, abuse reporting, trust, and security workflows."], bullets: ["postmaster", "abuse", "spam", "security", "soc", "trust", "compliance"]),
            .init(title: "Management and financial authority", paragraphs: ["Names that could imply official authority, finance ownership, or executive control."], bullets: ["ceo", "cfo", "coo", "cto", "director", "management", "finance", "billing"]),
            .init(title: "Brand impersonation", paragraphs: ["Names that imitate major outside companies or platforms."], bullets: ["google", "facebook", "meta", "microsoft", "paypal", "twitter"]),
            .init(title: "Exact reserved names", paragraphs: ["Protected usernames include the following exact names, plus lookalike patterns."], bullets: ["abuse", "admin", "administrator", "billing", "bookkeeper", "cdc", "ceo", "cfo", "chairman", "compliance", "contact", "controller", "coo", "cto", "director", "eirikhanasand", "executive", "facebook", "finance", "google", "hanasand", "help", "hr", "legal", "management", "manager", "meta", "microsoft", "noreply", "owner", "paypal", "postmaster", "president", "root", "security", "soc", "spam", "staff", "support", "sysadmin", "treasurer", "trust", "twitter", "x"])
        ],
        links: [.init(title: "Create an allowed account", route: "/register"), .init(title: "Request a reserved name", route: "/contact")]
    )

    static let pricing = NativePublicInfoPage(
        route: "/pricing", title: "Know more. Respond faster.", eyebrow: "Pricing",
        intro: "Search threats. Watch your exposure. Scan your attack surface. Investigate what you find.",
        kind: .pricing,
        sections: [.init(title: "Container host options", paragraphs: ["VM creation is free. Automatic failover is an optional upgrade: a standby copy on the other host with a verified container transfer."])]
    )

    static let scannerSolution = NativePublicInfoPage(
        route: "/solutions/scanner", title: "See exposure, changes, and the next control to review.",
        eyebrow: "Security Scanner · safe validation",
        intro: "Hanasand’s scanner runs bounded, identifiable checks against approved assets, preserves concrete results, and gives operators a history of every run. It validates controls without destructive exploit delivery.",
        kind: .scannerSolution,
        sections: [
            .init(title: "Actionable results", paragraphs: ["Review passed, warned, and failed controls with severity and target context."]),
            .init(title: "Historical runs", paragraphs: ["Compare current and previous scan durations, findings, and errors."]),
            .init(title: "Always scheduled", paragraphs: ["Keep the Hanasand organization scanning continuously with an adjustable cadence."])
        ],
        links: [.init(title: "Go to scanner workspace", route: "/scanner")]
    )

    static let monitoringSolution = NativePublicInfoPage(
        route: "/solutions/security-monitoring", title: "Turn security logs into findings your team can investigate.",
        eyebrow: "Security Monitoring · managed detection",
        intro: "Send JSON events to Hanasand for authentication checks, suspicious-login findings, and analyst review.",
        kind: .monitoringSolution,
        sections: [
            .init(title: "One endpoint", paragraphs: ["Send JSON events using an organization API key."]),
            .init(title: "Useful first detections", paragraphs: ["Start with repeated failures, new countries, and geographically incompatible logins."]),
            .init(title: "Evidence-first review", paragraphs: ["Inspect the matching events, rule ID, source context, and original event sample."]),
            .init(title: "Send an event", paragraphs: ["POST https://api.hanasand.com/mill\nAuthorization: Bearer hsk_<organization-key>\nContent-Type: application/json\n\n{\n  \"events\": [{\n    \"timestamp\": \"2026-08-03T08:15:00Z\",\n    \"event_type\": \"authentication\",\n    \"action\": \"login\",\n    \"outcome\": \"success\",\n    \"user\": {\"id\": \"user-123\"},\n    \"source\": {\"ip\": \"203.0.113.10\", \"country\": \"NO\"}\n  }]\n}"], bullets: ["Suspicious login findings", "Impossible-travel evidence", "Organization-specific raw and normalized events", "Extensible path for Sigma and Hanasand rules"])
        ],
        links: [.init(title: "Open cases", route: "/cases"), .init(title: "View API docs", route: "/developers")]
    )

    static let securityContact = NativePublicInfoPage(
        route: "/security.txt", title: "Report a security issue",
        eyebrow: "Security contact",
        intro: "Use this public security contact information to report a vulnerability affecting Hanasand.",
        kind: .securityContact,
        sections: [
            .init(title: "security.txt", paragraphs: [
                "Contact: mailto:security@hanasand.com",
                "Canonical: https://hanasand.com/security.txt",
                "Preferred-Languages: en",
                "Expires: 2027-10-04T00:00:00Z"
            ])
        ]
    )

    static let plans: [NativePublicInfoPlan] = [
        .init(checkoutPlanID: "threat-intelligence", name: "Threat Intelligence", priceNok: 199, quota: "100 searches per day", summary: "Search actors, domains, companies, and current public intelligence.", features: ["Threat actor profiles", "Current intelligence results", "API access", "Saved searches"]),
        .init(checkoutPlanID: "monitoring", name: "Dark Web Monitoring", priceNok: 499, quota: "25 watch terms", summary: "Monitor relevant public intelligence and turn matches into alerts and cases.", features: ["Customer watchlists", "Evidence-backed alerts", "Case workflow", "Source health and freshness"]),
        .init(checkoutPlanID: "scanner", name: "Security Scanner", priceNok: 299, quota: "10 monitored targets", summary: "Run scheduled security checks against approved websites and review the findings.", features: ["Scheduled scans", "Severity-based findings", "Scan history", "Run-now controls"])
    ]

    static let faqItems: [NativePublicInfoFAQ] = [
        .init(category: "Basics", question: "What is a threat actor?", answer: "A threat actor is a person, group, or organization that carries out cyber activity. In Hanasand, the term usually means a ransomware group, leak-site operator, broker, or criminal crew claiming access to data."),
        .init(category: "Monitoring", question: "What does Hanasand monitor?", answer: "Hanasand monitors company, vendor, domain, brand, and executive mentions across exposure sources such as leak sites, extortion posts, public threat intelligence, advisories, and analyst-reviewed records."),
        .init(category: "Alerts", question: "What counts as a company exposure alert?", answer: "An exposure alert is created when a monitored company, supplier, domain, or related term appears in a source that may indicate leaked data, ransomware activity, credential exposure, or a security-relevant claim."),
        .init(category: "Alerts", question: "Does an alert mean the company was breached?", answer: "No. An alert means a source made a relevant claim or mention. Hanasand shows the source, context, data mentioned, confidence, and next review step so an analyst can verify the claim before escalation."),
        .init(category: "Monitoring", question: "How often is activity refreshed?", answer: "The live activity feed refreshes automatically. Some sources update within minutes, while others depend on source availability, verification, and collection timing."),
        .init(category: "Monitoring", question: "Can Hanasand monitor vendors and suppliers?", answer: "Yes. Watchlists can include suppliers, portfolio companies, subsidiaries, domains, brands, and executive names so third-party exposure is visible before it becomes a customer issue."),
        .init(category: "Alerts", question: "What information is included in an alert?", answer: "A typical alert includes the actor or source, company name, data mentioned, country if available, timing, source context, confidence, and suggested triage action."),
        .init(category: "Basics", question: "What is dark web monitoring?", answer: "Dark web monitoring is the process of watching hard-to-find or restricted sources for mentions of companies, credentials, data sets, actors, and other risk signals."),
        .init(category: "Basics", question: "What is ransomware monitoring?", answer: "Ransomware monitoring tracks groups and leak sites where attackers publish claims about victims, stolen data, negotiations, or planned disclosures."),
        .init(category: "Basics", question: "What is a leak site?", answer: "A leak site is a page or service where an actor publishes victim names, samples, files, or claims intended to pressure organizations or advertise stolen data."),
        .init(category: "Alerts", question: "What does ‘not disclosed by TA’ mean?", answer: "It means the threat actor did not disclose that specific detail in the source material. Hanasand preserves that uncertainty instead of inventing missing facts."),
        .init(category: "Routing", question: "Can alerts be sent to our existing tools?", answer: "Yes. Alerts can be routed through webhooks and operational workflows so teams can send findings into Slack, Jira, SIEM, case queues, or internal review systems."),
        .init(category: "Monitoring", question: "Can we search historical exposure records?", answer: "Yes. The threat intelligence search lets teams look up companies, domains, vendors, groups, source notes, and past exposure records."),
        .init(category: "Alerts", question: "How should a team triage a new mention?", answer: "Check whether the source names the correct organization, whether the records match the business, how fresh the post is, and whether the actor has a history of credible claims."),
        .init(category: "Trust", question: "Does Hanasand replace incident response?", answer: "No. Hanasand provides monitoring, context, and routing. Incident response, legal review, forensics, and customer communication remain the responsibility of the organization and its response partners."),
        .init(category: "Trust", question: "Who is Hanasand for?", answer: "Hanasand is for security teams, founders, managed service providers, portfolio operators, and risk teams that need early visibility into external exposure claims.")
    ]

    static let reservedNames: [String] = [
        "abuse", "admin", "administrator", "billing", "bookkeeper", "cdc", "ceo", "cfo", "chairman", "compliance", "contact", "controller", "coo", "cto", "director", "eirikhanasand", "executive", "facebook", "finance", "google", "hanasand", "help", "hr", "legal", "management", "manager", "meta", "microsoft", "noreply", "owner", "paypal", "postmaster", "president", "root", "security", "soc", "spam", "staff", "support", "sysadmin", "treasurer", "trust", "twitter", "x"
    ]
}
