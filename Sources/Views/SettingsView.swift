import SwiftUI
import AppKit

enum Pane: String, CaseIterable, Identifiable {
    case pointer, dragging, edge, gestures, brightness, keyboard, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pointer: return "Pointer"
        case .dragging: return "Dragging"
        case .edge: return "Edge Motion"
        case .gestures: return "Gestures"
        case .brightness: return "Brightness"
        case .keyboard: return "Keyboard"
        case .about: return "About"
        }
    }
    var icon: String {
        switch self {
        case .pointer: return "cursorarrow.rays"
        case .dragging: return "hand.draw"
        case .edge: return "arrow.right.to.line"
        case .gestures: return "hand.tap"
        case .brightness: return "sun.max"
        case .keyboard: return "keyboard"
        case .about: return "info.circle"
        }
    }
    var tint: Color {
        switch self {
        case .pointer: return .blue
        case .dragging: return .purple
        case .edge: return .teal
        case .gestures: return .pink
        case .brightness: return .orange
        case .keyboard: return .gray
        case .about: return .secondary
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var s: AppState
    @State private var pane: Pane? = .pointer

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { p in
                Label {
                    Text(p.title)
                } icon: {
                    Image(systemName: p.icon)
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(p.tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .tag(p)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200)
        } detail: {
            Group {
                switch pane ?? .pointer {
                case .pointer: PointerPane()
                case .dragging: DraggingPane()
                case .edge: EdgePane()
                case .gestures: GesturesPane()
                case .brightness: BrightnessPane()
                case .keyboard: KeyboardPane()
                case .about: AboutPane()
                }
            }
            .navigationTitle((pane ?? .pointer).title)
        }
    }
}

// MARK: - Pointer

struct PointerPane: View {
    @EnvironmentObject var s: AppState
    var body: some View {
        Form {
            Section {
                CurveGraph(config: s.engineConfig)
                    .frame(height: 190)
                    .padding(.vertical, 6)
            } footer: {
                Text("Slow finger movements are scaled down for precision (green), medium speeds move 1:1, and fast flicks accelerate (orange). The default curve is libinput's, the touchpad driver used on Linux.")
            }

            Section {
                Toggle("EdgeMotion moves the pointer", isOn: $s.pointerTakeover)
            } footer: {
                Text("Replaces macOS's own trackpad tracking with the curve below. Needed for the two-finger drag fix. macOS's Tracking speed setting no longer applies while this is on.")
            }

            Section("Curve") {
                Picker("Preset", selection: Binding(get: { s.preset }, set: { s.apply(preset: $0) })) {
                    ForEach(CurvePreset.allCases) { p in Text(p.title).tag(p) }
                }
                ValueSlider(title: "Speed", value: $s.speed, range: 0.25...3, step: 0.05, format: "%.2f×",
                            help: "Overall pointer speed.")
                ValueSlider(title: "Precision", value: $s.precFloor, range: 0.1...0.9, step: 0.05, format: "%.2f×",
                            help: "How much very slow movements are scaled down. Lower = finer micro movements.")
                ValueSlider(title: "Precision below", value: $s.precZone, range: 0...20, step: 0.5, format: "%.1f mm/s",
                            help: "Finger speeds under this get the precision treatment.")
                ValueSlider(title: "Acceleration starts at", value: $s.threshold, range: 30...300, step: 5, format: "%.0f mm/s")
                ValueSlider(title: "Acceleration strength", value: $s.incline, range: 0...0.012, step: 0.0005, format: "%.4f")
                ValueSlider(title: "Acceleration limit", value: $s.capMul, range: 1...6, step: 0.25, format: "%.2f× start",
                            help: "Above this speed the pointer stops accelerating further.")
            }
            .disabled(!s.pointerTakeover)

            Section {
                Button("Restore Defaults") { s.resetPointerDefaults() }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Dragging

struct DraggingPane: View {
    @EnvironmentObject var s: AppState
    var body: some View {
        Form {
            Section {
                DragIllustration().frame(height: 150).padding(.vertical, 6)
            }
            Section {
                Toggle("Click with one finger, drag with another", isOn: $s.dragOtherFinger)
                    .disabled(!s.pointerTakeover)
            } footer: {
                Text("Press and hold the click with one finger, then move a second finger: the pointer follows the moving finger, not the one holding the click. Works whichever finger touches first. Needs \"EdgeMotion moves the pointer\" (Pointer).")
            }
            Section("Also useful") {
                LabeledContent("Three-finger drag") {
                    Button("Open Pointer Control…") {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?Mouse") {
                            NSWorkspace.shared.open(u)
                        }
                    }
                }
                Text("Accessibility › Pointer Control › Trackpad Options › Dragging style. Edge motion works with three-finger drag too.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Edge motion

struct EdgePane: View {
    @EnvironmentObject var s: AppState
    var body: some View {
        Form {
            Section {
                EdgeIllustration(zonePct: s.edgeZone).frame(height: 160).padding(.vertical, 8)
            }
            Section {
                Toggle("Edge motion", isOn: $s.edgeEnabled)
                ValueSlider(title: "Edge width", value: $s.edgeZone, range: 2...25, step: 1, format: "%.0f%%")
                ValueSlider(title: "Speed", value: $s.edgeSpeed, range: 1...40, step: 1, format: "%.0f",
                            help: "Starts gently and ramps up; deeper in the band moves faster.")
                Toggle("Only while dragging", isOn: $s.edgeDragOnly)
                Toggle("Three-finger drag counts as a drag", isOn: $s.edgeThree)
            }
            .disabled(!s.enabled)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Gestures

struct GesturesPane: View {
    @EnvironmentObject var s: AppState
    var body: some View {
        Form {
            Section {
                TapIllustration(fingers: 3, active: s.tap3Action != .none).frame(height: 110).padding(.vertical, 6)
                Picker("Tap with three fingers", selection: $s.tap3Action) {
                    ForEach(GestureAction.allCases) { a in Text(a.title).tag(a) }
                }
                if !s.tap3Action.detail.isEmpty { Text(s.tap3Action.detail).font(.caption).foregroundStyle(.secondary) }
            } footer: {
                Text("If you use this, turn off macOS's own \"Look up & data detectors: Tap with three fingers\" in Trackpad settings so they don't both fire.")
            }
            Section {
                TapIllustration(fingers: 4, active: s.tap4Action != .none).frame(height: 110).padding(.vertical, 6)
                Picker("Tap with four fingers", selection: $s.tap4Action) {
                    ForEach(GestureAction.allCases) { a in Text(a.title).tag(a) }
                }
                if !s.tap4Action.detail.isEmpty { Text(s.tap4Action.detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Brightness

struct BrightnessPane: View {
    @EnvironmentObject var s: AppState
    var body: some View {
        Form {
            Section {
                BrightnessIllustration().frame(height: 100).padding(.vertical, 8)
            } footer: {
                Text("Fades the backlight between brightness steps instead of jumping, like a real Mac.")
            }
            if !s.brightnessAvailable {
                Section {
                    Label("Brightness control isn't available for this display.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                Toggle("Smooth brightness keys", isOn: $s.smoothBrightness)
                ValueSlider(title: "Fade duration", value: $s.brightnessDuration, range: 80...600, step: 10, format: "%.0f ms")
                Toggle("Finer steps (32 instead of 16)", isOn: $s.brightnessFine)
                Toggle("Show brightness indicator", isOn: $s.brightnessHUD)
                HStack {
                    Text("Try it")
                    Spacer()
                    Button { s.brightness.step(up: false) } label: { Image(systemName: "sun.min") }
                    Button { s.brightness.step(up: true) } label: { Image(systemName: "sun.max") }
                }
            }
            .disabled(!s.brightnessAvailable)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Keyboard

struct KeyboardPane: View {
    @EnvironmentObject var s: AppState
    var body: some View {
        Form {
            Section {
                if s.mappings.isEmpty {
                    Text("No mappings yet. Add one, then press the key you want to remap, for example PrtSc (arrives as F13 on ThinkPads).")
                        .foregroundStyle(.secondary)
                }
                ForEach($s.mappings) { $m in
                    MappingRow(m: $m)
                }
                Button { s.addMapping() } label: { Label("Add Mapping", systemImage: "plus") }
            } header: {
                Text("Key mappings")
            } footer: {
                Text("Mapped keys are swallowed and replaced by the action. Mappings are off while EdgeMotion is disabled.")
            }
        }
        .formStyle(.grouped)
    }
}

struct MappingRow: View {
    @EnvironmentObject var s: AppState
    @Binding var m: KeyMapping

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle("", isOn: $m.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                recordButton(target: false, code: m.keyCode, mods: m.modifiers)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Picker("", selection: $m.action) {
                    ForEach(KeyActionKind.allCases) { a in Text(a.title).tag(a) }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                Spacer()
                Button(role: .destructive) { s.remove(m.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            switch m.action {
            case .openApp:
                HStack {
                    Text(m.param.isEmpty ? "No app chosen" : (m.param as NSString).lastPathComponent)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") { chooseApp() }
                }
            case .runShortcut:
                TextField("Shortcut name", text: $m.param)
            case .typeText:
                TextField("Text to type", text: $m.param)
            case .keystroke:
                HStack {
                    Text("Sends")
                    recordButton(target: true, code: m.targetKeyCode, mods: m.targetModifiers)
                }
            default:
                EmptyView()
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func recordButton(target: Bool, code: Int, mods: UInt64) -> some View {
        let isRec = s.recording == m.id && s.recordingTarget == target
        Button {
            if isRec { s.cancelRecording() } else { s.startRecording(m.id, target: target) }
        } label: {
            Text(isRec ? "Press a key…" : KeyNames.combo(code, mods))
                .monospaced()
                .frame(minWidth: 110)
        }
        .buttonStyle(.bordered)
        .tint(isRec ? .accentColor : nil)
    }

    private func chooseApp() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        if p.runModal() == .OK, let u = p.url { m.param = u.path }
    }
}

// MARK: - About

struct AboutPane: View {
    @EnvironmentObject var s: AppState
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–" }
    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "cursorarrow.motionlines")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(Color.blue.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("EdgeMotion").font(.title2.weight(.semibold))
                        Text("Version \(version)").foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Status") {
                LabeledContent("Accessibility", value: s.trusted ? "Allowed" : "Not allowed")
                LabeledContent("Trackpads found", value: "\(max(0, s.devices))")
                LabeledContent("Trackpad size", value: padSize)
                LabeledContent("Brightness control", value: s.brightnessAvailable ? "Available" : "Not available")
                Toggle("Open at login", isOn: Binding(get: { s.launchAtLogin }, set: { s.setLaunchAtLogin($0) }))
            }
            Section {
                Link("Project on GitHub", destination: URL(string: "https://github.com/chxnathanaels/EdgeMotion")!)
                if !s.trusted { Button("Open Accessibility Settings") { s.openAccessibilitySettings() } }
            }
        }
        .formStyle(.grouped)
    }
    var padSize: String {
        var w: Float = 0, h: Float = 0
        em_pad_size(&w, &h)
        return String(format: "%.0f × %.0f mm", w, h)
    }
}
