import AppKit
import SwiftUI

final class LauncherWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Owns the fullscreen window: show/hide, background style, keyboard navigation, launching.
final class LauncherController: NSObject, ObservableObject, NSWindowDelegate {
    @Published var query = "" { didSet { updateResults() } }
    @Published var results: [AppItem] = []
    @Published var selection: Int?
    @Published var page: Int? = 0
    @Published var pageCount = 1
    @Published var shown = false
    @Published var insets = NSEdgeInsets()
    @Published var focusTick = 0

    let store: AppStore
    private var window: LauncherWindow!
    private var effect: NSVisualEffectView!
    private var dimView: NSView!
    private var keyMonitor: Any?
    private var settingsWindow: NSWindow?
    private(set) var visible = false
    private var hiding = false

    init(store: AppStore) {
        self.store = store
        super.init()
        buildWindow()
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged),
                                               name: UserDefaults.didChangeNotification, object: nil)
    }

    private var columns: Int { max(1, UserDefaults.standard.integer(forKey: "columns")) }
    private var rows: Int { max(1, UserDefaults.standard.integer(forKey: "rows")) }
    private var perPage: Int { columns * rows }
    private var animate: Bool { UserDefaults.standard.bool(forKey: "animate") }

    // MARK: window

    private func buildWindow() {
        let w = LauncherWindow(contentRect: NSScreen.main?.frame ?? .zero, styleMask: [.borderless],
                               backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        // One level below the Dock: the Dock stays visible and clickable on top, so apps can be dragged onto it.
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.isReleasedWhenClosed = false
        w.delegate = self

        let root = NSView()
        root.wantsLayer = true
        let fx = NSVisualEffectView()
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.autoresizingMask = [.width, .height]
        let dim = NSView()
        dim.wantsLayer = true
        dim.autoresizingMask = [.width, .height]
        let host = NSHostingView(rootView: LauncherView(store: store, c: self))
        host.autoresizingMask = [.width, .height]
        root.addSubview(fx)
        root.addSubview(dim)
        root.addSubview(host)
        w.contentView = root
        fx.frame = root.bounds; dim.frame = root.bounds; host.frame = root.bounds

        window = w; effect = fx; dimView = dim
        applyBackground()
    }

    @objc private func defaultsChanged() {
        DispatchQueue.main.async { self.applyBackground(); self.updateResults() }
    }

    private func applyBackground() {
        let style = BackgroundStyle(rawValue: UserDefaults.standard.string(forKey: "background") ?? "") ?? .light
        let dim = UserDefaults.standard.double(forKey: "dim")
        switch style {
        case .light:
            effect.isHidden = false
            effect.material = .fullScreenUI
            effect.appearance = NSAppearance(named: .vibrantLight)
            dimView.layer?.backgroundColor = NSColor.black.withAlphaComponent(CGFloat(dim)).cgColor
        case .dark:
            effect.isHidden = false
            effect.material = .hudWindow
            effect.appearance = NSAppearance(named: .vibrantDark)
            dimView.layer?.backgroundColor = NSColor.black.withAlphaComponent(CGFloat(min(0.9, dim + 0.2))).cgColor
        case .solid:
            effect.isHidden = true
            dimView.layer?.backgroundColor = NSColor(white: 0.08, alpha: CGFloat(max(0.82, dim))).cgColor
        }
    }

    // MARK: show / hide

    func toggle() { visible ? hide() : show() }

    func show() {
        guard !visible else { return }
        visible = true; hiding = false
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let scr = screen {
            let f = scr.frame, v = scr.visibleFrame
            window.setFrame(f, display: false)
            // Keep the grid out of the Dock's area (Dock on bottom, left or right; auto-hide gives 0).
            insets = NSEdgeInsets(top: 0,
                                  left: v.minX - f.minX,
                                  bottom: v.minY - f.minY,
                                  right: f.maxX - v.maxX)
        }
        NSApp.presentationOptions = [.autoHideMenuBar]
        updateResults()
        NSApp.activate(ignoringOtherApps: true)
        window.alphaValue = animate ? 0 : 1
        window.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        focusTick += 1
        if animate {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                window.animator().alphaValue = 1
            }
            withAnimation(.easeOut(duration: 0.2)) { shown = true }
        } else {
            shown = true
        }
    }

    func hide(completion: (() -> Void)? = nil) {
        guard visible, !hiding else { completion?(); return }
        hiding = true
        removeKeyMonitor()
        let finish = { [weak self] in
            guard let self = self else { return }
            self.window.orderOut(nil)
            NSApp.presentationOptions = []
            self.visible = false; self.hiding = false
            self.query = ""; self.selection = nil
            if self.settingsWindow?.isVisible != true { NSApp.hide(nil) }
            completion?()
        }
        if animate {
            withAnimation(.easeIn(duration: 0.15)) { shown = false }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                window.animator().alphaValue = 0
            }, completionHandler: finish)
        } else {
            shown = false
            finish()
        }
    }

    func hideThen(_ action: @escaping () -> Void) { hide(completion: action) }

    func windowDidResignKey(_ notification: Notification) {
        if visible && !dragging && settingsWindow?.isKeyWindow != true { hide() }
    }

    /// While an icon is being dragged, don't auto-close. Clear the flag once the mouse button is up.
    var dragging = false
    func watchDragEnd() {
        if NSEvent.pressedMouseButtons & 1 != 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.watchDragEnd() }
        } else {
            dragging = false
            if visible { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
        }
    }

    // MARK: actions

    func launch(_ item: AppItem) {
        hide {
            NSWorkspace.shared.openApplication(at: item.url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }

    func searchSpotlight() {
        let q = query
        hide { _ = NSWorkspace.shared.showSearchResults(forQueryString: q) }
    }

    func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "LaunchGrid Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(store: store))
            w.center()
            settingsWindow = w
        }
        let open = { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.settingsWindow?.makeKeyAndOrderFront(nil)
        }
        if visible { hide(completion: open) } else { open() }
    }

    private func updateResults() {
        results = query.isEmpty ? [] : store.search(query)
    }

    // MARK: keyboard

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self, self.visible else { return e }
            return self.handleKey(e) ? nil : e
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    private var currentList: [AppItem] { query.isEmpty ? store.apps : Array(results.prefix(perPage)) }

    /// Returns true when the key was handled.
    private func handleKey(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.contains(.command)
        switch e.keyCode {
        case 53:                                                   // Esc
            if !query.isEmpty { query = "" } else { hide() }
            return true
        case 36, 76:                                               // Return / Enter
            if cmd { searchSpotlight(); return true }
            let list = currentList
            if let s = selection, s < list.count { launch(list[s]) }
            else if !query.isEmpty, let first = list.first { launch(first) }
            else if !query.isEmpty { searchSpotlight() }
            return true
        case 123, 124, 125, 126:                                   // arrows
            moveSelection(e.keyCode)
            return true
        case 43 where cmd:                                         // ⌘,
            openSettings(); return true
        default:
            return false
        }
    }

    private func moveSelection(_ key: UInt16) {
        let list = currentList
        guard !list.isEmpty else { return }
        var s = selection ?? (query.isEmpty ? (page ?? 0) * perPage : 0)
        if selection != nil {
            switch key {
            case 123: s -= 1
            case 124: s += 1
            case 125: s += columns
            default: s -= columns
            }
        }
        s = max(0, min(list.count - 1, s))
        selection = s
        if query.isEmpty {
            let p = s / perPage
            if p != page { withAnimation(.easeOut(duration: 0.25)) { page = p } }
        }
    }
}
