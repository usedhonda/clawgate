import ApplicationServices
import XCTest
@testable import ClawGate

final class LineSidebarDiscoveryTests: XCTestCase {
    func testFindSidebarListPrefersLeftPaneList() {
        let windowFrame = CGRect(x: 60, y: 45, width: 1200, height: 859)
        let leftList = makeNode(role: "AXList", frame: CGRect(x: 122, y: 116, width: 302, height: 787))
        let rightList = makeNode(role: "AXList", frame: CGRect(x: 425, y: 123, width: 835, height: 660))

        let result = LineSidebarDiscovery.findSidebarList(
            in: [rightList, leftList],
            windowFrame: windowFrame,
            rowCountProvider: { node, _ in
                node.frame?.minX == leftList.frame?.minX ? 2 : 28
            }
        )

        XCTAssertEqual(result?.frame, leftList.frame)
    }

    func testVisibleRowsDropsHeaderAndZeroSizedRows() {
        let listFrame = CGRect(x: 122, y: 116, width: 302, height: 787)
        let rows = [
            makeNode(role: "AXRow", frame: CGRect(x: 122, y: 116, width: 302, height: 34)),
            makeNode(role: "AXRow", frame: CGRect(x: 122, y: 150, width: 302, height: 57)),
            makeNode(role: "AXRow", frame: CGRect(x: 0, y: 0, width: 0, height: 0)),
            makeNode(role: "AXRow", frame: CGRect(x: 122, y: 207, width: 302, height: 57)),
        ]

        let visible = LineSidebarDiscovery.visibleRows(from: rows, listFrame: listFrame)

        XCTAssertEqual(visible.count, 2)
        XCTAssertEqual(visible[0].frame, CGRect(x: 122, y: 150, width: 302, height: 57))
        XCTAssertEqual(visible[0].yOrder, 0)
        XCTAssertEqual(visible[1].yOrder, 1)
    }

    func testBuildConversationEntriesPrefersAXAndDedupesNames() {
        let axCandidates = [
            LineSidebarDiscovery.SidebarConversationCandidate(
                name: "Alice Smith",
                frame: CGRect(x: 122, y: 150, width: 302, height: 57),
                yOrder: 0,
                source: .ax
            ),
            LineSidebarDiscovery.SidebarConversationCandidate(
                name: "Work Group",
                frame: CGRect(x: 122, y: 207, width: 302, height: 57),
                yOrder: 1,
                source: .ax
            ),
        ]
        let ocrCandidates = [
            LineSidebarDiscovery.SidebarConversationCandidate(
                name: "Alice Smith",
                frame: CGRect(x: 122, y: 150, width: 302, height: 57),
                yOrder: 0,
                source: .ocr
            ),
            LineSidebarDiscovery.SidebarConversationCandidate(
                name: "Alice Smith",
                frame: CGRect(x: 122, y: 264, width: 302, height: 57),
                yOrder: 2,
                source: .ocr
            ),
        ]
        let unreadFrames = [
            CGRect(x: 360, y: 225, width: 10, height: 10),
        ]

        let entries = LineSidebarDiscovery.buildConversationEntries(
            axCandidates: axCandidates,
            ocrCandidates: ocrCandidates,
            unreadFrames: unreadFrames,
            limit: 10
        )

        XCTAssertEqual(entries.map(\.name), ["Alice Smith", "Work Group"])
        XCTAssertEqual(entries.map(\.hasUnread), [false, true])
        XCTAssertEqual(entries.map(\.yOrder), [0, 1])
    }

    private func makeNode(
        role: String?,
        frame: CGRect?,
        value: String? = nil,
        title: String? = nil,
        description: String? = nil
    ) -> AXNode {
        AXNode(
            element: AXUIElementCreateSystemWide(),
            role: role,
            subrole: nil,
            title: title,
            description: description,
            identifier: nil,
            roleDescription: nil,
            frame: frame,
            actions: [],
            settableAttributes: [],
            value: value
        )
    }
}
