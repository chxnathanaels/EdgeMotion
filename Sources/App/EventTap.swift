import AppKit
import CoreGraphics

/// One system-wide event tap (on its own thread) that:
///  * hides macOS's own trackpad pointer motion while EdgeMotion drives the pointer,
///  * catches brightness keys for smooth brightness,
///  * applies keyboard mappings (and records new ones).
final class EventTap {
    struct Snapshot {
        var smoothBrightness = false
        var mappings: [KeyMapping] = []
        var recording: UUID?            // mapping being recorded
        var recordingTarget = false     // recording the target combo of a .keystroke mapping
    }

    private let lock = NSLock()
    private var snap = Snapshot()
    private var swallowKeyUp = Set<Int64>()
    private var tap: CFMachPort?
    private var thread: Thread?

    var onBrightness: ((Bool) -> Void)?                    // up?
    var onMappingFired: ((KeyMapping) -> Void)?
    var onRecorded: ((UUID, Bool, Int, UInt64) -> Void)?   // id, isTarget, keyCode, modifiers

    private(set) var running = false

    func update(_ f: (inout Snapshot) -> Void) {
        lock.lock(); f(&snap); lock.unlock()
    }
    private func current() -> Snapshot { lock.lock(); defer { lock.unlock() }; return snap }

    func start() {
        guard tap == nil else { return }
        let t = Thread { [weak self] in self?.runTap() }
        t.name = "EdgeMotion.EventTap"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    private func runTap() {
        let types: [UInt64] = [5, 6, 7, 27, 10, 11, 14]   // moved, L/R/other dragged, keyDown, keyUp, system-defined
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: eventTapCallback, userInfo: refcon) else {
            NSLog("EdgeMotion: event tap could not be created (Accessibility permission?)")
            return
        }
        tap = port
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        running = true
        DispatchQueue.main.async { AppState.shared?.tapStarted() }
        CFRunLoopRun()
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            em_note_external_motion()
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Int64(em_magic()) {
            return Unmanaged.passUnretained(event)        // our own synthetic events
        }

        switch type.rawValue {
        case 5, 6, 7, 27:                                 // pointer motion
            if em_should_suppress_system_motion() != 0 { return nil }
            em_note_external_motion()                     // macOS / trackpoint / mouse moved it: re-sync our position
            return Unmanaged.passUnretained(event)

        case 14:                                          // NX_SYSDEFINED (media / brightness keys)
            let s = current()
            guard s.smoothBrightness, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
                return Unmanaged.passUnretained(event)
            }
            let code = (ns.data1 & 0xFFFF0000) >> 16
            let state = (ns.data1 & 0xFF00) >> 8          // 0xA down, 0xB up
            if code == 2 || code == 3 {                   // NX_KEYTYPE_BRIGHTNESS_UP / _DOWN
                if state == 0xA { let up = code == 2; DispatchQueue.main.async { self.onBrightness?(up) } }
                return nil
            }
            return Unmanaged.passUnretained(event)

        case 10, 11:                                      // keyDown / keyUp
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let mods = event.flags.rawValue & KeyMapping.modMask
            let s = current()

            if type.rawValue == 11 {
                lock.lock(); let sw = swallowKeyUp.remove(code) != nil; lock.unlock()
                return sw ? nil : Unmanaged.passUnretained(event)
            }

            if let id = s.recording {                     // recording a new key
                lock.lock(); swallowKeyUp.insert(code); lock.unlock()
                let isTarget = s.recordingTarget
                DispatchQueue.main.async { self.onRecorded?(id, isTarget, Int(code), mods) }
                return nil
            }

            if s.smoothBrightness, code == 144 || code == 145 {   // brightness keys sent as key codes
                lock.lock(); swallowKeyUp.insert(code); lock.unlock()
                let up = code == 144
                DispatchQueue.main.async { self.onBrightness?(up) }
                return nil
            }

            if let m = s.mappings.first(where: { $0.enabled && $0.keyCode == Int(code) && $0.modifiers == mods }) {
                lock.lock(); swallowKeyUp.insert(code); lock.unlock()
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !isRepeat { DispatchQueue.main.async { self.onMappingFired?(m) } }
                return nil
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let me = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
    return me.handle(type: type, event: event)
}
