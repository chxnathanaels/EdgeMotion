import SwiftUI
import AppKit

struct MenuPanel: View {
    @EnvironmentObject var s: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("EdgeMotion").font(.headline)
                Spacer()
                Toggle("", isOn: $s.enabled).toggleStyle(.switch).labelsHidden()
            }

            if !s.trusted {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Needs Accessibility permission.").font(.caption).foregroundColor(.orange)
                    Button("Open Accessibility Settings") { s.openAccessibilitySettings() }.controlSize(.small)
                }
            }
            if s.devices <= 0 {
                Text(s.devices < 0 ? "Couldn't load the multitouch framework." : "No trackpad found.")
                    .font(.caption).foregroundColor(.red)
            }

            Divider()

            ValueSlider(title: "Pointer speed", value: $s.speed, range: 0.25...3, step: 0.05, format: "%.2f×")
                .disabled(!s.pointerTakeover)
            Toggle("EdgeMotion moves the pointer", isOn: $s.pointerTakeover)
            Toggle("Edge motion", isOn: $s.edgeEnabled)
            Toggle("Smooth brightness keys", isOn: $s.smoothBrightness)
                .disabled(!s.brightnessAvailable)

            Divider()

            HStack {
                Button("Settings…") {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 280)
    }
}

/// Slider with a title and a live value, used everywhere.
struct ValueSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var format: String
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
            if let help { Text(help).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
