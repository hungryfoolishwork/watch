import Foundation

extension Array {

    /// Moves the elements at `source` so they sit before the element that's
    /// currently at `destination`, keeping their order. The same as SwiftUI's
    /// `move(fromOffsets:toOffset:)`, for code that doesn't import SwiftUI.
    public mutating func shift(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { self[$0] }
        let before = indices.filter { $0 < destination && !source.contains($0) }.map { self[$0] }
        let after = indices.filter { $0 >= destination && !source.contains($0) }.map { self[$0] }
        self = before + moving + after
    }
}
