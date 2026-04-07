import AppKit
import Combine
import SwiftUI

/// Transparent always-on-top window for the pet character
final class PetWindowController {
    private var window: NSWindow?
    private var spriteView: PetSpriteView?
    private var bubbleHostingView: NSHostingView<AnyView>?
    private let model: PetModel
    private var opacityObservation: AnyCancellable?
    private var stateObservation: AnyCancellable?

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

        window = w
        spriteView = sprite
        w.orderFront(nil)

        // Load initial character (spriteView must be set first)
        updateSpriteForCurrentState()

        // Observe state machine changes
        stateObservation = model.stateMachine.$current.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateSpriteForCurrentState()
            }
        }

        // Observe opacity via Combine
        opacityObservation = model.$opacity.sink { [weak w] newValue in
            DispatchQueue.main.async {
                w?.alphaValue = newValue
            }
        }
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
        spriteView = nil
        stateObservation = nil
        opacityObservation = nil
    }

    private func updateSpriteForCurrentState() {
        guard let sprite = spriteView else { return }
        let stateName = model.stateMachine.animationName
        if var character = model.characterManager.current() {
            let frames = character.frames(for: stateName)
            let fps = character.fps(for: stateName)
            let loop = character.shouldLoop(for: stateName)
            if !frames.isEmpty {
                sprite.setAnimation(frames: frames, fps: fps, stateName: stateName, loop: loop)
                if !loop {
                    sprite.onAnimationComplete = { [weak self] in
                        // Return to idle after non-looping animation
                        DispatchQueue.main.async {
                            self?.model.stateMachine.handle(.assistantFinished)
                        }
                    }
                }
            } else {
                // Fallback to idle
                let idleFrames = character.frames(for: "idle")
                sprite.setAnimation(frames: idleFrames, fps: character.fps(for: "idle"), stateName: "idle", loop: true)
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
    private var whisperWindow: NSWindow?
    private var bubbleObservation: Any?
    private var whisperObservation: Any?

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

        // Observe whisper text (Layer 1)
        whisperObservation = model.$whisperText.sink { [weak self] text in
            DispatchQueue.main.async {
                if let text, !text.isEmpty {
                    self?.showWhisper(text)
                } else {
                    self?.hideWhisper()
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

    // MARK: - Right-Click Context Menu

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()

        // Mode items
        for mode in PetModel.PetMode.allCases {
            let item = NSMenuItem(title: mode.rawValue, action: #selector(changePetMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            item.state = model.petMode == mode ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Open chat
        let chatItem = NSMenuItem(title: "チャットを開く", action: #selector(openChat(_:)), keyEquivalent: "")
        chatItem.target = self
        menu.addItem(chatItem)

        menu.addItem(.separator())

        // Opacity submenu
        let opacityItem = NSMenuItem(title: "透明度", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        for percent in [100, 75, 50, 25] {
            let value = Double(percent) / 100.0
            let sub = NSMenuItem(title: "\(percent)%", action: #selector(changeOpacity(_:)), keyEquivalent: "")
            sub.target = self
            sub.tag = percent
            sub.state = abs(model.opacity - value) < 0.01 ? .on : .off
            opacityMenu.addItem(sub)
        }
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func changePetMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? PetModel.PetMode else { return }
        model.petMode = mode
    }

    @objc private func openChat(_ sender: NSMenuItem) {
        model.stateMachine.handle(.userDoubleClicked)
    }

    @objc private func changeOpacity(_ sender: NSMenuItem) {
        model.opacity = Double(sender.tag) / 100.0
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

    // MARK: - Whisper Window (Layer 1)

    private func showWhisper(_ text: String) {
        hideWhisper()
        guard let parentWindow = window else { return }

        let whisperView = PetWhisperView(text: text)
        let hosting = NSHostingView(rootView: AnyView(whisperView))
        let size = hosting.intrinsicContentSize
        let w = max(size.width + 16, 60)
        let h = max(size.height + 8, 24)
        hosting.frame = NSRect(x: 0, y: 0, width: w, height: h)

        let ww = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        ww.isOpaque = false
        ww.backgroundColor = .clear
        ww.level = .floating
        ww.hasShadow = false
        ww.contentView = hosting
        ww.isReleasedWhenClosed = false
        ww.ignoresMouseEvents = true

        let parentFrame = parentWindow.frame
        let origin = NSPoint(
            x: parentFrame.midX - w / 2,
            y: parentFrame.maxY + 2
        )
        ww.setFrameOrigin(origin)

        parentWindow.addChildWindow(ww, ordered: .above)
        whisperWindow = ww
    }

    private func hideWhisper() {
        if let ww = whisperWindow {
            window?.removeChildWindow(ww)
            ww.orderOut(nil)
            whisperWindow = nil
        }
    }
}
