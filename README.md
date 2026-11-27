# ShortCuts for macOS

A menu-bar utility that shows the keyboard shortcuts of the app in front of you.
Double-press **⌘** and a searchable panel lists every menu command of the frontmost
application with its shortcut, grouped by menu and filterable as you type.

![ShortCuts demo: double-press ⌘, filter, copy a shortcut](docs/demo.gif)

[Full video (23.7 s, 1080p, with sound)](docs/demo.mp4). The panel is a faithful re-render
of the SwiftUI code in `Sources/ShortCuts/PanelController.swift` with Finder's standard
shortcuts as example rows; the build and test lines are copied from a real CI run.

Built as a clean-room implementation after a static security audit of
[KeyClu](https://github.com/Anze/KeyCluCask). No KeyClu code, assets, strings or
bundle identifiers are used — the app is a separate program written from public
macOS APIs.

## Safety posture

This app is deliberately less privileged than the tool that inspired it:

- **Read-only Accessibility.** It reads menu titles and `AXMenuItemCmd*` attributes.
  It never calls `AXUIElementPerformAction` or `AXUIElementSetAttributeValue`, so it
  cannot press buttons or modify another app's UI.
- **No network code.** No `URLSession`, no sockets, no updater, no telemetry, no
  analytics. There is nothing to phone home with.
- **No shell.** No `Process`, no `NSTask`, no AppleScript.
- **No screen access.** No screen recording, no keylogging — it observes modifier
  state only, and resets whenever a normal key is typed.
- **Local state only.** Bookmarks, hidden flags and your settings live in
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
- Type to filter by action, menu path or shortcut.
- Click a row (or press Return) to copy that shortcut to the clipboard.
- **Esc** closes the panel.
- The menu-bar item offers Export Markdown… and Settings….

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
- Optional invocation of a menu item, behind an explicit user action

## Licence

MIT. See `LICENSE`.
