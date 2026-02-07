import ApplicationServices
import Foundation

struct AXNode {
    let element: AXUIElement
    let role: String?
    let subrole: String?
    let title: String?
    let description: String?
    let identifier: String?
    let roleDescription: String?
    let frame: CGRect?
    let actions: [String]
    let settableAttributes: Set<String>
    let value: String?
}

enum AXQuery {
    static func applicationElement(pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    static func focusedWindow(appElement: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value)
        guard status == .success, let element = value else {
            return nil
        }
        return (element as! AXUIElement)
    }

    /// Get all windows of an application (including minimized ones).
    static func windows(appElement: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard status == .success, let windows = value as? [AXUIElement] else { return [] }
        return windows
    }

    static func descendants(of root: AXUIElement, maxDepth: Int = 5, maxNodes: Int = 300) -> [AXNode] {
        var results: [AXNode] = []
        traverse(element: root, depth: 0, maxDepth: maxDepth, maxNodes: maxNodes, results: &results)
        return results
    }

    static func bestMatch(selector: LineSelector, in nodes: [AXNode]) -> AXNode? {
        let normalizedTitle = selector.titleContains.map { $0.lowercased() }
        let normalizedDescription = selector.descriptionContains.map { $0.lowercased() }
        let hasTextHints = !normalizedTitle.isEmpty || !normalizedDescription.isEmpty

        let candidates = nodes
            .filter {
                if let role = selector.role, $0.role != role {
                    return false
                }
                if let subrole = selector.subrole, $0.subrole != subrole {
                    return false
                }
                return true
            }
            .map { node in
                (node: node, score: score(node: node, titleTokens: normalizedTitle, descTokens: normalizedDescription))
            }
            .sorted { $0.score > $1.score }

        // When text hints are specified, require at least one match (score > 0)
        // to avoid returning unrelated elements (e.g. close button for send button).
        guard let best = candidates.first else { return nil }
        if hasTextHints && best.score == 0 { return nil }
        return best.node
    }

    private static func score(node: AXNode, titleTokens: [String], descTokens: [String]) -> Int {
        var value = 0
        let title = node.title?.lowercased() ?? ""
        let description = node.description?.lowercased() ?? ""
        for token in titleTokens where title.contains(token) {
            value += 2
        }
        for token in descTokens where description.contains(token) {
            value += 1
        }
        return value
    }

    private static func traverse(
        element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        maxNodes: Int,
        results: inout [AXNode]
    ) {
        if depth > maxDepth || results.count >= maxNodes {
            return
        }

        let role = copyStringAttribute(element, attribute: kAXRoleAttribute)
        let subrole = copyStringAttribute(element, attribute: kAXSubroleAttribute)
        let title = copyStringAttribute(element, attribute: kAXTitleAttribute)
        let description = copyStringAttribute(element, attribute: kAXDescriptionAttribute)
        let identifier = copyStringAttribute(element, attribute: "AXIdentifier")
        let roleDescription = copyStringAttribute(element, attribute: kAXRoleDescriptionAttribute as String)
        let frame = copyFrameAttribute(element)
        let actions = copyActionNames(element)
        let settable = copySettableAttributes(element)
        let value = copyStringAttribute(element, attribute: kAXValueAttribute as String)
        results.append(AXNode(
            element: element, role: role, subrole: subrole,
            title: title, description: description,
            identifier: identifier, roleDescription: roleDescription,
            frame: frame, actions: actions, settableAttributes: settable,
            value: value
        ))

        guard results.count < maxNodes else { return }

        var childrenValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
        guard status == .success, let children = childrenValue as? [AXUIElement] else {
            return
        }

        for child in children {
            traverse(element: child, depth: depth + 1, maxDepth: maxDepth, maxNodes: maxNodes, results: &results)
            if results.count >= maxNodes {
                return
            }
        }
    }

    static func copyStringAttribute(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success else {
            return nil
        }

        if let cfString = value as? String {
            return cfString
        }
        return nil
    }

    static func copyFrameAttribute(_ element: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        let posStatus = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue)
        let sizeStatus = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
        guard posStatus == .success, sizeStatus == .success else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }

    static func copyActionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        let status = AXUIElementCopyActionNames(element, &names)
        guard status == .success, let array = names as? [String] else { return [] }
        return array
    }

    static func copySettableAttributes(_ element: AXUIElement) -> Set<String> {
        var names: CFArray?
        let status = AXUIElementCopyAttributeNames(element, &names)
        guard status == .success, let allNames = names as? [String] else { return [] }

        var settable = Set<String>()
        for name in allNames {
            var isSettable: DarwinBoolean = false
            let check = AXUIElementIsAttributeSettable(element, name as CFString, &isSettable)
            if check == .success && isSettable.boolValue {
                settable.insert(name)
            }
        }
        return settable
    }

    static func elementAtPosition(x: CGFloat, y: CGFloat) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(systemWide, Float(x), Float(y), &element)
        guard status == .success else { return nil }
        return element
    }

    /// Get the system-wide focused element.
    static func systemFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value)
        guard status == .success, let element = value else { return nil }
        return (element as! AXUIElement)
    }

    /// Get the PID of an AXUIElement.
    static func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        let status = AXUIElementGetPid(element, &pid)
        guard status == .success else { return nil }
        return pid
    }

    /// Get direct children of an AXUIElement.
    static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        guard status == .success, let children = value as? [AXUIElement] else { return [] }
        return children
    }

    /// Get a boolean attribute value (e.g. kAXFrontmostAttribute, kAXMinimizedAttribute).
    static func copyBoolAttribute(_ element: AXUIElement, attribute: String) -> Bool? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success else { return nil }
        if let boolVal = value as? Bool {
            return boolVal
        }
        if let numVal = value as? NSNumber {
            return numVal.boolValue
        }
        return nil
    }
}
