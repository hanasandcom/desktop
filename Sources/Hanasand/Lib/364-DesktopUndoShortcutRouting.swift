enum DesktopUndoShortcutTarget: Equatable {
    case undoImageDecision
    case redoThesisDraft
}

enum DesktopUndoShortcutRouting {
    static func commandShiftZTarget(section: DesktopSection, dashboardPath: String?) -> DesktopUndoShortcutTarget? {
        if section == .images { return .undoImageDecision }
        if section == .dashboard, dashboardPath == "/thesis" { return .redoThesisDraft }
        return nil
    }
}
