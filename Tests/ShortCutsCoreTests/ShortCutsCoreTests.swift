import XCTest
@testable import ShortCutsCore

final class ShortCutsCoreTests: XCTestCase {

    // MARK: Modifiers

    func testAXModifierMaskMapping() {
        XCTAssertEqual(ShortcutParser.modifiers(fromAXMask: 0), [.command])
        XCTAssertEqual(ShortcutParser.modifiers(fromAXMask: 1), [.command, .shift])
        XCTAssertEqual(ShortcutParser.modifiers(fromAXMask: 2), [.command, .option])
        XCTAssertEqual(ShortcutParser.modifiers(fromAXMask: 4), [.command, .control])
        XCTAssertEqual(ShortcutParser.modifiers(fromAXMask: 8), [])
        XCTAssertEqual(ShortcutParser.modifiers(fromAXMask: 15), [.shift, .option, .control])
    }

    func testGlyphOrderIsAppleCanonical() {
        let m: Modifiers = [.command, .shift, .option, .control]
        XCTAssertEqual(m.glyphs, "⌃⌥⇧⌘")
    }

    // MARK: Key normalisation

    func testSpecialKeys() {
        XCTAssertEqual(ShortcutParser.displayKey(char: nil, virtualKey: 36), "↩")
        XCTAssertEqual(ShortcutParser.displayKey(char: nil, virtualKey: 53), "⎋")
        XCTAssertEqual(ShortcutParser.displayKey(char: nil, virtualKey: 123), "←")
        XCTAssertEqual(ShortcutParser.displayKey(char: nil, virtualKey: 96), "F5")
        XCTAssertEqual(ShortcutParser.displayKey(char: nil, virtualKey: 999), "")
    }

    func testPlainCharactersAreUppercased() {
        XCTAssertEqual(ShortcutParser.displayKey(char: "s", virtualKey: 1), "S")
        XCTAssertEqual(ShortcutParser.displayKey(char: "1", virtualKey: 18), "1")
    }

    func testShortcutRequiresAKey() {
        XCTAssertNil(ShortcutParser.shortcut(char: nil, axModifiers: 0, virtualKey: nil))
        XCTAssertNil(ShortcutParser.shortcut(char: "", axModifiers: 4, virtualKey: nil))
        let s = ShortcutParser.shortcut(char: "k", axModifiers: 1, virtualKey: 40)
        XCTAssertEqual(s?.display, "⇧⌘K")
    }

    // MARK: Flattening

    func testFlattenOnlyEmitsLeavesWithShortcuts() {
        let tree = [
            MenuNode(id: "1", title: "File", shortcut: nil, enabled: true, children: [
                MenuNode(id: "2", title: "New", shortcut: Shortcut(key: "N", modifiers: [.command]), enabled: true, children: []),
                MenuNode(id: "3", title: "Close", shortcut: nil, enabled: true, children: []),
            ]),
            MenuNode(id: "4", title: "Edit", shortcut: nil, enabled: true, children: [
                MenuNode(id: "5", title: "Copy", shortcut: Shortcut(key: "C", modifiers: [.command]), enabled: false, children: []),
            ]),
        ]
        let entries = MenuFlattener.flatten(nodes: tree, appName: "Demo")
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.title).sorted(), ["Copy", "New"])
        XCTAssertEqual(entries.first(where: { $0.title == "New" })?.path, ["File"])
        XCTAssertEqual(entries.first(where: { $0.title == "Copy" })?.enabled, false)
    }

    func testStableIDsAcrossRuns() {
        let sc = Shortcut(key: "S", modifiers: [.command])
        let a = ShortcutEntry(appName: "X", appBundleID: nil, path: ["File"], title: "Save", shortcut: sc, enabled: true)
        let b = ShortcutEntry(appName: "X", appBundleID: nil, path: ["File"], title: "Save", shortcut: sc, enabled: true)
        XCTAssertEqual(a.id, b.id)
        let c = ShortcutEntry(appName: "X", appBundleID: nil, path: ["File"], title: "Save", shortcut: Shortcut(key: "S", modifiers: [.shift]), enabled: true)
        XCTAssertNotEqual(a.id, c.id)
    }

    // MARK: Search

    func testSearchRanksPrefixAboveSubsequence() {
        let entries = [
            make("Save", "S"),
            make("Save As", "S"),
            make("Reveal in Finder", "R"),
        ]
        let result = Search.filter(entries, query: "save")
        XCTAssertEqual(result.first?.title, "Save")
        XCTAssertEqual(result.count, 2)
    }

    func testSearchSubsequence() {
        let entries = [make("Reveal in Finder", "R")]
        XCTAssertEqual(Search.filter(entries, query: "rif").count, 1)
        XCTAssertEqual(Search.filter(entries, query: "zzz").count, 0)
    }

    // MARK: Export

    func testMarkdownEscapesPipes() {
        let entry = ShortcutEntry(appName: "Demo", appBundleID: nil, path: ["A|B"], title: "Do | thing",
                                  shortcut: Shortcut(key: "D", modifiers: [.command]), enabled: true)
        let md = MarkdownExporter.document(appName: "Demo", bundleID: nil, entries: [entry])
        XCTAssertTrue(md.contains("A\\|B"))
        XCTAssertTrue(md.contains("Do \\| thing"))
        XCTAssertTrue(md.contains("⌘D"))
    }

    func testMarkdownRespectsHiddenFilter() {
        var entry = ShortcutEntry(appName: "Demo", appBundleID: nil, path: ["File"], title: "Hide me",
                                  shortcut: Shortcut(key: "H", modifiers: [.command]), enabled: true)
        entry.isHidden = true
        let md = MarkdownExporter.document(appName: "Demo", bundleID: nil, entries: [entry])
        XCTAssertFalse(md.contains("Hide me"))
    }

    // MARK: Gesture

    func testDoubleCommandFiresOnce() {
        var g = GestureDetector(interval: 0.4)
        XCTAssertFalse(g.handle(keyCode: 55, isDown: true, at: 0.0))
        XCTAssertFalse(g.handle(keyCode: 55, isDown: false, at: 0.08))
        XCTAssertTrue(g.handle(keyCode: 55, isDown: true, at: 0.2))
        XCTAssertFalse(g.handle(keyCode: 55, isDown: false, at: 0.25))
        XCTAssertFalse(g.handle(keyCode: 55, isDown: true, at: 0.3))
    }

    func testSlowDoublePressDoesNotFire() {
        var g = GestureDetector(interval: 0.3)
        XCTAssertFalse(g.handle(keyCode: 55, isDown: true, at: 0.0))
        XCTAssertFalse(g.handle(keyCode: 55, isDown: false, at: 0.05))
        XCTAssertFalse(g.handle(keyCode: 55, isDown: true, at: 0.9))
    }

    func testTypingResetsGesture() {
        var g = GestureDetector(interval: 0.4)
        _ = g.handle(keyCode: 55, isDown: true, at: 0.0)
        _ = g.handle(keyCode: 55, isDown: false, at: 0.05)
        g.reset()
        XCTAssertFalse(g.handle(keyCode: 55, isDown: true, at: 0.2))
    }

    func testRightCommandAlsoWorks() {
        var g = GestureDetector(interval: 0.4)
        _ = g.handle(keyCode: 54, isDown: true, at: 0.0)
        _ = g.handle(keyCode: 54, isDown: false, at: 0.05)
        XCTAssertTrue(g.handle(keyCode: 54, isDown: true, at: 0.2))
    }

    private func make(_ title: String, _ key: String) -> ShortcutEntry {
        ShortcutEntry(appName: "Demo", appBundleID: nil, path: ["Menu"], title: title,
                      shortcut: Shortcut(key: key, modifiers: [.command]), enabled: true)
    }
}
