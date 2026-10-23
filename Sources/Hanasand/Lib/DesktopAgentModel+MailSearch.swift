import Foundation

extension DesktopAgentModel {
    func searchMail(_ text: String, after cursor: String? = nil) async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            mailSearchRequestGeneration += 1
            mailSearchQuery = ""
            mailSearchResults = []
            mailSearchCursor = nil
            mailSearchError = ""
            mailSearchPending = false
            return
        }

        guard let mailboxUser = mailOverview?.mailboxUser, !mailboxUser.isEmpty,
              !selectedMailboxID.isEmpty else {
            mailSearchError = "Select a mailbox before searching."
            mailSearchPending = false
            return
        }
        guard hasHanasandAuth else {
            mailSearchError = "Sign in to search this mailbox."
            mailSearchPending = false
            return
        }

        if cursor == nil {
            mailSearchRequestGeneration += 1
            mailSearchQuery = query
            mailSearchResults = []
            mailSearchCursor = nil
            mailSearchError = ""
        } else if query != mailSearchQuery {
            return
        }

        let generation = mailSearchRequestGeneration
        let mailboxID = selectedMailboxID
        mailSearchPending = true
        do {
            let url = try MailSearchRequest.makeURL(
                baseURL: settings.apiBaseURL,
                mailboxUser: mailboxUser,
                mailboxID: mailboxID,
                query: query,
                after: cursor
            )
            let page: MailSearchPage = try await requestJSON(url, authenticated: true)
            guard generation == mailSearchRequestGeneration,
                  mailboxUser == mailOverview?.mailboxUser,
                  selectedMailboxID == mailboxID,
                  query == mailSearchQuery else { return }

            if cursor == nil {
                mailSearchResults = page.messages
            } else {
                var seen = Set(mailSearchResults.map(\.id))
                mailSearchResults.append(contentsOf: page.messages.filter { seen.insert($0.id).inserted })
            }
            mailSearchCursor = page.nextCursor
            mailSearchError = ""
        } catch {
            guard generation == mailSearchRequestGeneration else { return }
            mailSearchError = error.localizedDescription
        }
        if generation == mailSearchRequestGeneration {
            mailSearchPending = false
        }
    }

    func resetMailSearch() {
        mailSearchRequestGeneration += 1
        mailSearchQuery = ""
        mailSearchResults = []
        mailSearchCursor = nil
        mailSearchError = ""
        mailSearchPending = false
    }
}
