import AppKit

/// NSImageView-based frame animator for pet character sprites
final class PetSpriteView: NSImageView {
    private var frames: [NSImage] = []
    private var currentFrame = 0
    private var animationTimer: Timer?
    private var currentStateName: String = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageScaling = .scaleProportionallyUpOrDown
        animates = false
        wantsLayer = true
        layer?.magnificationFilter = .nearest  // crisp pixel art
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Set animation frames and start playback
    func setAnimation(frames: [NSImage], fps: Double, stateName: String) {
        guard stateName != currentStateName || self.frames.count != frames.count else { return }
        currentStateName = stateName
        self.frames = frames
        currentFrame = 0
        animationTimer?.invalidate()

        if frames.isEmpty { return }
        image = frames[0]

        if frames.count > 1 {
            let interval = 1.0 / max(fps, 1.0)
            animationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.advanceFrame()
            }
        }
    }

    /// Set a single static image (no animation)
    func setStatic(_ image: NSImage) {
        animationTimer?.invalidate()
        animationTimer = nil
        frames = [image]
        currentFrame = 0
        currentStateName = ""
        self.image = image
    }

    private func advanceFrame() {
        guard !frames.isEmpty else { return }
        currentFrame = (currentFrame + 1) % frames.count
        image = frames[currentFrame]
    }

    deinit {
        animationTimer?.invalidate()
    }
}
