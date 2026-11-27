import Foundation

/// Gives a similarity score (about -1 to 1) for each entry ID, for one query.
public protocol SemanticScoring: AnyObject {
    func similarities(for query: String) -> [String: Float]
}

/// The meaning-based scores for the menu entries of one panel.
///
/// It does no work until the first query: then it embeds each title one time and keeps
/// the vectors until the panel shows another app.
public final class SemanticIndex: SemanticScoring {

    private let entries: [ShortcutEntry]
    private let model: () -> SemanticModel?
    private var titleVectors: [(id: String, vector: [Float])]?
    private var lastQuery: String?
    private var lastResult: [String: Float] = [:]

    public init(entries: [ShortcutEntry], model: @escaping () -> SemanticModel?) {
        self.entries = entries
        self.model = model
    }

    public func similarities(for query: String) -> [String: Float] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let model = model() else { return [:] }
        if trimmed == lastQuery { return lastResult }

        if titleVectors == nil {
            titleVectors = entries.compactMap { entry in
                model.embed(Self.clean(entry.title)).map { (entry.id, $0) }
            }
        }
        var result: [String: Float] = [:]
        if let queryVector = model.embed(QueryAliases.expand(trimmed)) {
            for item in titleVectors ?? [] {
                result[item.id] = SemanticModel.similarity(queryVector, item.vector)
            }
        }
        lastQuery = trimmed
        lastResult = result
        return result
    }

    /// Menu titles often end in "…". The ellipsis carries no meaning, so it is removed.
    static func clean(_ title: String) -> String {
        title.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
    }
}

/// Common words that a tiny model cannot connect to the menu wording. Each word adds its
/// menu terms to the query before the query is embedded. The table is short on purpose.
public enum QueryAliases {

    static let table: [String: String] = [
        "incognito": "private window",
        "inspect": "developer tools",
        "devtools": "developer tools",
        "refresh": "reload",
        "preferences": "settings",
        "prefs": "settings",
        "options": "settings",
        "bigger": "zoom in",
        "larger": "zoom in",
        "enlarge": "zoom in",
        "magnify": "zoom in",
        "smaller": "zoom out",
        "shrink": "zoom out",
        "delete": "trash",
        "bin": "trash",
        "restore": "reopen",
        "fullscreen": "full screen",
        "hotkeys": "shortcuts",
    ]

    public static func expand(_ query: String) -> String {
        let words = query.lowercased().split { !$0.isLetter }.map(String.init)
        let extra = words.compactMap { table[$0] }
        return extra.isEmpty ? query : query + " " + extra.joined(separator: " ")
    }
}

// MARK: - Combined search

public struct SearchResult: Sendable {
    /// Word matches: the title, the menu path or the keys contain the query.
    public var strong: [ShortcutEntry]
    /// Meaning matches first, then loose letter-order matches.
    public var similar: [ShortcutEntry]
    /// True when the first similar entry is a meaning match with a high score.
    public var confidentSimilar: Bool
}

extension Search {

    /// Meaning matches below this score are not shown.
    public static let similarFloor: Float = 0.30
    /// A meaning match at or above this score can get the first highlight.
    public static let similarConfident: Float = 0.50
    /// The largest number of meaning matches in the list.
    public static let similarLimit = 6

    public static func search(_ entries: [ShortcutEntry], query: String, semantic: SemanticScoring?) -> SearchResult {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return SearchResult(strong: entries, similar: [], confidentSimilar: false) }

        var strong: [ShortcutEntry] = []
        var loose: [ShortcutEntry] = []
        var seen = Set<String>()
        for (entry, score) in ranked(entries, query: q) where seen.insert(entry.id).inserted {
            if score >= 500 { strong.append(entry) } else { loose.append(entry) }
        }

        var meaning: [(entry: ShortcutEntry, score: Float)] = []
        if let semantic {
            let scores = semantic.similarities(for: query)
            let strongIDs = Set(strong.map(\.id))
            var used = Set<String>()
            meaning = entries.enumerated()
                .compactMap { index, entry -> (ShortcutEntry, Float, Int)? in
                    guard !strongIDs.contains(entry.id), let score = scores[entry.id],
                          score >= similarFloor, used.insert(entry.id).inserted else { return nil }
                    return (entry, score, index)
                }
                .sorted { a, b in a.1 != b.1 ? a.1 > b.1 : a.2 < b.2 }
                .prefix(similarLimit)
                .map { ($0.0, $0.1) }
        }

        let meaningIDs = Set(meaning.map(\.entry.id))
        let similar = meaning.map(\.entry) + loose.filter { !meaningIDs.contains($0.id) }
        let confident = (meaning.first?.score ?? 0) >= similarConfident
        return SearchResult(strong: strong, similar: similar, confidentSimilar: confident)
    }
}

// MARK: - Panel layout with the Similar section

public struct PanelLayoutResult: Sendable {
    public var rows: [PanelRow]
    public var defaultSelection: String?
}

extension PanelLayout {

    public static let similarHeader = "Similar"

    /// The panel rows for a query, with meaning matches when `semantic` is set.
    ///
    /// The first highlight goes to the best word match. Without one, it goes to a confident
    /// meaning match. Otherwise it stays on "Show all shortcuts", so Return never runs a
    /// weak guess.
    public static func build(entries: [ShortcutEntry], query: String, semantic: SemanticScoring?) -> PanelLayoutResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let rows = rows(entries: entries, query: "")
            return PanelLayoutResult(rows: rows, defaultSelection: PanelRow.showAllID)
        }

        let result = Search.search(entries, query: trimmed, semantic: semantic)
        var rows: [PanelRow] = [.showAll]
        rows.append(contentsOf: result.strong.map(PanelRow.item))
        if !result.similar.isEmpty {
            rows.append(.header(similarHeader))
            rows.append(contentsOf: result.similar.map(PanelRow.item))
        }

        // A meaning match in the Apple menu (Log Out, Lock Screen, Force Quit...) never gets the
        // first highlight. Only a word match that the user typed can preselect those commands.
        let firstSimilar = result.similar.first
        let similarSelection = (result.confidentSimilar && firstSimilar.map(isSystemMenu) == false)
            ? firstSimilar?.id : nil
        let selection = result.strong.first?.id ?? similarSelection ?? PanelRow.showAllID
        return PanelLayoutResult(rows: rows, defaultSelection: selection)
    }

    /// The Apple menu is always the first item of the menu bar.
    static func isSystemMenu(_ entry: ShortcutEntry) -> Bool {
        entry.indexPath.first == 0
    }
}
