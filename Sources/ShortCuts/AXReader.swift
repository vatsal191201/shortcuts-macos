import AppKit
import ApplicationServices
import ShortCutsCore

/// Reads the menu bar of another process through the public Accessibility API.
///
/// The app uses one Accessibility action only: `AXPress` on the menu item that the user picks
/// with Return or a click in the panel. It never sets attribute values.
enum AXReader {

    /// The longest time one Accessibility call waits for a frozen app.
    static let messagingTimeout: Float = 1.0

    static func isTrusted(prompt: Bool = false) -> Bool {
        if prompt {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        return AXIsProcessTrusted()
    }

    static func menuTree(for app: NSRunningApplication, maxNodes: Int = 5000, maxDepth: Int = 8) -> [MenuNode] {
        guard let menuBar = menuBar(for: app) else { return [] }
        var budget = maxNodes
        return children(of: menuBar).enumerated().compactMap { index, item in
            node(from: item, indexPath: [index], depth: 1, maxDepth: maxDepth, budget: &budget)
        }
    }

    // MARK: - Press

    enum PressResult: Equatable {
        case pressed
        case notFound
        case changed
        case disabled
        case failed(Int32)
    }

    /// Finds the entry's menu item again, checks that it is the same command, and presses it.
    /// Call this off the main thread: an app can hold the reply while it shows a modal dialog.
    static func press(_ entry: ShortcutEntry, in app: NSRunningApplication) -> PressResult {
        guard let menuBar = menuBar(for: app) else { return .notFound }
        guard let item = MenuItemLocator.locate(root: menuBar,
                                                indexPath: entry.indexPath,
                                                expectedPath: entry.path,
                                                expectedTitle: entry.title,
                                                children: { children(of: $0) },
                                                title: { string($0, kAXTitleAttribute as CFString) ?? "" }) else {
            return .notFound
        }
        // The same title in the same menu is not enough. The shortcut must also match.
        guard shortcut(for: item)?.display == entry.shortcut.display else { return .changed }
        guard bool(item, kAXEnabledAttribute as CFString) ?? false else { return .disabled }

        AXUIElementSetMessagingTimeout(item, messagingTimeout)
        let error = AXUIElementPerformAction(item, kAXPressAction as CFString)
        switch error {
        case .success:
            return .pressed
        case .cannotComplete:
            // The app received the press but did not answer in time, for example
            // because the command opened a modal dialog.
            return .pressed
        default:
            return .failed(error.rawValue)
        }
    }

    // MARK: - Recursion

    private static func menuBar(for app: NSRunningApplication) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, messagingTimeout)
        return copyElement(axApp, kAXMenuBarAttribute as CFString)
    }

    private static func node(from element: AXUIElement,
                             indexPath: [Int],
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
            for (index, child) in children(of: element).enumerated() {
                if let childNode = node(from: child, indexPath: indexPath + [index],
                                        depth: depth + 1, maxDepth: maxDepth, budget: &budget) {
                    kids.append(childNode)
                }
            }
        }

        if title.isEmpty && kids.isEmpty { return nil }
        let id = indexPath.map(String.init).joined(separator: ".")
        return MenuNode(id: id, title: title, shortcut: shortcut, enabled: enabled,
                        children: kids, indexPath: indexPath)
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
