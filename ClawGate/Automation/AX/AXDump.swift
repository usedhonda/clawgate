import AppKit
import ApplicationServices
import Foundation

struct CodableRect: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.size.width)
        self.height = Double(rect.size.height)
    }
}

struct AXDumpNode: Codable {
    let role: String?
    let subrole: String?
    let title: String?
    let description: String?
    let identifier: String?
    let roleDescription: String?
    let frame: CodableRect?
    let actions: [String]?
    let settableAttributes: [String]?
    let value: String?
    let children: [AXDumpNode]
}

enum AXDump {
    static func dump(bundleIdentifier: String, maxDepth: Int = 8, maxChildren: Int = 30) throws -> AXDumpNode {
        guard AXIsProcessTrusted() else {
            throw NSError(domain: "AXDump", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Accessibility permission is not granted"])
        }

        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            throw NSError(domain: "AXDump", code: 1002, userInfo: [NSLocalizedDescriptionKey: "Target app is not running"])
        }

        let appElement = AXQuery.applicationElement(pid: app.processIdentifier)

        // Try focused window first, then first window from kAXWindowsAttribute
        let root: AXUIElement
        if let focused = AXQuery.focusedWindow(appElement: appElement) {
            root = focused
        } else if let firstWindow = firstWindow(appElement: appElement) {
            root = firstWindow
        } else {
            root = appElement
        }

        return dumpNode(element: root, depth: 0, maxDepth: maxDepth, maxChildren: maxChildren)
    }

    private static func firstWindow(appElement: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard status == .success, let windows = value as? [AXUIElement], let first = windows.first else {
            return nil
        }
        return first
    }

    private static func dumpNode(element: AXUIElement, depth: Int, maxDepth: Int, maxChildren: Int) -> AXDumpNode {
        if depth > maxDepth {
            return AXDumpNode(role: nil, subrole: nil, title: nil, description: nil, identifier: nil, roleDescription: nil, frame: nil, actions: nil, settableAttributes: nil, value: nil, children: [])
        }

        var children: [AXDumpNode] = []
        if depth < maxDepth {
            var childrenValue: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
            if status == .success, let axChildren = childrenValue as? [AXUIElement] {
                for child in axChildren.prefix(maxChildren) {
                    children.append(dumpNode(element: child, depth: depth + 1, maxDepth: maxDepth, maxChildren: maxChildren))
                }
            }
        }

        let frameRect = AXQuery.copyFrameAttribute(element)
        let actionNames = AXQuery.copyActionNames(element)
        let settable = AXQuery.copySettableAttributes(element)
        return AXDumpNode(
            role: AXQuery.copyStringAttribute(element, attribute: kAXRoleAttribute),
            subrole: AXQuery.copyStringAttribute(element, attribute: kAXSubroleAttribute),
            title: AXQuery.copyStringAttribute(element, attribute: kAXTitleAttribute),
            description: AXQuery.copyStringAttribute(element, attribute: kAXDescriptionAttribute),
            identifier: AXQuery.copyStringAttribute(element, attribute: "AXIdentifier"),
            roleDescription: AXQuery.copyStringAttribute(element, attribute: kAXRoleDescriptionAttribute as String),
            frame: frameRect.map { CodableRect($0) },
            actions: actionNames.isEmpty ? nil : actionNames,
            settableAttributes: settable.isEmpty ? nil : Array(settable).sorted(),
            value: AXQuery.copyStringAttribute(element, attribute: kAXValueAttribute as String),
            children: children
        )
    }
}
