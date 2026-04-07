import Foundation

/// Pet character states
enum PetState: String, CaseIterable {
    case idle
    case blinkA = "blink-a"
    case blinkB = "blink-b"
    case bodyA = "body-a"
    case bodyB = "body-b"
    case speak
    case speakMix = "speak-mix"
    case speakTilt = "speak-tilt"
    case talk
    case walkFront = "walk-front"
    case walkBack = "walk-back"
    case walkRight = "walk-right"
    case walkLeft = "walk-left"
    case wave
    case react
    case blush
    case secretary
    case funny
    case sleep
    case idleBreathe = "idle-breathe"
    case blink
}

/// Events that trigger state transitions
enum PetEvent {
    case assistantStarted          // message incoming -> speak
    case assistantFinished         // message done -> idle
    case userClicked               // click -> show bubble / open chat
    case userDoubleClicked         // double click -> open full chat
    case bubbleDismissed           // escape / click outside
    case mouseEntered              // hover -> react
    case mouseExited               // hover end -> idle
    case disconnected              // ws disconnect -> sleep
    case reconnected               // ws reconnect -> idle
    case idleTimeout               // long idle -> breathe/walk/secretary
    case notification(String)      // whisper text for Layer 1 reaction
    case greeting                  // morning/startup -> wave
    case error                     // error -> react
    case success                   // task done -> react happy
    case lateNight                 // deep night -> sleepy
}

/// State machine for pet character with 3-layer UX
final class PetStateMachine: ObservableObject {
    @Published var current: PetState = .idle
    @Published var isBubbleVisible = false
    @Published private(set) var isChatOpen = false
    /// Whisper text is managed by PetModel (Layer 1 display payload)

    /// Transition based on incoming event
    @discardableResult
    func handle(_ event: PetEvent) -> PetState {
        switch event {
        case .assistantStarted:
            current = randomSpeakState()

        case .assistantFinished:
            current = .idle

        case .userClicked:
            // Simple toggle: click = chat open/close
            if isChatOpen {
                isChatOpen = false
            } else {
                isChatOpen = true
                isBubbleVisible = false  // dismiss notification when opening chat
            }

        case .userDoubleClicked:
            // Same as single click
            if isChatOpen {
                isChatOpen = false
            } else {
                isChatOpen = true
                isBubbleVisible = false
            }

        case .bubbleDismissed:
            isBubbleVisible = false
            isChatOpen = false
            if current != .speak && current != .speakMix && current != .speakTilt && current != .talk {
                current = .idle
            }

        case .mouseEntered:
            break  // PetModel handles whisper

        case .mouseExited:
            break

        case .disconnected:
            current = .sleep

        case .reconnected:
            current = .idle

        case .idleTimeout:
            let variations: [PetState] = [.idleBreathe, .blink, .secretary, .funny]
            current = variations.randomElement() ?? .idleBreathe

        case .notification:
            break  // PetModel handles whisper text

        case .greeting:
            current = .wave

        case .error:
            current = .react

        case .success:
            current = .react

        case .lateNight:
            current = .sleep
        }
        return current
    }

    /// Pick a random speak animation for variety
    private func randomSpeakState() -> PetState {
        let options: [PetState] = [.speak, .speakMix, .speakTilt, .talk]
        return options.randomElement() ?? .speak
    }

    /// Animation name for the current state (maps to manifest state name)
    var animationName: String {
        current.rawValue
    }

}
