import XCTest
@testable import ClawGate

final class OpenClawMinutesCapabilityTests: XCTestCase {
    func testHelloOkMethodsDecodeAndRequireBothMethodsOnCurrentGeneration() async throws {
        let data = Data(#"{"type":"res","id":"connect-1","ok":true,"payload":{"type":"hello-ok","features":{"methods":["chat.send","chat.result.get"],"events":[]}}}"#.utf8)
        let message = try JSONDecoder().decode(IncomingMessage.self, from: data)
        XCTAssertEqual(message.payload?.features?.methods, ["chat.send", "chat.result.get"])

        let client = OpenClawWSClient()
        await client.seedGatewayAdvertisementForTesting(
            methods: message.payload?.features?.methods ?? [], generation: 7,
            connected: true, handshaken: true)
        let supported = await client.supportsDedicatedMinutesExecution()
        XCTAssertTrue(supported)

        await client.beginConnectionGenerationForTesting()
        let supportedAfterReconnect = await client.supportsDedicatedMinutesExecution()
        XCTAssertFalse(supportedAfterReconnect, "a reconnect generation cannot reuse the prior hello advertisement")

        await client.seedGatewayAdvertisementForTesting(
            methods: ["chat.send"], generation: 8, connected: true, handshaken: true)
        let missingResultRead = await client.supportsDedicatedMinutesExecution()
        XCTAssertFalse(missingResultRead, "chat.result.get is required for the dedicated preflight")
    }

    func testMinutesRunRegistrationIsExactAndClearedOnDisconnect() async {
        let client = OpenClawWSClient()
        await client.registerMinutesExecutionRunID("  run-42 ")
        await client.registerMinutesExecutionRunID("")
        let registered = await client.registeredMinutesRunIDsForTesting()
        XCTAssertEqual(registered, ["  run-42 "])

        await client.disconnect(reason: "test")
        let registeredAfterDisconnect = await client.registeredMinutesRunIDsForTesting()
        XCTAssertTrue(registeredAfterDisconnect.isEmpty)
    }

    func testRegisteredRunEventsAreExcludedAtRoutingSeam() throws {
        let runID = "run-dedicated"
        let excluded: Set<String> = [runID]
        let final = try payload(#"{"state":"final","runId":"run-dedicated","sessionKey":"main","message":{"content":[{"type":"text","text":"private"}]}}"#)
        let error = try payload(#"{"state":"error","runId":"run-dedicated","sessionKey":"main","errorMessage":"private"}"#)
        let delta = try payload(#"{"stream":"assistant","runId":"run-dedicated","sessionKey":"main","data":{"delta":"private"}}"#)

        XCTAssertTrue(OpenClawWSClient.routeIncomingEvent(name: "chat", payload: final, excludingRunIDs: excluded).isEmpty)
        XCTAssertTrue(OpenClawWSClient.routeIncomingEvent(name: "chat", payload: error, excludingRunIDs: excluded).isEmpty)
        XCTAssertTrue(OpenClawWSClient.routeIncomingEvent(name: "agent", payload: delta, excludingRunIDs: excluded).isEmpty)

        let unrelated = try payload(#"{"state":"final","runId":"other","sessionKey":"main","message":{"content":[{"type":"text","text":"visible"}]}}"#)
        XCTAssertFalse(OpenClawWSClient.routeIncomingEvent(name: "chat", payload: unrelated, excludingRunIDs: excluded).isEmpty)
    }

    private func payload(_ json: String) throws -> IncomingPayload {
        try JSONDecoder().decode(IncomingPayload.self, from: Data(json.utf8))
    }
}
