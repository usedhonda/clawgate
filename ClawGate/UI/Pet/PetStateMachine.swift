import Foundation

/// Legacy combined state kept as a compatibility bridge while locomotion and
/// expression are split into separate layers.
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

enum PetExpression: String, CaseIterable {
    case idle
    case blinkA = "blink-a"
    case blinkB = "blink-b"
    case bodyA = "body-a"
    case bodyB = "body-b"
    case speak
    case speakMix = "speak-mix"
    case speakTilt = "speak-tilt"
    case talk
    case wave
    case react
    case blush
    case secretary
    case funny
    case sleep
    case idleBreathe = "idle-breathe"
    case blink
}

enum LocomotionState: Equatable {
    case stationary
    case walking(WalkDirection)

    enum WalkDirection: String {
        case front = "walk-front"
        case back = "walk-back"
        case left = "walk-left"
        case right = "walk-right"
    }
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
    @Published var expression: PetExpression = .idle
    @Published var locomotion: LocomotionState = .stationary
    @Published var isBubbleVisible = false
    @Published var isChatOpen = false
    /// Whisper text is managed by PetModel (Layer 1 display payload)

    /// Transition based on incoming event
    @discardableResult
    func handle(_ event: PetEvent) -> PetExpression {
        switch event {
        case .assistantStarted:
            expression = randomSpeakState()

        case .assistantFinished:
            expression = .idle

        case .userClicked:
            // Simple toggle: click = chat open/close
            NSLog("[Pet] userClicked: isChatOpen=%d isBubbleVisible=%d", isChatOpen ? 1 : 0, isBubbleVisible ? 1 : 0)
            if isChatOpen {
                isChatOpen = false
            } else {
                isChatOpen = true
                isBubbleVisible = false
            }
            NSLog("[Pet] after userClicked: isChatOpen=%d", isChatOpen ? 1 : 0)

        case .userDoubleClicked:
            NSLog("[Pet] userDoubleClicked: isChatOpen=%d", isChatOpen ? 1 : 0)
            if isChatOpen {
                isChatOpen = false
            } else {
                isChatOpen = true
                isBubbleVisible = false
            }

        case .bubbleDismissed:
            isBubbleVisible = false
            // Don't touch isChatOpen — notification dismiss is independent of chat

        case .mouseEntered:
            break  // PetModel handles whisper

        case .mouseExited:
            break

        case .disconnected:
            expression = .sleep

        case .reconnected:
            expression = .idle

        case .idleTimeout:
            let variations: [PetExpression] = [.idleBreathe, .blink, .secretary, .funny]
            expression = variations.randomElement() ?? .idleBreathe

        case .notification:
            break  // PetModel handles whisper text

        case .greeting:
            expression = .wave

        case .error:
            expression = .react

        case .success:
            expression = .react

        case .lateNight:
            expression = .sleep
        }
        return expression
    }

    /// Pick a random speak animation for variety
    private func randomSpeakState() -> PetExpression {
        let options: [PetExpression] = [.speak, .speakMix, .speakTilt, .talk]
        return options.randomElement() ?? .speak
    }

    var resolvedAnimationName: String {
        switch locomotion {
        case .walking(let direction):
            switch expression {
            case .speak, .speakMix, .speakTilt, .talk, .wave:
                return expression.rawValue
            default:
                return direction.rawValue
            }
        case .stationary:
            return expression.rawValue
        }
    }

    /// Legacy bridge for code that still talks in the old combined-state dialect.
    var current: PetState {
        get {
            switch locomotion {
            case .walking(.front): return .walkFront
            case .walking(.back): return .walkBack
            case .walking(.left): return .walkLeft
            case .walking(.right): return .walkRight
            case .stationary:
                switch expression {
                case .idle: return .idle
                case .blinkA: return .blinkA
                case .blinkB: return .blinkB
                case .bodyA: return .bodyA
                case .bodyB: return .bodyB
                case .speak: return .speak
                case .speakMix: return .speakMix
                case .speakTilt: return .speakTilt
                case .talk: return .talk
                case .wave: return .wave
                case .react: return .react
                case .blush: return .blush
                case .secretary: return .secretary
                case .funny: return .funny
                case .sleep: return .sleep
                case .idleBreathe: return .idleBreathe
                case .blink: return .blink
                }
            }
        }
        set {
            switch newValue {
            case .walkFront:
                locomotion = .walking(.front)
            case .walkBack:
                locomotion = .walking(.back)
            case .walkLeft:
                locomotion = .walking(.left)
            case .walkRight:
                locomotion = .walking(.right)
            case .idle:
                locomotion = .stationary
                expression = .idle
            case .blinkA:
                locomotion = .stationary
                expression = .blinkA
            case .blinkB:
                locomotion = .stationary
                expression = .blinkB
            case .bodyA:
                locomotion = .stationary
                expression = .bodyA
            case .bodyB:
                locomotion = .stationary
                expression = .bodyB
            case .speak:
                locomotion = .stationary
                expression = .speak
            case .speakMix:
                locomotion = .stationary
                expression = .speakMix
            case .speakTilt:
                locomotion = .stationary
                expression = .speakTilt
            case .talk:
                locomotion = .stationary
                expression = .talk
            case .wave:
                locomotion = .stationary
                expression = .wave
            case .react:
                locomotion = .stationary
                expression = .react
            case .blush:
                locomotion = .stationary
                expression = .blush
            case .secretary:
                locomotion = .stationary
                expression = .secretary
            case .funny:
                locomotion = .stationary
                expression = .funny
            case .sleep:
                locomotion = .stationary
                expression = .sleep
            case .idleBreathe:
                locomotion = .stationary
                expression = .idleBreathe
            case .blink:
                locomotion = .stationary
                expression = .blink
            }
        }
    }
}
