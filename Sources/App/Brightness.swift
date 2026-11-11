import AppKit
import SwiftUI

/// Smooth brightness: animates the built-in display's backlight between steps,
/// like a real Mac, and shows a small on-screen indicator.
final class BrightnessController {
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32
    private typealias ChangedFn = @convention(c) (UInt32, Double) -> Void
    private typealias IOGetFn = @convention(c) (UInt32, UInt32, CFString, UnsafeMutablePointer<Float>) -> Int32
    private typealias IOSetFn = @convention(c) (UInt32, UInt32, CFString, Float) -> Int32

    private var dsGet: GetFn?
    private var dsSet: SetFn?
    private var dsChanged: ChangedFn?
    private var ioGet: IOGetFn?
    private var ioSet: IOSetFn?
    private var ioService: UInt32 = 0

    private var timer: Timer?
    private var animFrom: Float = 0
    private var animTo: Float = 0
    private var animStart = Date()
    private var target: Float?

    var duration: Double = 0.22
    var fineSteps = false
    var showHUD = true

    private let hud = BrightnessHUD()

    init() {
        if let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW) {
            if let s = dlsym(h, "DisplayServicesGetBrightness") { dsGet = unsafeBitCast(s, to: GetFn.self) }
            if let s = dlsym(h, "DisplayServicesSetBrightness") { dsSet = unsafeBitCast(s, to: SetFn.self) }
            if let s = dlsym(h, "DisplayServicesBrightnessChanged") { dsChanged = unsafeBitCast(s, to: ChangedFn.self) }
        }
        if let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) {
            if let s = dlsym(h, "IODisplayGetFloatParameter") { ioGet = unsafeBitCast(s, to: IOGetFn.self) }
            if let s = dlsym(h, "IODisplaySetFloatParameter") { ioSet = unsafeBitCast(s, to: IOSetFn.self) }
            ioService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"))
        }
    }

    private var display: CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &n)
        for i in 0..<Int(n) where CGDisplayIsBuiltin(ids[i]) != 0 { return ids[i] }
        return CGMainDisplayID()
    }

    func get() -> Float? {
        var v: Float = 0
        if let g = dsGet, g(display, &v) == 0 { return v }
        if let g = ioGet, ioService != 0, g(ioService, 0, "brightness" as CFString, &v) == 0 { return v }
        return nil
    }

    private func set(_ v: Float) {
        if let s = dsSet, s(display, v) == 0 { return }
        if let s = ioSet, ioService != 0 { _ = s(ioService, 0, "brightness" as CFString, v) }
    }

    var available: Bool { get() != nil }

    /// Called on the main thread for each brightness key press (and auto-repeat).
    func step(up: Bool) {
        guard let current = get() else { return }
        let step: Float = fineSteps ? 1.0 / 32.0 : 1.0 / 16.0
        let base = target ?? current
        var t = (base / step).rounded() * step + (up ? step : -step)
        t = min(1, max(0, t))
        target = t
        animFrom = current
        animTo = t
        animStart = Date()
        if showHUD { hud.show(level: t) }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer!, forMode: .common)
        }
    }

    private func tick() {
        let p = min(1.0, Date().timeIntervalSince(animStart) / max(0.01, duration))
        let eased = Float(1 - pow(1 - p, 3))                 // ease-out
        set(animFrom + (animTo - animFrom) * eased)
        if p >= 1 {
            timer?.invalidate(); timer = nil
            dsChanged?(display, Double(animTo))
            target = nil
        }
    }
}

// MARK: - On-screen indicator

final class HUDModel: ObservableObject {
    @Published var level: Float = 0
}

struct HUDView: View {
    @ObservedObject var model: HUDModel
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.level < 0.01 ? "sun.min" : "sun.max.fill")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 20)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.15))
                    Capsule().fill(Color.primary.opacity(0.85))
                        .frame(width: max(6, g.size.width * CGFloat(model.level)))
                        .animation(.easeOut(duration: 0.15), value: model.level)
                }
            }
            .frame(height: 6)
        }
        .padding(.horizontal, 16)
        .frame(width: 220, height: 44)
        .background(.regularMaterial, in: Capsule())
    }
}

final class BrightnessHUD {
    private var panel: NSPanel?
    private let model = HUDModel()
    private var hideWork: DispatchWorkItem?

    func show(level: Float) {
        model.level = level
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: HUDView(model: model))
            panel = p
        }
        guard let p = panel, let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        p.setFrameOrigin(NSPoint(x: vf.maxX - 220 - 16, y: vf.maxY - 44 - 12))
        p.alphaValue = 1
        p.orderFrontRegardless()
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                self?.panel?.animator().alphaValue = 0
            }, completionHandler: { self?.panel?.orderOut(nil) })
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: w)
    }
}
