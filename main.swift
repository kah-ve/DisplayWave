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
//              matters because plenty of monitors and adapters don't pass DDC at all.
//              Temperature is a real kelvin figure that drives the table, not a
//              slider position with a label on it.
//   Mode     — resolution and refresh rate, switched the same way System Settings
//              does it, from a submenu under each display's card. Layouts save the
//              modes and the arrangement of every display together.
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
    /// The product name — what the monitor calls itself, and not unique: two of the
    /// same model share it.
    let name: String
    /// What everything about this display is stored under. See `displayIdentity`.
    let key: String
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

/// Something saved under a name that can be recaptured from how the displays are
/// right now and kept in the defaults as a plain property list — a preset or a layout.
protocol Snapshot {
    var name: String { get set }
    /// One line for the editor saying what it covers.
    var detail: String { get }
    static func fromCurrent(name: String) -> Self
    init?(plist: [String: Any])
    var plist: [String: Any] { get }
}

/// A named snapshot of how the desk should look: what each monitor's brightness and
/// colour temperature should be. One click puts every display back to it.
struct Preset {
    /// Settings under this key apply to any display the preset doesn't name, so a
    /// preset still does something sensible on a monitor plugged in later.
    static let anyDisplay = "*"

    var name: String
    /// Keyed by `Display.key`.
    var settings: [String: Settings]

    func settings(for key: String) -> Settings? {
        settings[key] ?? settings[Preset.anyDisplay]
    }

    /// How many displays this preset names. An entry under a bare product name,
    /// left by an older version, isn't counted again once it's been adopted.
    var displayCount: Int {
        let keys = settings.keys.filter { $0 != Preset.anyDisplay }
        return keys.filter { k in !keys.contains { $0.hasPrefix(k + "#") } }.count
    }
}

extension Preset: Snapshot {
    /// Captures what every active display is set to right now.
    static func fromCurrent(name: String) -> Preset {
        let displays = onlineDisplays().filter(\.active)
        // Keys can still collide — two identical monitors that report no serial — and
        // that has to be survivable. They share one stored setting anyway.
        var settings = Dictionary(displays.map { ($0.key, Store.shared[$0.key]) },
                                  uniquingKeysWith: { first, _ in first })
        // Give unknown displays the first monitor's look rather than nothing.
        if let first = displays.first { settings[anyDisplay] = Store.shared[first.key] }
        return Preset(name: name, settings: settings)
    }

    /// "All displays" for a preset that applies everywhere, otherwise how many
    /// monitors it remembers.
    var detail: String {
        let named = displayCount
        if named == 0 { return "All displays" }
        return named == 1 ? "1 display" : "\(named) displays"
    }

    init?(plist entry: [String: Any]) {
        guard let name = entry["name"] as? String,
              let values = entry["settings"] as? [String: [Double]] else { return nil }
        self.init(name: name, settings: values.compactMapValues { v in
            v.count == 2 ? Settings(brightness: v[0], kelvin: migratedKelvin(v[1])) : nil
        })
    }

    var plist: [String: Any] {
        ["name": name, "settings": settings.mapValues { [$0.brightness, $0.kelvin] }]
    }
}

let defaultPresets = [
    Preset(name: "Day", settings: [Preset.anyDisplay: Settings(brightness: 1.0, kelvin: 6500)]),
    Preset(name: "Evening", settings: [Preset.anyDisplay: Settings(brightness: 0.70, kelvin: 4200)]),
    Preset(name: "Night", settings: [Preset.anyDisplay: Settings(brightness: 0.35, kelvin: 2700)]),
]

/// What the editor window sees of a list of snapshots, whatever kind they are.
protocol SnapshotList: AnyObject {
    var names: [String] { get }
    func detail(at index: Int) -> String
    /// Presets keep at least one, since an empty row would have nothing to click;
    /// layouts can all go.
    var minimumCount: Int { get }
    var canRestoreDefaults: Bool { get }
    func addFromCurrent(name: String)
    func updateFromCurrent(index: Int)
    func rename(index: Int, to name: String)
    func remove(index: Int)
    func resetToDefaults()
}

/// Saved snapshots in menu order. Editable via the editor window.
final class SnapshotStore<Item: Snapshot>: SnapshotList {
    private let key: String
    private let defaults: [Item]
    let minimumCount: Int
    private(set) var items: [Item]

    init(key: String, defaults: [Item], minimumCount: Int) {
        self.key = key
        self.defaults = defaults
        self.minimumCount = minimumCount
        items = defaults
        guard let raw = UserDefaults.standard.array(forKey: key) as? [[String: Any]] else { return }
        let loaded = raw.compactMap(Item.init(plist:))
        if !loaded.isEmpty { items = loaded }
    }

    private func save() {
        UserDefaults.standard.set(items.map(\.plist), forKey: key)
    }

    var names: [String] { items.map(\.name) }

    func detail(at index: Int) -> String {
        items.indices.contains(index) ? items[index].detail : ""
    }

    var canRestoreDefaults: Bool { !defaults.isEmpty }

    /// Names have to be distinct — they're how snapshots are told apart in the menu.
    private func uniqueName(_ wanted: String, excluding index: Int? = nil) -> String {
        let taken = items.enumerated()
            .filter { $0.offset != index }
            .map { $0.element.name.lowercased() }
        var name = wanted.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "Untitled" }
        var candidate = name, n = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(name) \(n)"
            n += 1
        }
        return candidate
    }

    func addFromCurrent(name: String) {
        items.append(Item.fromCurrent(name: uniqueName(name)))
        save()
    }

    /// Replaces a snapshot's contents with the way the displays are right now.
    func updateFromCurrent(index: Int) {
        guard items.indices.contains(index) else { return }
        items[index] = Item.fromCurrent(name: items[index].name)
        save()
    }

    func rename(index: Int, to name: String) {
        guard items.indices.contains(index) else { return }
        items[index].name = uniqueName(name, excluding: index)
        save()
    }

    func remove(index: Int) {
        guard items.indices.contains(index), items.count > minimumCount else { return }
        items.remove(at: index)
        save()
    }

    func resetToDefaults() {
        items = defaults
        UserDefaults.standard.removeObject(forKey: key)
    }
}

extension SnapshotStore where Item == Preset {
    /// The preset counterpart of `Store.adopt`.
    func adopt(_ key: String, from legacy: String) {
        var changed = false
        for i in items.indices where items[i].settings[key] == nil {
            guard let old = items[i].settings[legacy] else { continue }
            items[i].settings[key] = old
            changed = true
        }
        if changed { save() }
    }
}

let presetStore = SnapshotStore(key: "presets", defaults: defaultPresets, minimumCount: 1)

// MARK: - Layouts

/// Where one monitor sits in the arrangement, and the mode it runs in there.
struct Placement {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    /// Backing pixels across. The HiDPI mode and the plain one can share a point
    /// size, and this is what tells them apart.
    var pixelWidth: Int
    var refresh: Int
}

/// A named arrangement of the desk: where each monitor sits, which one is the main
/// display, and the resolution and refresh rate each runs at. Kept apart from
/// presets, which are about how the picture looks rather than where it goes.
struct Layout {
    var name: String
    /// Keyed by `Display.key`. Positions are in the global display space, where the
    /// main display is by definition the one at the origin — so saving positions
    /// saves which display is main as well.
    var placements: [String: Placement]
}

extension Layout: Snapshot {
    static func fromCurrent(name: String) -> Layout {
        var placements: [String: Placement] = [:]
        for d in onlineDisplays() where d.active {
            // A mirror takes another display's position and mode, so has none of
            // its own to keep. Two serial-less identical monitors share a key; the
            // first wins, as it does for presets.
            guard CGDisplayMirrorsDisplay(d.id) == kCGNullDirectDisplay,
                  placements[d.key] == nil,
                  let mode = CGDisplayCopyDisplayMode(d.id) else { continue }
            let origin = CGDisplayBounds(d.id).origin
            placements[d.key] = Placement(x: Int(origin.x), y: Int(origin.y),
                                          width: mode.width, height: mode.height,
                                          pixelWidth: mode.pixelWidth,
                                          refresh: Int(mode.refreshRate.rounded()))
        }
        return Layout(name: name, placements: placements)
    }

    var detail: String {
        placements.count == 1 ? "1 display" : "\(placements.count) displays"
    }

    init?(plist entry: [String: Any]) {
        guard let name = entry["name"] as? String,
              let values = entry["placements"] as? [String: [Int]] else { return nil }
        self.init(name: name, placements: values.compactMapValues { v in
            v.count == 6 ? Placement(x: v[0], y: v[1], width: v[2], height: v[3],
                                     pixelWidth: v[4], refresh: v[5]) : nil
        })
    }

    var plist: [String: Any] {
        ["name": name,
         "placements": placements.mapValues { [$0.x, $0.y, $0.width, $0.height, $0.pixelWidth, $0.refresh] }]
    }
}

let layoutStore = SnapshotStore<Layout>(key: "layouts", defaults: [], minimumCount: 0)

// MARK: - Display modes

// Anything derived from the display configuration is cached until that configuration
// changes, which is the only thing that can invalidate it. The menu is rebuilt from
// scratch every time it opens, and without this it re-derived all of it each time.
//
// Main thread only — everything that reads them builds its display list on the main
// thread before handing work off.
private var modeCache: [CGDirectDisplayID: [CGDisplayMode]] = [:]
private var identityCache: [CGDirectDisplayID: (name: String, key: String)] = [:]

func invalidateDisplayCaches() {
    modeCache.removeAll()
    identityCache.removeAll()
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

/// A mode a menu item would switch a display to.
final class ModeChoice {
    let display: CGDirectDisplayID
    let mode: CGDisplayMode
    init(display: CGDirectDisplayID, mode: CGDisplayMode) {
        self.display = display
        self.mode = mode
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

/// The mode a placement asks for on this display, or nil when it's already in it —
/// switching modes blanks the screen for a moment, so it isn't done for nothing.
/// The exact mode is used where the monitor still offers it; otherwise the nearest
/// one, chosen the way the resolution menu chooses.
private func mode(for placement: Placement, on display: Display) -> CGDisplayMode? {
    func matches(_ m: CGDisplayMode) -> Bool {
        m.width == placement.width && m.height == placement.height
            && m.pixelWidth == placement.pixelWidth
            && Int(m.refreshRate.rounded()) == placement.refresh
    }
    if let current = CGDisplayCopyDisplayMode(display.id), matches(current) { return nil }
    let modes = displayModes(display.id)
    return modes.first(where: matches)
        ?? bestMode(modes, width: placement.width, height: placement.height, rate: placement.refresh)
}

/// Puts every connected display the layout names back where it was saved and in
/// the mode it was saved in, as one configuration change — the way System Settings
/// applies an arrangement, so the screens rearrange once rather than once per
/// monitor. Displays the layout doesn't name stay put, and macOS nudges them aside
/// if anything now overlaps. Settings reapply from the reconfiguration callback.
func applyLayout(_ layout: Layout) {
    let present = onlineDisplays().filter(\.active).compactMap { d in
        layout.placements[d.key].map { (display: d, placement: $0) }
    }
    guard !present.isEmpty else { NSSound.beep(); return }

    // Positions are measured from the layout's main display. When that one isn't
    // plugged in, measure from the current main display instead, so a monitor going
    // missing doesn't hand the main role to whatever happens to land at the origin.
    let savedMainPresent = present.contains { $0.placement.x == 0 && $0.placement.y == 0 }
    let anchor = savedMainPresent ? nil
        : present.first { CGDisplayIsMain($0.display.id) != 0 }?.placement
    let dx = anchor?.x ?? 0, dy = anchor?.y ?? 0

    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
    for (display, placement) in present {
        let modeOK = mode(for: placement, on: display).map {
            CGConfigureDisplayWithDisplayMode(config, display.id, $0, nil) == .success
        } ?? true
        let originOK = CGConfigureDisplayOrigin(config, display.id, Int32(placement.x - dx),
                                                Int32(placement.y - dy)) == .success
        guard modeOK, originOK else {
            CGCancelDisplayConfiguration(config)
            diag.error("Layout \(layout.name, privacy: .public): couldn't configure \(display.name, privacy: .public)")
            NSSound.beep()
            return
        }
    }
    guard CGCompleteDisplayConfiguration(config, .permanently) == .success else {
        CGCancelDisplayConfiguration(config)
        diag.error("Layout \(layout.name, privacy: .public): configuration rejected")
        NSSound.beep()
        return
    }
    diag.log("Applied layout \(layout.name, privacy: .public) to \(present.count) displays")
}

// MARK: - Display enumeration

/// The monitor's product name, and the key its settings are stored under: the name
/// plus the EDID serial number, so two monitors of the same model keep separate
/// settings. Unlike the display ID, both survive reboots and replugging. A monitor
/// that reports no serial is keyed by its bare name — two of those still share,
/// there being nothing stable to tell them apart by.
///
/// Building the CoreDisplay dictionary this reads isn't free, and `onlineDisplays()`
/// asks for one per display every time it runs — several times over for a single
/// menu open — so the answer is kept until the configuration changes.
func displayIdentity(_ id: CGDirectDisplayID) -> (name: String, key: String) {
    if let cached = identityCache[id] { return cached }
    var name = CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)"
    var serial: Int64 = 0
    if let dict = CoreDisplay_DisplayCreateInfoDictionary(id)?.takeRetainedValue() as NSDictionary? {
        if let names = dict["DisplayProductName"] as? [String: String],
           let product = names["en_US"] ?? names.first?.value {
            name = product
        }
        serial = dict[kDisplaySerialNumber] as? Int64 ?? 0
    }
    let identity = (name: name, key: serial != 0 ? "\(name)#\(serial)" : name)
    identityCache[id] = identity
    return identity
}

/// The product name part of a display key.
func displayName(key: String) -> String {
    key.split(separator: "#", maxSplits: 1).first.map(String.init) ?? key
}

/// What each display is called on screen: its product name, unless another display
/// has the same one. Identical monitors are told apart by where they sit in the
/// arrangement — the thing a person can actually see — as Left/Right or Top/Bottom
/// for a pair, and numbered left to right beyond that.
func displayLabels(_ displays: [Display]) -> [CGDirectDisplayID: String] {
    var labels: [CGDirectDisplayID: String] = [:]
    for (name, group) in Dictionary(grouping: displays, by: \.name) {
        guard group.count > 1 else { labels[group[0].id] = name; continue }
        let ordered = group.map { (id: $0.id, at: CGDisplayBounds($0.id).origin) }
            .sorted { $0.at.x != $1.at.x ? $0.at.x < $1.at.x : $0.at.y < $1.at.y }
        let places = ordered.count != 2 ? ordered.indices.map { "\($0 + 1)" }
            : ordered[0].at.x != ordered[1].at.x ? ["Left", "Right"] : ["Top", "Bottom"]
        for (d, place) in zip(ordered, places) { labels[d.id] = "\(name) · \(place)" }
    }
    return labels
}

func onlineDisplays() -> [Display] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }
    return ids.prefix(Int(count)).map { id in
        let mode = CGDisplayCopyDisplayMode(id)
        let identity = displayIdentity(id)
        return Display(id: id,
                       name: identity.name,
                       key: identity.key,
                       active: CGDisplayIsActive(id) != 0,
                       width: mode?.width ?? 0,
                       height: mode?.height ?? 0,
                       refresh: mode?.refreshRate ?? 0)
    }
}

// MARK: - Settings store

final class Store {
    static let shared = Store()
    private let settingsKey = "displaySettings"
    private var cache: [String: Settings] = [:]

    private init() {
        if let raw = UserDefaults.standard.dictionary(forKey: settingsKey) as? [String: [Double]] {
            for (key, v) in raw where v.count == 2 {
                cache[key] = Settings(brightness: v[0], kelvin: migratedKelvin(v[1]))
            }
        }
    }

    subscript(key: String) -> Settings {
        get { cache[key] ?? Settings() }
        set {
            cache[key] = newValue
            scheduleFlush()
        }
    }

    /// Starts a display off from what was saved under its bare product name, if it
    /// has nothing of its own yet. The old entry is kept, so an identical monitor
    /// that turns up later starts from it too.
    func adopt(_ key: String, from legacy: String) {
        guard cache[key] == nil, let old = cache[legacy] else { return }
        self[key] = old
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
        UserDefaults.standard.set(cache.mapValues { [$0.brightness, $0.kelvin] }, forKey: settingsKey)
    }

    func reset() {
        pendingFlush?.cancel()
        pendingFlush = nil
        cache = [:]
        UserDefaults.standard.removeObject(forKey: settingsKey)
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

/// Takes every display dark without letting go of it — for leaving the Mac working
/// overnight without lighting up the room. The picture goes to black on the GPU, and
/// a monitor that answers DDC has its backlight zeroed too. The displays stay awake
/// and connected the whole time: no OS display sleep, so nothing disconnects, no windows move, and Keep Mac
/// Awake carries on holding its assertions instead of fighting this one.
///
/// It used to work the other way — `pmset displaysleepnow` — but forced display
/// sleep is a one-shot the rest of the system happily undoes, drops monitors into
/// deep standby or off the bus entirely, and is exactly the thing keep-awake exists
/// to prevent. Darkness made from the picture and the backlight needs none of it.
///
/// Nor does it switch panels off over DDC (power mode, VCP D6). Monitors implement
/// that inconsistently, and some go into standby and ignore the command to come back
/// until their power button is pressed. The backlight at zero behind a black picture
/// is nearly as dark and always comes back.
///
/// The normal brightness floors exist so a screen can't go dark enough to hide the
/// menu; this deliberately steps past them, so it is session-only and quitting or
/// restarting always brings the screens back.
final class Blackout {
    static let shared = Blackout()
    /// All the way off: backlight at zero and the image fully black. A monitor with
    /// no DDC can only be blacked on the GPU, so its backlight keeps the faint glow
    /// an LCD showing black always has — the physics of the panel, not a bug.
    static let level = 0.0

    /// Input within this long of switching blackout on doesn't count as the escape —
    /// otherwise the very click that turned it on would undo it instantly.
    private static let grace: TimeInterval = 1.5

    private(set) var active = false
    private var startedAt = Date()
    private var watchdog: Timer?

    func toggle() {
        if active {
            deactivate()
        } else {
            active = true
            // The screens must not sleep now: their darkness is their own, and OS
            // display sleep would only knock the monitors off the bus.
            KeepAwake.shared.updateDisplayHold()
            watchForInput()
            applyAll()
            diag.log("Blackout on")
        }
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
        applyAll()
        diag.log("Blackout off")
        // A monitor can be slow to take its backlight back up, or settle on its own
        // idea of brightness; apply everything again once it has.
        Resync.schedule(after: 2.0)
    }

    /// Quit is one of blackout's promised ways out, and macOS reverts the gamma on
    /// its own when the process dies — but a backlight zeroed over DDC stays at zero
    /// until someone says otherwise, so say otherwise before the process goes away.
    /// Synchronous: the queues that normally carry DDC writes die with the app.
    func restoreForQuit() {
        guard active else { return }
        active = false
        watchdog?.invalidate()
        watchdog = nil
        for d in onlineDisplays() where d.active {
            guard Capabilities.shared.mode(for: d.key) == .hardware,
                  let service = Capabilities.shared.service(for: d.key) else { continue }
            Backlight.shared.restoreForQuit(display: d, service: service,
                                            brightness: Store.shared[d.key].brightness,
                                            ceiling: Capabilities.shared.maxLuminance(for: d.key))
        }
    }

    /// Watches for a keypress or a click without an event tap — asking the system
    /// how long input has been idle needs no permissions, where monitoring events
    /// does. Both count, so there are two ways back from a black screen. Mouse
    /// *movement* is ignored on purpose: a nudged desk shouldn't light the room —
    /// and since the screens are dark rather than asleep, it can't wake them anyway.
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
    let s = Store.shared[display.key]
    let hardwareService = Capabilities.shared.mode(for: display.key) == .hardware
        ? Capabilities.shared.service(for: display.key) : nil
    let ceiling = Capabilities.shared.maxLuminance(for: display.key)

    if Blackout.shared.active {
        // Backlight as low as it goes and gamma past its usual floor. As warm as it
        // goes too, for whatever glow remains — blue light is the part that keeps
        // you awake.
        if let service = hardwareService {
            Backlight.shared.set(percent: Blackout.level, display: display, service: service,
                                 ceiling: ceiling)
        }
        applyGamma(display.id, brightness: Blackout.level, kelvin: warmestKelvin,
                   floor: Blackout.level)
        return
    }

    if let service = hardwareService {
        Backlight.shared.set(percent: s.brightness, display: display, service: service,
                             ceiling: ceiling)
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
        guard let settings = preset.settings(for: display.key) else { continue }
        Store.shared[display.key] = settings
        apply(display)
    }
    AppDelegate.shared?.refreshVisibleCards()
}

/// Settings used to be stored under the product name alone, which identical monitors
/// share. A display seen under its own key for the first time starts from whatever
/// was saved under its name. Done per display as each one appears, rather than once
/// at upgrade, so a monitor that wasn't connected then still keeps its settings.
func adoptLegacySettings(_ displays: [Display]) {
    for d in displays where d.key != d.name {
        Store.shared.adopt(d.key, from: d.name)
        presetStore.adopt(d.key, from: d.name)
    }
}

/// Brings everything back in line after a display reconfiguration: drops the caches
/// that the configuration invalidated, re-resolves DDC handles (the old ones are
/// dead), probes anything newly plugged in, then reapplies every setting.
func resyncAndApply() {
    invalidateDisplayCaches()
    logModeChanges(onlineDisplays())
    adoptLegacySettings(onlineDisplays())
    Capabilities.shared.sync(displays: onlineDisplays().filter(\.active)) {
        applyAll()
    }
}

/// What each display was running at last resync, so a mode that changed underneath
/// us — a refresh rate that dropped after a wake or a replug — shows up in the log.
private var lastModes: [String: String] = [:]

private func logModeChanges(_ displays: [Display]) {
    for d in displays where d.active {
        let now = d.modeDescription
        if let before = lastModes[d.key], before != now {
            diag.log("\(d.name, privacy: .public) changed mode: \(before, privacy: .public) → \(now, privacy: .public)")
        }
        lastModes[d.key] = now
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
            diag.log("Resyncing")
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
    // screens from sleeping. Blackout holds the second one too — its darkness is the
    // app's own doing, and OS display sleep would drop the monitors into deep
    // standby or disconnect them outright.
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

    /// The screens are held awake while keep-awake is on, and during blackout too:
    /// a blacked-out display is dark by its own doing and has to stay connected,
    /// which display sleep is not compatible with. Holding off display sleep also
    /// keeps the Mac from idle-sleeping, which is what blackout's "the Mac keeps
    /// working" promise rests on when keep-awake itself is off.
    func updateDisplayHold() {
        let wanted = active || Blackout.shared.active
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
    static let height: CGFloat = 164

    private let display: Display
    private weak var hostMenu: NSMenu?

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

    /// `title` is what the card is headed with — see `displayLabels`.
    init(display: Display, title: String, menu: NSMenu?, canPowerOff: Bool) {
        self.display = display
        self.hostMenu = menu
        let hardware = Capabilities.shared.mode(for: display.key) == .hardware
        let brightnessScale = Scale.brightness(hardware: hardware)
        self.brightnessScale = brightnessScale
        let s = Store.shared[display.key]
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

        let name = label(title, size: 13, weight: .semibold)
        name.frame = NSRect(x: pad + 22, y: y, width: contentWidth - 50, height: 17)
        addSubview(name)

        let power = NSButton()
        power.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Turn display off")
        power.imagePosition = .imageOnly
        power.isBordered = false
        power.contentTintColor = canPowerOff ? .secondaryLabelColor : .tertiaryLabelColor
        power.isEnabled = canPowerOff
        power.toolTip = canPowerOff ? "Turn \(title) off" : "Can't turn off the last active display"
        power.target = self
        power.action = #selector(togglePower)
        power.frame = NSRect(x: Self.width - pad - 20, y: y - 1, width: 20, height: 20)
        addSubview(power)
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
        let s = Store.shared[display.key]
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
        Store.shared[display.key] = s
        // Touching a slider means the screens are wanted back.
        Blackout.shared.deactivate()
        apply(display)
    }

    /// Every brightness change funnels through here, whichever control caused it.
    /// Values are snapped to the scale first, so what's stored is exactly what the
    /// readout says and a preset lights up when the slider reaches it.
    private func setBrightness(_ value: Double) {
        var s = Store.shared[display.key]
        s.brightness = brightnessScale.snap(value)
        show(s.brightness, brightnessScale, brightnessSlider, brightnessReadout,
             brightnessPresetControl)
        commit(s)
    }

    private func setKelvin(_ value: Double) {
        var s = Store.shared[display.key]
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

    @objc private func togglePower() {
        hostMenu?.cancelTracking()
        AppDelegate.shared?.setPower(id: display.id, key: display.key, on: false)
    }
}

// MARK: - Snapshot rows

// One click puts the desk back to something saved — a preset or a layout. They wrap
// onto extra rows rather than squeezing, so the labels stay readable however many
// there are. With nothing saved yet the row offers to save the current state, so the
// feature can be found from the menu itself.
final class SnapshotRow: FlippedView {
    private static let perRow = 3
    private let pick: (Int) -> Void
    private let saveFirst: () -> Void

    init(title: String, names: [String], emptyTitle: String,
         pick: @escaping (Int) -> Void, saveFirst: @escaping () -> Void) {
        self.pick = pick
        self.saveFirst = saveFirst
        let rows = stride(from: 0, to: max(names.count, 1), by: Self.perRow).map {
            Array(names[$0 ..< min($0 + Self.perRow, names.count)])
        }
        super.init(frame: NSRect(x: 0, y: 0, width: DisplayCard.width,
                                 height: 25 + CGFloat(rows.count) * 26 + 6))
        let pad: CGFloat = 16
        let contentWidth = DisplayCard.width - pad * 2

        let heading = label(title, size: 11, weight: .medium, color: .secondaryLabelColor)
        heading.frame = NSRect(x: pad, y: 6, width: contentWidth, height: 14)
        addSubview(heading)

        guard !names.isEmpty else {
            let save = NSButton(title: emptyTitle, target: self, action: #selector(saveCurrent))
            save.bezelStyle = .rounded
            save.frame = NSRect(x: pad, y: 25, width: contentWidth, height: 22)
            addSubview(save)
            return
        }
        for (row, chunk) in rows.enumerated() {
            let control = NSSegmentedControl(labels: chunk, trackingMode: .momentary,
                                             target: self, action: #selector(picked(_:)))
            control.segmentDistribution = .fillEqually
            // Tag carries the index of this row's first entry.
            control.tag = row * Self.perRow
            control.frame = NSRect(x: pad, y: 25 + CGFloat(row) * 26, width: contentWidth, height: 22)
            addSubview(control)
        }
    }

    required init?(coder: NSCoder) { nil }

    @objc private func picked(_ sender: NSSegmentedControl) {
        pick(sender.tag + sender.selectedSegment)
    }

    @objc private func saveCurrent() { saveFirst() }
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

// MARK: - Snapshot editor

/// How the editor talks about what it's editing.
struct EditorWording {
    /// "Preset" or "Layout".
    let noun: String
    /// What "the way things are now" means for this kind: the look or the arrangement.
    let current: String
    let newButton: String

    static let presets = EditorWording(noun: "Preset", current: "how your displays look",
                                       newButton: "New from Current Settings")
    static let layouts = EditorWording(noun: "Layout", current: "where your displays are",
                                       newButton: "New from Current Arrangement")
}

// One row per preset or layout: type to rename, Save to overwrite it with how the
// displays are right now, ✕ to delete. Everything saves immediately.
final class SnapshotEditorView: FlippedView, NSTextFieldDelegate {
    static let width: CGFloat = 420
    private static let rowHeight: CGFloat = 32
    private weak var hostWindow: NSWindow?
    private let list: SnapshotList
    private let wording: EditorWording

    init(list: SnapshotList, wording: EditorWording, window: NSWindow?) {
        self.list = list
        self.wording = wording
        self.hostWindow = window
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        reload()
    }

    required init?(coder: NSCoder) { nil }

    /// Rebuilds from scratch — entries can be added and removed, so the row count
    /// isn't fixed.
    private func reload() {
        subviews.forEach { $0.removeFromSuperview() }
        let names = list.names
        let pad: CGFloat = 16
        let height = 44 + CGFloat(names.count) * Self.rowHeight + 48
        setFrameSize(NSSize(width: Self.width, height: height))

        let heading = label("Save replaces a \(wording.noun.lowercased()) with \(wording.current) right now.",
                            size: 11, color: .secondaryLabelColor)
        heading.frame = NSRect(x: pad, y: 14, width: Self.width - pad * 2, height: 16)
        addSubview(heading)

        for (i, entry) in names.enumerated() {
            let y = 44 + CGFloat(i) * Self.rowHeight

            let name = NSTextField(string: entry)
            name.font = .systemFont(ofSize: 12)
            name.tag = i
            name.delegate = self
            name.target = self
            name.action = #selector(renamed(_:))
            name.frame = NSRect(x: pad, y: y, width: 200, height: 22)
            addSubview(name)

            let detail = label(list.detail(at: i), size: 10, color: .tertiaryLabelColor)
            detail.frame = NSRect(x: pad + 208, y: y + 4, width: 84, height: 14)
            addSubview(detail)

            let save = NSButton(title: "Save", target: self, action: #selector(updateFromCurrent(_:)))
            save.bezelStyle = .rounded
            save.controlSize = .small
            save.tag = i
            save.toolTip = "Replace \"\(entry)\" with \(wording.current) right now"
            save.frame = NSRect(x: Self.width - pad - 92, y: y, width: 56, height: 22)
            addSubview(save)

            let delete = NSButton(title: "", target: self, action: #selector(remove(_:)))
            delete.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Delete")
            delete.isBordered = false
            delete.contentTintColor = .tertiaryLabelColor
            delete.tag = i
            delete.toolTip = "Delete \"\(entry)\""
            delete.isEnabled = names.count > list.minimumCount
            delete.frame = NSRect(x: Self.width - pad - 24, y: y + 2, width: 20, height: 18)
            addSubview(delete)
        }

        let add = NSButton(title: wording.newButton, target: self, action: #selector(addNew))
        add.bezelStyle = .rounded
        add.controlSize = .small
        add.frame = NSRect(x: pad, y: height - 38, width: 200, height: 24)
        addSubview(add)

        let reset = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.frame = NSRect(x: Self.width - pad - 130, y: height - 38, width: 130, height: 24)
        reset.isHidden = !list.canRestoreDefaults
        addSubview(reset)

        hostWindow?.setContentSize(NSSize(width: Self.width, height: height))
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        renamed(field)
    }

    @objc private func renamed(_ sender: NSTextField) {
        list.rename(index: sender.tag, to: sender.stringValue)
        reload()
    }

    @objc private func updateFromCurrent(_ sender: NSButton) {
        list.updateFromCurrent(index: sender.tag)
        reload()
    }

    @objc private func remove(_ sender: NSButton) {
        list.remove(index: sender.tag)
        reload()
    }

    @objc private func addNew() {
        list.addFromCurrent(name: "New \(wording.noun)")
        reload()
    }

    @objc private func restoreDefaults() {
        list.resetToDefaults()
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
    // remembered or there would be no way to reconnect it. Keyed by display key;
    // older versions keyed it by name, which reads back the same way.
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

        let startup = onlineDisplays().filter(\.active)
            .map { "\($0.name) \($0.modeDescription)" }.joined(separator: ", ")
        diag.log("Started with \(startup, privacy: .public)")
        adoptLegacySettings(onlineDisplays())
        applyAll()
        // Work out which monitors can dim their own backlight. This touches the DDC
        // channel, so it happens off the main thread and only for monitors we haven't
        // already classified.
        Capabilities.shared.sync(displays: onlineDisplays().filter(\.active)) {
            applyAll()
        }
        // macOS wipes gamma on display changes and on wake, and reconfigurations also
        // invalidate the cached DDC service handles — so re-attach those, then reapply.
        CGDisplayRegisterReconfigurationCallback({ id, flags, _ in
            // beginConfigurationFlag fires before the change lands; reapplying then
            // would just be overwritten by the change itself.
            if flags.contains(.beginConfigurationFlag) { return }
            diag.debug("Reconfigured display \(id), flags \(flags.rawValue)")
            Resync.schedule()
        }, nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            // Waking the Mac means someone is back at the desk; never wake to black.
            Blackout.shared.deactivate()
            // Displays come back at their own pace after a wake, so give them longer
            // than a plain reconfiguration would get.
            diag.log("Mac woke")
            Resync.schedule(after: 2.0)
        }
        // Screens can sleep and wake on their own while the Mac stays up, and coming
        // back into the session after a lock or a user switch is much the same — both
        // can leave gamma wiped and DDC handles stale without any reconfiguration to
        // say so.
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { note in
                diag.log("\(note.name.rawValue, privacy: .public)")
                Resync.schedule(after: 2.0)
            }
        }
    }

    /// Settings are written back lazily while sliders move; make sure the last of
    /// them reaches disk before the app goes away. And if the app dies mid-blackout,
    /// backlights zeroed over DDC have to be turned back up — gamma reverts by
    /// itself, the backlight doesn't.
    func applicationWillTerminate(_ notification: Notification) {
        Blackout.shared.restoreForQuit()
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
            presetsItem.view = SnapshotRow(
                title: "Presets", names: presetStore.names, emptyTitle: "Save Current Look",
                pick: { i in
                    guard presetStore.items.indices.contains(i) else { return }
                    applyPreset(presetStore.items[i])
                },
                saveFirst: { presetStore.addFromCurrent(name: "Preset") })
            menu.addItem(presetsItem)
        }
        // An arrangement only means something with more than one screen in it.
        if activeCount > 1 {
            let layoutsItem = NSMenuItem()
            layoutsItem.view = SnapshotRow(
                title: "Layouts", names: layoutStore.names, emptyTitle: "Save Current Arrangement",
                pick: { [weak menu] i in
                    guard layoutStore.items.indices.contains(i) else { return }
                    // The screens are about to move; the open menu would be left
                    // hanging where they used to be.
                    menu?.cancelTracking()
                    applyLayout(layoutStore.items[i])
                },
                saveFirst: { [weak menu] in
                    menu?.cancelTracking()
                    layoutStore.addFromCurrent(name: "Layout 1")
                })
            menu.addItem(layoutsItem)
        }
        if activeCount > 0 { menu.addItem(.separator()) }

        visibleCards.removeAll()
        let labels = displayLabels(online.filter(\.active))
        for d in online where d.active {
            let card = DisplayCard(display: d, title: labels[d.id] ?? d.name, menu: menu,
                                   canPowerOff: activeCount > 1)
            visibleCards.append(card)
            let item = NSMenuItem()
            item.view = card
            menu.addItem(item)
            menu.addItem(modeItem(for: d))
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
            let offNames = stillOff.keys.map { displayName(key: $0) }
            for (key, id) in stillOff.sorted(by: { $0.key < $1.key }) {
                // Where a display sits means nothing once it's off, so identical ones
                // are told apart by serial number instead.
                var name = displayName(key: key)
                if key != name, offNames.filter({ $0 == name }).count > 1 {
                    name += " · S/N \(key.dropFirst(name.count + 1))"
                }
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
        blackout.toolTip = "Takes every display dark while the Mac keeps running — for leaving it working overnight. The monitors stay connected, so windows don't move. Press any key or click to bring the screens back exactly as they were."
        // A tooltip only shows after a hover, so say what it does where it can be seen.
        if #available(macOS 14.4, *) {
            blackout.subtitle = "Screens dark, Mac stays on · key or click to undo"
        }
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

        let editLayouts = NSMenuItem(title: "Edit Layouts…", action: #selector(openLayoutEditor), keyEquivalent: "")
        editLayouts.target = self
        editLayouts.toolTip = "Save where your displays are and the resolution each runs at, or rename and delete layouts"
        menu.addItem(editLayouts)
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

    /// `key` is only needed to turn a display off; one being turned back on is found
    /// by its ID.
    func setPower(id: CGDirectDisplayID, key: String? = nil, on: Bool) {
        guard setDisplay(id, enabled: on) else {
            NSSound.beep()
            return
        }
        var off = offDisplays
        if on { off = off.filter { $0.value != id } } else if let key { off[key] = id }
        offDisplays = off
        if on {
            // The display needs a moment to come back before gamma will stick.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { resyncAndApply() }
        }
    }

    @objc private func turnOn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? CGDirectDisplayID else { return }
        setPower(id: id, on: true)
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

    private var editorWindow: NSWindow?

    @objc private func openPresetEditor() {
        openEditor(list: presetStore, wording: .presets, title: "Presets")
    }

    @objc private func openLayoutEditor() {
        openEditor(list: layoutStore, wording: .layouts, title: "Layouts")
    }

    private func openEditor(list: SnapshotList, wording: EditorWording, title: String) {
        // Rebuilt each time so it reflects the list as it is now.
        editorWindow?.close()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SnapshotEditorView.width, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = title
        window.contentView = SnapshotEditorView(list: list, wording: wording, window: window)
        window.isReleasedWhenClosed = false
        window.center()
        editorWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Display modes

    /// Resolution and refresh rate as a native submenu under each card. They used to
    /// be pop-up buttons inside the card, but a pop-up can't open its own menu while
    /// the status menu is tracking, so they never responded to a click.
    private func modeItem(for display: Display) -> NSMenuItem {
        let item = NSMenuItem(title: display.modeDescription, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "rectangle.expand.vertical", accessibilityDescription: nil)
        item.toolTip = "Change this display's resolution and refresh rate"
        let modes = displayModes(display.id)
        guard !modes.isEmpty else { return item }
        let submenu = NSMenu()
        let currentRate = display.refresh > 0 ? Int(display.refresh.rounded()) : nil

        submenu.addItem(sectionHeader("Resolution"))
        for (w, h) in resolutionOptions(modes) {
            let option = NSMenuItem(title: "\(w) × \(h)", action: #selector(pickMode(_:)), keyEquivalent: "")
            option.target = self
            option.state = w == display.width && h == display.height ? .on : .off
            option.representedObject = bestMode(modes, width: w, height: h, rate: currentRate)
                .map { ModeChoice(display: display.id, mode: $0) }
            submenu.addItem(option)
        }

        let rates = refreshOptions(modes, width: display.width, height: display.height)
        if !rates.isEmpty {
            submenu.addItem(.separator())
            submenu.addItem(sectionHeader("Refresh Rate"))
            for rate in rates {
                let option = NSMenuItem(title: "\(rate) Hz", action: #selector(pickMode(_:)), keyEquivalent: "")
                option.target = self
                option.state = rate == currentRate ? .on : .off
                option.representedObject = bestMode(modes, width: display.width, height: display.height, rate: rate)
                    .map { ModeChoice(display: display.id, mode: $0) }
                submenu.addItem(option)
            }
        }
        item.submenu = submenu
        return item
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14, *) { return .sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func pickMode(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ModeChoice else { return }
        diag.log("Mode change on display \(choice.display): \(choice.mode.width)×\(choice.mode.height) @ \(Int(choice.mode.refreshRate.rounded())) Hz")
        setMode(choice.display, choice.mode)
    }

    @objc private func recheckHardware() {
        diag.log("Resync Monitors chosen")
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
        let active = onlineDisplays().filter(\.active)
        adoptLegacySettings(active)
        let labels = displayLabels(active)
        let rows: [NSView] = [SnapshotRow(title: "Presets", names: presetStore.names, emptyTitle: "",
                                          pick: { _ in }, saveFirst: {}),
                              SnapshotRow(title: "Layouts", names: layoutStore.names,
                                          emptyTitle: "Save Current Arrangement",
                                          pick: { _ in }, saveFirst: {})]
            + active.map { DisplayCard(display: $0, title: labels[$0.id] ?? $0.name,
                                       menu: nil, canPowerOff: true) }
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
        let editor = SnapshotEditorView(list: presetStore, wording: .presets, window: nil)
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
