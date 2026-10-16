import Foundation

enum MenuBarStatusItemPlacement {
    static let autosaveName = "ClawGate"
    static let positionKey = "NSStatusItem Preferred Position \(autosaveName)"
    static let savedPositionKey = "ClawGateStatusItemPosition"

    static func preferredPosition(savedPosition: Double?, rightSideWidth: Double) -> Double {
        guard let savedPosition,
              savedPosition.isFinite,
              savedPosition >= 0,
              savedPosition < rightSideWidth else { return 0 }
        return savedPosition
    }
}
