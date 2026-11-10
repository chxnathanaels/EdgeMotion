import SwiftUI
import AppKit
import ApplicationServices
import ServiceManagement

final class EdgeModel: ObservableObject {
    private let d = UserDefaults.standard

    @Published var enabled: Bool { didSet { save() } }
    @Published var zone: Double { didSet { save() } }      // % of pad
    @Published var speed: Double { didSet { save() } }     // points per 10 ms
    @Published var dragOnly: Bool { didSet { save() } }
    @Published var threeFinger: Bool { didSet { save() } }

    @Published var trusted = false
    @Published var devices: Int32 = 0
    @Published var launchAtLogin = false

    private var timer: Timer?

    init() {
        d.register(defaults: ["enabled": true, "zone": 8.0, "speed": 8.0,
                              "dragOnly": false, "threeFinger": true])
        enabled = d.bool(forKey: "enabled")
        zone = d.double(forKey: "zone")
        speed = d.double(forKey: "speed")
        dragOnly = d.bool(forKey: "dragOnly")
        threeFinger = d.bool(forKey: "threeFinger")

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(opts)

        devices = edge_start()
        apply()
        launchAtLogin = (SMAppService.mainApp.status == .enabled)

        // Keep the permission status fresh (user grants it in System Settings).
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let t = AXIsProcessTrusted()
            if t != self.trusted { self.trusted = t }
        }
    }

    private func save() {
        d.set(enabled, forKey: "enabled")
        d.set(zone, forKey: "zone")
        d.set(speed, forKey: "speed")
        d.set(dragOnly, forKey: "dragOnly")
        d.set(threeFinger, forKey: "threeFinger")
        apply()
    }

    private func apply() {
        edge_config(enabled ? 1 : 0, Float(zone), Float(speed), dragOnly ? 1 : 0, threeFinger ? 1 : 0)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("EdgeMotion: login item change failed: \(error)")
        }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    func resetDefaults() {
        zone = 8; speed = 8; dragOnly = false; threeFinger = true
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct PanelView: View {
    @ObservedObject var m: EdgeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Edge Motion").font(.headline)
                Spacer()
                Toggle("", isOn: $m.enabled).toggleStyle(.switch).labelsHidden()
            }

            if !m.trusted {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Needs Accessibility permission to move the cursor.")
                        .font(.caption).foregroundColor(.orange)
                    Button("Open Accessibility Settings") { m.openAccessibilitySettings() }
                        .controlSize(.small)
                }
            }
            if m.devices <= 0 {
                Text(m.devices < 0 ? "Couldn't load the multitouch framework." : "No trackpad found.")
                    .font(.caption).foregroundColor(.red)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Edge width")
                    Spacer()
                    Text("\(Int(m.zone))%").monospacedDigit().foregroundColor(.secondary)
                }
                Slider(value: $m.zone, in: 2...25, step: 1)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Speed")
                    Spacer()
                    Text("\(Int(m.speed))").monospacedDigit().foregroundColor(.secondary)
                }
                Slider(value: $m.speed, in: 1...40, step: 1)
            }

            Toggle("Only while dragging", isOn: $m.dragOnly)
            Toggle("Three-finger drag counts as a drag", isOn: $m.threeFinger)

            Divider()

            Toggle("Open at login", isOn: Binding(
                get: { m.launchAtLogin },
                set: { m.setLaunchAtLogin($0) }))

            HStack {
                Button("Defaults") { m.resetDefaults() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 270)
        .disabled(false)
    }
}

@main
struct EdgeMotionApp: App {
    @StateObject private var model = EdgeModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(m: model)
        } label: {
            Image(systemName: model.enabled ? "cursorarrow.motionlines" : "cursorarrow")
        }
        .menuBarExtraStyle(.window)
    }
}
