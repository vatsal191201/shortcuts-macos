import XCTest
@testable import ShortCutsCore

final class SemanticTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let model: SemanticModel? = SemanticModel(url: repoRoot.appendingPathComponent("Resources/semantic-model.bin"))

    private struct Fixture: Decodable {
        struct Case: Decodable { let text: String; let tokens: [String]; let vector: [Float]? }
        let dims: Int
        let cases: [Case]
    }

    private func loadModel() throws -> SemanticModel {
        try XCTUnwrap(Self.model, "Resources/semantic-model.bin is missing or damaged")
    }

    private func loadFixture() throws -> Fixture {
        let url = Self.repoRoot.appendingPathComponent("Tests/ShortCutsCoreTests/Fixtures/semantic-fixture.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    // MARK: Parity with the Python reference (scripts/build-semantic-model.py)

    func testTokenizerMatchesReference() throws {
        let model = try loadModel()
        for c in try loadFixture().cases {
            XCTAssertEqual(model.tokens(for: c.text), c.tokens, "tokens of \(c.text.debugDescription)")
        }
    }

    func testVectorsMatchReference() throws {
        let model = try loadModel()
        let fixture = try loadFixture()
        XCTAssertEqual(model.dims, fixture.dims)
        for c in fixture.cases {
            let vector = model.embed(c.text)
            guard let expected = c.vector else {
                XCTAssertNil(vector, "\(c.text.debugDescription) has no known token")
                continue
            }
            let actual = try XCTUnwrap(vector, "vector of \(c.text.debugDescription)")
            XCTAssertEqual(actual.count, expected.count)
            let worst = zip(actual, expected).map { abs($0 - $1) }.max() ?? 0
            XCTAssertLessThan(worst, 1e-4, "vector of \(c.text.debugDescription)")
        }
    }

    // MARK: Damaged files never load

    func testDamagedFilesAreRejected() throws {
        let good = try Data(contentsOf: Self.repoRoot.appendingPathComponent("Resources/semantic-model.bin"))
        XCTAssertNil(SemanticModel(data: Data()))
        XCTAssertNil(SemanticModel(data: good.prefix(good.count - 1)), "truncated")
        XCTAssertNil(SemanticModel(data: good + Data([0])), "extra byte")
        var badMagic = good
        badMagic[0] = UInt8(ascii: "X")
        XCTAssertNil(SemanticModel(data: badMagic))
        var badOffset = good
        badOffset[20] = 0; badOffset[21] = 0; badOffset[22] = 0; badOffset[23] = 0   // second offset = first offset
        XCTAssertNil(SemanticModel(data: badOffset))
    }

    // MARK: Search quality and behavior

    private static let browserTitles = [
        "New Tab", "New Window", "New Private Window", "Reopen Closed Tab", "Close Tab", "Close Window",
        "Close All", "Open Location…", "Save Page As…", "Print…", "Undo", "Redo", "Cut", "Copy", "Paste",
        "Select All", "Find…", "Find Next", "Reload Page", "Stop", "Zoom In", "Zoom Out", "Actual Size",
        "Enter Full Screen", "Show Sidebar", "View Source", "Developer Tools", "Back", "Forward", "Home",
        "Show History", "Bookmark This Tab…", "Show All Bookmarks", "Duplicate Tab", "Pin Tab", "Mute Tab",
        "Show Downloads", "Minimize", "Move to Trash", "New Folder", "Get Info", "Empty Trash…",
        "Show Next Tab", "Show Previous Tab", "Settings…", "Hide Others", "Quit",
    ]

    private func browserEntries() -> [ShortcutEntry] {
        Self.browserTitles.enumerated().map { index, title in
            ShortcutEntry(appName: "Browser", appBundleID: nil, path: ["Menu"], title: title,
                          shortcut: Shortcut(key: String(UnicodeScalar(UInt8(65 + index % 26))), modifiers: [.command]),
                          enabled: true)
        }
    }

    func testNaturalLanguageQueriesFindTheRightCommand() throws {
        let model = try loadModel()
        let entries = browserEntries()
        let index = SemanticIndex(entries: entries, model: { model })
        let cases: [(String, String)] = [
            ("reopen tab", "Reopen Closed Tab"), ("undo close tab", "Reopen Closed Tab"),
            ("make text bigger", "Zoom In"), ("go back", "Back"), ("search in page", "Find…"),
            ("delete file", "Move to Trash"), ("incognito", "New Private Window"), ("refresh", "Reload Page"),
            ("save bookmark", "Bookmark This Tab…"), ("inspect element", "Developer Tools"),
            ("next tab", "Show Next Tab"), ("downloads", "Show Downloads"),
            ("make window full screen", "Enter Full Screen"), ("preferences", "Settings…"),
            ("copy the tab", "Duplicate Tab"),
        ]
        var inTopThree = 0
        for (query, want) in cases {
            let layout = PanelLayout.build(entries: entries, query: query, semantic: index)
            let titles = layout.rows.compactMap(\.entry).map(\.title)
            if titles.prefix(3).contains(want) { inTopThree += 1 } else {
                print("not in top 3: \(query) -> \(titles.prefix(3))")
            }
        }
        XCTAssertGreaterThanOrEqual(inTopThree, 14, "natural-language quality dropped")
    }

    func testMeaningMatchesComeAfterWordMatchesUnderSimilar() throws {
        let model = try loadModel()
        let entries = browserEntries()
        let index = SemanticIndex(entries: entries, model: { model })

        // "reload" is a word match: it is first and highlighted.
        let reload = PanelLayout.build(entries: entries, query: "reload", semantic: index)
        XCTAssertEqual(reload.rows.compactMap(\.entry).first?.title, "Reload Page")
        XCTAssertEqual(reload.defaultSelection, reload.rows.compactMap(\.entry).first?.id)

        // "refresh" has no word match: "Reload Page" comes under the Similar header,
        // and it gets the highlight only because its score is high.
        let refresh = PanelLayout.build(entries: entries, query: "refresh", semantic: index)
        guard let header = refresh.rows.firstIndex(of: .header(PanelLayout.similarHeader)) else {
            return XCTFail("no Similar header")
        }
        let afterHeader = refresh.rows[(header + 1)...].compactMap(\.entry)
        XCTAssertEqual(afterHeader.first?.title, "Reload Page")
        XCTAssertEqual(refresh.defaultSelection, afterHeader.first?.id)
    }

    func testWeakGuessesNeverGetTheHighlight() throws {
        let model = try loadModel()
        let entries = browserEntries()
        let index = SemanticIndex(entries: entries, model: { model })
        for query in ["weather tomorrow", "banana", "my mother", "football score", "qwerty"] {
            let layout = PanelLayout.build(entries: entries, query: query, semantic: index)
            XCTAssertEqual(layout.defaultSelection, PanelRow.showAllID, "\(query) must not preselect a command")
            XCTAssertLessThanOrEqual(layout.rows.compactMap(\.entry).count,
                                     Search.similarLimit + Search.filter(entries, query: query).count)
        }
    }

    private final class FixedScores: SemanticScoring {
        let scores: [String: Float]
        init(_ scores: [String: Float]) { self.scores = scores }
        func similarities(for query: String) -> [String: Float] { scores }
    }

    func testAppleMenuCommandsAreNeverPreselectedByMeaning() {
        // The Apple menu is the first menu-bar item, so its index paths start with 0.
        let lock = ShortcutEntry(appName: "Browser", appBundleID: nil, path: ["Apple"], title: "Lock Screen",
                                 shortcut: Shortcut(key: "Q", modifiers: [.control, .command]), enabled: true,
                                 indexPath: [0, 0, 5])
        let reload = ShortcutEntry(appName: "Browser", appBundleID: nil, path: ["View"], title: "Reload Page",
                                   shortcut: Shortcut(key: "R", modifiers: [.command]), enabled: true,
                                   indexPath: [3, 0, 1])
        let entries = [lock, reload]

        // A strong meaning match in the Apple menu is listed first, but not highlighted.
        let system = PanelLayout.build(entries: entries, query: "sleepy time", semantic: FixedScores([lock.id: 0.9]))
        XCTAssertEqual(system.rows.compactMap(\.entry).first?.id, lock.id)
        XCTAssertEqual(system.defaultSelection, PanelRow.showAllID)

        // The same score in a normal menu gets the highlight.
        let normal = PanelLayout.build(entries: entries, query: "sleepy time", semantic: FixedScores([reload.id: 0.9]))
        XCTAssertEqual(normal.defaultSelection, reload.id)

        // A word match that the user typed can still preselect the Apple-menu command.
        let typed = PanelLayout.build(entries: entries, query: "lock screen", semantic: FixedScores([:]))
        XCTAssertEqual(typed.defaultSelection, lock.id)
    }

    func testSearchWorksWithoutTheModel() {
        let entries = browserEntries()
        let index = SemanticIndex(entries: entries, model: { nil })
        let layout = PanelLayout.build(entries: entries, query: "reload", semantic: index)
        XCTAssertEqual(layout.rows.compactMap(\.entry).first?.title, "Reload Page")
        XCTAssertEqual(PanelLayout.build(entries: entries, query: "refresh", semantic: index).defaultSelection,
                       PanelRow.showAllID)
    }

    func testAliasesExpandOnlyKnownWords() {
        XCTAssertEqual(QueryAliases.expand("refresh"), "refresh reload")
        XCTAssertEqual(QueryAliases.expand("Inspect element"), "Inspect element developer tools")
        XCTAssertEqual(QueryAliases.expand("close tab"), "close tab")
    }

    func testIndexingAThousandTitlesIsFast() throws {
        let model = try loadModel()
        let entries = (0..<1000).map { i in
            ShortcutEntry(appName: "Big", appBundleID: nil, path: ["Menu \(i / 50)"],
                          title: "\(Self.browserTitles[i % Self.browserTitles.count]) \(i)",
                          shortcut: Shortcut(key: "K", modifiers: [.command]), enabled: true)
        }
        let index = SemanticIndex(entries: entries, model: { model })
        let start = Date()
        _ = index.similarities(for: "reopen tab")      // embeds all 1000 titles
        let first = Date().timeIntervalSince(start)
        let again = Date()
        _ = index.similarities(for: "reopen tabs")     // titles are cached now
        let next = Date().timeIntervalSince(again)
        print(String(format: "1000 titles: first query %.1f ms, next query %.2f ms", first * 1000, next * 1000))
        XCTAssertLessThan(first, 0.5, "the first query must stay well under half a second")
        XCTAssertLessThan(next, 0.05)
    }
}
