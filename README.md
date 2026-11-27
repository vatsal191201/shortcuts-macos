# ShortCuts for macOS

A menu-bar utility that shows the keyboard shortcuts of the app in front of you.
Double-press **⌘** and a searchable panel lists every menu command of the frontmost
application with its shortcut, grouped by menu and filterable as you type.

![ShortCuts demo: double-press ⌘, filter, copy a shortcut](docs/demo.gif)

[Full video (23.7 s, 1080p, with sound)](docs/demo.mp4). The panel is a faithful re-render
of the SwiftUI code in `Sources/ShortCuts/PanelController.swift` with Finder's standard
shortcuts as example rows; the build and test lines are copied from a real CI run.
The video shows version 0.1.0. In that version, a click copied the shortcut. Now a click or
Return runs the command, and ⌥ with a click or Return copies it.

Built as a clean-room implementation after a static security audit of
[KeyClu](https://github.com/Anze/KeyCluCask). No KeyClu code, assets, strings or
bundle identifiers are used — the app is a separate program written from public
macOS APIs.

## Safety posture

This app keeps its privileges small:

- **One Accessibility action, only on your command.** It reads menu titles and
  `AXMenuItemCmd*` attributes. It presses a menu item (`AXPress`) only when you press
  Return or click a row in its own panel. Before the press, it finds the item again and
  checks the title, the menu path, the shortcut and the enabled state. If one of them
  changed, it beeps and does nothing. It never calls `AXUIElementSetAttributeValue`, and
  no URL scheme, IPC channel or helper can start a press.
- **No network code.** No `URLSession`, no sockets, no updater, no telemetry, no
  analytics. There is nothing to phone home with.
- **No shell.** No `Process`, no `NSTask`, no AppleScript.
- **No screen access.** No screen recording and no keylogging. The app watches key
  events only to detect the double ⌘ press. A normal key cancels the detection. It never
  stores or sends the keys.
- **Local state only.** Your settings, bookmarks, hidden flags and the use count of each
  shortcut that you run or copy live in
  `~/Library/Application Support/ShortCuts/state.json` with `0600` permissions.

The one privileged thing it needs is Accessibility, which macOS requires for any app
that reads another app's UI. Grant it in System Settings → Privacy & Security →
Accessibility.

## Build

Requires macOS 13+ and Xcode command line tools.

```bash
swift build          # compile
swift test           # unit tests for the pure logic
bash scripts/build-app.sh   # assemble and ad-hoc sign dist/ShortCuts.app
open dist/ShortCuts.app
```

On first launch, allow the app under **System Settings → Privacy & Security →
Accessibility**, then quit and reopen it.

## Use

- Double-press **⌘** to open the panel for the frontmost app.
- Type to filter by action, menu path or shortcut. The search field accepts ⌘A, ⌘C,
  ⌘V, ⌘X, ⌘Z and the usual delete keys.
- Use **↑** and **↓** to move the selection. Page Up, Page Down, Home and End also work.
  When you move the pointer over a row, that row becomes the selection.
- Press **Return** or click a row to run that command in the app. Disabled commands
  do not run.
- Press **⌥ Return** or ⌥-click a row to copy the shortcut to the clipboard.
- The first row, **Show all shortcuts**, opens a sheet with every menu of the app in
  columns. Click a row in the sheet to run it. **Esc** or **⌘W** closes the sheet.
- **Esc** closes the panel, and the app that you used gets the focus back.
- The menu-bar item offers Show Shortcuts, Show All Shortcuts, Export Markdown… and
  Settings…. If the menu-bar item is hidden, open the app again to show Settings.

## Layout

```
Sources/ShortCutsCore/   pure logic: AX parsing, menu flattening, search, export, storage
Sources/ShortCuts/       AppKit/SwiftUI shell: event monitor, panel, settings
Tests/                   unit tests for the core
```

The split exists so the tricky parts (modifier masks, key glyphs, stable IDs,
search ranking, Markdown escaping) are testable without a screen or permissions.

## Roadmap

- Global hotkey listing (`com.apple.symbolichotkeys.plist`)
- Trackpad gesture reference
- skhd and Jitouch2 config import (read-only parsing, never execution)
- Custom shortcut groups and bookmarks

## Licence

MIT. See `LICENSE`.
