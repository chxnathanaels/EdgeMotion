import SwiftUI
import Carbon
import ServiceManagement

enum BackgroundStyle: String, CaseIterable, Identifiable {
    case light, dark, solid
    var id: String { rawValue }
    var title: String {
        switch self {
        case .light: return "Light blur"
        case .dark: return "Dark blur"
        case .solid: return "Solid (fastest)"
        }
    }
}

enum HotKeyPreset: String, CaseIterable, Identifiable {
    case optionSpace, controlOptionSpace, f4, f13, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .optionSpace: return "⌥ Space"
        case .controlOptionSpace: return "⌃⌥ Space"
        case .f4: return "F4"
        case .f13: return "F13 (PrtSc on ThinkPad)"
        case .none: return "None"
        }
    }
    var key: (code: UInt32, mods: UInt32)? {
        switch self {
        case .optionSpace: return (49, UInt32(optionKey))
        case .controlOptionSpace: return (49, UInt32(optionKey | controlKey))
        case .f4: return (118, 0)
        case .f13: return (105, 0)
        case .none: return nil
        }
    }
}

enum Defaults {
    static func register() {
        UserDefaults.standard.register(defaults: [
            "columns": 7, "rows": 5, "iconSize": 88.0, "background": BackgroundStyle.light.rawValue,
            "animate": true, "hotkey": HotKeyPreset.optionSpace.rawValue, "dim": 0.15,
        ])
    }
}

struct SettingsView: View {
    @ObservedObject var store: AppStore
    @AppStorage("columns") private var columns = 7
    @AppStorage("rows") private var rows = 5
    @AppStorage("iconSize") private var iconSize = 88.0
    @AppStorage("background") private var background = BackgroundStyle.light.rawValue
    @AppStorage("dim") private var dim = 0.15
    @AppStorage("animate") private var animate = true
    @AppStorage("hotkey") private var hotkey = HotKeyPreset.optionSpace.rawValue
    @State private var loginItem = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Layout") {
                Stepper("Columns: \(columns)", value: $columns, in: 4...10)
                Stepper("Rows: \(rows)", value: $rows, in: 3...8)
                HStack {
                    Text("Icon size")
                    Slider(value: $iconSize, in: 56...128, step: 4)
                    Text("\(Int(iconSize))").monospacedDigit().foregroundStyle(.secondary).frame(width: 32)
                }
                Button("Classic Launchpad (7 × 5)") { columns = 7; rows = 5; iconSize = 88 }
            }
            Section("Look") {
                Picker("Background", selection: $background) {
                    ForEach(BackgroundStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
                HStack {
                    Text("Dimming")
                    Slider(value: $dim, in: 0...0.8, step: 0.05)
                    Text("\(Int(dim * 100))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 40)
                }
                Toggle("Open and close animation", isOn: $animate)
            }
            Section("Opening") {
                Picker("Keyboard shortcut", selection: $hotkey) {
                    ForEach(HotKeyPreset.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Text("Clicking the app's Dock icon also opens it.").font(.caption).foregroundStyle(.secondary)
                Toggle("Open at login", isOn: Binding(get: { loginItem }, set: { on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
                    loginItem = SMAppService.mainApp.status == .enabled
                }))
            }
            Section("Hidden apps") {
                let hidden = store.hidden.sorted()
                if hidden.isEmpty {
                    Text("Right-click an app in the grid to hide it.").foregroundStyle(.secondary)
                }
                ForEach(hidden, id: \.self) { path in
                    HStack {
                        Text((path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""))
                        Spacer()
                        Button("Show") { var h = store.hidden; h.remove(path); store.hidden = h }
                    }
                }
                Button("Rescan apps") { store.refresh() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 560)
    }
}
