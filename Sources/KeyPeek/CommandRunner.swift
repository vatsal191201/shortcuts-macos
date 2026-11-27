import AppKit
import KeyPeekCore

/// Runs a menu command in another app on behalf of the user.
///
/// Order of events: make the target app active, wait until macOS reports it active,
/// then find the menu item again and press it on a background queue. The press runs off the
/// main thread because an app can hold its reply while it shows a modal dialog.
enum CommandRunner {

    private static let queue = DispatchQueue(label: "KeyPeek.press", qos: .userInitiated)

    /// Makes `app` the active app.
    static func activate(_ app: NSRunningApplication) {
        guard !app.isTerminated else { return }
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [])
        }
    }

    /// Gives focus back to `app` after a panel closes, so that a second ⌘⌘ works at once.
    /// One request only: a repeat could pull focus away from an app that the user clicked.
    static func returnFocus(to app: NSRunningApplication) {
        guard !app.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier else { return }
        activate(app)
    }

    /// Activates `app`, waits for it, and presses the menu item of `entry`.
    /// It beeps when the item is gone, changed, disabled, or the press fails.
    static func run(_ entry: ShortcutEntry, in app: NSRunningApplication) {
        guard entry.enabled, !app.isTerminated else {
            NSSound.beep()
            return
        }
        activate(app)
        waitUntilActive(app, attemptsLeft: 20) { active in
            guard active else {
                NSSound.beep()
                return
            }
            queue.async {
                let result = AXReader.press(entry, in: app)
                if result != .pressed {
                    DispatchQueue.main.async { NSSound.beep() }
                }
            }
        }
    }

    /// Checks every 50 ms, for at most 1 second, that `app` is active.
    private static func waitUntilActive(_ app: NSRunningApplication,
                                        attemptsLeft: Int,
                                        completion: @escaping (Bool) -> Void) {
        if app.isActive {
            completion(true)
            return
        }
        guard attemptsLeft > 0, !app.isTerminated else {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            waitUntilActive(app, attemptsLeft: attemptsLeft - 1, completion: completion)
        }
    }

    /// The screen under the pointer, so that the panel opens where the user looks.
    static func screenUnderPointer() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }
}
