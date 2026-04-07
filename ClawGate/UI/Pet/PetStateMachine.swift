import Foundation

/// Pet character states (Phase 1: idle + speak only)
enum PetState: String, CaseIterable {
    case idle
    case speak

    // Phase 2 (not yet implemented)
    // case hover
    // case walk
    // case react
    // case sleep
}

/// Events that trigger state transitions
enum PetEvent {
    case assistantStarted          // assistant.message.start -> speak
    case assistantFinished         // assistant.message.done  -> idle
    case userClicked               // click -> show bubble
    case bubbleDismissed           // escape / click outside
    case disconnected              // ws disconnect (Phase 2: -> sleep)
    case reconnected               // ws reconnect  (Phase 2: -> idle)
}

/// Minimal state machine for pet character animation
final class PetStateMachine: ObservableObject {
    @Published private(set) var current: PetState = .idle
    @Published private(set) var isBubbleVisible = false

    /// Transition based on incoming event. Returns the new state.
    @discardableResult
    func handle(_ event: PetEvent) -> PetState {
        switch event {
        case .assistantStarted:
            current = .speak
            isBubbleVisible = true
        case .assistantFinished:
            current = .idle
            // Keep bubble visible so user can read the response
        case .userClicked:
            isBubbleVisible = true
        case .bubbleDismissed:
            isBubbleVisible = false
            if current == .speak {
                // If still speaking, let it finish; otherwise go idle
            }
        case .disconnected:
            current = .idle
            // Phase 2: current = .sleep
        case .reconnected:
            current = .idle
        }
        return current
    }

    /// Animation name for the current state (maps to sprite sheet row)
    var animationName: String {
        current.rawValue
    }
}
