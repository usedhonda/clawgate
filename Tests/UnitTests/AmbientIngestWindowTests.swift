import XCTest
@testable import ClawGate

/// Exercises the production producer across a controlled sender suspension.
/// Existing AmbientTests cover the payload/schema and the live opt-in suite
/// covers the Gateway contract; neither covered this local queue ownership.
final class AmbientIngestWindowTests: XCTestCase {
    func testAcknowledgementKeepsNewArrivalsIncludingIdenticalContent() async throws {
        let ack = try acceptedPayload()
        for newText in ["new segment", "old segment"] {
            let entered = expectation(description: "first window suspended: \(newText)")
            let sender = ControlledWindowSender(ack: ack) { entered.fulfill() }
            let producer = makeProducer(sender: sender)
            await producer.start(sessionID: "queue-retention-test")
            await producer.add([segment("old segment")])

            let firstFlush = Task { await producer.flush() }
            await fulfillment(of: [entered], timeout: 5)
            await producer.add([segment(newText)])
            await sender.finishFirst(with: .success(ack))
            await firstFlush.value

            await producer.flush()
            await producer.stop()
            let summaries = await sender.summaries
            XCTAssertEqual(summaries, ["old segment", newText],
                           "new queue entries must survive even with identical stable transcript IDs")
        }
    }

    func testAcknowledgementDoesNotRemoveNewEntriesWhenCapEvictedSnapshot() async throws {
        let ack = try acceptedPayload()
        let entered = expectation(description: "old window suspended")
        let sender = ControlledWindowSender(ack: ack) { entered.fulfill() }
        let producer = makeProducer(sender: sender)
        await producer.start(sessionID: "queue-cap-test")
        await producer.add([segment("previous")])

        let firstFlush = Task { await producer.flush() }
        await fulfillment(of: [entered], timeout: 5)
        let arrivals = (0..<121).map { String(format: "sample%03d", $0) }
        await producer.add(arrivals.map(segment))
        await sender.finishFirst(with: .success(ack))
        await firstFlush.value

        await producer.flush()
        await producer.stop()
        let summaries = await sender.summaries
        XCTAssertEqual(summaries, ["previous", arrivals.suffix(120).joined(separator: " ")],
                       "acknowledging an evicted snapshot must preserve every retained new entry")
    }

    func testFailedSendKeepsSnapshotAndNewArrivalsForLaterRetry() async throws {
        let ack = try acceptedPayload()
        let entered = expectation(description: "failing window suspended")
        let sender = ControlledWindowSender(ack: ack) { entered.fulfill() }
        let producer = makeProducer(sender: sender)
        await producer.start(sessionID: "queue-retry-test")
        await producer.add([segment("old segment")])

        let firstFlush = Task { await producer.flush() }
        await fulfillment(of: [entered], timeout: 5)
        await producer.add([segment("new segment")])
        await sender.finishFirst(with: .failure(WindowSendFailure.transient))
        await firstFlush.value

        await producer.flush()
        await producer.stop()
        let summaries = await sender.summaries
        XCTAssertEqual(summaries, ["old segment", "old segment new segment"])
    }

    private func makeProducer(sender: ControlledWindowSender) -> AmbientIngestProducer {
        AmbientIngestProducer(
            windowSender: { params in try await sender.send(params) },
            successfulWindowObserver: { _, _, _ in }
        )
    }

    private func segment(_ text: String) -> TranscriptSegment {
        TranscriptSegment(startSeconds: 0, endSeconds: 1, text: text)
    }

    private func acceptedPayload() throws -> IncomingPayload {
        try JSONDecoder().decode(IncomingPayload.self, from: Data(#"{"stateAccepted":true,"events":[]}"#.utf8))
    }
}

private enum WindowSendFailure: Error { case transient }

private actor ControlledWindowSender {
    private let ack: IncomingPayload
    private let onEntered: @Sendable () -> Void
    private var first: CheckedContinuation<IncomingPayload?, Error>?
    private(set) var summaries: [String] = []

    init(ack: IncomingPayload, onEntered: @escaping @Sendable () -> Void) {
        self.ack = ack
        self.onEntered = onEntered
    }

    func send(_ params: AmbientIngestParams) async throws -> IncomingPayload? {
        summaries.append(params.state.summary)
        if summaries.count == 1 {
            return try await withCheckedThrowingContinuation { continuation in
                first = continuation
                onEntered()
            }
        }
        return ack
    }

    func finishFirst(with result: Result<IncomingPayload?, Error>) {
        let continuation = first
        first = nil
        continuation?.resume(with: result)
    }
}
