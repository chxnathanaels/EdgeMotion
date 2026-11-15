import AppKit
import Carbon

/// Global shortcut through Carbon's hot key API (no Accessibility permission needed).
final class HotKey {
    static var action: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func register(_ preset: HotKeyPreset) {
        unregister()
        guard let k = preset.key else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
                DispatchQueue.main.async { HotKey.action?() }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4C475244), id: 1)   // 'LGRD'
        RegisterEventHotKey(k.code, k.mods, id, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let r = ref { UnregisterEventHotKey(r); ref = nil }
    }
}

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: AppStore!
    private var controller: LauncherController!
    private let hotKey = HotKey()
    private var currentHotKey = ""

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Defaults.register()
        buildMenu()
        NSApp.applicationIconImage = Self.makeIcon()
        store = AppStore()
        controller = LauncherController(store: store)
        HotKey.action = { [weak self] in self?.controller.toggle() }
        applyHotKey()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyHotKey()
        }
        store.prewarm()
        // Opened by the user: show right away. Started at login: stay hidden.
        if ProcessInfo.processInfo.systemUptime > 120 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.controller.show() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.toggle()
        return false
    }

    private func applyHotKey() {
        let raw = UserDefaults.standard.string(forKey: "hotkey") ?? HotKeyPreset.optionSpace.rawValue
        guard raw != currentHotKey else { return }
        currentHotKey = raw
        hotKey.register(HotKeyPreset(rawValue: raw) ?? .optionSpace)
    }

    @objc private func showLauncher() { controller.show() }
    @objc private func showSettings() { controller.openSettings() }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Show LaunchGrid", action: #selector(showLauncher), keyEquivalent: "l")
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide LaunchGrid", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit LaunchGrid", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    /// Simple matte icon: light rounded square with a 3x3 grid of soft dots.
    static func makeIcon() -> NSImage {
        let size = NSSize(width: 512, height: 512)
        return NSImage(size: size, flipped: false) { r in
            let bg = NSBezierPath(roundedRect: r.insetBy(dx: 40, dy: 40), xRadius: 96, yRadius: 96)
            NSColor(white: 0.93, alpha: 1).setFill(); bg.fill()
            NSColor(white: 0.80, alpha: 1).setStroke(); bg.lineWidth = 4; bg.stroke()
            let colors: [NSColor] = [.systemBlue, .systemTeal, .systemGreen, .systemOrange, .systemPink,
                                     .systemPurple, .systemYellow, .systemRed, .systemIndigo]
            for i in 0..<9 {
                let x = 136 + CGFloat(i % 3) * 96, y = 136 + CGFloat(i / 3) * 96
                colors[i].withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 64, height: 64), xRadius: 16, yRadius: 16).fill()
            }
            return true
        }
    }
}
