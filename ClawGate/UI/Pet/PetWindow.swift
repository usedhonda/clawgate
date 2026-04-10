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
        model.moveController.bind(window: w)

        // Load initial character (spriteView must be set first)
        updateSpriteForCurrentState()

        // Observe state layers for sprite updates
        stateObservation = Publishers.CombineLatest(
            model.stateMachine.$expression,
            model.stateMachine.$locomotion
        ).sink { [weak self] _, _ in
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

    }

    func hide() {
        model.moveController.stop()
        window?.orderOut(nil)
        window = nil
        spriteView = nil
        stateObservation = nil
        opacityObservation = nil
        sizeObservation = nil
    }

    private func updateSpriteForCurrentState() {
        guard let sprite = spriteView else { return }
        let stateName = model.stateMachine.resolvedAnimationName
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
    private var clipboardObservation: AnyCancellable?
    private var screenshotObservation: AnyCancellable?
    private var chatObservation: AnyCancellable?
    private var summonObservation: AnyCancellable?
    private var whisperObservation: AnyCancellable?
    private var summonMenuGlobalMonitor: Any?

    // Drag state
    private var dragStartScreenPos: NSPoint?
    private var dragStartWindowOrigin: NSPoint?
    private var isDragging = false
    private var singleClickTask: DispatchWorkItem?

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

        // Observe clipboard offers
        clipboardObservation = model.$pendingClipboardOffer.sink { [weak self] offer in
            DispatchQueue.main.async {
                guard let self else { return }
                if offer != nil {
                    self.showNotification()
                } else if self.model.notificationMessage == nil && self.model.pendingScreenshotOffer == nil {
                    self.hideNotificationBubble()
                }
            }
        }

        // Observe screenshot offers
        screenshotObservation = model.$pendingScreenshotOffer.sink { [weak self] offer in
            DispatchQueue.main.async {
                guard let self else { return }
                if offer != nil {
                    self.showNotification()
                } else if self.model.notificationMessage == nil && self.model.pendingClipboardOffer == nil {
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
        if model.isHiding {
            model.unhide()
            dragStartScreenPos = nil
            dragStartWindowOrigin = nil
            isDragging = false
            return
        }
        if !isDragging {
            if event.clickCount == 2 {
                singleClickTask?.cancel()
                singleClickTask = nil
                model.moveToOppositeSide()
            } else {
                singleClickTask?.cancel()
                singleClickTask = DispatchWorkItem { [weak self] in
                    self?.model.toggleChat()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: singleClickTask!)
            }
        }
        dragStartScreenPos = nil
        dragStartWindowOrigin = nil
        isDragging = false
    }

    // MARK: - Right-Click Summon Menu

    private var summonMenuWindow: NSWindow?
    private var summonMenuMonitor: Any?

    override func rightMouseDown(with event: NSEvent) {
        dismissSummonMenu()

        let appName = model.lastTrackedApp?.localizedName ?? "Unknown"
        let appIcon = model.lastTrackedApp?.icon

        let terminalBundles: Set<String> = [
            "com.mitchellh.ghostty", "com.apple.Terminal",
            "com.googlecode.iterm2", "net.kovidgoyal.kitty",
        ]
        let isTerminal = terminalBundles.contains(model.lastTrackedApp?.bundleIdentifier ?? "")

        // Build menu items
        struct MenuItem {
            let iconImage: NSImage
            let title: String
            let action: () -> Void
        }
        var items: [MenuItem] = [
            MenuItem(iconImage: emojiIconImage("✨"), title: "Omakase", action: { [weak self] in
                self?.model.stateMachine.expression = .wave
                self?.model.summonOmakase()
            }),
            MenuItem(iconImage: emojiIconImage("❓"), title: "Ask...", action: { [weak self] in
                self?.showAskInput()
            }),
        ]
        if isTerminal {
            items.append(MenuItem(iconImage: emojiIconImage("📄"), title: "Draft PR", action: { [weak self] in
                self?.model.summonDraftPR()
            }))
        }

        let browserBundles: Set<String> = [
            "com.google.Chrome", "com.google.Chrome.beta",
            "org.mozilla.firefox", "com.apple.Safari",
        ]
        let isBrowser = browserBundles.contains(model.lastTrackedApp?.bundleIdentifier ?? "")
        if isBrowser {
            items.insert(MenuItem(
                iconImage: emojiIconImage("🌐"),
                title: "Get this page",
                action: { [weak self] in self?.model.requestChromePage() }
            ), at: 0)
        }

        let outerPadding: CGFloat = 6
        let itemHeight: CGFloat = 30
        let headerHeight: CGFloat = 28
        let separatorHeight: CGFloat = 1
        let panelWidth: CGFloat = 180
        let panelHeight = outerPadding * 2 + headerHeight + separatorHeight + CGFloat(items.count) * itemHeight

        let container = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(red: 0.11, green: 0.12, blue: 0.16, alpha: 0.96).cgColor
        container.layer?.cornerRadius = 12

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: outerPadding),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -outerPadding),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: outerPadding),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -outerPadding),
        ])

        let headerRow = SummonMenuHeaderRow(
            frame: NSRect(x: 0, y: 0, width: panelWidth - outerPadding * 2, height: headerHeight),
            appIcon: appIcon,
            title: appName
        )
        stack.addArrangedSubview(headerRow)

        let separator = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth - outerPadding * 2, height: separatorHeight))
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            separator.widthAnchor.constraint(equalToConstant: panelWidth - outerPadding * 2),
            separator.heightAnchor.constraint(equalToConstant: separatorHeight),
        ])
        stack.addArrangedSubview(separator)

        for item in items {
            let button = SummonMenuButton(
                frame: NSRect(x: 0, y: 0, width: panelWidth - outerPadding * 2, height: itemHeight),
                iconImage: item.iconImage,
                title: item.title,
                action: { [weak self] in
                    self?.dismissSummonMenu()
                    item.action()
                }
            )
            stack.addArrangedSubview(button)
        }

        let bw = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
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

        // Position: pointer sits on the first action row center.
        let mouseScreen = NSEvent.mouseLocation
        let firstItemOffsetFromTop = outerPadding + headerHeight + separatorHeight + itemHeight / 2
        bw.setFrameOrigin(NSPoint(
            x: mouseScreen.x - panelWidth / 2,
            y: mouseScreen.y - panelHeight + firstItemOffsetFromTop
        ))

        bw.makeKeyAndOrderFront(nil)
        summonMenuWindow = bw

        // Dismiss on click outside or Escape
        summonMenuMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, let menuWin = self.summonMenuWindow else { return event }
            if event.type == .keyDown && event.keyCode == 53 {  // Escape
                self.dismissSummonMenu()
                return nil
            }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                if event.window != menuWin {
                    self.dismissSummonMenu()
                }
            }
            return event
        }
        summonMenuGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismissSummonMenu()
        }
    }

    private func dismissSummonMenu() {
        if let monitor = summonMenuMonitor {
            NSEvent.removeMonitor(monitor)
            summonMenuMonitor = nil
        }
        if let monitor = summonMenuGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            summonMenuGlobalMonitor = nil
        }
        summonMenuWindow?.orderOut(nil)
        summonMenuWindow = nil
    }

    @objc private func summonOmakase(_ sender: NSMenuItem) {
        model.stateMachine.expression = .wave
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
        model.stateMachine.expression = .wave

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
            y: parentFrame.maxY + 4  // bottom of bubble just above character's head
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
            styleMask: [.resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        bw.titleVisibility = .hidden
        bw.isOpaque = false
        bw.backgroundColor = .clear
        bw.level = .floating
        bw.hasShadow = true
        bw.isMovable = true
        bw.isMovableByWindowBackground = true
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

// MARK: - Summon Menu Button

private func emojiIconImage(_ emoji: String, canvas: CGSize = CGSize(width: 16, height: 16), fontSize: CGFloat = 13) -> NSImage {
    let image = NSImage(size: canvas)
    image.lockFocusFlipped(false)
    defer { image.unlockFocus() }
    NSColor.clear.setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: canvas)).fill()
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize), .paragraphStyle: paragraph]
    let text = NSString(string: emoji)
    let textSize = text.size(withAttributes: attrs)
    let rect = NSRect(x: floor((canvas.width - textSize.width) / 2.0), y: floor((canvas.height - textSize.height) / 2.0) - 1, width: textSize.width, height: textSize.height)
    text.draw(in: rect, withAttributes: attrs)
    image.isTemplate = false
    return image
}

private let summonMenuIconSlot: CGFloat = 28

private class SummonMenuRow: NSView {
    let iconView: NSImageView
    let textLabel: NSTextField

    init(frame: NSRect, iconImage: NSImage?, title: String, titleColor: NSColor) {
        iconView = NSImageView()
        textLabel = NSTextField(labelWithString: title)
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = iconImage
        iconView.imageScaling = .scaleNone
        iconView.imageAlignment = .alignCenter

        let iconSlot = NSView()
        iconSlot.translatesAutoresizingMaskIntoConstraints = false
        iconSlot.addSubview(iconView)

        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.font = .systemFont(ofSize: 13, weight: .medium)
        textLabel.textColor = titleColor
        textLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [iconSlot, textLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: frame.height),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconSlot.widthAnchor.constraint(equalToConstant: summonMenuIconSlot),

            iconView.centerXAnchor.constraint(equalTo: iconSlot.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconSlot.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

private final class SummonMenuHeaderRow: SummonMenuRow {
    init(frame: NSRect, appIcon: NSImage?, title: String) {
        super.init(frame: frame, iconImage: appIcon, title: title, titleColor: NSColor.white.withAlphaComponent(0.5))
        iconView.imageScaling = .scaleProportionallyUpOrDown
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

private final class SummonMenuButton: NSView {
    private let action: () -> Void
    private var trackingArea: NSTrackingArea?
    private let row: SummonMenuRow

    init(frame: NSRect, iconImage: NSImage, title: String, action: @escaping () -> Void) {
        self.action = action
        self.row = SummonMenuRow(frame: frame, iconImage: iconImage, title: title, titleColor: .white)
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: frame.height),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }

    override func mouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if bounds.contains(loc) {
            action()
        }
    }
}
