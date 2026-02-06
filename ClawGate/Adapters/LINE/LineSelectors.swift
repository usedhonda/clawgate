import Foundation

// Legacy type kept for source compatibility during migration.
// New code should use UniversalSelector + SelectorResolver.
struct LineSelector {
    let role: String?
    let subrole: String?
    let titleContains: [String]
    let descriptionContains: [String]

    init(role: String?, subrole: String? = nil, titleContains: [String] = [], descriptionContains: [String] = []) {
        self.role = role
        self.subrole = subrole
        self.titleContains = titleContains
        self.descriptionContains = descriptionContains
    }
}

// LINE for Mac (Qt-based) AX tree observations:
// - AXTextArea: message input (title/description are empty)
// - AXTextField: search field (visible only in sidebar/friend list view)
// - No send button in AX tree; LINE uses Enter key to send
// - AXList: conversation list or message history
// - Window title = current conversation name
enum LineSelectors {
    // --- UniversalSelector definitions (capability + geometry based) ---

    static let messageInputU = UniversalSelector(
        role: "AXTextArea",
        mustBeSettable: ["AXValue"],
        geometryHint: GeometryHint(
            regionX: 0.2...1.0,
            regionY: 0.7...1.0,
            minWidth: 0.3
        )
    )

    static let searchFieldU = UniversalSelector(
        role: "AXTextField",
        textHints: ["search", "検索"],
        mustBeSettable: ["AXValue"],
        geometryHint: GeometryHint(
            regionX: 0.0...0.4,
            regionY: 0.0...0.15,
            minWidth: nil
        )
    )

    static let sendButtonU = UniversalSelector(
        role: "AXButton",
        textHints: ["send", "送信"],
        requiredActions: ["AXPress"]
    )

    // Message area AXStaticText (right pane, below title bar and above input)
    static let messageTextU = UniversalSelector(
        role: "AXStaticText",
        geometryHint: GeometryHint(
            regionX: 0.2...1.0,
            regionY: 0.08...0.75,
            minWidth: nil
        )
    )

    // Sidebar conversation names (left pane)
    static let conversationNameU = UniversalSelector(
        role: "AXStaticText",
        geometryHint: GeometryHint(
            regionX: 0.0...0.35,
            regionY: 0.08...1.0,
            minWidth: nil
        )
    )

    // --- Legacy selectors (kept for backward compatibility) ---

    static let searchField = LineSelector(
        role: "AXTextField",
        titleContains: ["search", "検索"],
        descriptionContains: ["search", "検索"]
    )

    static let messageInput = LineSelector(
        role: "AXTextArea"
    )

    static let sendButton = LineSelector(
        role: "AXButton",
        titleContains: ["send", "送信"],
        descriptionContains: ["send", "送信"]
    )
}
