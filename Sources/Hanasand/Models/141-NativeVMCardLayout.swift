import SwiftUI

enum NativeVMCardLayout {
    static let metricMinimumWidth: CGFloat = 132
    static let metricSpacing: CGFloat = 8

    static var metricColumns: [GridItem] {
        [GridItem(.adaptive(minimum: metricMinimumWidth), spacing: metricSpacing, alignment: .leading)]
    }

    static func metricColumnCount(contentWidth: CGFloat) -> Int {
        guard contentWidth.isFinite, contentWidth > 0 else { return 1 }
        return max(1, Int((contentWidth + metricSpacing) / (metricMinimumWidth + metricSpacing)))
    }
}
