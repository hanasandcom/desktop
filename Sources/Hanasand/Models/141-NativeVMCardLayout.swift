import SwiftUI

enum NativeVMCardLayout {
    // Keep status/value text readable in card columns at compact and wide widths.
    static let metricMinimumWidth: CGFloat = 180
    static let metricSpacing: CGFloat = 8

    static var metricColumns: [GridItem] {
        [GridItem(.adaptive(minimum: metricMinimumWidth), spacing: metricSpacing, alignment: .leading)]
    }

    static func metricColumnCount(contentWidth: CGFloat) -> Int {
        guard contentWidth.isFinite, contentWidth > 0 else { return 1 }
        return max(1, Int((contentWidth + metricSpacing) / (metricMinimumWidth + metricSpacing)))
    }
}
