import AppKit
import SwiftUI
import ShortCutsCore

// MARK: - Model

@MainActor
final class PanelModel: ObservableObject {
    @Published var appName: String = ""
    @Published var appIcon: NSImage?
    @Published private(set) var rows: [PanelRow] = []
    @Published var selectedID: String?
    /// The row that the list must scroll to. Set by keyboard moves only.
    @Published var scrollTarget: String?
    @Published var query: String = "" {
        didSet { if query != oldValue { rebuild() } }
    }

    private(set) var entries: [ShortcutEntry] = []

    /// Meaning-based search for this panel. The model opens on the first query only.
    private var semantic: SemanticIndex?

    /// The pointer position at the last keyboard move or list change.
    /// Hover selects a row only after the pointer leaves this position, so a resting pointer
    /// or a scroll under the pointer never changes the selection.
    private var pointerAnchor: NSPoint?

    var totalCount: Int { entries.count }
    var hasMatches: Bool { rows.contains { $0.entry != nil } }

    var selectedRow: PanelRow? {
        guard let selectedID else { return nil }
        return rows.first { $0.id == selectedID }
    }

    func load(appName: String, icon: NSImage?, entries: [ShortcutEntry]) {
        self.appName = appName
        self.appIcon = icon
        self.entries = entries
        self.semantic = SemanticIndex(entries: entries, model: { SemanticModel.shared })
        if query.isEmpty { rebuild() } else { query = "" }
    }

    func rebuild() {
        let layout = PanelLayout.build(entries: entries, query: query, semantic: semantic)
        rows = layout.rows
        selectedID = layout.defaultSelection
        scrollTarget = PanelRow.showAllID
        pointerAnchor = NSEvent.mouseLocation
    }

    func moveSelection(by delta: Int) {
        select(SelectionNavigator.move(from: selectedID, by: delta, in: rows))
    }

    func selectFirst() { select(SelectionNavigator.first(in: rows)) }
    func selectLast() { select(SelectionNavigator.last(in: rows)) }

    private func select(_ id: String?) {
        selectedID = id
        scrollTarget = id
        pointerAnchor = NSEvent.mouseLocation
    }

    /// Called for every pointer move over a row.
    func hover(_ id: String) {
        let location = NSEvent.mouseLocation
        if let anchor = pointerAnchor, anchor == location { return }
        pointerAnchor = nil
        if selectedID != id { selectedID = id }
    }
}

// MARK: - Search field with keyboard commands

enum SearchCommand {
    case up, down, pageUp, pageDown, top, bottom
    case submit(option: Bool)
    case cancel
}

/// An AppKit text field. SwiftUI's TextField on macOS 13 cannot catch the arrow keys,
/// so this field sends them to the panel through its delegate.
struct KeyboardSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onCommand: (SearchCommand) -> Void
    var registerFocus: (@escaping () -> Void) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 19)
        field.isEditable = true
        field.isSelectable = true
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        registerFocus { [weak field] in
            guard let field, let window = field.window else { return }
            window.makeFirstResponder(field)
            let end = (field.stringValue as NSString).length
            field.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: KeyboardSearchField

        init(parent: KeyboardSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let command: SearchCommand
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                command = .up
            case #selector(NSResponder.moveDown(_:)):
                command = .down
            case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)):
                command = .pageUp
            case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)):
                command = .pageDown
            case #selector(NSResponder.scrollToBeginningOfDocument(_:)):
                command = .top
            case #selector(NSResponder.scrollToEndOfDocument(_:)):
                command = .bottom
            case #selector(NSResponder.insertNewline(_:)):
                command = .submit(option: NSApp.currentEvent?.modifierFlags.contains(.option) ?? false)
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                command = .submit(option: true)
            case #selector(NSResponder.cancelOperation(_:)):
                command = .cancel
            default:
                return false
            }
            parent.onCommand(command)
            return true
        }
    }
}

// MARK: - Window

/// Borderless floating panel that can take keyboard focus.
final class ShortcutPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

// MARK: - Controller

@MainActor
final class PanelController {
    private let panel: ShortcutPanel
    private let model = PanelModel()
    private let store: StateStore
    private var focusSearch: (() -> Void)?

    /// The app whose menus the panel shows. Focus goes back to it when the panel closes.
    private(set) var targetApp: NSRunningApplication?

    /// Called when the user picks "Show all shortcuts".
    var onShowAll: ((_ app: NSRunningApplication, _ name: String, _ icon: NSImage?, _ entries: [ShortcutEntry]) -> Void)?

    static let size = NSSize(width: 640, height: 480)

    init(store: StateStore) {
        self.store = store

        panel = ShortcutPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = true

        let root = PanelView(
            model: model,
            onCommand: { [weak self] command in self?.handle(command) },
            onActivate: { [weak self] row, option in self?.activate(row, option: option) },
            registerFocus: { [weak self] focus in self?.focusSearch = focus }
        )
        panel.contentView = NSHostingView(rootView: root)
        panel.onCancel = { [weak self] in self?.close(restoreFocus: true) }
    }

    // MARK: Show and close

    func show() {
        guard let app = resolveTarget() else { return }
        targetApp = app
        let name = app.localizedName ?? "Application"
        model.load(appName: name, icon: app.icon, entries: entries(for: app, name: name))

        position()
        // Without this request the panel loses keyboard focus at once and closes.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        focusSearch?()
    }

    /// Opens the overview for the front app without the panel (status menu).
    func showAllForFrontmost() {
        guard let app = resolveTarget() else { return }
        targetApp = app
        let name = app.localizedName ?? "Application"
        onShowAll?(app, name, app.icon, entries(for: app, name: name))
    }

    func close(restoreFocus: Bool) {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        if restoreFocus, let app = targetApp {
            CommandRunner.returnFocus(to: app)
        }
    }

    /// The front app, or the last target when ShortCuts itself is in front.
    private func resolveTarget() -> NSRunningApplication? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        if front.processIdentifier == NSRunningApplication.current.processIdentifier {
            if let last = targetApp, !last.isTerminated { return last }
            return nil
        }
        return front
    }

    private func entries(for app: NSRunningApplication, name: String) -> [ShortcutEntry] {
        let tree = AXReader.menuTree(for: app)
        return MenuFlattener.flatten(nodes: tree, appName: name, appBundleID: app.bundleIdentifier)
    }

    // MARK: Commands

    private func handle(_ command: SearchCommand) {
        switch command {
        case .up: model.moveSelection(by: -1)
        case .down: model.moveSelection(by: 1)
        case .pageUp: model.moveSelection(by: -SelectionNavigator.pageSize)
        case .pageDown: model.moveSelection(by: SelectionNavigator.pageSize)
        case .top: model.selectFirst()
        case .bottom: model.selectLast()
        case .submit(let option):
            if let row = model.selectedRow { activate(row, option: option) }
        case .cancel:
            close(restoreFocus: true)
        }
    }

    private func activate(_ row: PanelRow, option: Bool) {
        switch row {
        case .showAll:
            showAll()
        case .header:
            break
        case .item(let entry):
            if option { copy(entry) } else { run(entry) }
        }
    }

    private func run(_ entry: ShortcutEntry) {
        guard entry.enabled else {
            NSSound.beep()
            return
        }
        guard let app = targetApp else { return }
        store.recordUse(entry.id)
        panel.orderOut(nil)
        CommandRunner.run(entry, in: app)
    }

    private func copy(_ entry: ShortcutEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.shortcut.display, forType: .string)
        store.recordUse(entry.id)
        close(restoreFocus: true)
    }

    private func showAll() {
        guard let app = targetApp else { return }
        panel.orderOut(nil)
        onShowAll?(app, model.appName, model.appIcon, model.entries)
    }

    private func position() {
        guard let screen = CommandRunner.screenUnderPointer() else { return }
        let visible = screen.visibleFrame
        let size = Self.size
        let x = visible.midX - size.width / 2
        let y = visible.midY - size.height / 2 + visible.height * 0.12
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}

// MARK: - SwiftUI content

struct PanelView: View {
    @ObservedObject var model: PanelModel
    var onCommand: (SearchCommand) -> Void
    var onActivate: (PanelRow, Bool) -> Void
    var registerFocus: (@escaping () -> Void) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: PanelController.size.width, height: PanelController.size.height)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let icon = model.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(model.appName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                KeyboardSearchField(text: $model.query,
                                    placeholder: "Search shortcuts",
                                    onCommand: onCommand,
                                    registerFocus: registerFocus)
                    .frame(height: 24)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rows) { row in
                        rowView(row).id(row.id)
                    }
                    if !model.hasMatches {
                        emptyState
                    }
                }
                .padding(.vertical, 6)
            }
            .onReceive(model.$scrollTarget) { target in
                guard let target else { return }
                proxy.scrollTo(target)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: PanelRow) -> some View {
        let selected = row.id == model.selectedID
        switch row {
        case .showAll:
            ShowAllRow(count: model.totalCount, selected: selected)
                .contentShape(Rectangle())
                .onContinuousHover { phase in if case .active = phase { model.hover(row.id) } }
                .onTapGesture { onActivate(row, false) }
        case .header(let title):
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 4)
        case .item(let entry):
            ShortcutRow(entry: entry, selected: selected, showPath: !model.query.isEmpty)
                .contentShape(Rectangle())
                .onContinuousHover { phase in if case .active = phase { model.hover(row.id) } }
                .onTapGesture {
                    onActivate(row, NSEvent.modifierFlags.contains(.option))
                }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(model.totalCount == 0 ? "No shortcuts found" : "No matches")
                .font(.system(size: 13, weight: .medium))
            Text(model.totalCount == 0
                 ? "Grant Accessibility access, then try again."
                 : "Try a different search.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            KeyHint(keys: "↑↓", label: "select")
            KeyHint(keys: "↩", label: "run")
            KeyHint(keys: "⌥↩", label: "copy")
            KeyHint(keys: "esc", label: "close")
            Spacer()
            Text("\(model.totalCount) shortcuts")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - Rows

struct ShowAllRow: View {
    var count: Int
    var selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.3x2")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 18)
            Text("Show all shortcuts")
                .font(.system(size: 13, weight: .medium))
            Spacer(minLength: 12)
            Text("\(count)")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .opacity(0.7)
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RowHighlight(selected: selected))
        .padding(.horizontal, 6)
    }
}

struct ShortcutRow: View {
    var entry: ShortcutEntry
    var selected: Bool
    var showPath: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                if showPath, !entry.path.isEmpty {
                    Text(entry.path.joined(separator: " › "))
                        .font(.system(size: 10))
                        .opacity(0.6)
                } else if entry.path.count > 1 {
                    Text(entry.path.dropFirst().joined(separator: " › "))
                        .font(.system(size: 10))
                        .opacity(0.6)
                }
            }
            Spacer(minLength: 12)
            Text(entry.shortcut.display)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(selected ? 0 : 0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .foregroundStyle(selected ? Color.white : (entry.enabled ? Color.primary : Color.secondary))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RowHighlight(selected: selected))
        .padding(.horizontal, 6)
    }
}

struct RowHighlight: View {
    var selected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(selected ? Color.accentColor : Color.clear)
    }
}

struct KeyHint: View {
    var keys: String
    var label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(label)
                .font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
    }
}
