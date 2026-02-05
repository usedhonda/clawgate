import Foundation

enum Direction {
    case left, right, above, below
}

struct GeometryHint {
    let regionX: ClosedRange<Double>    // 0.0-1.0 relative to window width
    let regionY: ClosedRange<Double>    // 0.0-1.0 relative to window height
    let minWidth: Double?               // minimum width relative to window width
}

struct NeighborHint {
    let adjacentRole: String
    let direction: Direction
}
