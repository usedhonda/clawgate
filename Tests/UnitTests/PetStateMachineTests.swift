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
        let speakStates: [PetExpression] = [.speak, .speakMix, .speakTilt, .talk]
        XCTAssertTrue(speakStates.contains(sm.expression), "Should be in a speak state, got \(sm.expression)")
    }

    func testAssistantFinishedReturnsToIdle() {
        let sm = PetStateMachine()
        sm.handle(.assistantStarted)
        sm.handle(.assistantFinished)
        XCTAssertEqual(sm.expression, .idle)
    }

    // MARK: - Click Behavior (Chat Toggle)

    func testUserClickOpensChatWhenClosed() {
        let sm = PetStateMachine()
        sm.handle(.userClicked)
        XCTAssertTrue(sm.isChatOpen)
    }

    func testUserClickClosesChatWhenOpen() {
        let sm = PetStateMachine()
        sm.handle(.userClicked)   // open
        sm.handle(.userClicked)   // close
        XCTAssertFalse(sm.isChatOpen)
    }

    func testDoubleClickOpensChatWhenClosed() {
        let sm = PetStateMachine()
        sm.handle(.userDoubleClicked)
        XCTAssertTrue(sm.isChatOpen)
    }

    // MARK: - Bubble Dismiss

    func testBubbleDismissedDoesNotAffectChat() {
        let sm = PetStateMachine()
        sm.handle(.userClicked)       // open chat
        sm.isBubbleVisible = true     // simulate notification
        sm.handle(.bubbleDismissed)
        XCTAssertFalse(sm.isBubbleVisible)
        XCTAssertTrue(sm.isChatOpen)  // chat stays open
    }

    // MARK: - Connection States

    func testDisconnectedGoesToSleep() {
        let sm = PetStateMachine()
        sm.handle(.disconnected)
        XCTAssertEqual(sm.expression, .sleep)
    }

    func testReconnectedGoesToIdle() {
        let sm = PetStateMachine()
        sm.handle(.disconnected)
        sm.handle(.reconnected)
        XCTAssertEqual(sm.expression, .idle)
    }

    // MARK: - Special Events

    func testGreetingGoesToWave() {
        let sm = PetStateMachine()
        sm.handle(.greeting)
        XCTAssertEqual(sm.expression, .wave)
    }

    func testErrorGoesToReact() {
        let sm = PetStateMachine()
        sm.handle(.error)
        XCTAssertEqual(sm.expression, .react)
    }

    func testSuccessGoesToReact() {
        let sm = PetStateMachine()
        sm.handle(.success)
        XCTAssertEqual(sm.expression, .react)
    }

    func testLateNightGoesToSleep() {
        let sm = PetStateMachine()
        sm.handle(.lateNight)
        XCTAssertEqual(sm.expression, .sleep)
    }

    func testIdleTimeoutChangesState() {
        let sm = PetStateMachine()
        sm.handle(.idleTimeout)
        let expectedStates: [PetExpression] = [.idleBreathe, .blink, .secretary, .funny]
        XCTAssertTrue(expectedStates.contains(sm.expression), "Should be idle variation, got \(sm.expression)")
    }

    // MARK: - Animation Name

    func testAnimationNameMatchesExpression() {
        let sm = PetStateMachine()
        XCTAssertEqual(sm.resolvedAnimationName, "idle")
        sm.handle(.disconnected)
        XCTAssertEqual(sm.resolvedAnimationName, "sleep")
        sm.handle(.greeting)
        XCTAssertEqual(sm.resolvedAnimationName, "wave")
    }

    // MARK: - Walk Direction

    func testWalkDirectionOverridesExpression() {
        let sm = PetStateMachine()
        sm.locomotion = .walking(.right)
        XCTAssertEqual(sm.resolvedAnimationName, "walk-right")
        sm.locomotion = .walking(.left)
        XCTAssertEqual(sm.resolvedAnimationName, "walk-left")
    }

    func testStationaryUsesExpression() {
        let sm = PetStateMachine()
        sm.expression = .wave
        sm.locomotion = .stationary
        XCTAssertEqual(sm.resolvedAnimationName, "wave")
    }

    // MARK: - Expression Lock (Hide)

    func testExpressionLockBlocksChanges() {
        let sm = PetStateMachine()
        sm.isExpressionLocked = true
        sm.expression = .hideClaw
        sm.handle(.assistantStarted)
        // Expression should stay as hideClaw, not change to speak
        XCTAssertEqual(sm.expression, .hideClaw)
    }

    func testExpressionLockAllowsClick() {
        let sm = PetStateMachine()
        sm.isExpressionLocked = true
        sm.handle(.userClicked)
        // Click should still work (toggle chat)
        XCTAssertTrue(sm.isChatOpen)
    }

    // MARK: - Hide Animation Suffix

    func testHideAnimationSuffix() {
        let sm = PetStateMachine()
        sm.expression = .hideClaw
        sm.hideAnimationSuffix = "-left"
        sm.locomotion = .stationary
        XCTAssertEqual(sm.resolvedAnimationName, "hide-claw-left")
    }

    func testHideAnimationSuffixEmpty() {
        let sm = PetStateMachine()
        sm.expression = .hideEmerge
        sm.hideAnimationSuffix = ""
        sm.locomotion = .stationary
        XCTAssertEqual(sm.resolvedAnimationName, "hide-emerge")
    }
}
