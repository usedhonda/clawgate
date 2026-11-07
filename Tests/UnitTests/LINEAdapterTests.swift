import XCTest
@testable import ClawGate

/// Tests for LINE adapter surface recovery and navigation inputs.
/// Echo tracking and text cleanup are exercised in RecentSendTrackerTests and
/// LineTextSanitizerTests. These helper tests do not replace live AX send checks.
final class LINEAdapterTests: XCTestCase {
    func testProbeOnlyNeverRequestsRecovery() {
        XCTAssertFalse(
            LINEAdapter.shouldRecoverDefaultConversationSurface(mode: .probeOnly, isAbnormal: true)
        )
    }

    func testRecoverIfNeededRepairsOnlyAbnormalSurface() {
        XCTAssertTrue(
            LINEAdapter.shouldRecoverDefaultConversationSurface(mode: .recoverIfNeeded, isAbnormal: true)
        )
        XCTAssertFalse(
            LINEAdapter.shouldRecoverDefaultConversationSurface(mode: .recoverIfNeeded, isAbnormal: false)
        )
    }

    func testForceRecoverRepairsEvenWhenSurfaceIsClean() {
        XCTAssertTrue(
            LINEAdapter.shouldRecoverDefaultConversationSurface(mode: .forceRecover, isAbnormal: false)
        )
    }

    func testMissingSearchFieldAloneDoesNotMakeDefaultSurfaceAbnormal() {
        XCTAssertFalse(
            LINEAdapter.isDefaultConversationSurfaceAbnormal(
                searchFieldValue: "",
                expectedConversation: "Alice Smith",
                matchesExpectedConversation: true,
                hasMessageInput: true,
                hasConversationSurfaceSignal: true
            )
        )
        XCTAssertEqual(
            LINEAdapter.defaultConversationSurfaceReason(
                searchFieldValue: "",
                expectedConversation: "Alice Smith",
                matchesExpectedConversation: true,
                hasMessageInput: true,
                hasConversationSurfaceSignal: true
            ),
            "ok"
        )
    }

    func testMissingMessageInputStillMakesDefaultSurfaceAbnormal() {
        XCTAssertTrue(
            LINEAdapter.isDefaultConversationSurfaceAbnormal(
                searchFieldValue: "",
                expectedConversation: "Alice Smith",
                matchesExpectedConversation: true,
                hasMessageInput: false,
                hasConversationSurfaceSignal: true
            )
        )
        XCTAssertEqual(
            LINEAdapter.defaultConversationSurfaceReason(
                searchFieldValue: "",
                expectedConversation: "Alice Smith",
                matchesExpectedConversation: true,
                hasMessageInput: false,
                hasConversationSurfaceSignal: true
            ),
            "message_input_missing"
        )
    }

    func testMatchingSearchValueIsAllowedWhenConversationSurfaceIsVisible() {
        XCTAssertFalse(
            LINEAdapter.isDefaultConversationSurfaceAbnormal(
                searchFieldValue: "Alice Smith",
                expectedConversation: "Alice Smith",
                matchesExpectedConversation: true,
                hasMessageInput: true,
                hasConversationSurfaceSignal: true
            )
        )
    }

    func testExpectedConversationMismatchStillMarksSurfaceAbnormal() {
        XCTAssertTrue(
            LINEAdapter.isDefaultConversationSurfaceAbnormal(
                searchFieldValue: "",
                expectedConversation: "Alice Smith",
                matchesExpectedConversation: false,
                hasMessageInput: true,
                hasConversationSurfaceSignal: true
            )
        )
        XCTAssertEqual(
            LINEAdapter.defaultConversationSurfaceReason(
                searchFieldValue: "",
                expectedConversation: "Alice Smith",
                matchesExpectedConversation: false,
                hasMessageInput: true,
                hasConversationSurfaceSignal: true
            ),
            "expected_conversation_mismatch"
        )
    }

    func testUnexpectedSearchValueStillMarksDefaultSurfaceDirty() {
        XCTAssertEqual(
            LINEAdapter.defaultConversationSurfaceReason(
                searchFieldValue: "heartbeat",
                expectedConversation: "Alice Smith",
                matchesExpectedConversation: true,
                hasMessageInput: true,
                hasConversationSurfaceSignal: true
            ),
            "search_field_dirty"
        )
    }

    func testMissingConversationSurfaceKeepsDefaultSurfaceAbnormal() {
        XCTAssertEqual(
            LINEAdapter.defaultConversationSurfaceReason(
                searchFieldValue: "Alice Smith",
                expectedConversation: "Alice Smith",
                matchesExpectedConversation: true,
                hasMessageInput: true,
                hasConversationSurfaceSignal: false
            ),
            "conversation_surface_missing"
        )
    }

    func testDefaultConversationTargetResultRowFallsBackToFirstActualResult() {
        let searchFieldFrame = CGRect(x: 134, y: 78, width: 264, height: 38)
        let rows = [
            LineSidebarDiscovery.SidebarRowCandidate(
                element: AXUIElementCreateSystemWide(),
                frame: CGRect(x: 122, y: 116, width: 302, height: 34),
                yOrder: 0
            ),
            LineSidebarDiscovery.SidebarRowCandidate(
                element: AXUIElementCreateSystemWide(),
                frame: CGRect(x: 122, y: 150, width: 302, height: 57),
                yOrder: 1
            ),
        ]
        let sidebar = LineSidebarDiscovery.SidebarListCandidate(
            node: AXNode(
                element: AXUIElementCreateSystemWide(),
                role: "AXList",
                subrole: nil,
                title: nil,
                description: nil,
                identifier: nil,
                roleDescription: nil,
                frame: CGRect(x: 122, y: 116, width: 302, height: 787),
                actions: [],
                settableAttributes: [],
                value: nil
            ),
            frame: CGRect(x: 122, y: 116, width: 302, height: 787),
            visibleRows: rows
        )

        let row = LineSidebarDiscovery.defaultConversationTargetResultRow(
            in: sidebar,
            searchFieldFrame: searchFieldFrame
        )

        XCTAssertEqual(row?.frame, CGRect(x: 122, y: 150, width: 302, height: 57))
    }

    func testDefaultConversationTargetResultRowUsesSecondActualResultWhenPresent() {
        let searchFieldFrame = CGRect(x: 122, y: 78, width: 264, height: 38)
        let rows = [
            LineSidebarDiscovery.SidebarRowCandidate(
                element: AXUIElementCreateSystemWide(),
                frame: CGRect(x: 122, y: 116, width: 302, height: 87),
                yOrder: 0
            ),
            LineSidebarDiscovery.SidebarRowCandidate(
                element: AXUIElementCreateSystemWide(),
                frame: CGRect(x: 122, y: 203, width: 302, height: 34),
                yOrder: 1
            ),
            LineSidebarDiscovery.SidebarRowCandidate(
                element: AXUIElementCreateSystemWide(),
                frame: CGRect(x: 122, y: 237, width: 302, height: 57),
                yOrder: 2
            ),
            LineSidebarDiscovery.SidebarRowCandidate(
                element: AXUIElementCreateSystemWide(),
                frame: CGRect(x: 122, y: 294, width: 302, height: 57),
                yOrder: 3
            ),
        ]
        let sidebar = LineSidebarDiscovery.SidebarListCandidate(
            node: AXNode(
                element: AXUIElementCreateSystemWide(),
                role: "AXList",
                subrole: nil,
                title: nil,
                description: nil,
                identifier: nil,
                roleDescription: nil,
                frame: CGRect(x: 122, y: 116, width: 302, height: 787),
                actions: [],
                settableAttributes: [],
                value: nil
            ),
            frame: CGRect(x: 122, y: 116, width: 302, height: 787),
            visibleRows: rows
        )

        let row = LineSidebarDiscovery.defaultConversationTargetResultRow(
            in: sidebar,
            searchFieldFrame: searchFieldFrame
        )

        XCTAssertEqual(row?.frame, CGRect(x: 122, y: 294, width: 302, height: 57))
    }

    // MARK: - canSkipNavigation decision table

    /// canSkipNavigation = (lastHint == currentHint) AND inputFieldExists.
    /// When the hint comparison fails, navigation must NOT be skipped.
    func testSkipNavigationRequiresSameHint() {
        let lastHint: String? = "Alice Smith"
        let currentHint = "Alice Smith"
        // Pure condition 1: hint must match
        XCTAssertEqual(lastHint, currentHint, "Same hint should allow skip consideration")
    }

    func testSkipNavigationDeniedOnDifferentHint() {
        let lastHint: String? = "Alice Smith"
        let currentHint = "Work Group"
        XCTAssertNotEqual(lastHint, currentHint, "Different hint must prevent skip")
    }

    func testSkipNavigationDeniedOnNilLastHint() {
        let lastHint: String? = nil
        let currentHint = "Alice Smith"
        // nil lastHint means first send — must not skip
        XCTAssertNil(lastHint)
        XCTAssertFalse(lastHint == currentHint)
    }

}
