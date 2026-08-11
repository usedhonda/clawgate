import XCTest
@testable import ClawGate

final class PetTabRequestTests: XCTestCase {
    func testColdOpenInitializesFromPendingTargetAndAcknowledgesByGeneration() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ClawGate/UI/Pet/PetBubbleView.swift")
            .path
        let source = try String(contentsOfFile: path, encoding: .utf8)

        XCTAssertTrue(source.contains(
            "State(initialValue: model.pendingTabRequests.last?.target ?? \"log\")"
        ))
        XCTAssertTrue(source.contains("model.acknowledgeTabRequest(generation: request.generation)"))
    }

    func testRepeatedSummonRequestsRemainQueuedWithDistinctGenerations() {
        let model = PetModel()

        model.requestTab("summon")
        model.requestTab("summon")

        XCTAssertEqual(model.pendingTabRequests.map(\.target), ["summon", "summon"])
        XCTAssertEqual(model.pendingTabRequests.map(\.generation), [1, 2])
        model.acknowledgeTabRequest(generation: 1)
        XCTAssertEqual(model.pendingTabRequests.map(\.generation), [2])
        model.acknowledgeTabRequest(generation: 2)
        XCTAssertTrue(model.pendingTabRequests.isEmpty)
        model.cleanup()
    }

    func testEachSummonResultAdvancesScrollGenerationOnce() {
        let model = PetModel()
        let initialGeneration = model.summonScrollGeneration

        model.addSummonResult(text: "one", source: "ask")
        model.addSummonResult(text: "two", source: "ask")

        XCTAssertEqual(model.summonResults.suffix(2).map(\.text), ["one", "two"])
        XCTAssertEqual(model.summonScrollGeneration, initialGeneration + 2)
        XCTAssertEqual(model.pendingTabRequests.map(\.generation).count, 2)
        model.cleanup()
    }

    func testDelayedConsumerIsBoundedAndRetainsNewestGeneration() {
        let model = PetModel()

        for index in 0..<40 {
            model.requestTab(index.isMultiple(of: 2) ? "log" : "summon")
        }

        XCTAssertEqual(model.pendingTabRequests.count, 32)
        XCTAssertEqual(model.pendingTabRequests.first?.generation, 9)
        XCTAssertEqual(model.pendingTabRequests.last?.generation, 40)
        XCTAssertEqual(model.pendingTabRequests.last?.target, "summon")

        for request in model.pendingTabRequests {
            model.acknowledgeTabRequest(generation: request.generation)
        }
        XCTAssertTrue(model.pendingTabRequests.isEmpty)
        model.cleanup()
    }

    func testTabConsumerResubscribesAcrossAppearAndPendingChanges() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ClawGate/UI/Pet/PetBubbleView.swift")
            .path
        let source = try String(contentsOfFile: path, encoding: .utf8)

        XCTAssertTrue(source.contains(".onAppear { consumePendingTabRequests() }"))
        XCTAssertTrue(source.contains(".onChange(of: model.pendingTabRequests)"))
        XCTAssertTrue(source.contains("for request in model.pendingTabRequests"))
    }
}
