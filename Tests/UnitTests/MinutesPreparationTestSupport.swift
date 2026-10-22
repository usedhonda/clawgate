import XCTest
@testable import ClawGate

extension XCTestCase {
    func waitForMinutesPreparation(of model: PetModel, file: StaticString = #filePath, line: UInt = #line) {
        guard !model.preparingMinutesIDs.isEmpty || model.minutesDrainInFlightForTesting else { return }
        let finished = expectation(description: "minutes input preparation finished")
        let check = {
            if model.preparingMinutesIDs.isEmpty && !model.minutesDrainInFlightForTesting { finished.fulfill() }
        }
        model.minutesPreparationDidFinishForTesting = check
        model.minutesDrainDidFinishForTesting = check
        wait(for: [finished], timeout: 10)
        model.minutesPreparationDidFinishForTesting = nil
        model.minutesDrainDidFinishForTesting = nil
        XCTAssertTrue(model.preparingMinutesIDs.isEmpty, file: file, line: line)
    }
}
