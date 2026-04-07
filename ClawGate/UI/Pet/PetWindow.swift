import AppKit
import SwiftUI

/// Transparent always-on-top window for the pet character
final class PetWindowController {
    private var window: NSWindow?
    private var spriteView: PetSpriteView?
    private var bubbleHostingView: NSHostingView<AnyView>?
    private let model: PetModel
    private var observation: NSKeyValueObservation?
    private var stateObservation: Any?

    /// Character display size in points
    private let characterSize: CGFloat = 128

    init(model: PetModel) {
        self.model = model
    }

    func show() {
        guard window == nil else { return }

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        // Default position: bottom-right of screen
        let windowSize = NSSize(width: characterSize + 20, height: characterSize + 20)
        let origin = NSPoint(
            x: screenFrame.maxX - windowSize.width - 40,
            y: screenFrame.minY + 40
        )

        let w = NSWindow(
            contentRect: NSRect(origin: origin, size: windowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating
        w.hasShadow = false
        w.isMovableByWindowBackground = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.sharingType = .none
        w.isReleasedWhenClosed = false

        // Sprite view
        let sprite = PetSpriteView(frame: NSRect(origin: .zero, size: NSSize(width: characterSize, height: characterSize)))
        sprite.translatesAutoresizingMaskIntoConstraints = false

        let contentView = PetContentView(spriteView: sprite, model: model, characterSize: characterSize)
        w.contentView = contentView

        // Load initial character
        updateSpriteForCurrentState()

        window = w
        spriteView = sprite
        w.orderFront(nil)

        // Observe state machine changes
        stateObservation = model.stateMachine.$current.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateSpriteForCurrentState()
            }
        }

        // Observe opacity
        observation = model.observe(\.opacity, options: [.new]) { [weak w] _, change in
            w?.alphaValue = change.newValue ?? 1.0
        }
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
        spriteView = nil
        stateObservation = nil
        observation = nil
    }

    private func updateSpriteForCurrentState() {
        guard let sprite = spriteView else { return }
        let stateName = model.stateMachine.animationName
        if var character = model.characterManager.current() {
            let frames = character.frames(for: stateName)
            let fps = character.fps(for: stateName)
            if !frames.isEmpty {
                sprite.setAnimation(frames: frames, fps: fps, stateName: stateName)
            } else {
                // Fallback to idle
                let idleFrames = character.frames(for: "idle")
                sprite.setAnimation(frames: idleFrames, fps: character.fps(for: "idle"), stateName: "idle")
            }
        } else {
            // No character loaded — show placeholder
            let placeholder = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
                NSColor.systemPink.withAlphaComponent(0.3).setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4)).fill()
                return true
            }
            sprite.setStatic(placeholder)
        }
    }
}

// MARK: - Content View (sprite + click handling + bubble)

private final class PetContentView: NSView {
    private let spriteView: PetSpriteView
    private let model: PetModel
    private let characterSize: CGFloat
    private var bubbleWindow: NSWindow?
    private var bubbleObservation: Any?

    init(spriteView: PetSpriteView, model: PetModel, characterSize: CGFloat) {
        self.spriteView = spriteView
        self.model = model
        self.characterSize = characterSize
        super.init(frame: .zero)
        addSubview(spriteView)

        // Observe bubble visibility
        bubbleObservation = model.stateMachine.$isBubbleVisible.sink { [weak self] visible in
            DispatchQueue.main.async {
                if visible {
                    self?.showBubble()
                } else {
                    self?.hideBubble()
                }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        spriteView.frame = bounds
    }

    override func mouseDown(with event: NSEvent) {
        model.stateMachine.handle(.userClicked)
    }

    // MARK: - Bubble Window

    private func showBubble() {
        guard bubbleWindow == nil, let parentWindow = window else { return }
        let bubbleView = PetBubbleView(model: model)
        let hosting = NSHostingView(rootView: AnyView(bubbleView))
        hosting.frame = NSRect(x: 0, y: 0, width: 260, height: 260)

        let bw = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 260),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        bw.isOpaque = false
        bw.backgroundColor = .clear
        bw.level = .floating
        bw.hasShadow = true
        bw.contentView = hosting
        bw.isReleasedWhenClosed = false

        // Position bubble above the character
        let parentFrame = parentWindow.frame
        let bubbleOrigin = NSPoint(
            x: parentFrame.midX - 130,
            y: parentFrame.maxY + 8
        )
        bw.setFrameOrigin(bubbleOrigin)

        parentWindow.addChildWindow(bw, ordered: .above)
        bubbleWindow = bw
    }

    private func hideBubble() {
        if let bw = bubbleWindow {
            window?.removeChildWindow(bw)
            bw.orderOut(nil)
            bubbleWindow = nil
        }
    }
}
