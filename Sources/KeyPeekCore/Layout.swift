import Foundation

// MARK: - Panel rows

/// One line in the panel list.
public enum PanelRow: Hashable, Identifiable, Sendable {
    case showAll
    case header(String)
    case item(ShortcutEntry)

    public static let showAllID = "row.show-all"

    public var id: String {
        switch self {
        case .showAll: return Self.showAllID
        case .header(let title): return "header.\(title)"
        case .item(let entry): return entry.id
        }
    }

    /// Headers are labels only. The arrow keys skip them.
    public var isSelectable: Bool {
        if case .header = self { return false }
        return true
    }

    public var entry: ShortcutEntry? {
        if case .item(let entry) = self { return entry }
        return nil
    }
}

public enum PanelLayout {

    /// Groups entries by their top-level menu and keeps the menu-bar order.
    /// Entries with the same ID appear one time only.
    public static func orderedGroups(_ entries: [ShortcutEntry]) -> [(title: String, items: [ShortcutEntry])] {
        var order: [String] = []
        var buckets: [String: [ShortcutEntry]] = [:]
        var seen = Set<String>()
        for entry in entries where seen.insert(entry.id).inserted {
            let key = entry.groupTitle
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(entry)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    /// The rows that the panel shows, from top to bottom.
    /// - The "Show all shortcuts" row is always first.
    /// - With an empty query, the rows are grouped in menu-bar order.
    /// - With a query, the rows are one flat list in rank order, so the first row is the best match.
    public static func rows(entries: [ShortcutEntry], query: String) -> [PanelRow] {
        var rows: [PanelRow] = [.showAll]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            for group in orderedGroups(entries) {
                rows.append(.header(group.title))
                rows.append(contentsOf: group.items.map(PanelRow.item))
            }
        } else {
            var seen = Set<String>()
            for entry in Search.filter(entries, query: trimmed) where seen.insert(entry.id).inserted {
                rows.append(.item(entry))
            }
        }
        return rows
    }

    /// With no query, Return opens the overview. With a query, Return runs the best match.
    public static func defaultSelection(in rows: [PanelRow], query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return PanelRow.showAllID }
        return rows.first(where: { $0.entry != nil })?.id ?? PanelRow.showAllID
    }
}

// MARK: - Keyboard navigation

public enum SelectionNavigator {

    public static let pageSize = 10

    /// Moves the selection by `delta` selectable rows and stops at the ends.
    public static func move(from current: String?, by delta: Int, in rows: [PanelRow]) -> String? {
        let ids = rows.filter(\.isSelectable).map(\.id)
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else {
            return delta >= 0 ? ids.first : ids.last
        }
        let target = min(max(index + delta, 0), ids.count - 1)
        return ids[target]
    }

    public static func first(in rows: [PanelRow]) -> String? {
        rows.first(where: \.isSelectable)?.id
    }

    public static func last(in rows: [PanelRow]) -> String? {
        rows.last(where: \.isSelectable)?.id
    }
}

// MARK: - Overview columns

public enum ColumnBalancer {

    /// Splits groups into at most `columns` columns. The groups keep their order
    /// (top to bottom, then left to right), and the tallest column is as short as possible.
    /// Returns the group indices for each column.
    public static func balance(heights: [Int], columns: Int) -> [[Int]] {
        let n = heights.count
        guard n > 0 else { return [] }
        let k = max(1, min(columns, n))
        if k == 1 { return [Array(0..<n)] }

        var prefix = [0]
        for h in heights { prefix.append(prefix.last! + max(h, 0)) }
        func sum(_ from: Int, _ to: Int) -> Int { prefix[to] - prefix[from] }   // groups from..<to

        // cost[j][i]: the smallest possible tallest column for the first i groups in j columns.
        let big = Int.max / 4
        var cost = Array(repeating: Array(repeating: big, count: n + 1), count: k + 1)
        var split = Array(repeating: Array(repeating: 0, count: n + 1), count: k + 1)
        for i in 0...n { cost[1][i] = sum(0, i) }
        if k >= 2 {
            for j in 2...k {
                for i in 0...n {
                    for p in 0...i {
                        let value = max(cost[j - 1][p], sum(p, i))
                        if value < cost[j][i] {
                            cost[j][i] = value
                            split[j][i] = p
                        }
                    }
                }
            }
        }

        var result: [[Int]] = []
        var end = n
        var j = k
        while j >= 1 {
            let start = j == 1 ? 0 : split[j][end]
            result.insert(Array(start..<end), at: 0)
            end = start
            j -= 1
        }
        return result.filter { !$0.isEmpty }
    }
}

// MARK: - Menu item lookup before a press

public enum MenuItemLocator {

    /// Finds a menu item again before the app presses it.
    ///
    /// First it follows `indexPath` from the menu bar. That node is accepted only when its title
    /// and its titled parents match the entry. If the menu changed, it searches the tree for a
    /// leaf with the same title and the same titled parents. It never returns a node that does
    /// not match, so a changed menu cannot make the app press a different command.
    public static func locate<Node>(root: Node,
                                    indexPath: [Int],
                                    expectedPath: [String],
                                    expectedTitle: String,
                                    maxNodes: Int = 5000,
                                    children: (Node) -> [Node],
                                    title: (Node) -> String) -> Node? {
        // 1. Direct path.
        var node = root
        var titled: [String] = []
        var followed = true
        for (step, index) in indexPath.enumerated() {
            let kids = children(node)
            guard index >= 0, index < kids.count else { followed = false; break }
            node = kids[index]
            let name = title(node)
            let isLeaf = step == indexPath.count - 1
            if !isLeaf && !name.isEmpty { titled.append(name) }
        }
        if followed, !indexPath.isEmpty, title(node) == expectedTitle, titled == expectedPath {
            return node
        }

        // 2. Search by titles.
        var budget = maxNodes
        func search(_ current: Node, _ path: [String]) -> Node? {
            guard budget > 0 else { return nil }
            budget -= 1
            let kids = children(current)
            if kids.isEmpty {
                return (title(current) == expectedTitle && path == expectedPath) ? current : nil
            }
            let name = title(current)
            let nextPath = name.isEmpty ? path : path + [name]
            guard expectedPath.starts(with: nextPath) else { return nil }
            for kid in kids {
                if let found = search(kid, nextPath) { return found }
            }
            return nil
        }
        // The root is the menu bar. Its title is not part of the path.
        for kid in children(root) {
            if let found = search(kid, []) { return found }
        }
        return nil
    }
}
