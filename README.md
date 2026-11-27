# KeyPeek for macOS

A menu-bar utility that shows the keyboard shortcuts of the app in front of you.
Double-press **⌘** to peek at every menu command of the frontmost application with its
shortcut. Search in words or in plain language, and press Return to run a command.

KeyPeek was named ShortCuts up to version 0.2.0.

![KeyPeek demo: double-press ⌘ in any app, type what you want, Return runs it](docs/demo.gif)

[Full video (24.6 s, 1080p, with sound)](docs/demo.mp4). It shows version 0.3.0: the same
double-press ⌘ in Safari, Finder and Notes, plain-language search ("make text bigger" finds
Zoom In, "checkbox" finds Checklist), and Return running the command. The panel is a faithful
re-render of the SwiftUI code in `Sources/KeyPeek/PanelController.swift`, with standard Safari,
Finder and Notes shortcuts as example data. The Similar results come from a Python port of the
app's search and its bundled model, checked against `Tests/KeyPeekCoreTests/Fixtures/semantic-fixture.json`.
The web page, note and folders behind the panel are illustrative.
Earlier videos are attached to the [v0.2.0](https://github.com/vatsal191201/shortcuts-macos/releases/tag/v0.2.0)
and [v0.1.0](https://github.com/vatsal191201/shortcuts-macos/releases/tag/v0.1.0) releases.

Built as an independent implementation after a static security audit of
[KeyClu](https://github.com/Anze/KeyCluCask). No KeyClu code, assets, strings or
bundle identifiers are used — the app is a separate program written from public
macOS APIs.

## Install

KeyPeek runs on macOS 13 or later, on Apple Silicon and Intel Macs.

1. Download the newest `KeyPeek-x.y.z.zip` from
   [Releases](https://github.com/vatsal191201/shortcuts-macos/releases/latest), open it,
   and move `KeyPeek.app` to Applications.
2. Open KeyPeek. macOS shows a warning, because the app is not notarized yet. Click **Done**.
3. Allow the app to open:
   - **macOS 15 or later:** open System Settings > Privacy & Security. Find the line about
     KeyPeek and click **Open Anyway**.
   - **macOS 13 or 14:** in Finder, Control-click KeyPeek, choose **Open**, then click **Open**.
4. Give Accessibility access: System Settings > Privacy & Security > Accessibility (on
   macOS 27, "Device Control and Data Access"). Turn on **KeyPeek**.
5. Double-press **⌘** in any app.

After each update, macOS asks for Accessibility access again, because the app does not
have a Developer ID signature yet. Remove the old entry and turn on the new one.

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
  `~/Library/Application Support/KeyPeek/state.json` with `0600` permissions.
- **Local search model.** Natural-language search uses a 5 MB lookup table inside the
  app (`Resources/semantic-model.bin`). It is not a neural network, and the app never
  downloads anything. The table opens only when you type in the panel, through a memory
  map. A query takes well under 1 ms, and the first query for a large app (1,000 menu
  items) takes about 10 ms.

The one privileged thing it needs is Accessibility, which macOS requires for any app
that reads another app's UI. Grant it in System Settings → Privacy & Security →
Accessibility.

## Build

Requires macOS 13+ and Xcode command line tools.

```bash
swift build          # compile
swift test           # unit tests for the pure logic
bash scripts/build-app.sh   # assemble and ad-hoc sign dist/KeyPeek.app
UNIVERSAL=1 bash scripts/build-app.sh   # the same for Apple Silicon and Intel
open dist/KeyPeek.app
```

To publish a release, set the version in `Resources/Info.plist`, write
`docs/releases/vX.Y.Z.md`, and push the tag `vX.Y.Z`. GitHub Actions then runs the tests,
builds the universal app, and publishes the zip with its SHA-256.

On first launch, allow the app under **System Settings → Privacy & Security →
Accessibility**, then quit and reopen it.

## Use

- Double-press **⌘** to open the panel for the frontmost app.
- Type to filter by action, menu path or shortcut. The search field accepts ⌘A, ⌘C,
  ⌘V, ⌘X, ⌘Z and the usual delete keys.
- Type in plain words, for example "refresh", "make text bigger" or "incognito".
  Word matches come first. Below them, a **Similar** section shows commands with a
  similar meaning. A Similar row gets the first highlight only when the match is
  strong. Otherwise the highlight stays on "Show all shortcuts", so Return never runs
  a weak guess.
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
Sources/KeyPeekCore/   pure logic: AX parsing, menu flattening, search, export, storage
Sources/KeyPeek/       AppKit/SwiftUI shell: event monitor, panel, settings
Resources/               Info.plist, app icon, semantic-model.bin
scripts/                 build-app.sh, build-semantic-model.py
Tests/                   unit tests for the core
```

### The search model

`scripts/build-semantic-model.py` makes `Resources/semantic-model.bin`. It downloads
`minishlab/potion-base-32M` at a pinned revision, checks the SHA-256 of each file,
reduces the vectors from 512 to 64 numbers with PCA, and stores them as 8-bit values.
It also writes `Tests/KeyPeekCoreTests/Fixtures/semantic-fixture.json`, so the Swift
tests can check that the Swift tokenizer and vectors match the Python reference.
The script is the only part of the project that uses the network.

The split exists so the tricky parts (modifier masks, key glyphs, stable IDs,
search ranking, Markdown escaping) are testable without a screen or permissions.

## Roadmap

- Global hotkey listing (`com.apple.symbolichotkeys.plist`)
- Trackpad gesture reference
- skhd and Jitouch2 config import (read-only parsing, never execution)
- Custom shortcut groups and bookmarks

## Licence

MIT. See `LICENSE`.

`Resources/semantic-model.bin` is derived from
[minishlab/potion-base-32M](https://huggingface.co/minishlab/potion-base-32M)
(MIT License, revision `1e5a03f8eeb2c98b928fbbd846f22f816360919f`). That model is
distilled from [BAAI/bge-base-en-v1.5](https://huggingface.co/BAAI/bge-base-en-v1.5)
(MIT License).
