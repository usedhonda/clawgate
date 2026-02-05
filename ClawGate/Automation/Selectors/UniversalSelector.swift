import Foundation

struct UniversalSelector {
    let role: String?
    let subrole: String?
    let identifier: String?
    let textHints: [String]
    let requiredActions: [String]
    let mustBeSettable: [String]
    let geometryHint: GeometryHint?
    let neighborHint: NeighborHint?

    init(
        role: String? = nil,
        subrole: String? = nil,
        identifier: String? = nil,
        textHints: [String] = [],
        requiredActions: [String] = [],
        mustBeSettable: [String] = [],
        geometryHint: GeometryHint? = nil,
        neighborHint: NeighborHint? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.textHints = textHints
        self.requiredActions = requiredActions
        self.mustBeSettable = mustBeSettable
        self.geometryHint = geometryHint
        self.neighborHint = neighborHint
    }
}

struct SelectorCandidate {
    let node: AXNode
    let confidence: Double   // 0.0 - 1.0
    let matchedLayer: Int    // 1-4
}
