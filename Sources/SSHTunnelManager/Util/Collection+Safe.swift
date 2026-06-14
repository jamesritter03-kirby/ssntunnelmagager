import Foundation

extension Collection {
    /// Returns the element at `index` if it is within bounds, otherwise `nil`.
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
