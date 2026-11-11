import SwiftUI
import AppKit
import ApplicationServices
import ServiceManagement

enum CurvePreset: String, CaseIterable, Identifiable {
    case linux, mac, linear, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .linux: return "Linux (libinput)"
        case .mac: return "macOS-like"
        case .linear: return "Linear"
        case .custom: return "Custom"
        }
    }
    // speed is kept separately; these set the curve shape
    var values: (floor: Double, zone: Double, threshold: Double, incline: Double, cap: Double)? {
        switch self {
        case .linux: return (0.3, 7, 130, 0.0025, 4)
        case .mac: return (0.45, 6, 60, 0.006, 4)
        case .linear: return (0.9, 0, 130, 0, 1)
        case .custom: return nil
        }
    }
}

/// All settings + the bridges to the engine, event tap and brightness.
final class AppState: ObservableObject {
    static var shared: AppState?

    private let d = UserDefaults.standard
    private var loading = true

    // master
    @Published var enabled = true { didSet { changed() } }
    // pointer
    @Published var pointerTakeover = true { didSet { changed() } }
    @Published var speed = 1.0 { didSet { changed() } }
    @Published var precFloor = 0.3 { didSet { changed() } }
    @Published var precZone = 7.0 { didSet { changed() } }
    @Published var threshold = 130.0 { didSet { changed() } }
    @Published var incline = 0.0025 { didSet { changed() } }
    @Published var capMul = 4.0 { didSet { changed() } }
    // dragging
    @Published var dragOtherFinger = true { didSet { changed() } }
    // edge motion
    @Published var edgeEnabled = true { didSet { changed() } }
    @Published var edgeZone = 8.0 { didSet { changed() } }
    @Published var edgeSpeed = 8.0 { didSet { changed() } }
    @Published var edgeDragOnly = false { didSet { changed() } }
    @Published var edgeThree = true { didSet { changed() } }
    // gestures
    @Published var tap3Action: GestureAction = .lookUp { didSet { changed() } }
    @Published var tap4Action: GestureAction = .none { didSet { changed() } }
    // brightness
    @Published var smoothBrightness = false { didSet { changed() } }
    @Published var brightnessDuration = 220.0 { didSet { changed() } }   // ms
    @Published var brightnessFine = false { didSet { changed() } }
    @Published var brightnessHUD = true { didSet { changed() } }
    // keyboard
    @Published var mappings: [KeyMapping] = [] { didSet { changed() } }
    @Published var recording: UUID? { didSet { pushTap() } }
    @Published var recordingTarget = false { didSet { pushTap() } }

    // status
    @Published var trusted = false
    @Published var devices: Int32 = 0
    @Published var launchAtLogin = false
    @Published var brightnessAvailable = false

    let tap = EventTap()
    let brightness = BrightnessController()
    private var pollTimer: Timer?
    private var tapWasRunning = false

    var preset: CurvePreset {
        for p in CurvePreset.allCases {
            if let v = p.values, abs(v.floor - precFloor) < 0.001, abs(v.zone - precZone) < 0.01,
               abs(v.threshold - threshold) < 0.5, abs(v.incline - incline) < 0.00001, abs(v.cap - capMul) < 0.01 { return p }
        }
        return .custom
    }

    func apply(preset: CurvePreset) {
        guard let v = preset.values else { return }
        precFloor = v.floor; precZone = v.zone; threshold = v.threshold; incline = v.incline; capMul = v.cap
    }

    init() {
        load()
        loading = false
        AppState.shared = self

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(opts)

        devices = em_start()
        em_set_tap_callback { n in
            let fingers = Int(n)
            DispatchQueue.main.async { AppState.shared?.handleTap(fingers) }
        }
        tap.onBrightness = { [weak self] up in self?.brightness.step(up: up) }
        tap.onMappingFired = { m in m.perform() }
        tap.onRecorded = { [weak self] id, isTarget, code, mods in self?.finishRecording(id, isTarget, code, mods) }

        brightnessAvailable = brightness.available
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        apply()
        if trusted { tap.start() }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let t = AXIsProcessTrusted()
            if t != self.trusted { self.trusted = t }
            if t && !self.tap.running { self.tap.start() }
            if self.tap.running != self.tapWasRunning { self.tapWasRunning = self.tap.running; self.apply() }
        }
    }

    // MARK: engine / tap / brightness

    var engineConfig: EMConfig {
        var c = EMConfig()
        em_get_default_config(&c)
        c.enabled = enabled ? 1 : 0
        // only take over once the event tap can hide macOS's own pointer motion
        c.pointerTakeover = (pointerTakeover && tap.running) ? 1 : 0
        c.speed = Float(speed)
        c.precFloor = Float(precFloor); c.precZone = Float(precZone)
        c.threshold = Float(threshold); c.incline = Float(incline); c.capMul = Float(capMul)
        c.dragOtherFinger = dragOtherFinger ? 1 : 0
        c.edgeEnabled = edgeEnabled ? 1 : 0
        c.edgeZonePct = Float(edgeZone); c.edgeSpeed = Float(edgeSpeed)
        c.edgeDragOnly = edgeDragOnly ? 1 : 0; c.edgeThreeFinger = edgeThree ? 1 : 0
        c.tap3 = (tap3Action != .none) ? 1 : 0
        c.tap4 = (tap4Action != .none) ? 1 : 0
        return c
    }

    private func apply() {
        var c = engineConfig
        em_set_config(&c)
        brightness.duration = brightnessDuration / 1000
        brightness.fineSteps = brightnessFine
        brightness.showHUD = brightnessHUD
        pushTap()
    }

    private func pushTap() {
        let on = enabled
        let smooth = smoothBrightness && brightnessAvailable && on
        let maps = on ? mappings : []
        let rec = recording, recT = recordingTarget
        tap.update { s in
            s.smoothBrightness = smooth
            s.mappings = maps
            s.recording = rec
            s.recordingTarget = recT
        }
    }

    private func changed() {
        guard !loading else { return }
        save()
        apply()
    }

    func tapStarted() { tapWasRunning = true; apply() }

    func handleTap(_ fingers: Int) {
        guard enabled else { return }
        (fingers == 3 ? tap3Action : tap4Action).perform()
    }

    // MARK: keyboard mapping editing

    func addMapping() {
        var m = KeyMapping()
        m.action = .screenshotArea
        mappings.append(m)
        startRecording(m.id, target: false)
    }
    func remove(_ id: UUID) { mappings.removeAll { $0.id == id }; if recording == id { recording = nil } }
    func startRecording(_ id: UUID, target: Bool) { recordingTarget = target; recording = id }
    func cancelRecording() { recording = nil }

    private func finishRecording(_ id: UUID, _ isTarget: Bool, _ code: Int, _ mods: UInt64) {
        if let i = mappings.firstIndex(where: { $0.id == id }) {
            if isTarget { mappings[i].targetKeyCode = code; mappings[i].targetModifiers = mods }
            else { mappings[i].keyCode = code; mappings[i].modifiers = mods }
        }
        recording = nil
    }

    // MARK: misc

    func setLaunchAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { NSLog("EdgeMotion: login item change failed: \(error)") }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func resetPointerDefaults() { speed = 1.0; apply(preset: .linux) }

    // MARK: persistence

    private func load() {
        func dbl(_ k: String, _ def: Double) -> Double { d.object(forKey: k) == nil ? def : d.double(forKey: k) }
        func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
        enabled = bool("enabled", true)
        pointerTakeover = bool("pointerTakeover", true)
        speed = dbl("speed", 1.0)
        precFloor = dbl("precFloor", 0.3); precZone = dbl("precZone", 7)
        threshold = dbl("threshold", 130); incline = dbl("incline", 0.0025); capMul = dbl("capMul", 4)
        dragOtherFinger = bool("dragOtherFinger", true)
        edgeEnabled = bool("edgeEnabled", true)
        edgeZone = dbl("edgeZone", 8); edgeSpeed = dbl("edgeSpeed", 8)
        edgeDragOnly = bool("edgeDragOnly", false); edgeThree = bool("edgeThree", true)
        tap3Action = GestureAction(rawValue: d.string(forKey: "tap3Action") ?? "") ?? .lookUp
        tap4Action = GestureAction(rawValue: d.string(forKey: "tap4Action") ?? "") ?? .none
        smoothBrightness = bool("smoothBrightness", false)
        brightnessDuration = dbl("brightnessDuration", 220)
        brightnessFine = bool("brightnessFine", false)
        brightnessHUD = bool("brightnessHUD", true)
        if let data = d.data(forKey: "mappings"), let m = try? JSONDecoder().decode([KeyMapping].self, from: data) {
            mappings = m
        }
    }

    private func save() {
        d.set(enabled, forKey: "enabled")
        d.set(pointerTakeover, forKey: "pointerTakeover")
        d.set(speed, forKey: "speed")
        d.set(precFloor, forKey: "precFloor"); d.set(precZone, forKey: "precZone")
        d.set(threshold, forKey: "threshold"); d.set(incline, forKey: "incline"); d.set(capMul, forKey: "capMul")
        d.set(dragOtherFinger, forKey: "dragOtherFinger")
        d.set(edgeEnabled, forKey: "edgeEnabled")
        d.set(edgeZone, forKey: "edgeZone"); d.set(edgeSpeed, forKey: "edgeSpeed")
        d.set(edgeDragOnly, forKey: "edgeDragOnly"); d.set(edgeThree, forKey: "edgeThree")
        d.set(tap3Action.rawValue, forKey: "tap3Action"); d.set(tap4Action.rawValue, forKey: "tap4Action")
        d.set(smoothBrightness, forKey: "smoothBrightness")
        d.set(brightnessDuration, forKey: "brightnessDuration")
        d.set(brightnessFine, forKey: "brightnessFine")
        d.set(brightnessHUD, forKey: "brightnessHUD")
        if let data = try? JSONEncoder().encode(mappings) { d.set(data, forKey: "mappings") }
    }
}
