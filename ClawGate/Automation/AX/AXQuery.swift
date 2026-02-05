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

    static func descendants(of root: AXUIElement, maxDepth: Int = 5, maxNodes: Int = 300) -> [AXNode] {
        var results: [AXNode] = []
        traverse(element: root, depth: 0, maxDepth: maxDepth, maxNodes: maxNodes, results: &results)
        return results
    }

    static func bestMatch(selector: LineSelector, in nodes: [AXNode]) -> AXNode? {
        let normalizedTitle = selector.titleContains.map { $0.lowercased() }
        let normalizedDescription = selector.descriptionContains.map { $0.lowercased() }

        return nodes
            .filter {
                if let role = selector.role, $0.role != role {
                    return false
                }
                if let subrole = selector.subrole, $0.subrole != subrole {
                    return false
                }
                return true
            }
            .sorted { lhs, rhs in
                score(node: lhs, titleTokens: normalizedTitle, descTokens: normalizedDescription) >
                    score(node: rhs, titleTokens: normalizedTitle, descTokens: normalizedDescription)
            }
            .first
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
}
