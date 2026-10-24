struct CasesWorkspaceFilters: Equatable {
    var search = ""
    var status = "active"
    var severity = "all"
    var source = "all"
    var owner = "all"
    var resolution = "all"
    var review = "all"

    var hasActiveFilters: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || status != "active" || severity != "all" || source != "all"
            || owner != "all" || resolution != "all" || review != "all"
    }

    mutating func reset() {
        self = Self()
    }
}
