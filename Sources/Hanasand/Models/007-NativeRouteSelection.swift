import Foundation

enum NativeRouteSelection {
    static func resolve(_ requestedID: String, among availableIDs: [String]) -> String? {
        let identifier = requestedID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty,
              identifier != ".",
              identifier != "..",
              !identifier.contains("/"),
              !identifier.contains("\\"),
              !identifier.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              availableIDs.contains(identifier) else {
            return nil
        }
        return identifier
    }
}
