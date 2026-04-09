import AppKit
import Foundation

/// Owns the full pet movement lifecycle so locomotion state is not split across
/// the polling model and the window controller animation callbacks.
final class MoveController {
    private weak var window: NSWindow?
    private unowned let stateMachine: PetStateMachine

    private(set) var generation: UInt = 0
    private(set) var isMoving = false
    private(set) var currentOrigin: NSPoint?

    private var pendingTarget: NSPoint?
    private var pendingWaveOnArrival = false
    private var moveTimer: Timer?

    init(stateMachine: PetStateMachine) {
        self.stateMachine = stateMachine
    }

    func bind(window: NSWindow) {
        self.window = window
        currentOrigin = window.frame.origin
    }

    enum MoveStyle { case animated, immediate }

    func moveTo(_ target: NSPoint, waveOnArrival: Bool, style: MoveStyle = .animated) {
        if style == .immediate {
            stop()
            window?.setFrameOrigin(target)
            currentOrigin = target
            return
        }
        if isMoving {
            pendingTarget = target
            pendingWaveOnArrival = waveOnArrival
            return
        }
        startMove(to: target, waveOnArrival: waveOnArrival)
    }

    func stop() {
        generation &+= 1
        moveTimer?.invalidate()
        moveTimer = nil
        pendingTarget = nil
        pendingWaveOnArrival = false
        isMoving = false
        currentOrigin = window?.frame.origin ?? currentOrigin
        stateMachine.locomotion = .stationary
    }

    private func startMove(to target: NSPoint, waveOnArrival: Bool) {
        guard let window else {
            stop()
            return
        }

        let start = window.frame.origin
        currentOrigin = start
        let dx = target.x - start.x
        let dy = target.y - start.y
        let distance = sqrt(dx * dx + dy * dy)

        guard distance > 5 else {
            currentOrigin = target
            stateMachine.locomotion = .stationary
            return
        }

        // Teleport for very long distances
        if distance > 2000 {
            stop()
            window.setFrameOrigin(target)
            currentOrigin = target
            stateMachine.locomotion = .stationary
            if waveOnArrival {
                stateMachine.expression = .wave
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    if self?.stateMachine.expression == .wave {
                        self?.stateMachine.expression = .idle
                    }
                }
            }
            return
        }

        generation &+= 1
        let gen = generation
        isMoving = true
        stateMachine.expression = .idle  // interrupt any blink/body animation
        stateMachine.locomotion = .walking(directionForMove(dx: dx, dy: dy))

        let speed: Double = distance < 200 ? 200 : distance < 500 ? 400 : distance < 1000 ? 1500 : 3000
        let duration: TimeInterval = min(max(distance / speed, 0.3), 1.5)
        let steps = max(1, Int(duration * 60))
        let interval = duration / Double(steps)
        var step = 0

        moveTimer?.invalidate()
        moveTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self, weak window] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            guard self.generation == gen else {
                timer.invalidate()
                if self.moveTimer === timer {
                    self.moveTimer = nil
                }
                return
            }
            guard let window else {
                timer.invalidate()
                if self.moveTimer === timer {
                    self.moveTimer = nil
                }
                self.stop()
                return
            }

            step += 1
            let t = min(Double(step) / Double(steps), 1.0)
            let ease = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            let x = start.x + dx * ease
            let y = start.y + dy * ease
            window.setFrameOrigin(NSPoint(x: x, y: y))
            self.currentOrigin = NSPoint(x: x, y: y)

            if step >= steps {
                timer.invalidate()
                self.finishMove(timer: timer, generation: gen, target: target, waveOnArrival: waveOnArrival)
            }
        }
    }

    private func finishMove(timer: Timer, generation gen: UInt, target: NSPoint, waveOnArrival: Bool) {
        guard generation == gen else {
            if moveTimer === timer {
                moveTimer = nil
            }
            return
        }

        moveTimer = nil
        currentOrigin = target
        stateMachine.locomotion = .stationary
        isMoving = false

        if waveOnArrival {
            stateMachine.expression = .wave
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, self.generation == gen else { return }
                if self.stateMachine.expression == .wave {
                    self.stateMachine.expression = .idle
                }
            }
        }

        if let next = pendingTarget {
            let nextWave = pendingWaveOnArrival
            pendingTarget = nil
            pendingWaveOnArrival = false
            startMove(to: next, waveOnArrival: nextWave)
        }
    }

    private func directionForMove(dx: CGFloat, dy: CGFloat) -> LocomotionState.WalkDirection {
        if abs(dx) > abs(dy) {
            return dx > 0 ? .right : .left
        }
        return dy > 0 ? .back : .front
    }
}
