import ApplicationServices
import Foundation
import XCTest
@testable import ClawGate

final class SelectorResolverTests: XCTestCase {

    // MARK: - Test helpers

    /// Creates a mock AXNode without a real AXUIElement (uses systemWide as placeholder).
    private func makeNode(
        role: String? = nil,
        subrole: String? = nil,
        title: String? = nil,
        description: String? = nil,
        identifier: String? = nil,
        roleDescription: String? = nil,
        frame: CGRect? = nil,
        actions: [String] = [],
        settableAttributes: Set<String> = [],
        value: String? = nil
    ) -> AXNode {
        AXNode(
            element: AXUIElementCreateSystemWide(),
            role: role,
            subrole: subrole,
            title: title,
            description: description,
            identifier: identifier,
            roleDescription: roleDescription,
            frame: frame,
            actions: actions,
            settableAttributes: settableAttributes,
            value: value
        )
    }

    private let windowFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)

    // MARK: - L1: Identifier match

    func testL1IdentifierMatch() {
        let selector = UniversalSelector(
            role: "AXButton",
            identifier: "btn-send"
        )
        let nodes = [
            makeNode(role: "AXButton", identifier: "btn-cancel"),
            makeNode(role: "AXButton", identifier: "btn-send"),
            makeNode(role: "AXTextField"),
        ]

        let result = SelectorResolver.resolve(selector: selector, in: nodes, windowFrame: windowFrame)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.matchedLayer, 1)
        XCTAssertEqual(result?.confidence, 1.0)
        XCTAssertEqual(result?.node.identifier, "btn-send")
    }

    func testL1IdentifierMismatchedRoleLowersConfidence() {
        let selector = UniversalSelector(
            role: "AXButton",
            identifier: "my-text"
        )
        let nodes = [
            makeNode(role: "AXTextField", identifier: "my-text"),
        ]

        let result = SelectorResolver.resolve(selector: selector, in: nodes, windowFrame: windowFrame)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.confidence, 0.9)
    }

    // MARK: - L1: Text hint match

    func testL1TextHintMatchOnTitle() {
        let selector = UniversalSelector(
            role: "AXTextField",
            textHints: ["search"]
        )
        let nodes = [
            makeNode(role: "AXTextField", title: "Search contacts"),
            makeNode(role: "AXTextField", title: "Name"),
        ]

        let result = SelectorResolver.resolve(selector: selector, in: nodes, windowFrame: windowFrame)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.matchedLayer, 1)
        XCTAssertEqual(result?.node.title, "Search contacts")
    }

    func testL1TextHintNoMatchFallsThrough() {
        let selector = UniversalSelector(
            role: "AXTextField",
            textHints: ["nonexistent"]
        )
        let nodes = [
            makeNode(role: "AXTextField", title: "Name"),
        ]

        let result = SelectorResolver.resolve(selector: selector, in: nodes, windowFrame: windowFrame)
        // Should fall through to L3 (or nil if L3 also fails)
        XCTAssertTrue(result == nil || result?.matchedLayer == 3)
    }

    // MARK: - L3: Capability match

    func testL3RoleAndSettableMatch() {
        let selector = UniversalSelector(
            role: "AXTextArea",
            mustBeSettable: ["AXValue"]
        )
        let nodes = [
            makeNode(role: "AXTextArea", settableAttributes: []),
            makeNode(role: "AXTextArea", settableAttributes: ["AXValue"]),
            makeNode(role: "AXButton"),
        ]

        let result = SelectorResolver.resolve(selector: selector, in: nodes, windowFrame: windowFrame)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.matchedLayer, 3)
        XCTAssertEqual(result?.node.settableAttributes, ["AXValue"])
    }

    func testL3RequiredActionsFilter() {
        let selector = UniversalSelector(
            role: "AXButton",
            requiredActions: ["AXPress"]
        )
        let nodes = [
            makeNode(role: "AXButton", actions: []),
            makeNode(role: "AXButton", actions: ["AXPress", "AXShowMenu"]),
        ]

        let result = SelectorResolver.resolve(selector: selector, in: nodes, windowFrame: windowFrame)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.node.actions, ["AXPress", "AXShowMenu"])
    }

    // MARK: - L3: Geometry

    func testL3GeometryFilterRejectsOutOfBounds() {
        let selector = UniversalSelector(
            role: "AXTextArea",
            mustBeSettable: ["AXValue"],
            geometryHint: GeometryHint(
                regionX: 0.5...1.0,
                regionY: 0.7...1.0,
                minWidth: nil
            )
        )
        // Node at top-left corner (outside specified region)
        let nodes = [
            makeNode(role: "AXTextArea",
                     frame: CGRect(x: 50, y: 50, width: 200, height: 40),
                     settableAttributes: ["AXValue"]),
        ]

        let result = SelectorResolver.resolve(selector: selector, in: nodes, windowFrame: windowFrame)
        XCTAssertNil(result)
    }

    func testL3GeometryAcceptsInBounds() {
        let selector = UniversalSelector(
            role: "AXTextArea",
            mustBeSettable: ["AXValue"],
            geometryHint: GeometryHint(
                regionX: 0.2...1.0,
                regionY: 0.7...1.0,
                minWidth: 0.3
            )
        )
        // Node in bottom-right area matching geometry hint
        let nodes = [
            makeNode(role: "AXTextArea",
                     frame: CGRect(x: 300, y: 600, width: 600, height: 80),
                     settableAttributes: ["AXValue"]),
        ]

        let result = SelectorResolver.resolve(selector: selector, in: nodes, windowFrame: windowFrame)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.matchedLayer, 3)
    }

    func testL3GeometryMinWidthRejectsNarrow() {
        let selector = UniversalSelector(
            role: "AXTextArea",
            mustBeSettable: ["AXValue"],
            geometryHint: GeometryHint(
                regionX: 0.2...1.0,
                regionY: 0.7...1.0,
                minWidth: 0.5
            )
        )
        // Node is in the right area but too narrow (100/1000 = 0.1 < 0.5)
        let nodes = [
            makeNode(role: "AXTextArea",
                     frame: CGRect(x: 600, y: 650, width: 100, height: 40),
                     settableAttributes: ["AXValue"]),
        ]

        let result = SelectorResolver.resolve(selector: selector, in: nodes, windowFrame: windowFrame)
        XCTAssertNil(result)
    }

    // MARK: - L3: Best candidate scoring

    func testL3PicksHighestScoringCandidate() {
        let selector = UniversalSelector(
            role: "AXTextArea",
            mustBeSettable: ["AXValue"],
            geometryHint: GeometryHint(
                regionX: 0.2...1.0,
                regionY: 0.7...1.0,
                minWidth: nil
            )
        )
        let nodes = [
            // Candidate A: role match + settable (no geometry)
            makeNode(role: "AXTextArea", settableAttributes: ["AXValue"]),
            // Candidate B: role match + settable + geometry match (higher score)
            makeNode(role: "AXTextArea",
                     frame: CGRect(x: 400, y: 600, width: 500, height: 60),
                     settableAttributes: ["AXValue"]),
        ]

        let result = SelectorResolver.resolve(selector: selector, in: nodes, windowFrame: windowFrame)
        XCTAssertNotNil(result)
        // B should win because it has geometry bonus
        XCTAssertNotNil(result?.node.frame)
    }

    // MARK: - No match

    func testNoMatchReturnsNil() {
        let selector = UniversalSelector(
            role: "AXSlider"
        )
        let nodes = [
            makeNode(role: "AXButton"),
            makeNode(role: "AXTextField"),
        ]

        let result = SelectorResolver.resolve(selector: selector, in: nodes, windowFrame: windowFrame)
        XCTAssertNil(result)
    }

    // MARK: - LINE-specific selectors

    func testLineMessageInputSelector() {
        let selector = LineSelectors.messageInputU
        let nodes = [
            makeNode(role: "AXTextArea",
                     frame: CGRect(x: 300, y: 600, width: 500, height: 80),
                     settableAttributes: ["AXValue", "AXFocused"]),
            makeNode(role: "AXStaticText",
                     frame: CGRect(x: 300, y: 100, width: 500, height: 20)),
        ]

        let result = SelectorResolver.resolve(selector: selector, in: nodes, windowFrame: windowFrame)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.node.role, "AXTextArea")
    }

    func testLineSearchFieldSelector() {
        let selector = LineSelectors.searchFieldU
        let nodes = [
            makeNode(role: "AXTextField",
                     title: "Search",
                     frame: CGRect(x: 20, y: 30, width: 200, height: 30),
                     settableAttributes: ["AXValue"]),
        ]

        let result = SelectorResolver.resolve(selector: selector, in: nodes, windowFrame: windowFrame)
        XCTAssertNotNil(result)
        // Should match via L1 text hint (title contains "search")
        XCTAssertEqual(result?.matchedLayer, 1)
    }
}
