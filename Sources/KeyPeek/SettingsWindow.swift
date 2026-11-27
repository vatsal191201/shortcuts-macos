import AppKit
import ServiceManagement
import SwiftUI
import KeyPeekCore

@MainActor
final class SettingsModel: ObservableObject {
    @Published var state: AppState
    private let store: StateStore

    init(store: StateStore) {
        self.store = store
        self.state = store.state
    }

    /// Takes the newest state, for example use counts that the panel wrote while Settings was closed.
    func reload() {
        state = store.state
    }

    /// Writes only the field that changed. A full copy would erase changes that the panel made
    /// after Settings opened, such as use counts.
    func save<T>(_ keyPath: WritableKeyPath<AppState, T>) {
        let value = state[keyPath: keyPath]
        store.mutate { $0[keyPath: keyPath] = value }
    }

    func unignore(_ bundleID: String) {
        state.ignoredApps.removeAll { $0 == bundleID }
        save(\.ignoredApps)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        state.launchAtLogin = enabled
        save(\.launchAtLogin)
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            state.launchAtLogin = !enabled
            save(\.launchAtLogin)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Activation") {
                HStack {
                    Text("Double-press window")
                    Spacer()
                    Text("\(Int(model.state.activationInterval * 1000)) ms")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: binding(\.activationInterval), in: 0.2...0.8, step: 0.05)
                Text("Press Command twice within this window to open the panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Display") {
                Toggle("Show disabled menu items", isOn: binding(\.showDisabled))
                Toggle("Show hidden shortcuts", isOn: binding(\.showHidden))
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.state.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
            }

            Section("Permissions") {
                HStack {
                    Circle()
                        .fill(AXReader.isTrusted() ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(AXReader.isTrusted() ? "Accessibility granted" : "Accessibility required")
                    Spacer()
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }

            Section("Ignored apps") {
                if model.state.ignoredApps.isEmpty {
                    Text("None")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.state.ignoredApps, id: \.self) { bundleID in
                        HStack {
                            Text(bundleID)
                            Spacer()
                            Button("Remove") { model.unignore(bundleID) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<AppState, T>) -> Binding<T> {
        Binding(
            get: { model.state[keyPath: keyPath] },
            set: { newValue in
                model.state[keyPath: keyPath] = newValue
                model.save(keyPath)
            }
        )
    }
}
