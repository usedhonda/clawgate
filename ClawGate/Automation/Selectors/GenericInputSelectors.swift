import Foundation

/// Generic input field selectors for messaging apps and browsers.
/// App-specific overrides for known apps, with generic fallbacks.
enum GenericInputSelectors {

    // MARK: - Generic Selectors

    /// Generic: settable AXTextArea in bottom 30% of window
    static let messagingInput = UniversalSelector(
        role: "AXTextArea",
        mustBeSettable: ["AXValue"],
        geometryHint: GeometryHint(
            regionX: 0.1...1.0,
            regionY: 0.7...1.0,
            minWidth: 0.2
        )
    )

    /// Fallback: AXTextField (single-line input) in bottom 30%
    static let messagingInputTextField = UniversalSelector(
        role: "AXTextField",
        mustBeSettable: ["AXValue"],
        geometryHint: GeometryHint(
            regionX: 0.1...1.0,
            regionY: 0.7...1.0,
            minWidth: 0.2
        )
    )

    // MARK: - Browser Selectors (no mustBeSettable — safePaste route)

    /// Browser compose area (contenteditable divs exposed as AXTextArea)
    static let browserComposeTextArea = UniversalSelector(
        role: "AXTextArea",
        // mustBeSettable omitted — browser contenteditable may not be AXValue-settable
        // DraftPlacer will try setValue first, then fall through to safePaste
        geometryHint: GeometryHint(
            regionX: 0.1...1.0,
            regionY: 0.3...0.9,
            minWidth: 0.2
        )
    )

    /// Browser compose area (newer Chromium exposes contenteditable as AXGroup)
    static let browserComposeGroup = UniversalSelector(
        role: "AXGroup",
        textHints: ["compose", "reply", "message", "draft"],
        geometryHint: GeometryHint(
            regionX: 0.1...1.0,
            regionY: 0.3...0.9,
            minWidth: 0.2
        )
    )

    // MARK: - App-Specific Selector Lists

    /// Returns ordered list of selectors to try for a given bundleId.
    /// First match wins; DraftPlacer tries each in order with fallback.
    static func selectors(for bundleId: String) -> [UniversalSelector] {
        switch bundleId {

        // LINE: proven selector from LINEAdapter
        case "jp.naver.line.mac":
            return [LineSelectors.messageInputU]

        // Slack: composer has AXDescription containing "Message"
        case "com.tinyspeck.slackmacgap":
            return [
                UniversalSelector(
                    role: "AXTextArea",
                    textHints: ["message"],
                    mustBeSettable: ["AXValue"],
                    geometryHint: GeometryHint(regionX: 0.1...1.0, regionY: 0.6...1.0, minWidth: 0.3)
                ),
                // Newer Chromium may expose as AXGroup
                UniversalSelector(
                    role: "AXGroup",
                    textHints: ["message"],
                    geometryHint: GeometryHint(regionX: 0.1...1.0, regionY: 0.6...1.0, minWidth: 0.3)
                ),
                messagingInput,
                messagingInputTextField,
            ]

        // Browsers: deeper tree, no mustBeSettable requirement
        case _ where DraftPlacer.browserBundles.contains(bundleId):
            return [browserComposeTextArea, browserComposeGroup, messagingInput]

        // Default: generic selectors
        default:
            return [messagingInput, messagingInputTextField]
        }
    }
}
