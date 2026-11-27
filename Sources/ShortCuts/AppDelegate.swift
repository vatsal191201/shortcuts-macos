import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ShortCutsCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var eventMonitor: Any?
    private var settingsWindow: NSWindow?

    private let store = StateStore()
    private var gesture = GestureDetector()
    private var panel: PanelController?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = PanelController(store: store)
        gesture.interval = store.state.activationInterval

        buildStatusItem()
        installEventMonitor()

        if !AXReader.isTrusted(prompt: false) {
            _ = AXReader.isTrusted(prompt: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    // MARK: - Status item

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "ShortCuts")

        let menu = NSMenu()
        menu.addItem(menuItem("Show Shortcuts", #selector(showPanel), ""))
        menu.addItem(.separator())
        menu.addItem(menuItem("Export Markdown…", #selector(exportMarkdown), ""))
        menu.addItem(menuItem("Settings…", #selector(openSettings), ","))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit ShortCuts", #selector(quit), "q"))

        item.menu = menu
        statusItem = item
    }

    private func menuItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Gesture

    private func installEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime

            switch event.type {
            case .flagsChanged:
                let isDown = event.modifierFlags.contains(.command)
                if self.gesture.handle(keyCode: event.keyCode, isDown: isDown, at: now) {
                    DispatchQueue.main.async { self.showPanel() }
                }
            case .keyDown:
                self.gesture.reset()
            default:
                break
            }
        }
    }

    // MARK: - Actions

    @objc private func showPanel() {
        gesture.interval = store.state.activationInterval
        panel?.show()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let model = SettingsModel(store: store)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
                                  styleMask: [.titled, .closable],
                                  backing: .buffered,
                                  defer: false)
            window.title = "ShortCuts Settings"
            window.contentView = NSHostingViewFactory.make(model: model)
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func exportMarkdown() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let tree = AXReader.menuTree(for: app)
        let name = app.localizedName ?? "Application"
        let entries = MenuFlattener.flatten(nodes: tree, appName: name, appBundleID: app.bundleIdentifier)
        let markdown = MarkdownExporter.document(appName: name,
                                                 bundleID: app.bundleIdentifier,
                                                 entries: entries,
                                                 includeDisabled: store.state.showDisabled,
                                                 includeHidden: store.state.showHidden)

        let panel = NSSavePanel()
        panel.title = "Export shortcuts"
        panel.nameFieldStringValue = "\(name)-shortcuts.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// Keeps SwiftUI type erasure out of AppDelegate's stored properties.
enum NSHostingViewFactory {
    static func make(model: SettingsModel) -> NSView {
        NSHostingView(rootView: SettingsView(model: model))
    }
}
