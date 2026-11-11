import SwiftUI
import AppKit

@main
struct EdgeMotionApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environmentObject(state)
        } label: {
            Image(systemName: state.enabled ? "cursorarrow.motionlines" : "cursorarrow")
        }
        .menuBarExtraStyle(.window)

        Window("EdgeMotion Settings", id: "settings") {
            SettingsView()
                .environmentObject(state)
                .frame(minWidth: 720, minHeight: 520)
        }
        .defaultSize(width: 780, height: 580)
    }
}
