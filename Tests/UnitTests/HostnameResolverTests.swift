import Foundation
import NIOPosix
import XCTest
@testable import ClawGate

final class HostnameResolverTests: XCTestCase {
    func testBlockedDiscoveryDoesNotBlockHTTPEventLoopAndIsSingleFlight() throws {
        let started = expectation(description: "discovery started")
        let gate = DispatchSemaphore(value: 0)
        let cache = HostnameSnapshot(initial: "cached.example", resolver: {
            started.fulfill()
            gate.wait()
            return "fresh.example"
        })
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { gate.signal(); try? group.syncShutdownGracefully() }
        let responsive = expectation(description: "HTTP loop remains responsive")
        group.next().execute {
            for _ in 0..<100 { XCTAssertEqual(cache.current(), "cached.example") }
            responsive.fulfill()
        }
        wait(for: [started, responsive], timeout: 1)
    }

    func testFailureKeepsValueAndNextRefreshRecovers() {
        let first = expectation(description: "failed discovery")
        let second = expectation(description: "successful discovery")
        let callsLock = NSLock()
        var calls = 0
        let cache = HostnameSnapshot(initial: "cached.example", refreshInterval: 0, resolver: {
            callsLock.lock()
            calls += 1
            let call = calls
            callsLock.unlock()
            if call == 1 { first.fulfill(); return nil }
            if call == 2 { second.fulfill() }
            return "fresh.example"
        })
        XCTAssertEqual(cache.current(), "cached.example")
        wait(for: [first], timeout: 1)
        // Wait for the completion lock, not just the resolver closure's signal.
        let limit = Date().addingTimeInterval(1)
        while Date() < limit {
            callsLock.lock()
            let count = calls
            callsLock.unlock()
            if count >= 2 { break }
            _ = cache.current()
            Thread.sleep(forTimeInterval: 0.005)
        }
        wait(for: [second], timeout: 1)
        while cache.current() != "fresh.example" && Date() < limit { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertEqual(cache.current(), "fresh.example")
    }

    func testHungChildIgnoresTerminationButReturnsWithinDeadline() {
        let start = ProcessInfo.processInfo.systemUptime
        let output = BoundedHostnameProcess.run(executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; while :; do :; done"], deadline: start + 0.15)
        XCTAssertNil(output)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
    }

    func testDrainsOutputBeyondPipeCapacityAndRejectsOverflow() {
        let command = "i=0; while [ $i -lt 20000 ]; do printf 'abcdefghi\\n'; i=$((i+1)); done"
        let output = BoundedHostnameProcess.run(executable: "/bin/sh", arguments: ["-c", command],
            deadline: ProcessInfo.processInfo.systemUptime + 3)
        XCTAssertEqual(output?.utf8.count, 200000)
        XCTAssertNil(BoundedHostnameProcess.run(executable: "/bin/sh", arguments: ["-c", command],
            deadline: ProcessInfo.processInfo.systemUptime + 3, outputLimit: 1024))
        XCTAssertEqual(BoundedHostnameProcess.run(executable: "/usr/bin/printf", arguments: ["recovered"],
            deadline: ProcessInfo.processInfo.systemUptime + 1), "recovered")
    }
}
