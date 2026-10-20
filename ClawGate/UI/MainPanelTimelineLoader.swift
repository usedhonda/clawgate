import Foundation

final class MainPanelTimelineLoader {
    private let queue = DispatchQueue(label: "com.clawgate.timeline", qos: .utility)
    private let read: () -> [MainPanelLogLine]?
    private var inFlight = false
    private var pending = false
    private var active = true
    private var previous: [MainPanelLogLine]?
    private var cachedLines: [MainPanelLogLine]?
    var didFinishForTesting: (() -> Void)?

    init(read: @escaping () -> [MainPanelLogLine]?) {
        self.read = read
    }

    convenience init(limit: Int, transform: @escaping ([OpsLogEntry]) -> [MainPanelLogLine]) {
        var store: OpsLogStore?
        self.init {
            if store == nil { store = OpsLogStore() }
            return store?.recentDisplayIfChanged(limit: limit).map(transform)
        }
    }

    func refresh(apply: @escaping ([MainPanelLogLine]) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard active else { return }
        pending = true
        guard !inFlight else { return }
        pending = false
        inFlight = true
        queue.async { [weak self] in
            guard let self else { return }
            if let changed = self.read() { self.cachedLines = changed }
            let lines = self.cachedLines
            DispatchQueue.main.async {
                self.inFlight = false
                guard self.active else {
                    self.didFinishForTesting?()
                    return
                }
                if !self.pending, let lines, !Self.equal(self.previous, lines) {
                    self.previous = lines
                    apply(lines)
                }
                self.didFinishForTesting?()
                if self.pending { self.refresh(apply: apply) }
            }
        }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        active = false
        pending = false
    }

    private static func equal(_ previous: [MainPanelLogLine]?, _ next: [MainPanelLogLine]) -> Bool {
        guard let previous, previous.count == next.count else { return false }
        return zip(previous, next).allSatisfy {
            $0.text == $1.text && $0.event == $1.event && $0.color.isEqual($1.color)
        }
    }
}
