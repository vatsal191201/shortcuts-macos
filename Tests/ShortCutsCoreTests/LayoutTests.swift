import XCTest
@testable import ShortCutsCore

final class LayoutTests: XCTestCase {

    private func entry(_ group: String, _ title: String, _ key: String, enabled: Bool = true) -> ShortcutEntry {
        ShortcutEntry(appName: "Demo", appBundleID: nil, path: [group], title: title,
                      shortcut: Shortcut(key: key, modifiers: [.command]), enabled: enabled)
    }

    // MARK: Rows

    func testEmptyQueryKeepsMenuBarOrderAndStartsWithShowAll() {
        let entries = [entry("File", "New", "N"), entry("Edit", "Copy", "C"), entry("File", "Open", "O"), entry("View", "Zoom", "=")]
        let rows = PanelLayout.rows(entries: entries, query: "")
        XCTAssertEqual(rows.first, .showAll)
        let headers = rows.compactMap { row -> String? in if case .header(let t) = row { return t }; return nil }
        XCTAssertEqual(headers, ["File", "Edit", "View"], "groups must keep the menu-bar order, not A to Z")
        XCTAssertEqual(rows.compactMap(\.entry).map(\.title), ["New", "Open", "Copy", "Zoom"])
    }

    func testQueryGivesFlatRankedListAfterShowAll() {
        let entries = [entry("File", "Save As", "S"), entry("Edit", "Paste", "V"), entry("File", "Save", "S")]
        let rows = PanelLayout.rows(entries: entries, query: "save")
        XCTAssertEqual(rows.first, .showAll)
        XCTAssertFalse(rows.contains { if case .header = $0 { return true }; return false }, "no group headers with a query")
        XCTAssertEqual(rows.compactMap(\.entry).map(\.title), ["Save", "Save As"])
    }

    func testEqualScoresKeepMenuOrder() {
        let titles = (1...40).map { String(format: "zq %02d", $0) }   // same length, same score
        let entries = titles.map { entry("M", $0, "K") }
        XCTAssertEqual(Search.filter(entries, query: "zq").map(\.title), titles)
    }

    func testDuplicateEntriesAppearOnce() {
        let a = entry("File", "Close", "W")
        let rows = PanelLayout.rows(entries: [a, a], query: "")
        XCTAssertEqual(rows.compactMap(\.entry).count, 1)
    }

    func testDefaultSelection() {
        let entries = [entry("File", "Save", "S"), entry("File", "Open", "O")]
        let empty = PanelLayout.rows(entries: entries, query: "")
        XCTAssertEqual(PanelLayout.defaultSelection(in: empty, query: ""), PanelRow.showAllID)
        let searched = PanelLayout.rows(entries: entries, query: "op")
        XCTAssertEqual(PanelLayout.defaultSelection(in: searched, query: "op"), entries[1].id)
        let none = PanelLayout.rows(entries: entries, query: "zzz")
        XCTAssertEqual(PanelLayout.defaultSelection(in: none, query: "zzz"), PanelRow.showAllID)
    }

    // MARK: Navigation

    func testArrowNavigationSkipsHeadersAndStopsAtEnds() {
        let entries = [entry("File", "New", "N"), entry("Edit", "Copy", "C")]
        let rows = PanelLayout.rows(entries: entries, query: "")
        // rows: showAll, header File, New, header Edit, Copy
        var sel: String? = PanelRow.showAllID
        sel = SelectionNavigator.move(from: sel, by: 1, in: rows)
        XCTAssertEqual(sel, entries[0].id)
        sel = SelectionNavigator.move(from: sel, by: 1, in: rows)
        XCTAssertEqual(sel, entries[1].id)
        sel = SelectionNavigator.move(from: sel, by: 1, in: rows)
        XCTAssertEqual(sel, entries[1].id, "stops at the last row")
        sel = SelectionNavigator.move(from: sel, by: -SelectionNavigator.pageSize, in: rows)
        XCTAssertEqual(sel, PanelRow.showAllID, "stops at the first row")
    }

    func testNavigationFromNoSelection() {
        let rows = PanelLayout.rows(entries: [entry("File", "New", "N")], query: "")
        XCTAssertEqual(SelectionNavigator.move(from: nil, by: 1, in: rows), PanelRow.showAllID)
        XCTAssertEqual(SelectionNavigator.move(from: "gone", by: -1, in: rows), rows.last?.id)
        XCTAssertEqual(SelectionNavigator.first(in: rows), PanelRow.showAllID)
        XCTAssertEqual(SelectionNavigator.last(in: rows), rows.last?.id)
    }

    // MARK: Columns

    func testBalancerKeepsOrderAndBalances() {
        XCTAssertEqual(ColumnBalancer.balance(heights: [10, 10, 10], columns: 3), [[0], [1], [2]])
        XCTAssertEqual(ColumnBalancer.balance(heights: [5, 1, 1, 1, 1, 1], columns: 2), [[0], [1, 2, 3, 4, 5]])
        XCTAssertEqual(ColumnBalancer.balance(heights: [3, 3, 3, 3], columns: 2), [[0, 1], [2, 3]])
        XCTAssertEqual(ColumnBalancer.balance(heights: [4, 4], columns: 5), [[0], [1]], "never more columns than groups")
        XCTAssertEqual(ColumnBalancer.balance(heights: [], columns: 3), [])
        let flat = ColumnBalancer.balance(heights: [8, 2, 7, 3, 9, 1, 4], columns: 3).flatMap { $0 }
        XCTAssertEqual(flat, Array(0..<7), "every group appears once, in order")
    }

    // MARK: Locator

    private final class FakeNode {
        let title: String
        var kids: [FakeNode]
        init(_ title: String, _ kids: [FakeNode] = []) { self.title = title; self.kids = kids }
    }

    private func menuBar() -> FakeNode {
        // Menu bar > "File" > (untitled AXMenu) > items. This is the shape of a real AX menu tree.
        FakeNode("", [
            FakeNode("Apple", [FakeNode("", [FakeNode("Lock Screen"), FakeNode("Log Out")])]),
            FakeNode("File", [FakeNode("", [FakeNode("New"), FakeNode(""), FakeNode("Close")])]),
        ])
    }

    private func locate(_ root: FakeNode, _ indexPath: [Int], _ path: [String], _ title: String) -> FakeNode? {
        MenuItemLocator.locate(root: root, indexPath: indexPath, expectedPath: path, expectedTitle: title,
                               children: { $0.kids }, title: { $0.title })
    }

    func testLocatorFollowsIndexPath() {
        let root = menuBar()
        let found = locate(root, [1, 0, 2], ["File"], "Close")
        XCTAssertTrue(found === root.kids[1].kids[0].kids[2])
    }

    func testLocatorFallsBackWhenMenuChanged() {
        let root = menuBar()
        // A new item moved "Close" down by one place.
        root.kids[1].kids[0].kids.insert(FakeNode("Open"), at: 1)
        let found = locate(root, [1, 0, 2], ["File"], "Close")
        XCTAssertEqual(found?.title, "Close")
        XCTAssertTrue(found === root.kids[1].kids[0].kids[3])
    }

    func testLocatorNeverReturnsADifferentCommand() {
        let root = menuBar()
        // The index path now points at "Log Out" in another menu. It must not match.
        XCTAssertNil(locate(root, [0, 0, 1], ["File"], "Quit"))
        XCTAssertNil(locate(root, [0, 0, 1], ["File"], "Log Out"), "same title, wrong menu")
        XCTAssertEqual(locate(root, [9, 9], ["File"], "Close")?.title, "Close", "a bad index path falls back to the title search")
    }

    func testFlattenCarriesIndexPath() {
        let tree = [MenuNode(id: "f", title: "File", shortcut: nil, enabled: true, children: [
            MenuNode(id: "m", title: "", shortcut: nil, enabled: true, children: [
                MenuNode(id: "n", title: "New", shortcut: Shortcut(key: "N", modifiers: [.command]), enabled: true,
                         children: [], indexPath: [1, 0, 0]),
            ], indexPath: [1, 0]),
        ], indexPath: [1])]
        let entries = MenuFlattener.flatten(nodes: tree, appName: "Demo")
        XCTAssertEqual(entries.first?.indexPath, [1, 0, 0])
        XCTAssertEqual(entries.first?.path, ["File"])
    }
}
