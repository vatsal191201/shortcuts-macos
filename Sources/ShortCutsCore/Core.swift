import Foundation

// MARK: - Modifiers

/// Keyboard modifiers in a normalised, platform-neutral order.
public struct Modifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = Modifiers(rawValue: 1 << 0)
    public static let option  = Modifiers(rawValue: 1 << 1)
    public static let shift   = Modifiers(rawValue: 1 << 2)
    public static let command = Modifiers(rawValue: 1 << 3)

    /// Apple's canonical glyph order: ⌃⌥⇧⌘
    public var glyphs: String {
        var out = ""
        if contains(.control) { out += "⌃" }
        if contains(.option)  { out += "⌥" }
        if contains(.shift)   { out += "⇧" }
        if contains(.command) { out += "⌘" }
        return out
    }

    public var names: [String] {
        var out: [String] = []
        if contains(.control) { out.append("Ctrl") }
        if contains(.option)  { out.append("Opt") }
        if contains(.shift)   { out.append("Shift") }
        if contains(.command) { out.append("Cmd") }
        return out
    }
}

extension Modifiers: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self.init(rawValue: try c.decode(Int.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

// MARK: - Shortcut

public struct Shortcut: Hashable, Codable, Sendable {
    /// Display key, already normalised ("S", "↩", "F5", "→").
    public var key: String
    public var modifiers: Modifiers
    public var virtualKey: Int?

    public init(key: String, modifiers: Modifiers, virtualKey: Int? = nil) {
        self.key = key
        self.modifiers = modifiers
        self.virtualKey = virtualKey
    }

    public var display: String {
        guard !key.isEmpty || !modifiers.isEmpty else { return "" }
        return modifiers.glyphs + key
    }

    public var isEmpty: Bool { key.isEmpty && modifiers.isEmpty }
}

// MARK: - AX parsing

public enum ShortcutParser {
    /// Apple's AXMenuItemCmdModifiers bitmask.
    /// 1 = shift, 2 = option, 4 = control, 8 = "no command" (command is implied otherwise).
    public static func modifiers(fromAXMask mask: Int) -> Modifiers {
        var m: Modifiers = []
        if mask & 1 != 0 { m.insert(.shift) }
        if mask & 2 != 0 { m.insert(.option) }
        if mask & 4 != 0 { m.insert(.control) }
        if mask & 8 == 0 { m.insert(.command) }
        return m
    }

    /// Maps a CGKeyCode to the symbol Apple shows in menus.
    public static func specialKey(forVirtualKey code: Int) -> String? {
        switch code {
        case 36, 76: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return "⎋"
        case 71: return "⌧"
        case 114: return "Help"
        case 115: return "↖"
        case 116: return "⇞"
        case 117: return "⌦"
        case 119: return "↘"
        case 121: return "⇟"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 122: return "F1"
        case 120: return "F2"
        case 99:  return "F3"
        case 118: return "F4"
        case 96:  return "F5"
        case 97:  return "F6"
        case 98:  return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default: return nil
        }
    }

    /// Normalises the raw AX command character into what a menu would display.
    public static func displayKey(char: String?, virtualKey: Int?) -> String {
        if let c = char, !c.isEmpty {
            // Control characters arrive as unicode scalars for Return/Tab/Escape.
            if let scalar = c.unicodeScalars.first, scalar.value < 0x20 {
                if let special = specialKey(forVirtualKey: virtualKey ?? -1) { return special }
            }
            return c.uppercased()
        }
        if let vk = virtualKey, let special = specialKey(forVirtualKey: vk) { return special }
        return ""
    }

    /// Returns nil when the menu item has no keyboard equivalent at all.
    public static func shortcut(char: String?, axModifiers: Int?, virtualKey: Int?) -> Shortcut? {
        let key = displayKey(char: char, virtualKey: virtualKey)
        let mods = modifiers(fromAXMask: axModifiers ?? 0)
        if key.isEmpty && mods.isEmpty { return nil }
        if key.isEmpty && !mods.isEmpty { return nil }
        return Shortcut(key: key, modifiers: mods, virtualKey: virtualKey)
    }
}

// MARK: - Menu tree

public struct MenuNode: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var title: String
    public var shortcut: Shortcut?
    public var enabled: Bool
    public var children: [MenuNode]
    /// Child indices from the menu bar to this element in the live Accessibility tree.
    public var indexPath: [Int]

    public init(id: String, title: String, shortcut: Shortcut?, enabled: Bool, children: [MenuNode], indexPath: [Int] = []) {
        self.id = id
        self.title = title
        self.shortcut = shortcut
        self.enabled = enabled
        self.children = children
        self.indexPath = indexPath
    }
}

public struct ShortcutEntry: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var appName: String
    public var appBundleID: String?
    public var path: [String]
    public var title: String
    public var shortcut: Shortcut
    public var enabled: Bool
    public var isHidden: Bool
    public var isBookmarked: Bool
    public var used: Int
    /// Where the menu item was in the live Accessibility tree. Used to find it again before a press.
    public var indexPath: [Int]

    public init(appName: String,
                appBundleID: String?,
                path: [String],
                title: String,
                shortcut: Shortcut,
                enabled: Bool,
                isHidden: Bool = false,
                isBookmarked: Bool = false,
                used: Int = 0,
                indexPath: [Int] = []) {
        self.appName = appName
        self.appBundleID = appBundleID
        self.path = path
        self.title = title
        self.shortcut = shortcut
        self.enabled = enabled
        self.isHidden = isHidden
        self.isBookmarked = isBookmarked
        self.used = used
        self.indexPath = indexPath
        self.id = Self.makeID(appName: appName, path: path, title: title, shortcut: shortcut)
    }

    public var groupTitle: String {
        path.first ?? "General"
    }

    /// Deterministic across launches (Swift's Hasher is seeded per process, so we do not use it).
    public static func makeID(appName: String, path: [String], title: String, shortcut: Shortcut) -> String {
        let joined = ([appName] + path + [title, shortcut.display]).joined(separator: "\u{1F}")
        return "\(fnv1a(joined))"
    }

    static func fnv1a(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

public enum MenuFlattener {
    /// Walks the menu tree and returns every leaf that has a keyboard shortcut.
    public static func flatten(nodes: [MenuNode],
                               appName: String,
                               appBundleID: String? = nil) -> [ShortcutEntry] {
        var out: [ShortcutEntry] = []
        func walk(_ node: MenuNode, path: [String]) {
            if node.children.isEmpty {
                if let sc = node.shortcut, !sc.isEmpty {
                    out.append(ShortcutEntry(appName: appName,
                                             appBundleID: appBundleID,
                                             path: path,
                                             title: node.title,
                                             shortcut: sc,
                                             enabled: node.enabled,
                                             indexPath: node.indexPath))
                }
                return
            }
            let nextPath = node.title.isEmpty ? path : path + [node.title]
            for child in node.children { walk(child, path: nextPath) }
        }
        for node in nodes { walk(node, path: []) }
        return out
    }
}

// MARK: - Search

public enum Search {
    /// Empty query returns everything, otherwise rank by match quality then title length.
    public static func filter(_ entries: [ShortcutEntry], query: String) -> [ShortcutEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return entries }
        // Ties keep the menu order, so the same query always gives the same list.
        return entries.enumerated()
            .compactMap { index, entry -> (entry: ShortcutEntry, score: Int, index: Int)? in
                guard let score = score(entry: entry, query: q) else { return nil }
                return (entry, score, index)
            }
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                if a.entry.title.count != b.entry.title.count { return a.entry.title.count < b.entry.title.count }
                return a.index < b.index
            }
            .map(\.entry)
    }

    static func score(entry: ShortcutEntry, query: String) -> Int? {
        let title = entry.title.lowercased()
        let path = entry.path.joined(separator: " ").lowercased()
        let display = entry.shortcut.display.lowercased()

        if title == query { return 1000 }
        if title.hasPrefix(query) { return 900 }
        if title.contains(query) { return 800 }
        if entry.shortcut.key.lowercased() == query { return 700 }
        if display.contains(query) { return 600 }
        if path.contains(query) { return 500 }
        if subsequence(query, of: title) { return 400 }
        return nil
    }

    static func subsequence(_ needle: String, of haystack: String) -> Bool {
        var it = haystack.makeIterator()
        for ch in needle {
            var found = false
            while let next = it.next() {
                if next == ch { found = true; break }
            }
            if !found { return false }
        }
        return true
    }
}

// MARK: - Export

public enum MarkdownExporter {
    public static func document(appName: String,
                                bundleID: String?,
                                entries: [ShortcutEntry],
                                includeDisabled: Bool = true,
                                includeHidden: Bool = false) -> String {
        let filtered = entries.filter { entry in
            (includeDisabled || entry.enabled) && (includeHidden || !entry.isHidden)
        }
        var lines: [String] = []
        lines.append("# \(appName) — keyboard shortcuts")
        lines.append("")
        if let bundleID { lines.append("`\(bundleID)`")
            lines.append("") }
        lines.append("_\(filtered.count) shortcuts_")
        lines.append("")

        let groups = Dictionary(grouping: filtered, by: { $0.groupTitle })
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }

        for (group, items) in groups {
            lines.append("## \(group)")
            lines.append("")
            lines.append("| Shortcut | Action | Menu |")
            lines.append("| --- | --- | --- |")
            for item in items.sorted(by: { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) {
                let keys = item.shortcut.display.isEmpty ? "—" : escape(item.shortcut.display)
                let title = escape(item.title)
                let path = escape(item.path.joined(separator: " › "))
                lines.append("| `\(keys)` | \(title) | \(path) |")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|")
    }
}

// MARK: - Persistence

public struct AppState: Codable, Sendable, Equatable {
    public var ignoredApps: [String] = []
    public var hidden: Set<String> = []
    public var bookmarked: Set<String> = []
    public var usage: [String: Int] = [:]
    public var activationInterval: Double = 0.35
    public var showDisabled: Bool = true
    public var showHidden: Bool = false
    public var launchAtLogin: Bool = false

    public init() {}
}

public final class StateStore: @unchecked Sendable {
    public private(set) var state: AppState
    private let url: URL

    public init(url: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("ShortCuts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = url ?? dir.appendingPathComponent("state.json")
        self.state = Self.load(from: self.url)
    }

    public static func load(from url: URL) -> AppState {
        guard let data = try? Data(contentsOf: url) else { return AppState() }
        return (try? JSONDecoder().decode(AppState.self, from: data)) ?? AppState()
    }

    public func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func mutate(_ body: (inout AppState) -> Void) {
        body(&state)
        save()
    }

    public func toggleHidden(_ id: String) {
        if state.hidden.contains(id) { state.hidden.remove(id) } else { state.hidden.insert(id) }
        save()
    }

    public func toggleBookmark(_ id: String) {
        if state.bookmarked.contains(id) { state.bookmarked.remove(id) } else { state.bookmarked.insert(id) }
        save()
    }

    public func recordUse(_ id: String) {
        state.usage[id, default: 0] += 1
        save()
    }

    public func ignoreApp(_ bundleID: String) {
        guard !state.ignoredApps.contains(bundleID) else { return }
        state.ignoredApps.append(bundleID)
        save()
    }

    public func unignoreApp(_ bundleID: String) {
        state.ignoredApps.removeAll { $0 == bundleID }
        save()
    }

    public var fileURL: URL { url }
}
