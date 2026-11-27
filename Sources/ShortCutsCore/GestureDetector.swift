import Foundation

/// Pure state machine for the "double-Command" activation gesture.
///
/// It consumes modifier transitions (not keystrokes): press ⌘, release, press again
/// inside `interval`, and it fires. Any unrelated key resets the sequence, so holding
/// ⌘ and typing ⌘C never opens the panel.
public struct GestureDetector: Sendable {
    public var interval: TimeInterval
    public var commandKeyCodes: Set<UInt16>

    private var firstDown: TimeInterval?
    private var sawRelease = false
    private var commandIsDown = false

    public init(interval: TimeInterval = 0.35,
                commandKeyCodes: Set<UInt16> = [55, 54]) {
        self.interval = interval
        self.commandKeyCodes = commandKeyCodes
    }

    /// Feed every flagsChanged event. `isDown` means the command modifier is now held.
    /// Returns true exactly once, on the completing press.
    public mutating func handle(keyCode: UInt16, isDown: Bool, at time: TimeInterval) -> Bool {
        guard commandKeyCodes.contains(keyCode) else { return false }

        if isDown {
            commandIsDown = true
            if let first = firstDown, sawRelease, time - first <= interval {
                reset()
                return true
            }
            if firstDown == nil || (time - (firstDown ?? 0)) > interval {
                firstDown = time
                sawRelease = false
            }
            return false
        } else {
            commandIsDown = false
            if firstDown != nil { sawRelease = true }
            return false
        }
    }

    /// Call when any non-modifier key is pressed — the user is typing, not gesturing.
    public mutating func reset() {
        firstDown = nil
        sawRelease = false
        commandIsDown = false
    }

    public var isCommandDown: Bool { commandIsDown }
}
