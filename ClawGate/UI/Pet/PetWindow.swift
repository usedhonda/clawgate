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
    private var positionObservation: AnyCancellable?
    private var sizeObservation: AnyCancellable?

    init(model: PetModel) {
        self.model = model
    }

    func show() {
        guard window == nil else { return }

        let characterSize = model.characterSize
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
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
        w.isMovableByWindowBackground = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.sharingType = .readOnly
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

        // Observe character size changes
        sizeObservation = model.$characterSize.sink { [weak self] newSize in
            guard let self, let w = self.window, let sprite = self.spriteView else { return }
            DispatchQueue.main.async {
                let winSize = NSSize(width: newSize + 20, height: newSize + 20)
                var frame = w.frame
                frame.size = winSize
                w.setFrame(frame, display: true)
                sprite.frame = NSRect(origin: .zero, size: NSSize(width: newSize, height: newSize))
            }
        }

        // Observe target position for window tracking
        positionObservation = model.$targetPosition.sink { [weak self] point in
            guard let point, let w = self?.window else { return }
            DispatchQueue.main.async {
                // Skip if currently animating (wait for current move to finish)
                if self?.moveTimer != nil { return }
                self?.model.currentWindowOrigin = w.frame.origin
                self?.animateWindowMove(to: point)
            }
        }
    }

    private var moveTimer: Timer?

    private func animateWindowMove(to target: NSPoint) {
        moveTimer?.invalidate()
        guard let w = window else { return }

        let start = w.frame.origin
        let dx = target.x - start.x
        let dy = target.y - start.y
        let distance = sqrt(dx * dx + dy * dy)
        guard distance > 5 else { return }  // Already close enough

        // Longer distance = faster speed (scaled for ultrawide)
        let speed: Double = distance < 300 ? 400 : distance < 1000 ? 1500 : 3000
        let duration: TimeInterval = min(max(distance / speed, 0.15), 1.5)
        let steps = Int(duration * 60)  // ~60fps
        var step = 0
        let interval = duration / Double(steps)

        moveTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self, weak w] timer in
            guard let w else { timer.invalidate(); return }
            step += 1
            let t = min(Double(step) / Double(steps), 1.0)
            // Ease-in-out
            let ease = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            let x = start.x + dx * ease
            let y = start.y + dy * ease
            w.setFrameOrigin(NSPoint(x: x, y: y))
            if step >= steps {
                timer.invalidate()
                self?.moveTimer = nil
                self?.model.currentWindowOrigin = target
                // Arrive → wave greeting or idle
                let current = self?.model.stateMachine.current
                if current == .walkFront || current == .walkBack
                    || current == .walkLeft || current == .walkRight {
                    if self?.model.shouldWaveOnArrival == true {
                        self?.model.shouldWaveOnArrival = false
                        self?.model.stateMachine.current = .wave
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                            if self?.model.stateMachine.current == .wave {
                                self?.model.stateMachine.current = .idle
                            }
                        }
                    } else {
                        self?.model.stateMachine.current = .idle
                    }
                }
            }
        }
    }

    func hide() {
        moveTimer?.invalidate()
        moveTimer = nil
        window?.orderOut(nil)
        window = nil
        spriteView = nil
        stateObservation = nil
        opacityObservation = nil
        positionObservation = nil
        sizeObservation = nil
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
    private var notificationWindow: NSWindow?
    private var chatWindow: NSWindow?
    private var whisperWindow: NSWindow?
    private var bubbleObservation: AnyCancellable?
    private var chatObservation: AnyCancellable?
    private var whisperObservation: AnyCancellable?

    // Drag state
    private var dragStartScreenPos: NSPoint?
    private var dragStartWindowOrigin: NSPoint?
    private var isDragging = false

    init(spriteView: PetSpriteView, model: PetModel, characterSize: CGFloat) {
        self.spriteView = spriteView
        self.model = model
        self.characterSize = characterSize
        super.init(frame: .zero)
        addSubview(spriteView)

        // Observe notification (independent of state machine)
        bubbleObservation = model.$notificationMessage.sink { [weak self] msg in
            DispatchQueue.main.async {
                guard let self else { return }
                if msg != nil {
                    self.showNotification()
                } else {
                    self.hideNotificationBubble()
                }
            }
        }

        // Observe chat open/close
        chatObservation = model.stateMachine.$isChatOpen.sink { [weak self] open in
            DispatchQueue.main.async {
                guard let self else { return }
                if open {
                    self.showFullChat()
                } else {
                    self.hideChatWindow()
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
        dragStartScreenPos = NSEvent.mouseLocation
        dragStartWindowOrigin = window?.frame.origin
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPos = dragStartScreenPos,
              let startOrigin = dragStartWindowOrigin,
              let w = window else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - startPos.x
        let dy = current.y - startPos.y
        if !isDragging && (abs(dx) > 3 || abs(dy) > 3) { isDragging = true }
        if isDragging {
            w.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
            model.onPetDragged()
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !isDragging { model.toggleChat() }
        dragStartScreenPos = nil
        dragStartWindowOrigin = nil
        isDragging = false
    }

    // MARK: - Right-Click Summon Menu

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()

        // Summon: Omakase
        let omakaseItem = NSMenuItem(title: "Omakase", action: #selector(summonOmakase(_:)), keyEquivalent: "")
        omakaseItem.target = self
        menu.addItem(omakaseItem)

        // Summon: Ask...
        let askItem = NSMenuItem(title: "Ask...", action: #selector(summonAsk(_:)), keyEquivalent: "")
        askItem.target = self
        menu.addItem(askItem)

        // Summon: Draft PR (Terminal only)
        let ctx = model.captureScreenContext()
        if ctx.isTerminal {
            menu.addItem(.separator())
            let draftPRItem = NSMenuItem(title: "Draft PR", action: #selector(summonDraftPR(_:)), keyEquivalent: "")
            draftPRItem.target = self
            menu.addItem(draftPRItem)
        }

        menu.addItem(.separator())

        // Opacity submenu
        let opacityItem = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
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

    @objc private func summonOmakase(_ sender: NSMenuItem) {
        model.summonOmakase()
    }

    @objc private func summonAsk(_ sender: NSMenuItem) {
        // Show input dialog
        let alert = NSAlert()
        alert.messageText = "Ask Chi"
        alert.informativeText = "Enter your instruction:"
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "e.g. 訳して, summarize, explain..."
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let instruction = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        model.summonAsk(instruction: instruction)
    }

    @objc private func summonDraftPR(_ sender: NSMenuItem) {
        model.summonDraftPR()
    }

    @objc private func changeOpacity(_ sender: NSMenuItem) {
        model.opacity = Double(sender.tag) / 100.0
    }

    // MARK: - Bubble Window (Layer 2: notification / Layer 3: full chat)

    private func showNotification() {
        guard notificationWindow == nil, let parentWindow = window else { return }
        let notifView = PetNotificationBubble(model: model)
        let hosting = NSHostingView(rootView: AnyView(notifView))

        // Dynamic size based on content
        let fitSize = hosting.intrinsicContentSize
        let w = min(max(fitSize.width, 120), 320)
        let h = min(max(fitSize.height, 30), 200)
        hosting.frame = NSRect(x: 0, y: 0, width: w, height: h)

        let bw = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
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

        // Position: centered above character's head
        let parentFrame = parentWindow.frame
        bw.setFrameOrigin(NSPoint(
            x: parentFrame.midX - w / 2,
            y: parentFrame.maxY - 10  // slightly overlap top of character
        ))

        parentWindow.addChildWindow(bw, ordered: .above)
        notificationWindow = bw
    }

    private func showFullChat() {
        guard chatWindow == nil, let parentWindow = window else { return }
        let chatView = PetChatContainerView(model: model)
        let hosting = NSHostingView(rootView: AnyView(chatView))
        hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 480)

        let bw = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 480),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        bw.titlebarAppearsTransparent = true
        bw.title = "Chi"
        bw.isOpaque = false
        bw.backgroundColor = NSColor(white: 0.12, alpha: 0.95)
        bw.level = .floating
        bw.hasShadow = true
        bw.contentView = hosting
        bw.isReleasedWhenClosed = false
        bw.minSize = NSSize(width: 280, height: 300)

        let parentFrame = parentWindow.frame
        bw.setFrameOrigin(NSPoint(
            x: parentFrame.midX - 180,
            y: parentFrame.maxY + 8
        ))

        bw.makeKeyAndOrderFront(nil)
        chatWindow = bw
    }

    private func hideNotificationBubble() {
        if let nw = notificationWindow {
            window?.removeChildWindow(nw)
            nw.orderOut(nil)
            notificationWindow = nil
        }
    }

    private func hideChatWindow() {
        if let cw = chatWindow {
            cw.orderOut(nil)
            chatWindow = nil
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

/// Borderless window that can become key (for text input)
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
