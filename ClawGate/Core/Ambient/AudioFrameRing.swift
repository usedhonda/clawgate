import Foundation
import os

/// Fixed-capacity byte ring between the HAL's I/O cycle and a worker. The writer
/// never allocates, logs or waits on a slow operation: the unfair lock only ever
/// guards a bounded copy and its counters, and a full ring drops the new audio.
final class AudioFrameRing {
    struct Counters: Equatable {
        var callbacks = 0
        var bufferCount = 0
        var framesIn = 0
        var wrapFailures = 0
        var droppedBytes = 0
    }

    private let storage: UnsafeMutableRawPointer
    private let capacity: Int
    private let bytesPerFrame: Int
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var head = 0
    private var count = 0
    private var counters = Counters()

    init(capacityBytes: Int, bytesPerFrame: Int) {
        capacity = capacityBytes
        self.bytesPerFrame = bytesPerFrame
        storage = UnsafeMutableRawPointer.allocate(byteCount: capacityBytes, alignment: 16)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        storage.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// Called from the IOProc. A nil source records a callback without usable audio.
    func write(_ source: UnsafeRawPointer?, byteCount: Int, bufferCount: Int) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        counters.callbacks += 1
        counters.bufferCount = bufferCount
        guard let source, byteCount > 0 else { counters.wrapFailures += 1; return }
        guard capacity - count >= byteCount else { counters.droppedBytes += byteCount; return }
        let tail = (head + count) % capacity
        let first = min(byteCount, capacity - tail)
        memcpy(storage + tail, source, first)
        if first < byteCount { memcpy(storage, source + first, byteCount - first) }
        count += byteCount
        counters.framesIn += byteCount / bytesPerFrame
    }

    /// Whole frames only. Returns the number of bytes copied into `target`.
    func read(into target: UnsafeMutableRawPointer, maxBytes: Int) -> Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let wanted = min(count, maxBytes) / bytesPerFrame * bytesPerFrame
        guard wanted > 0 else { return 0 }
        let first = min(wanted, capacity - head)
        memcpy(target, storage + head, first)
        if first < wanted { memcpy(target + first, storage, wanted - first) }
        head = (head + wanted) % capacity
        count -= wanted
        return wanted
    }

    var snapshot: Counters {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return counters
    }
}
