import XCTest
@testable import ClawGate

final class PetStateMachineTests: XCTestCase {

    // MARK: - Initial State

    func testInitialState() {
        let sm = PetStateMachine()
        XCTAssertEqual(sm.current, .idle)
        XCTAssertFalse(sm.isBubbleVisible)
        XCTAssertFalse(sm.isChatOpen)
    }

    // MARK: - Speak Transitions

    func testAssistantStartedTransitionsToSpeak() {
        let sm = PetStateMachine()
        sm.handle(.assistantStarted)
        let speakStates: [PetState] = [.speak, .speakMix, .speakTilt, .talk]
        XCTAssertTrue(speakStates.contains(sm.current), "Should be in a speak state, got \(sm.current)")
        XCTAssertTrue(sm.isBubbleVisible)
    }

    func testAssistantFinishedReturnsToIdle() {
        let sm = PetStateMachine()
        sm.handle(.assistantStarted)
        sm.handle(.assistantFinished)
        XCTAssertEqual(sm.current, .idle)
    }

    // MARK: - Click Behavior

    func testUserClickShowsBubble() {
        let sm = PetStateMachine()
        sm.handle(.userClicked)
        XCTAssertTrue(sm.isBubbleVisible)
    }

    func testUserClickOnBubbleOpensChatWhenBubbleVisible() {
        let sm = PetStateMachine()
        sm.handle(.userClicked)       // shows bubble
        XCTAssertTrue(sm.isBubbleVisible)
        sm.handle(.userClicked)       // bubble visible -> open chat
        XCTAssertTrue(sm.isChatOpen)
    }

    func testDoubleClickOpensChat() {
        let sm = PetStateMachine()
        sm.handle(.userDoubleClicked)
        XCTAssertTrue(sm.isChatOpen)
        XCTAssertFalse(sm.isBubbleVisible)
    }

    // MARK: - Bubble Dismiss

    func testBubbleDismissed() {
        let sm = PetStateMachine()
        sm.handle(.userClicked)
        sm.handle(.bubbleDismissed)
        XCTAssertFalse(sm.isBubbleVisible)
        XCTAssertFalse(sm.isChatOpen)
    }

    // MARK: - Connection States

    func testDisconnectedGoesToSleep() {
        let sm = PetStateMachine()
        sm.handle(.disconnected)
        XCTAssertEqual(sm.current, .sleep)
    }

    func testReconnectedGoesToIdle() {
        let sm = PetStateMachine()
        sm.handle(.disconnected)
        sm.handle(.reconnected)
        XCTAssertEqual(sm.current, .idle)
    }

    // MARK: - Special Events

    func testGreetingGoesToWave() {
        let sm = PetStateMachine()
        sm.handle(.greeting)
        XCTAssertEqual(sm.current, .wave)
    }

    func testErrorGoesToReact() {
        let sm = PetStateMachine()
        sm.handle(.error)
        XCTAssertEqual(sm.current, .react)
    }

    func testSuccessGoesToReact() {
        let sm = PetStateMachine()
        sm.handle(.success)
        XCTAssertEqual(sm.current, .react)
    }

    func testLateNightGoesToSleep() {
        let sm = PetStateMachine()
        sm.handle(.lateNight)
        XCTAssertEqual(sm.current, .sleep)
    }

    func testIdleTimeoutChangesState() {
        let sm = PetStateMachine()
        sm.handle(.idleTimeout)
        let expectedStates: [PetState] = [.idleBreathe, .blink, .secretary, .funny]
        XCTAssertTrue(expectedStates.contains(sm.current), "Should be idle variation, got \(sm.current)")
    }

    // MARK: - Animation Name

    func testAnimationNameMatchesState() {
        let sm = PetStateMachine()
        XCTAssertEqual(sm.animationName, "idle")
        sm.handle(.disconnected)
        XCTAssertEqual(sm.animationName, "sleep")
        sm.handle(.greeting)
        XCTAssertEqual(sm.animationName, "wave")
    }
}
