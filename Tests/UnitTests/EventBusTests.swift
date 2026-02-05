import XCTest
@testable import ClawGate

final class EventBusTests: XCTestCase {
    func testPollReturnsOnlyNewEvents() {
        let bus = EventBus()
        let first = bus.append(type: "inbound_message", adapter: "line", payload: ["text": "hello"])
        _ = bus.append(type: "inbound_message", adapter: "line", payload: ["text": "world"])

        let polled = bus.poll(since: first.id)
        XCTAssertEqual(polled.events.count, 1)
        XCTAssertEqual(polled.events.first?.payload["text"], "world")
    }

    func testEventBusDropsOldEventsWhenOverflow() {
        let bus = EventBus()
        for i in 1...1001 {
            _ = bus.append(type: "test", adapter: "line", payload: ["i": "\(i)"])
        }

        let all = bus.poll(since: nil)
        XCTAssertEqual(all.events.count, 1000)
        // The first event (id=1) should have been dropped
        XCTAssertEqual(all.events.first?.payload["i"], "2")
    }

    func testSubscribeReceivesEvents() {
        let bus = EventBus()
        let expectation = XCTestExpectation(description: "Subscriber receives event")
        var receivedText: String?

        _ = bus.subscribe { event in
            receivedText = event.payload["text"]
            expectation.fulfill()
        }

        _ = bus.append(type: "inbound_message", adapter: "line", payload: ["text": "subscribed"])

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(receivedText, "subscribed")
    }

    func testUnsubscribeStopsEvents() {
        let bus = EventBus()
        var callCount = 0

        let subID = bus.subscribe { _ in
            callCount += 1
        }

        _ = bus.append(type: "test", adapter: "line", payload: [:])
        XCTAssertEqual(callCount, 1)

        bus.unsubscribe(subID)

        _ = bus.append(type: "test", adapter: "line", payload: [:])
        XCTAssertEqual(callCount, 1)
    }
}
