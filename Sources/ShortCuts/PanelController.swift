import AppKit
import SwiftUI
import ShortCutsCore

@MainActor
final class PanelModel: ObservableObject {
    @Published var query: String = ""
    @Published var entries: [ShortcutEntry] = []
    @Published var appName: String = ""
}

/// Borderless floating panel that can take keyboard focus.
final class ShortcutPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

@MainActor
final class PanelController {
    private let panel: ShortcutPanel
    private let model = PanelModel()
    private let store: StateStore

    init(store: StateStore) {
        self.store = store

        panel = ShortcutPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
                              styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = true

        let root = PanelView(model: model) { [weak self] entry in
            self?.copy(entry)
        }
        panel.contentView = NSHostingView(rootView: root)
        panel.onCancel = { [weak self] in self?.close() }
    }

    func show() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return }

        let tree = AXReader.menuTree(for: app)
        let name = app.localizedName ?? "Application"
        let entries = MenuFlattener.flatten(nodes: tree,
                                            appName: name,
                                            appBundleID: app.bundleIdentifier)

        model.appName = name
        model.query = ""
        model.entries = entries

        position()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel.orderOut(nil)
    }

    private func copy(_ entry: ShortcutEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.shortcut.display, forType: .string)
        store.recordUse(entry.id)
        close()
    }

    private func position() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let width = panel.frame.width
        let height = panel.frame.height
        let x = visible.midX - width / 2
        let y = visible.midY - height / 2 + visible.height * 0.12
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}

// MARK: - SwiftUI content

struct PanelView: View {
    @ObservedObject var model: PanelModel
    var onSelect: (ShortcutEntry) -> Void

    @FocusState private var searchFocused: Bool

    private var filtered: [ShortcutEntry] {
        Search.filter(model.entries, query: model.query)
    }

    private var sections: [(String, [ShortcutEntry])] {
        let grouped = Dictionary(grouping: filtered, by: { $0.groupTitle })
        return grouped.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 620, height: 460)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .onAppear { searchFocused = true }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.appName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            TextField("Search shortcuts", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .focused($searchFocused)
                .onSubmit {
                    if let first = filtered.first { onSelect(first) }
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if filtered.isEmpty {
            VStack(spacing: 6) {
                Text(model.entries.isEmpty ? "No shortcuts found" : "No matches")
                    .font(.system(size: 13, weight: .medium))
                Text(model.entries.isEmpty
                     ? "Grant Accessibility access, then try again."
                     : "Try a different search.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections, id: \.0) { section in
                        Text(section.0)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .padding(.horizontal, 16)
                            .padding(.top, 10)
                            .padding(.bottom, 4)
                        ForEach(section.1) { entry in
                            row(entry)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }

    private func row(_ entry: ShortcutEntry) -> some View {
        Button(action: { onSelect(entry) }) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(entry.enabled ? Color.primary : Color.secondary)
                    if entry.path.count > 1 {
                        Text(entry.path.dropFirst().joined(separator: " › "))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 12)
                Text(entry.shortcut.display)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
