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

        // FIX: Set isAnimatingMove AFTER the distance check to avoid stuck flag
        guard distance > 5 else { return }  // Already close enough
        model.isAnimatingMove = true
        model.moveGeneration &+= 1
        let gen = model.moveGeneration

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
                // Atomic arrival: set state BEFORE clearing isAnimatingMove
                // This prevents polling from racing in between
                self?.model.currentWindowOrigin = target
                let current = self?.model.stateMachine.current
                let isWalking = current == .walkFront || current == .walkBack
                    || current == .walkLeft || current == .walkRight
                if isWalking {
                    if self?.model.shouldWaveOnArrival == true {
                        self?.model.shouldWaveOnArrival = false
                        self?.model.stateMachine.current = .wave
                        // Wave timeout with generation guard — only clear if same move
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                            guard let self, self.model.moveGeneration == gen else { return }
                            if self.model.stateMachine.current == .wave {
                                self.model.stateMachine.current = .idle
                            }
                        }
                    } else {
                        self?.model.stateMachine.current = .idle
                    }
                }
                // Clear flag LAST — polling won't interfere with arrival state
                self?.model.isAnimatingMove = false
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
    private var summonObservation: AnyCancellable?
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

        // Observe summon tab auto-open
        summonObservation = model.$showSummonTab.sink { [weak self] show in
            DispatchQueue.main.async {
                guard let self, show else { return }
                // Open chat window if not already open
                if !self.model.stateMachine.isChatOpen {
                    self.model.stateMachine.isChatOpen = true
                }
                // showSummonTab is consumed by PetChatContainerView's onChange
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

        // Header: show tracked app name
        let appName = model.lastTrackedApp?.localizedName ?? "Unknown"
        let header = NSMenuItem(title: "\u{1F4CD} \(appName)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

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

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func summonOmakase(_ sender: NSMenuItem) {
        model.stateMachine.current = .wave
        model.summonOmakase()
    }

    private var askWindow: NSWindow?

    @objc private func summonAsk(_ sender: NSMenuItem) {
        showAskInput()
    }

    private func showAskInput() {
        askWindow?.orderOut(nil)
        askWindow = nil

        guard let parentWindow = window else { return }

        let field = AskTextField(frame: NSRect(x: 8, y: 8, width: 244, height: 24))
        field.placeholderString = "e.g. 訳して, summarize, explain..."
        field.font = .systemFont(ofSize: 13)
        field.focusRingType = .none
        field.backgroundColor = NSColor(white: 0.2, alpha: 1.0)
        field.textColor = .white
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = true
        field.onSubmit = { [weak self] text in
            self?.askWindow?.orderOut(nil)
            self?.askWindow = nil
            let instruction = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instruction.isEmpty else { return }
            self?.model.summonAsk(instruction: instruction)
        }
        field.onCancel = { [weak self] in
            self?.askWindow?.orderOut(nil)
            self?.askWindow = nil
        }

        let label = NSTextField(labelWithString: "Type your instruction here")
        label.frame = NSRect(x: 10, y: 32, width: 240, height: 16)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.5)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.95).cgColor
        container.layer?.cornerRadius = 10
        container.addSubview(label)
        container.addSubview(field)

        // Trigger wave animation
        model.stateMachine.current = .wave

        let bw = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 56),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        bw.isOpaque = false
        bw.backgroundColor = .clear
        bw.level = .floating + 1
        bw.hasShadow = true
        bw.contentView = container
        bw.isReleasedWhenClosed = false

        // Position above pet
        let parentFrame = parentWindow.frame
        bw.setFrameOrigin(NSPoint(
            x: parentFrame.midX - 130,
            y: parentFrame.maxY + 4
        ))

        bw.makeKeyAndOrderFront(nil)
        bw.makeFirstResponder(field)
        askWindow = bw
    }

    @objc private func summonDraftPR(_ sender: NSMenuItem) {
        model.summonDraftPR()
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

/// Text field with Enter/Escape handling for Ask input
private final class AskTextField: NSTextField {
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    override func textDidEndEditing(_ notification: Notification) {
        // Check if ended by Return key
        if let movement = notification.userInfo?["NSTextMovement"] as? Int,
           movement == NSReturnTextMovement {
            onSubmit?(stringValue)
        }
        super.textDidEndEditing(notification)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
