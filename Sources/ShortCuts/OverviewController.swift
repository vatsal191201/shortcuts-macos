import AppKit
import SwiftUI
import ShortCutsCore

/// One menu and its shortcuts in the overview.
struct ShortcutGroup: Identifiable {
    let title: String
    let items: [ShortcutEntry]
    var id: String { title }
}

@MainActor
final class OverviewModel: ObservableObject {
    @Published var appName: String = ""
    @Published var appIcon: NSImage?
    @Published var columns: [[ShortcutGroup]] = []
    @Published var count: Int = 0
    @Published var hoveredID: String?
}

/// Borderless sheet that takes keyboard focus and closes on Esc or ⌘W.
final class OverviewPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 || (event.keyCode == 13 && flags == .command) {   // Esc, ⌘W
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }
}

/// The "Show all shortcuts" sheet: every menu of the app in balanced columns.
@MainActor
final class OverviewController {
    private let panel: OverviewPanel
    private let model = OverviewModel()
    private let store: StateStore
    private var targetApp: NSRunningApplication?

    /// The full width of one column: content, 2 x 12 pt padding and a 1 pt divider.
    static let columnWidth: CGFloat = 320
    static let columnContentWidth: CGFloat = columnWidth - 25

    init(store: StateStore) {
        self.store = store
        panel = OverviewPanel(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = true

        let root = OverviewView(
            model: model,
            onActivate: { [weak self] entry, option in self?.activate(entry, option: option) },
            onClose: { [weak self] in self?.close(restoreFocus: true) }
        )
        panel.contentView = NSHostingView(rootView: root)
        panel.onCancel = { [weak self] in self?.close(restoreFocus: true) }
    }

    // Layout constants for the size estimate, in points.
    private static let rowHeight: CGFloat = 20
    private static let groupChrome: CGFloat = 46     // title, divider and spacing of one group
    private static let windowChrome: CGFloat = 96    // header, divider and outer padding
    private static let sidePadding: CGFloat = 40

    func show(app: NSRunningApplication, name: String, icon: NSImage?, entries: [ShortcutEntry]) {
        targetApp = app
        guard let screen = CommandRunner.screenUnderPointer() else { return }
        let visible = screen.visibleFrame
        let maxWidth = min(visible.width * 0.92, 1560)
        let maxHeight = visible.height * 0.86

        let groups = PanelLayout.orderedGroups(entries).map { ShortcutGroup(title: $0.title, items: $0.items) }
        let columnCount = max(1, Int((maxWidth - Self.sidePadding) / Self.columnWidth))
        let heights = groups.map { $0.items.count + 2 }   // two lines for the group title
        let split = ColumnBalancer.balance(heights: heights, columns: columnCount)
        let columns = split.map { indices in indices.map { groups[$0] } }

        model.appName = name
        model.appIcon = icon
        model.count = entries.count
        model.hoveredID = nil
        model.columns = columns

        // Fit the sheet to its content, like a printed cheat sheet, within the screen limits.
        let usedColumns = CGFloat(max(columns.count, 1))
        let width = min(maxWidth, max(640, usedColumns * Self.columnWidth + Self.sidePadding))
        let tallest = columns.map { column in
            column.reduce(CGFloat(0)) { $0 + Self.groupChrome + CGFloat($1.items.count) * Self.rowHeight }
        }.max() ?? 120
        let height = min(maxHeight, max(320, tallest + Self.windowChrome))

        let frame = NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)
        panel.setFrame(frame, display: true)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close(restoreFocus: Bool) {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        if restoreFocus, let app = targetApp {
            CommandRunner.returnFocus(to: app)
        }
    }

    private func activate(_ entry: ShortcutEntry, option: Bool) {
        if option {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(entry.shortcut.display, forType: .string)
            store.recordUse(entry.id)
            close(restoreFocus: true)
            return
        }
        guard entry.enabled, let app = targetApp else {
            NSSound.beep()
            return
        }
        store.recordUse(entry.id)
        panel.orderOut(nil)
        CommandRunner.run(entry, in: app)
    }
}

// MARK: - SwiftUI content

struct OverviewView: View {
    @ObservedObject var model: OverviewModel
    var onActivate: (ShortcutEntry, Bool) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.count == 0 {
                Text("No shortcuts found. Grant Accessibility access, then try again.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(model.columns.enumerated()), id: \.offset) { index, column in
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(column) { group in
                                    groupView(group)
                                }
                            }
                            .frame(width: OverviewController.columnContentWidth, alignment: .topLeading)
                            .padding(.horizontal, 12)
                            if index < model.columns.count - 1 {
                                Divider()
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 16)
                    .padding(.horizontal, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let icon = model.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 32, height: 32)
            }
            Text(model.appName)
                .font(.system(size: 20, weight: .semibold))
            Text("\(model.count) shortcuts")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
            KeyHint(keys: "click", label: "run")
            KeyHint(keys: "⌥ click", label: "copy")
            KeyHint(keys: "esc", label: "close")
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func groupView(_ group: ShortcutGroup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(group.title)
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 6)
            Divider()
                .padding(.bottom, 4)
            ForEach(group.items) { entry in
                OverviewRow(entry: entry, hovered: model.hoveredID == entry.id)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { model.hoveredID = entry.id } else if model.hoveredID == entry.id { model.hoveredID = nil }
                    }
                    .onTapGesture {
                        onActivate(entry, NSEvent.modifierFlags.contains(.option))
                    }
            }
        }
    }
}

struct OverviewRow: View {
    var entry: ShortcutEntry
    var hovered: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.shortcut.modifiers.glyphs)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            Text(entry.shortcut.key)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .frame(width: 34, alignment: .leading)
                .lineLimit(1)
            Text(entry.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(hovered ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .opacity(entry.enabled ? 1 : 0.45)
        .help(entry.path.joined(separator: " › "))
    }
}
