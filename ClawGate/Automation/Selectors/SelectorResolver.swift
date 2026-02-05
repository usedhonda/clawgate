import ApplicationServices
import Foundation

enum SelectorResolver {

    static func resolve(
        selector: UniversalSelector,
        in nodes: [AXNode],
        windowFrame: CGRect
    ) -> SelectorCandidate? {
        // L1: Direct Match (identifier / title / description exact match)
        if let result = resolveL1(selector: selector, in: nodes) {
            return result
        }
        // L3: Capability + Geometry Search
        return resolveL3(selector: selector, in: nodes, windowFrame: windowFrame)
    }

    // MARK: - L1 Direct Match

    private static func resolveL1(
        selector: UniversalSelector,
        in nodes: [AXNode]
    ) -> SelectorCandidate? {
        // Identifier match (highest confidence)
        if let id = selector.identifier {
            if let node = nodes.first(where: { $0.identifier == id }) {
                let roleMatch = selector.role == nil || node.role == selector.role
                return SelectorCandidate(
                    node: node,
                    confidence: roleMatch ? 1.0 : 0.9,
                    matchedLayer: 1
                )
            }
        }

        // Text hint exact match on title/description/value
        if !selector.textHints.isEmpty {
            let loweredHints = selector.textHints.map { $0.lowercased() }
            var bestNode: AXNode?
            var bestScore = 0

            for node in nodes {
                if let role = selector.role, node.role != role { continue }
                if let subrole = selector.subrole, node.subrole != subrole { continue }

                var score = 0
                let title = node.title?.lowercased() ?? ""
                let desc = node.description?.lowercased() ?? ""
                let val = node.value?.lowercased() ?? ""

                for hint in loweredHints {
                    if title.contains(hint) { score += 3 }
                    if desc.contains(hint) { score += 2 }
                    if val.contains(hint) { score += 1 }
                }

                if score > bestScore {
                    bestScore = score
                    bestNode = node
                }
            }

            if let node = bestNode, bestScore > 0 {
                let confidence = min(1.0, 0.7 + Double(bestScore) * 0.05)
                return SelectorCandidate(node: node, confidence: confidence, matchedLayer: 1)
            }
        }

        return nil
    }

    // MARK: - L3 Capability + Geometry Search

    private static func resolveL3(
        selector: UniversalSelector,
        in nodes: [AXNode],
        windowFrame: CGRect
    ) -> SelectorCandidate? {
        var candidates: [(node: AXNode, score: Double)] = []

        for node in nodes {
            var score = 0.0

            // Role match
            if let role = selector.role {
                guard node.role == role else { continue }
                score += 0.2
            }

            // Subrole match
            if let subrole = selector.subrole {
                guard node.subrole == subrole else { continue }
                score += 0.1
            }

            // Required actions check
            if !selector.requiredActions.isEmpty {
                let hasAll = selector.requiredActions.allSatisfy { node.actions.contains($0) }
                guard hasAll else { continue }
                score += 0.15
            }

            // Must be settable check
            if !selector.mustBeSettable.isEmpty {
                let hasAll = selector.mustBeSettable.allSatisfy { node.settableAttributes.contains($0) }
                guard hasAll else { continue }
                score += 0.2
            }

            // Geometry check
            if let geo = selector.geometryHint, windowFrame.width > 0 && windowFrame.height > 0 {
                guard let frame = node.frame else { continue }
                let relX = Double(frame.midX - windowFrame.origin.x) / Double(windowFrame.width)
                let relY = Double(frame.midY - windowFrame.origin.y) / Double(windowFrame.height)

                guard geo.regionX.contains(relX) && geo.regionY.contains(relY) else { continue }
                score += 0.25

                if let minW = geo.minWidth {
                    let relW = Double(frame.width) / Double(windowFrame.width)
                    guard relW >= minW else { continue }
                    score += 0.05
                }
            }

            // Neighbor hint check
            if let neighbor = selector.neighborHint, let frame = node.frame {
                let hasNeighbor = nodes.contains { other in
                    guard other.role == neighbor.adjacentRole, let otherFrame = other.frame else { return false }
                    switch neighbor.direction {
                    case .left:
                        return otherFrame.maxX <= frame.minX && abs(otherFrame.midY - frame.midY) < frame.height
                    case .right:
                        return otherFrame.minX >= frame.maxX && abs(otherFrame.midY - frame.midY) < frame.height
                    case .above:
                        return otherFrame.maxY <= frame.minY && abs(otherFrame.midX - frame.midX) < frame.width
                    case .below:
                        return otherFrame.minY >= frame.maxY && abs(otherFrame.midX - frame.midX) < frame.width
                    }
                }
                if hasNeighbor {
                    score += 0.1
                }
            }

            if score > 0 {
                candidates.append((node: node, score: score))
            }
        }

        guard let best = candidates.max(by: { $0.score < $1.score }) else { return nil }
        let confidence = min(0.85, best.score)
        return SelectorCandidate(node: best.node, confidence: confidence, matchedLayer: 3)
    }
}
