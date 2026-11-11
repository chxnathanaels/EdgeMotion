import AppKit
import CoreGraphics

// MARK: - Synthetic input helpers

enum Synth {
    static var magic: Int64 { Int64(em_magic()) }

    static func keystroke(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: magic)
            e.post(tap: .cghidEventTap)
        }
    }

    static func typeText(_ text: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        for scalar in text.utf16 {
            var ch = scalar
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
                e.keyboardSetUnicodeString(stringLength: 1, unicodeString: &ch)
                e.setIntegerValueField(.eventSourceUserData, value: magic)
                e.post(tap: .cghidEventTap)
            }
        }
    }

    static var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    static func click(button: CGMouseButton) {
        let p = cursor
        let (downT, upT): (CGEventType, CGEventType) = {
            switch button {
            case .left: return (.leftMouseDown, .leftMouseUp)
            case .right: return (.rightMouseDown, .rightMouseUp)
            default: return (.otherMouseDown, .otherMouseUp)
            }
        }()
        for t in [downT, upT] {
            guard let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: button) else { continue }
            e.setIntegerValueField(.eventSourceUserData, value: magic)
            e.post(tap: .cghidEventTap)
        }
    }

    static func run(_ path: String, _ args: [String] = []) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
    }

    static func openApp(_ path: String) {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path),
                                           configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}

// Virtual key codes used below
enum VK {
    static let space: CGKeyCode = 49, d: CGKeyCode = 2, q: CGKeyCode = 12
    static let n3: CGKeyCode = 20, n4: CGKeyCode = 21, n5: CGKeyCode = 23
}

// MARK: - Shared actions

enum CommonAction {
    static func lookUpOrQuickLook() {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" {
            // select the item under the pointer, then Quick Look it
            Synth.click(button: .left)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { Synth.keystroke(VK.space) }
        } else {
            Synth.keystroke(VK.d, flags: [.maskControl, .maskCommand])   // Look Up
        }
    }
    static func missionControl() { Synth.openApp("/System/Applications/Mission Control.app") }
    static func appExpose() { Synth.run("/System/Applications/Mission Control.app/Contents/MacOS/Mission Control", ["2"]) }
    static func showDesktop() { Synth.run("/System/Applications/Mission Control.app/Contents/MacOS/Mission Control", ["1"]) }
    static func spotlight() { Synth.keystroke(VK.space, flags: .maskCommand) }
    static func screenshotToolbar() { Synth.keystroke(VK.n5, flags: [.maskCommand, .maskShift]) }
}

// MARK: - Gesture (tap) actions

enum GestureAction: String, CaseIterable, Identifiable, Codable {
    case none, lookUp, middleClick, missionControl, appExpose, showDesktop, spotlight, screenshot
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Do nothing"
        case .lookUp: return "Quick Look / Look Up"
        case .middleClick: return "Middle click"
        case .missionControl: return "Mission Control"
        case .appExpose: return "App windows"
        case .showDesktop: return "Show Desktop"
        case .spotlight: return "Spotlight"
        case .screenshot: return "Screenshot toolbar"
        }
    }
    var detail: String {
        switch self {
        case .lookUp: return "Like a Force Click: Quick Look in Finder, Look Up elsewhere."
        case .middleClick: return "Opens links in a new tab, closes tabs."
        default: return ""
        }
    }
    func perform() {
        switch self {
        case .none: break
        case .lookUp: CommonAction.lookUpOrQuickLook()
        case .middleClick: Synth.click(button: .center)
        case .missionControl: CommonAction.missionControl()
        case .appExpose: CommonAction.appExpose()
        case .showDesktop: CommonAction.showDesktop()
        case .spotlight: CommonAction.spotlight()
        case .screenshot: CommonAction.screenshotToolbar()
        }
    }
}

// MARK: - Keyboard mapping

enum KeyActionKind: String, CaseIterable, Identifiable, Codable {
    case screenshotArea, screenshotFull, screenshotToolbar, spotlight, siri, missionControl
    case lockScreen, openApp, runShortcut, typeText, keystroke
    var id: String { rawValue }
    var title: String {
        switch self {
        case .screenshotArea: return "Screenshot: selection"
        case .screenshotFull: return "Screenshot: full screen"
        case .screenshotToolbar: return "Screenshot toolbar"
        case .spotlight: return "Spotlight"
        case .siri: return "Siri"
        case .missionControl: return "Mission Control"
        case .lockScreen: return "Lock screen"
        case .openApp: return "Open app…"
        case .runShortcut: return "Run Shortcut…"
        case .typeText: return "Type text (macro)…"
        case .keystroke: return "Send key combination…"
        }
    }
    var needsParam: Bool { [.openApp, .runShortcut, .typeText].contains(self) }
}

struct KeyMapping: Identifiable, Codable, Equatable {
    var id = UUID()
    var enabled = true
    var keyCode: Int = -1                 // -1 = not recorded yet
    var modifiers: UInt64 = 0             // CGEventFlags, masked to ⌃⌥⇧⌘
    var action: KeyActionKind = .screenshotArea
    var param: String = ""                // app path / shortcut name / text
    var targetKeyCode: Int = -1           // for .keystroke
    var targetModifiers: UInt64 = 0

    static let modMask: UInt64 = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue |
                                 CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskControl.rawValue

    func perform() {
        switch action {
        case .screenshotArea: Synth.keystroke(VK.n4, flags: [.maskCommand, .maskShift])
        case .screenshotFull: Synth.keystroke(VK.n3, flags: [.maskCommand, .maskShift])
        case .screenshotToolbar: CommonAction.screenshotToolbar()
        case .spotlight: CommonAction.spotlight()
        case .siri: Synth.openApp("/System/Applications/Siri.app")
        case .missionControl: CommonAction.missionControl()
        case .lockScreen: Synth.keystroke(VK.q, flags: [.maskControl, .maskCommand])
        case .openApp: if !param.isEmpty { Synth.openApp(param) }
        case .runShortcut: if !param.isEmpty { Synth.run("/usr/bin/shortcuts", ["run", param]) }
        case .typeText: if !param.isEmpty { Synth.typeText(param) }
        case .keystroke:
            if targetKeyCode >= 0 { Synth.keystroke(CGKeyCode(targetKeyCode), flags: CGEventFlags(rawValue: targetModifiers)) }
        }
    }
}

enum KeyNames {
    static func modifiers(_ raw: UInt64) -> String {
        let f = CGEventFlags(rawValue: raw)
        var s = ""
        if f.contains(.maskControl) { s += "⌃" }
        if f.contains(.maskAlternate) { s += "⌥" }
        if f.contains(.maskShift) { s += "⇧" }
        if f.contains(.maskCommand) { s += "⌘" }
        return s
    }
    static func combo(_ code: Int, _ mods: UInt64) -> String {
        code < 0 ? "Record…" : modifiers(mods) + name(code)
    }
    static func name(_ code: Int) -> String {
        let table: [Int: String] = [
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13 (PrtSc)", 107: "F14", 113: "F15",
            106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc", 117: "Fwd Delete",
            115: "Home", 119: "End", 116: "Page Up", 121: "Page Down", 114: "Help/Insert",
            123: "←", 124: "→", 125: "↓", 126: "↑", 110: "Menu",
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K",
            37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U",
            9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
            29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        ]
        return table[code] ?? "Key \(code)"
    }
}
