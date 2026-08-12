import AppKit
import CoreGraphics
import Foundation
import ServiceManagement

// DisplayWave — menu bar control for external monitors.
//
//   Power    — connects/disconnects the display at the OS level via the private
//              CGSConfigureDisplayEnabled SPI. The monitor loses signal and enters
//              standby on its own, so this needs no DDC support from the monitor.
//   Brightness / colour temperature
//            — applied through the GPU's gamma transfer table rather than by asking
//              the monitor to change its own settings. Also works without DDC, which
//              matters because most monitors on this desk don't answer DDC at all.
//              Temperature is a real kelvin figure that drives the table, not a
//              slider position with a label on it.
//   Mode     — resolution and refresh rate, switched the same way System Settings
//              does it, from dropdowns on each display's card.
//
// macOS resets gamma whenever the display configuration changes or the machine wakes,
// so settings are reapplied from a reconfiguration callback.

// MARK: - Model

struct Settings {
    var brightness: Double = 1.0
    var kelvin: Double = neutralKelvin
}

// MARK: - Colour temperature

/// The white point a monitor already shows without help. Setting this asks for no
/// change at all, which is why it's the cool end of the slider.
let neutralKelvin: Double = 6500
/// As warm as the slider goes — candlelight. Below roughly this point the blue
/// channel has nothing left to give up, so going further mostly just clips.
let warmestKelvin: Double = 2000

/// The white point of a blackbody at `kelvin`, as the per-channel gains that produce
/// it, normalised so `neutralKelvin` comes out as no change whatsoever.
///
/// This is Tanner Helland's fit to the Planckian locus — the same approximation
/// Redshift and the various f.lux-alikes use. It lands within a couple of percent
/// across the range that matters here, and it's already in sRGB's encoded domain,
/// which is the domain `CGSetDisplayTransferByFormula` scales in.
func whitePoint(kelvin: Double) -> (r: Double, g: Double, b: Double) {
    func channels(_ kelvin: Double) -> (Double, Double, Double) {
        let t = min(40000, max(1000, kelvin)) / 100
        let r = t <= 66 ? 255 : 329.698_727_446 * pow(t - 60, -0.133_204_759_2)
        let g = t <= 66 ? 99.470_802_586_1 * log(t) - 161.119_568_166_1
                        : 288.122_169_528_3 * pow(t - 60, -0.075_514_849_2)
        let b = t >= 66 ? 255
              : t <= 19 ? 0
              : 138.517_731_223_1 * log(t - 10) - 305.044_792_730_7
        return (r, g, b)
    }
    let wanted = channels(kelvin)
    let neutral = channels(neutralKelvin)
    func gain(_ v: Double, _ n: Double) -> Double { min(1, max(0, v / n)) }
    return (gain(wanted.0, neutral.0), gain(wanted.1, neutral.1), gain(wanted.2, neutral.2))
}

/// Warmth used to be stored as a bare 0…1 amount rather than a temperature. The two
/// can't be confused — no temperature this app writes is anywhere near 1 — so old
/// values are recognised on sight and mapped onto the temperature they were really
/// producing, leaving saved presets looking the way they always did.
///
/// 3800 K is where the old formula's fully-warm end actually sat: it pulled green to
/// 0.82 and blue to 0.55, which is about a 3800 K white point.
func migratedKelvin(_ stored: Double) -> Double {
    guard stored <= 1.0 else { return stored }
    // Onto the same grid the slider works in, so a migrated value reads back exactly
    // as it was stored rather than shifting the first time it's touched.
    return Scale.warmth.snap(neutralKelvin - stored * (neutralKelvin - 3800))
}

struct Display {
    let id: CGDirectDisplayID
    let name: String
    let active: Bool
    let width: Int
    let height: Int
    let refresh: Double

    var modeDescription: String {
        guard width > 0 else { return "—" }
        let res = "\(width) × \(height)"
        return refresh > 0 ? "\(res)  ·  \(Int(refresh.rounded())) Hz" : res
    }
}

func percentString(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
func kelvinString(_ v: Double) -> String { "\(Int(v.rounded()))K" }

/// How one slider's numbers behave: the range it covers, the finest change it can
/// show, how far the nudge buttons move, and the quick values under it.
///
/// Brightness is a proportion and reads as a percentage; colour temperature is a
/// real unit and reads in kelvin. Keeping both descriptions in one shape is what
/// lets the two controls share their layout and their handlers.
struct Scale {
    let min: Double
    let max: Double
    /// The smallest step the readout can distinguish. Values are snapped to it, so
    /// what's stored is always exactly what's on screen — which in turn is what makes
    /// matching a value against the preset buttons exact rather than approximate.
    let quantum: Double
    /// How far the − and + buttons move, and what they're labelled with.
    let step: Double
    let stepLabel: String
    let presets: [Double]
    let unit: (Double) -> String

    func snap(_ v: Double) -> Double {
        Swift.min(max, Swift.max(min, (v / quantum).rounded() * quantum))
    }

    func describe(_ v: Double) -> String { unit(snap(v)) }

    /// Which preset button a value sits on, or -1 for none of them.
    func presetIndex(_ v: Double) -> Int {
        let snapped = snap(v)
        return presets.firstIndex { abs($0 - snapped) < quantum / 2 } ?? -1
    }

    /// Brightness bottoms out lower on a monitor that can dim its own backlight,
    /// because there the floor only has to keep the menu readable, not the whole
    /// picture.
    static func brightness(hardware: Bool) -> Scale {
        Scale(min: hardware ? 0.05 : 0.15, max: 1.0, quantum: 0.01, step: 0.05, stepLabel: "5",
              presets: [0.35, 0.50, 0.75, 1.0], unit: percentString)
    }

    /// Warm at the left, daylight at the right — the same direction as brightness
    /// beside it, so the left end of both sliders is the night-time end.
    /// The presets are the familiar light sources: candle, incandescent, halogen,
    /// warm white, and the monitor's own white point.
    static let warmth = Scale(min: warmestKelvin, max: neutralKelvin, quantum: 100,
                              step: 100, stepLabel: "100",
                              presets: [2000, 2700, 3400, 4200, 6500], unit: kelvinString)
}

/// A named snapshot of how the desk should look: what each monitor's brightness and
/// colour temperature should be. One click puts every display back to it.
struct Preset {
    /// Settings under this key apply to any display the preset doesn't name, so a
    /// preset still does something sensible on a monitor plugged in later.
    static let anyDisplay = "*"

    var name: String
    var settings: [String: Settings]

    func settings(for displayName: String) -> Settings? {
        settings[displayName] ?? settings[Preset.anyDisplay]
    }

    /// Captures what every active display is set to right now.
    static func fromCurrent(name: String) -> Preset {
        let displays = onlineDisplays().filter(\.active)
        var settings = Dictionary(uniqueKeysWithValues: displays.map { ($0.name, Store.shared[$0.name]) })
        // Give unknown displays the first monitor's look rather than nothing.
        if let first = displays.first { settings[anyDisplay] = Store.shared[first.name] }
        return Preset(name: name, settings: settings)
    }
}

let defaultPresets = [
    Preset(name: "Day", settings: [Preset.anyDisplay: Settings(brightness: 1.0, kelvin: 6500)]),
    Preset(name: "Evening", settings: [Preset.anyDisplay: Settings(brightness: 0.70, kelvin: 4200)]),
    Preset(name: "Night", settings: [Preset.anyDisplay: Settings(brightness: 0.35, kelvin: 2700)]),
]

/// The user's presets, in menu order. Editable via "Edit Presets…".
final class PresetStore {
    static let shared = PresetStore()
    private let key = "presets"
    private(set) var presets: [Preset] = defaultPresets

    private init() {
        guard let raw = UserDefaults.standard.array(forKey: key) as? [[String: Any]] else { return }
        let loaded = raw.compactMap { entry -> Preset? in
            guard let name = entry["name"] as? String,
                  let values = entry["settings"] as? [String: [Double]] else { return nil }
            let settings = values.compactMapValues { v in
                v.count == 2 ? Settings(brightness: v[0], kelvin: migratedKelvin(v[1])) : nil
            }
            return Preset(name: name, settings: settings)
        }
        if !loaded.isEmpty { presets = loaded }
    }

    private func save() {
        UserDefaults.standard.set(presets.map { preset in
            ["name": preset.name,
             "settings": preset.settings.mapValues { [$0.brightness, $0.kelvin] }]
        }, forKey: key)
    }

    /// Names have to be distinct — they're how presets are told apart in the menu.
    private func uniqueName(_ wanted: String, excluding index: Int? = nil) -> String {
        let taken = presets.enumerated()
            .filter { $0.offset != index }
            .map { $0.element.name.lowercased() }
        var name = wanted.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "Preset" }
        var candidate = name, n = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(name) \(n)"
            n += 1
        }
        return candidate
    }

    func addFromCurrent(name: String) {
        presets.append(Preset.fromCurrent(name: uniqueName(name)))
        save()
    }

    /// Replaces a preset's contents with the way the displays look right now.
    func updateFromCurrent(index: Int) {
        guard presets.indices.contains(index) else { return }
        presets[index] = Preset.fromCurrent(name: presets[index].name)
        save()
    }

    func rename(index: Int, to name: String) {
        guard presets.indices.contains(index) else { return }
        presets[index].name = uniqueName(name, excluding: index)
        save()
    }

    func remove(index: Int) {
        guard presets.indices.contains(index) else { return }
        presets.remove(at: index)
        save()
    }

    func resetToDefaults() {
        presets = defaultPresets
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - Display modes

// Anything derived from the display configuration is cached until that configuration
// changes, which is the only thing that can invalidate it. The menu is rebuilt from
// scratch every time it opens, and without this it re-derived all of it each time.
//
// Main thread only — everything that reads them builds its display list on the main
// thread before handing work off.
private var modeCache: [CGDirectDisplayID: [CGDisplayMode]] = [:]
private var nameCache: [CGDirectDisplayID: String] = [:]

func invalidateDisplayCaches() {
    modeCache.removeAll()
    nameCache.removeAll()
}

/// Every mode the monitor advertises that macOS considers usable for a desktop,
/// including HiDPI variants of the same point size.
///
/// Enumerating them costs a few milliseconds per monitor — measurable when the menu
/// builds a card per display — and the answer only moves when the configuration does.
func displayModes(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
    if let cached = modeCache[id] { return cached }
    let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue!] as CFDictionary
    let all = CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode] ?? []
    let usable = all.filter { $0.isUsableForDesktopGUI() }
    modeCache[id] = usable
    return usable
}

/// Distinct point resolutions, largest first.
func resolutionOptions(_ modes: [CGDisplayMode]) -> [(width: Int, height: Int)] {
    var seen = Set<Int>()
    return modes
        .sorted { $0.width * $0.height > $1.width * $1.height }
        .compactMap { seen.insert($0.width << 16 | $0.height).inserted ? ($0.width, $0.height) : nil }
}

/// Refresh rates available at one resolution, fastest first.
func refreshOptions(_ modes: [CGDisplayMode], width: Int, height: Int) -> [Int] {
    Set(modes
        .filter { $0.width == width && $0.height == height && $0.refreshRate > 0 }
        .map { Int($0.refreshRate.rounded()) })
        .sorted(by: >)
}

/// The mode to actually use for a chosen resolution and rate: keep the requested
/// rate when the resolution offers it, and prefer the HiDPI variant (largest pixel
/// backing) so text stays sharp.
func bestMode(_ modes: [CGDisplayMode], width: Int, height: Int, rate: Int?) -> CGDisplayMode? {
    let candidates = modes.filter { $0.width == width && $0.height == height }
    let atRate = candidates.filter { Int($0.refreshRate.rounded()) == rate }
    return (atRate.isEmpty ? candidates : atRate).max {
        $0.pixelWidth != $1.pixelWidth ? $0.pixelWidth < $1.pixelWidth
                                       : $0.refreshRate < $1.refreshRate
    }
}

// .permanently matches what System Settings does: the chosen mode survives restarts.
func setMode(_ id: CGDirectDisplayID, _ mode: CGDisplayMode) {
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
    guard CGConfigureDisplayWithDisplayMode(config, id, mode, nil) == .success,
          CGCompleteDisplayConfiguration(config, .permanently) == .success else {
        CGCancelDisplayConfiguration(config)
        return
    }
}

// MARK: - Display enumeration

/// The monitor's product name, which is also the key everything is stored under.
///
/// Building the CoreDisplay dictionary this reads isn't free, and `onlineDisplays()`
/// asks for one per display every time it runs — several times over for a single
/// menu open — so the answer is kept until the configuration changes.
func displayName(_ id: CGDirectDisplayID) -> String {
    if let cached = nameCache[id] { return cached }
    var name = CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)"
    if let dict = CoreDisplay_DisplayCreateInfoDictionary(id)?.takeRetainedValue() as NSDictionary?,
       let names = dict["DisplayProductName"] as? [String: String],
       let product = names["en_US"] ?? names.first?.value {
        name = product
    }
    nameCache[id] = name
    return name
}

func onlineDisplays() -> [Display] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }
    return ids.prefix(Int(count)).map { id in
        let mode = CGDisplayCopyDisplayMode(id)
        return Display(id: id,
                       name: displayName(id),
                       active: CGDisplayIsActive(id) != 0,
                       width: mode?.width ?? 0,
                       height: mode?.height ?? 0,
                       refresh: mode?.refreshRate ?? 0)
    }
}

// MARK: - Settings store

final class Store {
    static let shared = Store()
    private let key = "displaySettings"
    private var cache: [String: Settings] = [:]

    private init() {
        if let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] {
            for (name, v) in raw where v.count == 2 {
                cache[name] = Settings(brightness: v[0], kelvin: migratedKelvin(v[1]))
            }
        }
    }

    subscript(name: String) -> Settings {
        get { cache[name] ?? Settings() }
        set {
            cache[name] = newValue
            scheduleFlush()
        }
    }

    // A slider drag lands dozens of changes a second, and each one used to rebuild
    // and write the whole settings dictionary. Only the final value matters to disk,
    // so writes are coalesced; the in-memory cache is authoritative meanwhile, so
    // nothing reads a stale value, and the worst a hard crash mid-drag can cost is a
    // fraction of a second of slider movement.
    private var pendingFlush: DispatchWorkItem?
    private static let flushDelay: TimeInterval = 0.3

    private func scheduleFlush() {
        pendingFlush?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pendingFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flushDelay, execute: work)
    }

    /// Writes any pending change out now.
    func flush() {
        pendingFlush?.cancel()
        pendingFlush = nil
        UserDefaults.standard.set(cache.mapValues { [$0.brightness, $0.kelvin] }, forKey: key)
    }

    func reset() {
        pendingFlush?.cancel()
        pendingFlush = nil
        cache = [:]
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - Applying settings

// Brightness scales all three channels together; the colour temperature scales them
// against each other, holding back green and blue until what's left is the white of
// a blackbody at that temperature. The brightness floor keeps a screen from going
// fully black, which would leave no way to see the menu that brings it back.
func applyGamma(_ id: CGDirectDisplayID, brightness: Double, kelvin: Double, floor: Double = 0.15) {
    let b = max(floor, min(1.0, brightness))
    let w = whitePoint(kelvin: kelvin)
    CGSetDisplayTransferByFormula(id,
                                  0, Float(b * w.r), 1.0,
                                  0, Float(b * w.g), 1.0,
                                  0, Float(b * w.b), 1.0)
}

/// Takes every display far below the normal brightness floors — for leaving screens
/// on overnight without lighting up the room. The floors exist so a screen can't go
/// dark enough to hide the menu; this deliberately steps past them, so it is
/// session-only and quitting or restarting always brings the screens back.
final class Blackout {
    static let shared = Blackout()
    /// All the way off: backlight at its minimum and the image fully black. The
    /// displays stay awake and the Mac keeps working — there is simply nothing to
    /// see until a key or a click brings it back.
    static let level = 0.0

    /// Input within this long of switching blackout on doesn't count as the escape —
    /// otherwise the very click that turned it on would undo it instantly.
    private static let grace: TimeInterval = 1.5

    private(set) var active = false
    private var startedAt = Date()
    private var watchdog: Timer?
    private var lastSleepRequest = Date.distantPast

    func toggle() {
        active.toggle()
        // Keep Mac Awake normally stops the screens sleeping, which would fight this.
        KeepAwake.shared.updateDisplayHold()
        if active {
            watchForInput()
            sleepDisplays()
        } else {
            watchdog?.invalidate()
            watchdog = nil
            wakeDisplays()
        }
        applyAll()
    }

    /// Adjusting a display, applying a preset, or pressing any key means "I want to
    /// see this now". Stored settings are never touched by blackout, so leaving it
    /// puts every display back exactly as it was.
    func deactivate() {
        guard active else { return }
        active = false
        watchdog?.invalidate()
        watchdog = nil
        KeepAwake.shared.updateDisplayHold()
        wakeDisplays()
        applyAll()
    }

    /// Puts the displays into standby. This is the only way to darken a monitor that
    /// doesn't answer DDC: the backlight goes off because the monitor sleeps, not
    /// because it was asked to dim. The displays stay connected, so nothing moves.
    private func sleepDisplays() {
        lastSleepRequest = Date()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["displaysleepnow"]
        try? task.run()
    }

    private func wakeDisplays() {
        var id = IOPMAssertionID(0)
        IOPMAssertionDeclareUserActivity("DisplayWave: leaving blackout" as CFString,
                                         kIOPMUserActiveLocal, &id)
    }

    /// Watches for a keypress or a click without an event tap — asking the system
    /// how long input has been idle needs no permissions, where monitoring events
    /// does. Both count, so there are two ways back from a black screen. Mouse
    /// *movement* is ignored on purpose: a nudged desk shouldn't light the room.
    private func watchForInput() {
        startedAt = Date()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.active else { return }
            let elapsed = Date().timeIntervalSince(self.startedAt)
            let idle = min(
                CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown),
                CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown))
            if idle < elapsed - Self.grace {
                self.deactivate()
                return
            }
            // A nudged mouse wakes the screens without meaning to, so put them back.
            // Recent mouse movement is the signal: CGDisplayIsAsleep keeps reporting
            // external monitors as awake even once they're in standby, so it can't
            // be used to tell. They come back black meanwhile, blackout being still
            // on.
            let moved = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                                eventType: .mouseMoved)
            if moved < 3, Date().timeIntervalSince(self.lastSleepRequest) > 5 {
                self.sleepDisplays()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }
}

/// Where gamma starts helping the backlight out. A monitor's lowest backlight
/// setting is often still bright in a dark room, so under this point the image is
/// dimmed as well — that's what lets a DDC monitor get as dark as a gamma-only one.
let backlightFloor = 0.25
/// How far gamma is allowed to dim at the very bottom. Not lower: the screen has to
/// stay readable enough to open the menu and turn it back up.
let deepDimFloor = 0.35

/// Applies a display's settings using whichever brightness mechanism it supports.
///
/// On a monitor that answers DDC the backlight does the dimming and gamma stays at
/// full, so the two don't stack into a doubly-dark picture in normal use. Below
/// `backlightFloor` they do stack deliberately: the backlight keeps going down and
/// gamma joins in, which is the only way to reach the very dark end.
func apply(_ display: Display) {
    let s = Store.shared[display.name]
    let hardwareService = Capabilities.shared.mode(for: display.name) == .hardware
        ? Capabilities.shared.service(for: display.name) : nil

    if Blackout.shared.active {
        // Backlight as low as it goes and gamma past its usual floor. As warm as it
        // goes too — blue light is the part that keeps you awake.
        if let service = hardwareService {
            Backlight.shared.set(percent: Blackout.level, id: display.id, name: display.name,
                                 service: service,
                                 ceiling: Capabilities.shared.maxLuminance(for: display.name))
        }
        applyGamma(display.id, brightness: Blackout.level, kelvin: warmestKelvin,
                   floor: Blackout.level)
        return
    }

    if Capabilities.shared.mode(for: display.name) == .hardware,
       let service = Capabilities.shared.service(for: display.name) {
        Backlight.shared.set(percent: s.brightness, id: display.id, name: display.name,
                             service: service,
                             ceiling: Capabilities.shared.maxLuminance(for: display.name))
        let gamma = s.brightness < backlightFloor
            ? max(deepDimFloor, s.brightness / backlightFloor) : 1.0
        applyGamma(display.id, brightness: gamma, kelvin: s.kelvin)
    } else {
        applyGamma(display.id, brightness: s.brightness, kelvin: s.kelvin)
    }
}

func applyAll() {
    for d in onlineDisplays() where d.active { apply(d) }
}

/// Puts every active display back to how the preset describes it. Displays the
/// preset says nothing about are left alone.
func applyPreset(_ preset: Preset) {
    Blackout.shared.deactivate()
    for display in onlineDisplays() where display.active {
        guard let settings = preset.settings(for: display.name) else { continue }
        Store.shared[display.name] = settings
        apply(display)
    }
    AppDelegate.shared?.refreshVisibleCards()
}

/// Brings everything back in line after a display reconfiguration: drops the caches
/// that the configuration invalidated, re-resolves DDC handles (the old ones are
/// dead), probes anything newly plugged in, then reapplies every setting.
func resyncAndApply() {
    invalidateDisplayCaches()
    Capabilities.shared.sync(displays: onlineDisplays().filter(\.active)) {
        applyAll()
    }
}

/// Reconfigurations arrive in bursts — a callback per display, several times over,
/// for what a person experiences as one act of plugging a monitor in. Each used to
/// schedule its own resync, so a single plug meant a pile of registry walks and
/// rounds of DDC traffic all racing each other. They now collapse into one pass that
/// runs once the dust has settled.
enum Resync {
    private static var pending: DispatchWorkItem?
    /// Long enough for the burst to finish arriving and for the displays themselves
    /// to come back — gamma won't stick on a display that is still waking up.
    static let settling: TimeInterval = 1.5

    /// Main thread only, which is where the reconfiguration callback is delivered.
    static func schedule(after delay: TimeInterval = settling) {
        pending?.cancel()
        let work = DispatchWorkItem {
            pending = nil
            resyncAndApply()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

// kCGConfigureForSession keeps this out of the permanent display configuration, so a
// restart always brings every display back regardless of app state.
func setDisplay(_ id: CGDirectDisplayID, enabled: Bool) -> Bool {
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
    guard CGSConfigureDisplayEnabled(config, id, enabled) == .success else {
        CGCancelDisplayConfiguration(config)
        return false
    }
    guard CGCompleteDisplayConfiguration(config, .forSession) == .success else {
        CGCancelDisplayConfiguration(config)
        return false
    }
    return true
}

// MARK: - Keep awake

/// Holds a power-management assertion so the Mac and its displays don't sleep,
/// either indefinitely or for a set number of hours.
///
/// Deliberately session-only — it never survives a relaunch, so the machine can't
/// be left sleepless by a setting someone forgot about.
final class KeepAwake {
    static let shared = KeepAwake()
    static let maxHours: Double = 24

    // Two separate assertions: one keeps the Mac itself running, the other keeps the
    // screens lit. Blackout drops the second one so the displays can sleep while the
    // machine carries on working.
    private var systemAssertion = IOPMAssertionID(0)
    private var displayAssertion = IOPMAssertionID(0)
    private var holdingDisplay = false
    private var timer: Timer?
    private(set) var active = false
    /// When the session ends. Nil while active means no time limit.
    private(set) var expiry: Date?

    /// "Off", "No limit", or the time left — what the menu shows.
    var stateDescription: String {
        guard active else { return "Off" }
        guard let expiry else { return "No limit" }
        let seconds = max(0, Int(expiry.timeIntervalSinceNow.rounded(.up)))
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        if hours == 0 { return "\(max(1, minutes))m left" }
        return minutes == 0 ? "\(hours)h left" : "\(hours)h \(minutes)m left"
    }

    // Plain ASCII: this string is what `pmset -g assertions` prints.
    private static let reason = "DisplayWave: Keep Mac Awake"

    private static func hold(_ type: String, _ id: inout IOPMAssertionID) -> Bool {
        IOPMAssertionCreateWithName(type as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    reason as CFString, &id) == kIOReturnSuccess
    }

    func start(hours: Double?) {
        if !active {
            guard Self.hold("PreventUserIdleSystemSleep", &systemAssertion) else { return }
            active = true
        }
        updateDisplayHold()
        expiry = hours.map { Date(timeIntervalSinceNow: $0 * 3600) }
        rearm()
    }

    func stop() {
        guard active else { return }
        IOPMAssertionRelease(systemAssertion)
        active = false
        updateDisplayHold()
        expiry = nil
        rearm()
    }

    /// The screens are kept awake only while keep-awake is on and blackout is off.
    func updateDisplayHold() {
        let wanted = active && !Blackout.shared.active
        guard wanted != holdingDisplay else { return }
        if wanted {
            holdingDisplay = Self.hold("PreventUserIdleDisplaySleep", &displayAssertion)
        } else {
            IOPMAssertionRelease(displayAssertion)
            holdingDisplay = false
        }
    }

    /// Adds or removes time. Adding while off starts a timed session; removing the
    /// last of the time ends it. A session with no limit ignores adjustments —
    /// there is nothing to count down.
    func adjust(hours: Double) {
        guard active else {
            if hours > 0 { start(hours: hours) }
            return
        }
        guard let expiry else { return }
        let end = expiry.addingTimeInterval(hours * 3600)
        if end <= Date() {
            stop()
        } else {
            self.expiry = min(end, Date(timeIntervalSinceNow: Self.maxHours * 3600))
            rearm()
        }
    }

    /// Keeps a single timer aligned with the current expiry.
    private func rearm() {
        timer?.invalidate()
        timer = nil
        guard active, let expiry else { return }
        let t = Timer(fireAt: expiry, interval: 0, target: self,
                      selector: #selector(expired), userInfo: nil, repeats: false)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc private func expired() { stop() }
}

// MARK: - UI helpers

// Menu content is laid out top-down, which is much easier to reason about flipped.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
           color: NSColor = .labelColor, align: NSTextAlignment = .left) -> NSTextField {
    let f = NSTextField(labelWithString: text)
    f.font = .systemFont(ofSize: size, weight: weight)
    f.textColor = color
    f.alignment = align
    return f
}

// MARK: - Display card

// One self-contained panel per display: identity and current mode on top, then
// brightness and colour temperature, each with a slider and its own preset buttons.
final class DisplayCard: FlippedView {
    static let width: CGFloat = 320
    static let height: CGFloat = 190

    private let display: Display
    private let allModes: [CGDisplayMode]
    private weak var hostMenu: NSMenu?
    private let resolutionPopup = NSPopUpButton()
    private let refreshPopup = NSPopUpButton()

    // A monitor that answers DDC dims its own backlight, so it can go genuinely
    // dark; everything else can only darken the image the GPU sends it. That changes
    // how low brightness is allowed to go, so the scale is settled up front.
    private let brightnessScale: Scale
    private let warmthScale = Scale.warmth

    private let brightnessSlider = NSSlider()
    private let warmthSlider = NSSlider()
    private let brightnessReadout: NSTextField
    private let warmthReadout: NSTextField
    private let brightnessPresetControl: NSSegmentedControl
    private let warmthPresetControl: NSSegmentedControl

    init(display: Display, menu: NSMenu?, canPowerOff: Bool) {
        self.display = display
        self.allModes = displayModes(display.id)
        self.hostMenu = menu
        let hardware = Capabilities.shared.mode(for: display.name) == .hardware
        let brightnessScale = Scale.brightness(hardware: hardware)
        self.brightnessScale = brightnessScale
        let s = Store.shared[display.name]
        brightnessReadout = label(brightnessScale.describe(s.brightness), size: 11,
                                  color: .secondaryLabelColor, align: .right)
        warmthReadout = label(Scale.warmth.describe(s.kelvin), size: 11,
                              color: .secondaryLabelColor, align: .right)
        brightnessPresetControl = NSSegmentedControl(labels: brightnessScale.presets.map(brightnessScale.unit),
                                                     trackingMode: .selectOne, target: nil, action: nil)
        warmthPresetControl = NSSegmentedControl(labels: Scale.warmth.presets.map(Scale.warmth.unit),
                                                 trackingMode: .selectOne, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))

        let pad: CGFloat = 16
        let contentWidth = Self.width - pad * 2
        var y: CGFloat = 12

        let glyph = NSImageView(frame: NSRect(x: pad, y: y + 1, width: 16, height: 14))
        glyph.image = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
        glyph.contentTintColor = .labelColor
        addSubview(glyph)

        let name = label(display.name, size: 13, weight: .semibold)
        name.frame = NSRect(x: pad + 22, y: y, width: contentWidth - 50, height: 17)
        addSubview(name)

        let power = NSButton()
        power.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Turn display off")
        power.imagePosition = .imageOnly
        power.isBordered = false
        power.contentTintColor = canPowerOff ? .secondaryLabelColor : .tertiaryLabelColor
        power.isEnabled = canPowerOff
        power.toolTip = canPowerOff ? "Turn \(display.name) off" : "Can't turn off the last active display"
        power.target = self
        power.action = #selector(togglePower)
        power.frame = NSRect(x: Self.width - pad - 20, y: y - 1, width: 20, height: 20)
        addSubview(power)
        y += 18

        // Resolution and refresh rate — the same line that used to be read-only,
        // now directly changeable.
        setupModePopups(y: y, pad: pad)
        y += 26

        y = addControlGroup(title: hardware ? "Brightness" : "Brightness · software",
                            icon: hardware ? "sun.max.fill" : "sun.max", tint: .systemYellow,
                            tooltip: hardware
                                ? "Adjusts this monitor's backlight. Past the backlight's lowest useful setting, the image is dimmed as well so it can go darker still."
                                : "This monitor doesn't answer DDC, so the image is dimmed on the GPU instead of lowering the backlight",
                            scale: brightnessScale, value: s.brightness,
                            slider: brightnessSlider, readout: brightnessReadout,
                            action: #selector(brightnessChanged),
                            stepAction: #selector(brightnessStepped(_:)),
                            presets: brightnessPresetControl, presetAction: #selector(brightnessPresetPicked),
                            y: y, pad: pad, contentWidth: contentWidth)
        y += 10
        _ = addControlGroup(title: "Color temperature", icon: "sunset.fill", tint: .systemOrange,
                            tooltip: "The white the picture is shifted towards, in kelvin. \(Int(neutralKelvin))K is the monitor's own white point and leaves it alone; lower is warmer — 4200K warm white, 3400K halogen, 2700K incandescent, \(Int(warmestKelvin))K candlelight. Done on the GPU, so it works on any monitor.",
                            scale: warmthScale, value: s.kelvin,
                            slider: warmthSlider, readout: warmthReadout,
                            action: #selector(warmthChanged),
                            stepAction: #selector(warmthStepped(_:)),
                            presets: warmthPresetControl, presetAction: #selector(warmthPresetPicked),
                            y: y, pad: pad, contentWidth: contentWidth)
    }

    required init?(coder: NSCoder) { nil }

    // A subtle rounded panel behind each monitor's controls, so the cards read as
    // separate cards instead of one run-on column. labelColor adapts to the menu's
    // light or dark appearance.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.055).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 4), xRadius: 8, yRadius: 8).fill()
    }

    /// Two quiet dropdowns where the mode line used to be: one for resolution, one
    /// for refresh rate. They read like the old label until clicked.
    private func setupModePopups(y: CGFloat, pad: CGFloat) {
        for popup in [resolutionPopup, refreshPopup] {
            popup.isBordered = false
            popup.font = .systemFont(ofSize: 11)
            popup.target = self
        }

        for (w, h) in resolutionOptions(allModes) {
            resolutionPopup.addItem(withTitle: "\(w) × \(h)")
            resolutionPopup.lastItem?.representedObject = [w, h]
        }
        resolutionPopup.selectItem(withTitle: "\(display.width) × \(display.height)")
        resolutionPopup.action = #selector(resolutionPicked)
        resolutionPopup.toolTip = "Change this display's resolution"
        resolutionPopup.frame = NSRect(x: pad - 8, y: y - 3, width: 112, height: 20)
        addSubview(resolutionPopup)

        let rates = refreshOptions(allModes, width: display.width, height: display.height)
        for r in rates {
            refreshPopup.addItem(withTitle: "\(r) Hz")
            refreshPopup.lastItem?.representedObject = r
        }
        refreshPopup.selectItem(withTitle: "\(Int(display.refresh.rounded())) Hz")
        refreshPopup.action = #selector(refreshRatePicked)
        refreshPopup.toolTip = "Change this display's refresh rate"
        refreshPopup.frame = NSRect(x: pad + 116, y: y - 3, width: 68, height: 20)
        refreshPopup.isHidden = rates.isEmpty
        addSubview(refreshPopup)
    }

    /// Lays out a labelled control: caption row with the current value, the slider
    /// beneath it, and the preset buttons under that.
    private func addControlGroup(title: String, icon: String, tint: NSColor, tooltip: String,
                                 scale: Scale, value: Double,
                                 slider: NSSlider, readout: NSTextField,
                                 action: Selector, stepAction: Selector,
                                 presets: NSSegmentedControl, presetAction: Selector,
                                 y: CGFloat, pad: CGFloat, contentWidth: CGFloat) -> CGFloat {
        var y = y
        let iconView = NSImageView(frame: NSRect(x: pad, y: y + 1, width: 13, height: 13))
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
        iconView.contentTintColor = tint
        addSubview(iconView)

        let caption = label(title, size: 11, weight: .medium, color: .secondaryLabelColor)
        caption.frame = NSRect(x: pad + 18, y: y, width: contentWidth - 60, height: 14)
        caption.toolTip = tooltip
        iconView.toolTip = tooltip
        addSubview(caption)

        readout.frame = NSRect(x: pad + contentWidth - 42, y: y, width: 42, height: 14)
        addSubview(readout)
        y += 17

        // Tiny nudge buttons for fine adjustment without aiming at the slider. They
        // take exactly the width their labels need — "−100" is a good deal wider than
        // "−5" — and the slider gets whatever is left.
        let stepFont = NSFont.systemFont(ofSize: 10)
        let stepWidth = ceil(("−" + scale.stepLabel as NSString)
            .size(withAttributes: [.font: stepFont]).width) + 12
        let stepBlock = stepWidth * 2 + 2

        slider.minValue = scale.min
        slider.maxValue = scale.max
        slider.doubleValue = value
        slider.isContinuous = true
        slider.target = self
        slider.action = action
        slider.frame = NSRect(x: pad, y: y, width: contentWidth - stepBlock - 6, height: 19)
        addSubview(slider)

        for (i, tag) in [-1, 1].enumerated() {
            let button = NSButton(title: (tag < 0 ? "−" : "+") + scale.stepLabel,
                                  target: self, action: stepAction)
            button.tag = tag
            button.bezelStyle = .rounded
            button.controlSize = .mini
            button.font = stepFont
            button.frame = NSRect(x: pad + contentWidth - stepBlock + CGFloat(i) * (stepWidth + 2),
                                  y: y - 1, width: stepWidth, height: 18)
            addSubview(button)
        }
        y += 21

        presets.segmentDistribution = .fillEqually
        presets.controlSize = .small
        presets.font = .systemFont(ofSize: 10)
        presets.selectedSegmentBezelColor = tint.withAlphaComponent(0.55)
        presets.target = self
        presets.action = presetAction
        presets.selectedSegment = scale.presetIndex(value)
        presets.frame = NSRect(x: pad, y: y, width: contentWidth, height: 18)
        addSubview(presets)
        return y + 18
    }

    /// Pulls slider positions, readouts and preset highlighting back from the store,
    /// so a preset applied from the top of the menu is reflected in the cards below.
    func refreshFromStore() {
        let s = Store.shared[display.name]
        show(brightnessScale.snap(s.brightness), brightnessScale,
             brightnessSlider, brightnessReadout, brightnessPresetControl)
        show(warmthScale.snap(s.kelvin), warmthScale,
             warmthSlider, warmthReadout, warmthPresetControl)
    }

    // MARK: Actions

    /// Puts one value on screen in all three places it appears: the slider's
    /// position, the readout, and which preset button is lit.
    private func show(_ value: Double, _ scale: Scale, _ slider: NSSlider,
                      _ readout: NSTextField, _ presets: NSSegmentedControl) {
        slider.doubleValue = value
        readout.stringValue = scale.unit(value)
        presets.selectedSegment = scale.presetIndex(value)
    }

    private func commit(_ s: Settings) {
        Store.shared[display.name] = s
        // Touching a slider means the screens are wanted back.
        Blackout.shared.deactivate()
        apply(display)
    }

    /// Every brightness change funnels through here, whichever control caused it.
    /// Values are snapped to the scale first, so what's stored is exactly what the
    /// readout says and a preset lights up when the slider reaches it.
    private func setBrightness(_ value: Double) {
        var s = Store.shared[display.name]
        s.brightness = brightnessScale.snap(value)
        show(s.brightness, brightnessScale, brightnessSlider, brightnessReadout,
             brightnessPresetControl)
        commit(s)
    }

    private func setKelvin(_ value: Double) {
        var s = Store.shared[display.name]
        s.kelvin = warmthScale.snap(value)
        show(s.kelvin, warmthScale, warmthSlider, warmthReadout, warmthPresetControl)
        commit(s)
    }

    @objc private func brightnessChanged() { setBrightness(brightnessSlider.doubleValue) }

    @objc private func warmthChanged() { setKelvin(warmthSlider.doubleValue) }

    @objc private func brightnessStepped(_ sender: NSButton) {
        setBrightness(brightnessSlider.doubleValue + brightnessScale.step * Double(sender.tag))
    }

    @objc private func warmthStepped(_ sender: NSButton) {
        setKelvin(warmthSlider.doubleValue + warmthScale.step * Double(sender.tag))
    }

    @objc private func brightnessPresetPicked() {
        setBrightness(brightnessScale.presets[brightnessPresetControl.selectedSegment])
    }

    @objc private func warmthPresetPicked() {
        setKelvin(warmthScale.presets[warmthPresetControl.selectedSegment])
    }

    @objc private func resolutionPicked() {
        guard let dims = resolutionPopup.selectedItem?.representedObject as? [Int],
              dims.count == 2,
              let mode = bestMode(allModes, width: dims[0], height: dims[1],
                                  rate: display.refresh > 0 ? Int(display.refresh.rounded()) : nil)
        else { return }
        hostMenu?.cancelTracking()
        setMode(display.id, mode)
    }

    @objc private func refreshRatePicked() {
        guard let rate = refreshPopup.selectedItem?.representedObject as? Int,
              let mode = bestMode(allModes, width: display.width, height: display.height, rate: rate)
        else { return }
        hostMenu?.cancelTracking()
        setMode(display.id, mode)
    }

    @objc private func togglePower() {
        hostMenu?.cancelTracking()
        AppDelegate.shared?.setPower(id: display.id, name: display.name, on: false)
    }
}

// MARK: - Presets row

// One click restores every display to a saved look. Presets wrap onto extra rows
// rather than squeezing, so the labels stay readable however many there are.
final class PresetRow: FlippedView {
    private static let perRow = 3
    private var controls: [NSSegmentedControl] = []

    override init(frame: NSRect) {
        let presets = PresetStore.shared.presets
        let rows = stride(from: 0, to: max(presets.count, 1), by: Self.perRow).map {
            Array(presets[$0 ..< min($0 + Self.perRow, presets.count)])
        }
        super.init(frame: NSRect(x: 0, y: 0, width: DisplayCard.width,
                                 height: 25 + CGFloat(rows.count) * 26 + 6))
        let pad: CGFloat = 16
        let contentWidth = DisplayCard.width - pad * 2

        let title = label("Presets", size: 11, weight: .medium, color: .secondaryLabelColor)
        title.frame = NSRect(x: pad, y: 6, width: contentWidth, height: 14)
        addSubview(title)

        for (row, chunk) in rows.enumerated() where !chunk.isEmpty {
            let control = NSSegmentedControl(labels: chunk.map(\.name), trackingMode: .momentary,
                                             target: self, action: #selector(pick(_:)))
            control.segmentDistribution = .fillEqually
            // Tag carries the index of this row's first preset.
            control.tag = row * Self.perRow
            control.frame = NSRect(x: pad, y: 25 + CGFloat(row) * 26, width: contentWidth, height: 22)
            addSubview(control)
            controls.append(control)
        }
    }

    required init?(coder: NSCoder) { nil }

    @objc private func pick(_ sender: NSSegmentedControl) {
        let index = sender.tag + sender.selectedSegment
        guard PresetStore.shared.presets.indices.contains(index) else { return }
        applyPreset(PresetStore.shared.presets[index])
    }
}

// MARK: - Keep awake row

// Keep-awake with a duration: Off and Always at the ends, hour adjustments between.
// The readout counts down while the menu is open.
final class KeepAwakeRow: FlippedView {
    private static let steps: [Double] = [-5, -1, 1, 5]
    private let control: NSSegmentedControl
    private let readout: NSTextField
    private var ticker: Timer?

    override init(frame: NSRect) {
        control = NSSegmentedControl(
            labels: ["Off"] + Self.steps.map { $0 < 0 ? "−\(Int(-$0))h" : "+\(Int($0))h" } + ["Always"],
            trackingMode: .momentary, target: nil, action: nil)
        readout = label("", size: 11, color: .secondaryLabelColor, align: .right)
        super.init(frame: NSRect(x: 0, y: 0, width: DisplayCard.width, height: 54))
        let pad: CGFloat = 16
        let contentWidth = DisplayCard.width - pad * 2

        let icon = NSImageView(frame: NSRect(x: pad, y: 7, width: 13, height: 13))
        icon.image = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        addSubview(icon)

        let title = label("Keep Mac Awake", size: 11, weight: .medium, color: .secondaryLabelColor)
        title.frame = NSRect(x: pad + 18, y: 6, width: contentWidth - 100, height: 14)
        title.toolTip = "Stops the Mac and its displays from sleeping. Always runs until turned off or DisplayWave quits."
        addSubview(title)

        readout.frame = NSRect(x: pad + contentWidth - 82, y: 6, width: 82, height: 14)
        addSubview(readout)

        control.segmentDistribution = .fillEqually
        control.controlSize = .small
        control.font = .systemFont(ofSize: 10)
        control.target = self
        control.action = #selector(pick)
        control.frame = NSRect(x: pad, y: 25, width: contentWidth, height: 20)
        addSubview(control)

        refresh()
    }

    required init?(coder: NSCoder) { nil }

    // Tick only while the row is on screen, so an idle menu bar app stays idle.
    override func viewDidMoveToWindow() {
        ticker?.invalidate()
        guard window != nil else { ticker = nil; return }
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func refresh() {
        let awake = KeepAwake.shared
        readout.stringValue = awake.stateDescription
        readout.textColor = awake.active ? .labelColor : .secondaryLabelColor
    }

    @objc private func pick() {
        switch control.selectedSegment {
        case 0: KeepAwake.shared.stop()
        case control.segmentCount - 1: KeepAwake.shared.start(hours: nil)
        case let i: KeepAwake.shared.adjust(hours: Self.steps[i - 1])
        }
        refresh()
    }
}

// MARK: - Preset editor

// One row per preset: type to rename, Save to overwrite it with how the displays
// look right now, ✕ to delete. Everything saves immediately.
final class PresetEditorView: FlippedView, NSTextFieldDelegate {
    static let width: CGFloat = 420
    private static let rowHeight: CGFloat = 32
    private weak var hostWindow: NSWindow?

    init(window: NSWindow?) {
        self.hostWindow = window
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        reload()
    }

    required init?(coder: NSCoder) { nil }

    /// Rebuilds from scratch — presets can be added and removed, so the row count
    /// isn't fixed.
    private func reload() {
        subviews.forEach { $0.removeFromSuperview() }
        let presets = PresetStore.shared.presets
        let pad: CGFloat = 16
        let height = 44 + CGFloat(presets.count) * Self.rowHeight + 48
        setFrameSize(NSSize(width: Self.width, height: height))

        let heading = label("Save replaces a preset with how your displays look right now.",
                            size: 11, color: .secondaryLabelColor)
        heading.frame = NSRect(x: pad, y: 14, width: Self.width - pad * 2, height: 16)
        addSubview(heading)

        for (i, preset) in presets.enumerated() {
            let y = 44 + CGFloat(i) * Self.rowHeight

            let name = NSTextField(string: preset.name)
            name.font = .systemFont(ofSize: 12)
            name.tag = i
            name.delegate = self
            name.target = self
            name.action = #selector(renamed(_:))
            name.frame = NSRect(x: pad, y: y, width: 200, height: 22)
            addSubview(name)

            let detail = label(describe(preset), size: 10, color: .tertiaryLabelColor)
            detail.frame = NSRect(x: pad + 208, y: y + 4, width: 84, height: 14)
            addSubview(detail)

            let save = NSButton(title: "Save", target: self, action: #selector(updateFromCurrent(_:)))
            save.bezelStyle = .rounded
            save.controlSize = .small
            save.tag = i
            save.toolTip = "Replace \"\(preset.name)\" with how the displays look right now"
            save.frame = NSRect(x: Self.width - pad - 92, y: y, width: 56, height: 22)
            addSubview(save)

            let delete = NSButton(title: "", target: self, action: #selector(remove(_:)))
            delete.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Delete")
            delete.isBordered = false
            delete.contentTintColor = .tertiaryLabelColor
            delete.tag = i
            delete.toolTip = "Delete \"\(preset.name)\""
            delete.isEnabled = presets.count > 1
            delete.frame = NSRect(x: Self.width - pad - 24, y: y + 2, width: 20, height: 18)
            addSubview(delete)
        }

        let add = NSButton(title: "New from Current Settings", target: self, action: #selector(addNew))
        add.bezelStyle = .rounded
        add.controlSize = .small
        add.frame = NSRect(x: pad, y: height - 38, width: 200, height: 24)
        addSubview(add)

        let reset = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.frame = NSRect(x: Self.width - pad - 130, y: height - 38, width: 130, height: 24)
        addSubview(reset)

        hostWindow?.setContentSize(NSSize(width: Self.width, height: height))
    }

    /// "All displays" for a preset that applies everywhere, otherwise how many
    /// monitors it remembers.
    private func describe(_ preset: Preset) -> String {
        let named = preset.settings.keys.filter { $0 != Preset.anyDisplay }.count
        if named == 0 { return "All displays" }
        return named == 1 ? "1 display" : "\(named) displays"
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        renamed(field)
    }

    @objc private func renamed(_ sender: NSTextField) {
        PresetStore.shared.rename(index: sender.tag, to: sender.stringValue)
        reload()
    }

    @objc private func updateFromCurrent(_ sender: NSButton) {
        PresetStore.shared.updateFromCurrent(index: sender.tag)
        reload()
    }

    @objc private func remove(_ sender: NSButton) {
        PresetStore.shared.remove(index: sender.tag)
        reload()
    }

    @objc private func addNew() {
        PresetStore.shared.addFromCurrent(name: "New Preset")
        reload()
    }

    @objc private func restoreDefaults() {
        PresetStore.shared.resetToDefaults()
        reload()
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate?
    var statusItem: NSStatusItem!
    // Cards in the currently open menu, so a preset can update them in place.
    private var visibleCards: [DisplayCard] = []

    func refreshVisibleCards() {
        visibleCards.forEach { $0.refreshFromStore() }
    }

    /// The cards belong to the menu that was just torn down, so let go of them rather
    /// than keep pushing updates into views nobody can see.
    func menuDidClose(_ menu: NSMenu) {
        visibleCards.removeAll()
    }

    // A disconnected display disappears from the online list, so its ID has to be
    // remembered or there would be no way to reconnect it.
    private let offKey = "disconnectedDisplays"
    private var offDisplays: [String: CGDirectDisplayID] {
        get { (UserDefaults.standard.dictionary(forKey: offKey) as? [String: UInt32]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: offKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        applyAll()
        // Work out which monitors can dim their own backlight. This touches the DDC
        // channel, so it happens off the main thread and only for monitors we haven't
        // already classified.
        Capabilities.shared.sync(displays: onlineDisplays().filter(\.active)) {
            applyAll()
        }
        // macOS wipes gamma on display changes and on wake, and reconfigurations also
        // invalidate the cached DDC service handles — so re-attach those, then reapply.
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            // beginConfigurationFlag fires before the change lands; reapplying then
            // would just be overwritten by the change itself.
            if flags.contains(.beginConfigurationFlag) { return }
            Resync.schedule()
        }, nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            // Waking the Mac means someone is back at the desk; never wake to black.
            Blackout.shared.deactivate()
            // Displays come back at their own pace after a wake, so give them longer
            // than a plain reconfiguration would get.
            Resync.schedule(after: 2.0)
        }
    }

    /// Settings are written back lazily while sliders move; make sure the last of
    /// them reaches disk before the app goes away.
    func applicationWillTerminate(_ notification: Notification) {
        Store.shared.flush()
    }

    /// The wave-W from the logo, drawn as a template image: crisp at any backing
    /// scale, white in a dark menu bar and black in a light one.
    private static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let p = NSBezierPath()
            p.lineWidth = 1.7
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.move(to: NSPoint(x: 2.6, y: 4.6))
            p.curve(to: NSPoint(x: 5.6, y: 13.4),
                    controlPoint1: NSPoint(x: 3.6, y: 7.8), controlPoint2: NSPoint(x: 4.3, y: 11.4))
            p.curve(to: NSPoint(x: 9.0, y: 6.0),
                    controlPoint1: NSPoint(x: 6.9, y: 10.8), controlPoint2: NSPoint(x: 8.0, y: 8.4))
            p.curve(to: NSPoint(x: 12.4, y: 13.4),
                    controlPoint1: NSPoint(x: 10.0, y: 8.4), controlPoint2: NSPoint(x: 11.1, y: 10.8))
            p.curve(to: NSPoint(x: 15.4, y: 4.6),
                    controlPoint1: NSPoint(x: 13.7, y: 11.4), controlPoint2: NSPoint(x: 14.4, y: 7.8))
            NSColor.black.setStroke()
            p.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let online = onlineDisplays()
        let activeCount = online.filter(\.active).count

        // Presets first: the one-click action people reach for most often.
        if activeCount > 0 {
            let presetsItem = NSMenuItem()
            presetsItem.view = PresetRow(frame: .zero)
            menu.addItem(presetsItem)
            menu.addItem(.separator())
        }

        visibleCards.removeAll()
        for d in online where d.active {
            let card = DisplayCard(display: d, menu: menu, canPowerOff: activeCount > 1)
            visibleCards.append(card)
            let item = NSMenuItem()
            item.view = card
            menu.addItem(item)
        }
        // The card backgrounds separate the displays visually; one separator closes
        // the section.
        if activeCount > 0 { menu.addItem(.separator()) }

        // Displays we turned off no longer enumerate, so list them from what we saved.
        let stillOff = offDisplays.filter { entry in !online.contains { $0.id == entry.value } }
        if !stillOff.isEmpty {
            let header = NSMenuItem(title: "Turned off", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for (name, id) in stillOff.sorted(by: { $0.key < $1.key }) {
                let item = NSMenuItem(title: "  \(name)", action: #selector(turnOn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = id
                item.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
                item.toolTip = "Turn \(name) back on"
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let awake = NSMenuItem()
        awake.view = KeepAwakeRow(frame: .zero)
        menu.addItem(awake)

        let blackout = NSMenuItem(title: "Blackout", action: #selector(toggleBlackout), keyEquivalent: "")
        blackout.target = self
        blackout.state = Blackout.shared.active ? .on : .off
        blackout.image = NSImage(systemSymbolName: "moon.zzz.fill", accessibilityDescription: nil)
        blackout.toolTip = "Takes every display fully dark while the Mac keeps running — for leaving it working overnight. Press any key or click to bring the screens back exactly as they were."
        menu.addItem(blackout)
        menu.addItem(.separator())

        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.toolTip = "Launches DisplayWave automatically when you log in"
        menu.addItem(login)
        menu.addItem(.separator())

        let arrange = NSMenuItem(title: "Arrange Displays…", action: #selector(arrangeDisplays), keyEquivalent: "")
        arrange.target = self
        arrange.toolTip = "Opens macOS display settings, where displays can be arranged"
        menu.addItem(arrange)

        let editPresets = NSMenuItem(title: "Edit Presets…", action: #selector(openPresetEditor), keyEquivalent: "")
        editPresets.target = self
        editPresets.toolTip = "Save the current look as a preset, or rename and delete presets"
        menu.addItem(editPresets)
        menu.addItem(.separator())

        let resync = NSMenuItem(title: "Resync Monitors", action: #selector(recheckHardware), keyEquivalent: "")
        resync.target = self
        resync.toolTip = "Probes every monitor again — use after changing a cable, enabling DDC/CI in a monitor's menu, or if a monitor stops responding"
        menu.addItem(resync)

        let reset = NSMenuItem(title: "Reset All to Default", action: #selector(resetAll), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        menu.addItem(NSMenuItem(title: "Quit DisplayWave", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: Power

    func setPower(id: CGDirectDisplayID, name: String, on: Bool) {
        guard setDisplay(id, enabled: on) else {
            NSSound.beep()
            return
        }
        var off = offDisplays
        if on { off.removeValue(forKey: name) } else { off[name] = id }
        offDisplays = off
        if on {
            // The display needs a moment to come back before gamma will stick.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { resyncAndApply() }
        }
    }

    @objc private func turnOn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? CGDirectDisplayID else { return }
        setPower(id: id, name: sender.title.trimmingCharacters(in: .whitespaces), on: true)
    }

    @objc private func resetAll() {
        Store.shared.reset()
        // Also the way out of blackout for anyone who can't read the dimmed menu.
        Blackout.shared.deactivate()
        CGDisplayRestoreColorSyncSettings()
        applyAll()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
    }

    @objc private func toggleBlackout() {
        Blackout.shared.toggle()
    }

    @objc private func arrangeDisplays() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
    }

    private var presetEditor: NSWindow?

    @objc private func openPresetEditor() {
        // Rebuilt each time so it reflects the presets as they are now.
        presetEditor?.close()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PresetEditorView.width, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Presets"
        window.contentView = PresetEditorView(window: window)
        window.isReleasedWhenClosed = false
        window.center()
        presetEditor = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func recheckHardware() {
        Capabilities.shared.forget()
        invalidateDisplayCaches()
        // Clicking this closed the menu, and the cards — which say whether a monitor
        // drives its own backlight — are rebuilt from scratch on the next open.
        Capabilities.shared.sync(displays: onlineDisplays().filter(\.active)) {
            applyAll()
        }
    }
}

// `DisplayWave --preview <file.png>` renders the menu's custom views to an image so
// layout can be checked without opening the menu by hand, and the preset editor
// alongside it as `<file>-presets.png`. The views have to be in a real window in a
// running app before AppKit will draw them.
final class PreviewDelegate: NSObject, NSApplicationDelegate {
    private let path: String
    private var windows: [NSWindow] = []

    init(path: String) { self.path = path }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let rows: [NSView] = [PresetRow(frame: .zero)]
            + onlineDisplays().filter(\.active)
            .map { DisplayCard(display: $0, menu: nil, canPowerOff: true) }
            + [KeepAwakeRow(frame: .zero)]
        let height = rows.reduce(0) { $0 + $1.frame.height + 1 }

        let canvas = FlippedView(frame: NSRect(x: 0, y: 0, width: DisplayCard.width, height: height))
        var y: CGFloat = 0
        for row in rows {
            row.setFrameOrigin(NSPoint(x: 0, y: y))
            canvas.addSubview(row)
            y += row.frame.height + 1
        }

        let menuWindow = show(canvas)
        let editor = PresetEditorView(window: nil)
        let editorWindow = show(editor)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.capture(menuWindow, to: self.path)
            self.capture(editorWindow, to: (self.path as NSString).deletingPathExtension + "-presets.png")
            NSApp.terminate(nil)
        }
    }

    private func show(_ view: NSView) -> NSWindow {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.backgroundColor = .windowBackgroundColor
        window.setFrameOrigin(NSPoint(x: 60, y: 60))
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    private func capture(_ window: NSWindow, to path: String) {
        guard let view = window.contentView, let layer = view.layer else { return }
        let scale: CGFloat = 2
        let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        // The canvas is flipped, so undo that when rendering to the bitmap.
        ctx.cgContext.translateBy(x: 0, y: CGFloat(h))
        ctx.cgContext.scaleBy(x: scale, y: -scale)
        // Layer-backed controls are only captured by rendering the layer tree.
        layer.render(in: ctx.cgContext)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

let app = NSApplication.shared
let args = ProcessInfo.processInfo.arguments

if let i = args.firstIndex(of: "--preview"), i + 1 < args.count {
    let previewDelegate = PreviewDelegate(path: args[i + 1])
    app.delegate = previewDelegate
    app.setActivationPolicy(.regular)
    app.run()
} else {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
