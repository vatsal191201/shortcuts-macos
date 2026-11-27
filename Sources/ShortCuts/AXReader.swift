import AppKit
import ApplicationServices
import ShortCutsCore

/// Reads the menu bar of another process through the public Accessibility API.
/// Read-only: this app never calls AXUIElementPerformAction or SetAttributeValue.
enum AXReader {

    static func isTrusted(prompt: Bool = false) -> Bool {
        if prompt {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        return AXIsProcessTrusted()
    }

    static func frontmostApplication() -> NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication
    }

    static func menuTree(for app: NSRunningApplication, maxNodes: Int = 5000, maxDepth: Int = 8) -> [MenuNode] {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let menuBar = copyElement(axApp, kAXMenuBarAttribute as CFString) else { return [] }

        var budget = maxNodes
        return children(of: menuBar).compactMap { item in
            node(from: item, depth: 1, maxDepth: maxDepth, budget: &budget)
        }
    }

    // MARK: - Recursion

    private static func node(from element: AXUIElement,
                             depth: Int,
                             maxDepth: Int,
                             budget: inout Int) -> MenuNode? {
        guard budget > 0 else { return nil }
        budget -= 1

        let title = string(element, kAXTitleAttribute as CFString) ?? ""
        let enabled = bool(element, kAXEnabledAttribute as CFString) ?? true
        let shortcut = shortcut(for: element)

        var kids: [MenuNode] = []
        if depth < maxDepth {
            for child in children(of: element) {
                if let childNode = node(from: child, depth: depth + 1, maxDepth: maxDepth, budget: &budget) {
                    kids.append(childNode)
                }
            }
        }

        if title.isEmpty && kids.isEmpty { return nil }
        let id = "\(depth)-\(title)-\(shortcut?.display ?? "")"
        return MenuNode(id: id, title: title, shortcut: shortcut, enabled: enabled, children: kids)
    }

    private static func shortcut(for element: AXUIElement) -> Shortcut? {
        let char = string(element, "AXMenuItemCmdChar" as CFString)
        let modifiers = int(element, "AXMenuItemCmdModifiers" as CFString)
        let virtualKey = int(element, "AXMenuItemCmdVirtualKey" as CFString)
        return ShortcutParser.shortcut(char: char, axModifiers: modifiers, virtualKey: virtualKey)
    }

    // MARK: - Attribute helpers

    private static func copyValue(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        guard let value = copyValue(element, attribute) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ attribute: CFString) -> String? {
        guard let value = copyValue(element, attribute) else { return nil }
        return value as? String
    }

    private static func int(_ element: AXUIElement, _ attribute: CFString) -> Int? {
        guard let value = copyValue(element, attribute) else { return nil }
        return value as? Int
    }

    private static func bool(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        guard let value = copyValue(element, attribute) else { return nil }
        return value as? Bool
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        guard let value = copyValue(element, kAXChildrenAttribute as CFString) else { return [] }
        guard let array = value as? [AXUIElement] else { return [] }
        return array
    }
}
