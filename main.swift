import AppKit
import CoreGraphics
import Foundation
import ServiceManagement

// DisplayWave — menu bar control for external monitors.
//
//   Power    — connects/disconnects the display at the OS level via the private
//              CGSConfigureDisplayEnabled SPI. The monitor loses signal and enters
//              standby on its own, so this needs no DDC support from the monitor.
//   Brightness / warmth
//            — applied through the GPU's gamma transfer table rather than by asking
//              the monitor to change its own settings. Also works without DDC, which
//              matters because most monitors on this desk don't answer DDC at all.
//   Mode     — resolution and refresh rate, switched the same way System Settings
//              does it, from dropdowns on each display's card.
//
// macOS resets gamma whenever the display configuration changes or the machine wakes,
// so settings are reapplied from a reconfiguration callback.

// MARK: - Model

struct Settings {
    var brightness: Double = 1.0
    var warmth: Double = 0.0
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

let brightnessPresets: [Double] = [0.35, 0.50, 0.75, 1.0]
let warmthPresets: [Double] = [0.0, 0.25, 0.50, 0.75, 1.0]

// One-click combinations applied to every display at once.
struct Scene {
    let name: String
    let brightness: Double
    let warmth: Double
}

let defaultScenes = [
    Scene(name: "Day", brightness: 1.0, warmth: 0.0),
    Scene(name: "Evening", brightness: 0.70, warmth: 0.40),
    Scene(name: "Night", brightness: 0.35, warmth: 0.80),
]

/// Scene values are editable via "Edit Scenes…"; edits are stored as overrides on
/// the defaults, so resetting is just removing the overrides.
final class SceneStore {
    static let shared = SceneStore()
    private let key = "scenes"
    private(set) var scenes: [Scene] = defaultScenes

    private init() {
        if let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] {
            scenes = defaultScenes.map { s in
                guard let v = raw[s.name], v.count == 2 else { return s }
                return Scene(name: s.name, brightness: v[0], warmth: v[1])
            }
        }
    }

    func update(index: Int, brightness: Double, warmth: Double) {
        scenes[index] = Scene(name: scenes[index].name, brightness: brightness, warmth: warmth)
        let raw = Dictionary(uniqueKeysWithValues: scenes.map { ($0.name, [$0.brightness, $0.warmth]) })
        UserDefaults.standard.set(raw, forKey: key)
    }

    func reset() {
        scenes = defaultScenes
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - Display modes

/// Every mode the monitor advertises that macOS considers usable for a desktop,
/// including HiDPI variants of the same point size.
func displayModes(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
    let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue!] as CFDictionary
    let all = CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode] ?? []
    return all.filter { $0.isUsableForDesktopGUI() }
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

func displayName(_ id: CGDirectDisplayID) -> String {
    if let dict = CoreDisplay_DisplayCreateInfoDictionary(id)?.takeRetainedValue() as NSDictionary?,
       let names = dict["DisplayProductName"] as? [String: String],
       let name = names["en_US"] ?? names.first?.value {
        return name
    }
    return CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)"
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
                cache[name] = Settings(brightness: v[0], warmth: v[1])
            }
        }
    }

    subscript(name: String) -> Settings {
        get { cache[name] ?? Settings() }
        set {
            cache[name] = newValue
            UserDefaults.standard.set(cache.mapValues { [$0.brightness, $0.warmth] }, forKey: key)
        }
    }

    func reset() {
        cache = [:]
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - Applying settings

// Brightness scales the whole output; warmth pulls down green and blue so what's
// left skews red. The brightness floor keeps a screen from going fully black, which
// would leave no way to see the menu that brings it back.
func applyGamma(_ id: CGDirectDisplayID, brightness: Double, warmth: Double) {
    let b = Float(max(0.15, min(1.0, brightness)))
    let w = Float(max(0.0, min(1.0, warmth)))
    CGSetDisplayTransferByFormula(id,
                                  0, b, 1.0,
                                  0, b * (1.0 - 0.18 * w), 1.0,
                                  0, b * (1.0 - 0.45 * w), 1.0)
}

/// Applies a display's settings using whichever brightness mechanism it supports.
/// On a monitor that answers DDC the backlight does the dimming and gamma is left at
/// full brightness, so the two never stack into a doubly-dark picture.
func apply(_ display: Display) {
    let s = Store.shared[display.name]
    if Capabilities.shared.mode(for: display.name) == .hardware,
       let service = Capabilities.shared.service(for: display.name) {
        Backlight.shared.set(percent: s.brightness, id: display.id, name: display.name, service: service)
        applyGamma(display.id, brightness: 1.0, warmth: s.warmth)
    } else {
        applyGamma(display.id, brightness: s.brightness, warmth: s.warmth)
    }
}

func applyAll() {
    for d in onlineDisplays() where d.active { apply(d) }
}

/// Refreshes the DDC service handles first, then reapplies — for after any display
/// reconfiguration, which invalidates the old handles.
func resyncAndApply() {
    Capabilities.shared.reattachServices(displays: onlineDisplays().filter(\.active)) {
        applyAll()
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

/// Holds a power-management assertion so the Mac and its displays don't sleep.
/// Deliberately session-only — it never survives a relaunch, so the machine can't
/// be left sleepless by a setting someone forgot about.
final class KeepAwake {
    static let shared = KeepAwake()
    private var assertion = IOPMAssertionID(0)
    private(set) var active = false

    func toggle() {
        if active {
            IOPMAssertionRelease(assertion)
            active = false
        } else {
            active = IOPMAssertionCreateWithName(
                "PreventUserIdleDisplaySleep" as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "DisplayWave — Keep Mac Awake" as CFString,
                &assertion) == kIOReturnSuccess
        }
    }
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

func percentString(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

// MARK: - Display card

// One self-contained panel per display: identity and current mode on top, then
// brightness and warmth, each with a slider and its own preset buttons.
final class DisplayCard: FlippedView {
    static let width: CGFloat = 320
    static let height: CGFloat = 190

    private let display: Display
    private let allModes: [CGDisplayMode]
    private weak var hostMenu: NSMenu?
    private let resolutionPopup = NSPopUpButton()
    private let refreshPopup = NSPopUpButton()

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
        let s = Store.shared[display.name]
        brightnessReadout = label(percentString(s.brightness), size: 11, color: .secondaryLabelColor, align: .right)
        warmthReadout = label(percentString(s.warmth), size: 11, color: .secondaryLabelColor, align: .right)
        brightnessPresetControl = NSSegmentedControl(labels: brightnessPresets.map { percentString($0) },
                                                     trackingMode: .selectOne, target: nil, action: nil)
        warmthPresetControl = NSSegmentedControl(labels: warmthPresets.map { percentString($0) },
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

        // A monitor that answers DDC dims its own backlight, so it can go genuinely
        // dark; everything else can only darken the image the GPU sends it.
        let hardware = Capabilities.shared.mode(for: display.name) == .hardware
        y = addControlGroup(title: hardware ? "Brightness" : "Brightness · software",
                            icon: hardware ? "sun.max.fill" : "sun.max", tint: .systemYellow,
                            tooltip: hardware
                                ? "Adjusts this monitor's backlight"
                                : "This monitor doesn't answer DDC, so the image is dimmed on the GPU instead of lowering the backlight",
                            slider: brightnessSlider, minValue: hardware ? 0.05 : 0.15, value: s.brightness,
                            readout: brightnessReadout, action: #selector(brightnessChanged),
                            stepAction: #selector(brightnessStepped(_:)),
                            presets: brightnessPresetControl, presetAction: #selector(brightnessPresetPicked),
                            presetValues: brightnessPresets, current: s.brightness,
                            y: y, pad: pad, contentWidth: contentWidth)
        y += 10
        _ = addControlGroup(title: "Warmth", icon: "sunset.fill", tint: .systemOrange,
                            tooltip: "Shifts the picture warmer by reducing blue on the GPU",
                            slider: warmthSlider, minValue: 0.0, value: s.warmth,
                            readout: warmthReadout, action: #selector(warmthChanged),
                            stepAction: #selector(warmthStepped(_:)),
                            presets: warmthPresetControl, presetAction: #selector(warmthPresetPicked),
                            presetValues: warmthPresets, current: s.warmth,
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
                                 slider: NSSlider,
                                 minValue: Double, value: Double, readout: NSTextField,
                                 action: Selector, stepAction: Selector, presets: NSSegmentedControl,
                                 presetAction: Selector, presetValues: [Double], current: Double,
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

        slider.minValue = minValue
        slider.maxValue = 1.0
        slider.doubleValue = value
        slider.isContinuous = true
        slider.target = self
        slider.action = action
        slider.frame = NSRect(x: pad, y: y, width: contentWidth - 62, height: 19)
        addSubview(slider)

        // Tiny nudge buttons for fine adjustment without aiming at the slider.
        for (i, (tag, title)) in [(-1, "−5"), (1, "+5")].enumerated() {
            let button = NSButton(title: title, target: self, action: stepAction)
            button.tag = tag
            button.bezelStyle = .rounded
            button.controlSize = .mini
            button.font = .systemFont(ofSize: 10)
            button.frame = NSRect(x: pad + contentWidth - 56 + CGFloat(i) * 29, y: y - 1,
                                  width: 27, height: 18)
            addSubview(button)
        }
        y += 21

        presets.segmentDistribution = .fillEqually
        presets.controlSize = .small
        presets.font = .systemFont(ofSize: 10)
        presets.selectedSegmentBezelColor = tint.withAlphaComponent(0.55)
        presets.target = self
        presets.action = presetAction
        presets.selectedSegment = presetValues.firstIndex { abs($0 - current) < 0.005 } ?? -1
        presets.frame = NSRect(x: pad, y: y, width: contentWidth, height: 18)
        addSubview(presets)
        return y + 18
    }

    /// Pulls slider positions, readouts and preset highlighting back from the store,
    /// so a scene applied from the bottom of the menu is reflected in the cards above.
    func refreshFromStore() {
        let s = Store.shared[display.name]
        brightnessSlider.doubleValue = s.brightness
        warmthSlider.doubleValue = s.warmth
        brightnessReadout.stringValue = percentString(s.brightness)
        warmthReadout.stringValue = percentString(s.warmth)
        syncPresets(brightnessPresetControl, values: brightnessPresets, to: s.brightness)
        syncPresets(warmthPresetControl, values: warmthPresets, to: s.warmth)
    }

    // MARK: Actions

    private func commit(_ s: Settings) {
        Store.shared[display.name] = s
        apply(display)
    }

    private func syncPresets(_ control: NSSegmentedControl, values: [Double], to value: Double) {
        control.selectedSegment = values.firstIndex { abs($0 - value) < 0.005 } ?? -1
    }

    @objc private func brightnessChanged() {
        var s = Store.shared[display.name]
        s.brightness = brightnessSlider.doubleValue
        brightnessReadout.stringValue = percentString(s.brightness)
        syncPresets(brightnessPresetControl, values: brightnessPresets, to: s.brightness)
        commit(s)
    }

    @objc private func warmthChanged() {
        var s = Store.shared[display.name]
        s.warmth = warmthSlider.doubleValue
        warmthReadout.stringValue = percentString(s.warmth)
        syncPresets(warmthPresetControl, values: warmthPresets, to: s.warmth)
        commit(s)
    }

    @objc private func brightnessStepped(_ sender: NSButton) {
        brightnessSlider.doubleValue = min(1, max(brightnessSlider.minValue,
                                                  brightnessSlider.doubleValue + 0.05 * Double(sender.tag)))
        brightnessChanged()
    }

    @objc private func warmthStepped(_ sender: NSButton) {
        warmthSlider.doubleValue = min(1, max(0, warmthSlider.doubleValue + 0.05 * Double(sender.tag)))
        warmthChanged()
    }

    @objc private func brightnessPresetPicked() {
        let v = brightnessPresets[brightnessPresetControl.selectedSegment]
        var s = Store.shared[display.name]
        s.brightness = v
        brightnessSlider.doubleValue = v
        brightnessReadout.stringValue = percentString(v)
        commit(s)
    }

    @objc private func warmthPresetPicked() {
        let v = warmthPresets[warmthPresetControl.selectedSegment]
        var s = Store.shared[display.name]
        s.warmth = v
        warmthSlider.doubleValue = v
        warmthReadout.stringValue = percentString(v)
        commit(s)
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

// MARK: - Scenes row

// One click sets both brightness and warmth on every display.
final class SceneRow: FlippedView {
    private let control: NSSegmentedControl

    override init(frame: NSRect) {
        control = NSSegmentedControl(labels: SceneStore.shared.scenes.map(\.name), trackingMode: .momentary,
                                     target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: DisplayCard.width, height: 54))
        let pad: CGFloat = 16
        let contentWidth = DisplayCard.width - pad * 2

        let title = label("All Displays", size: 11, weight: .medium, color: .secondaryLabelColor)
        title.frame = NSRect(x: pad, y: 6, width: contentWidth, height: 14)
        addSubview(title)

        control.segmentDistribution = .fillEqually
        control.target = self
        control.action = #selector(pick)
        control.frame = NSRect(x: pad, y: 25, width: contentWidth, height: 22)
        addSubview(control)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func pick() {
        let scene = SceneStore.shared.scenes[control.selectedSegment]
        for d in onlineDisplays() where d.active {
            var s = Store.shared[d.name]
            s.brightness = scene.brightness
            s.warmth = scene.warmth
            Store.shared[d.name] = s
            apply(d)
        }
        AppDelegate.shared?.refreshVisibleCards()
    }
}

// MARK: - Scene editor

// A small window for tuning what each scene means. Changes save as they're made;
// they take effect the next time a scene is clicked.
final class SceneEditorView: FlippedView {
    private var brightnessSliders: [NSSlider] = []
    private var warmthSliders: [NSSlider] = []
    private var brightnessReadouts: [NSTextField] = []
    private var warmthReadouts: [NSTextField] = []

    init() {
        let width: CGFloat = 380
        let sceneCount = SceneStore.shared.scenes.count
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 16 + CGFloat(sceneCount) * 88 + 40))
        let pad: CGFloat = 16

        for (i, scene) in SceneStore.shared.scenes.enumerated() {
            let y0 = 16 + CGFloat(i) * 88

            let name = label(scene.name, size: 13, weight: .semibold)
            name.frame = NSRect(x: pad, y: y0, width: 200, height: 17)
            addSubview(name)

            addRow(title: "Brightness", value: scene.brightness, minValue: 0.15,
                   y: y0 + 22, pad: pad, width: width, tag: i,
                   sliders: &brightnessSliders, readouts: &brightnessReadouts)
            addRow(title: "Warmth", value: scene.warmth, minValue: 0.0,
                   y: y0 + 46, pad: pad, width: width, tag: i,
                   sliders: &warmthSliders, readouts: &warmthReadouts)
        }

        let hint = label("Scenes apply to every display at once", size: 10, color: .tertiaryLabelColor)
        hint.frame = NSRect(x: pad, y: frame.height - 32, width: 210, height: 14)
        addSubview(hint)

        let reset = NSButton(title: "Reset Scenes", target: self, action: #selector(resetScenes))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.frame = NSRect(x: width - pad - 110, y: frame.height - 38, width: 110, height: 24)
        addSubview(reset)
    }

    required init?(coder: NSCoder) { nil }

    private func addRow(title: String, value: Double, minValue: Double, y: CGFloat,
                        pad: CGFloat, width: CGFloat, tag: Int,
                        sliders: inout [NSSlider], readouts: inout [NSTextField]) {
        let caption = label(title, size: 11, color: .secondaryLabelColor)
        caption.frame = NSRect(x: pad, y: y + 2, width: 70, height: 14)
        addSubview(caption)

        let slider = NSSlider()
        slider.minValue = minValue
        slider.maxValue = 1.0
        slider.doubleValue = value
        slider.isContinuous = true
        slider.tag = tag
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.frame = NSRect(x: pad + 76, y: y, width: width - pad * 2 - 76 - 46, height: 19)
        addSubview(slider)
        sliders.append(slider)

        let readout = label(percentString(value), size: 11, color: .secondaryLabelColor, align: .right)
        readout.frame = NSRect(x: width - pad - 42, y: y + 2, width: 42, height: 14)
        addSubview(readout)
        readouts.append(readout)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let i = sender.tag
        SceneStore.shared.update(index: i,
                                 brightness: brightnessSliders[i].doubleValue,
                                 warmth: warmthSliders[i].doubleValue)
        brightnessReadouts[i].stringValue = percentString(brightnessSliders[i].doubleValue)
        warmthReadouts[i].stringValue = percentString(warmthSliders[i].doubleValue)
    }

    @objc private func resetScenes() {
        SceneStore.shared.reset()
        for (i, scene) in SceneStore.shared.scenes.enumerated() {
            brightnessSliders[i].doubleValue = scene.brightness
            warmthSliders[i].doubleValue = scene.warmth
            brightnessReadouts[i].stringValue = percentString(scene.brightness)
            warmthReadouts[i].stringValue = percentString(scene.warmth)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate?
    var statusItem: NSStatusItem!
    // Cards in the currently open menu, so a scene can update them in place.
    private var visibleCards: [DisplayCard] = []

    func refreshVisibleCards() {
        visibleCards.forEach { $0.refreshFromStore() }
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
        // The wave-W mark; the moon symbol is the fallback if the resource is missing
        // (e.g. running the bare binary outside the bundle).
        if let path = Bundle.main.path(forResource: "MenuIcon", ofType: "png"),
           let icon = NSImage(contentsOfFile: path) {
            icon.size = NSSize(width: 18, height: 18)
            statusItem.button?.image = icon
        } else {
            statusItem.button?.image = NSImage(systemSymbolName: "moon.stars", accessibilityDescription: "DisplayWave")
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        applyAll()
        // Work out which monitors can dim their own backlight. This touches the DDC
        // channel, so it happens off the main thread and only for monitors we haven't
        // already classified.
        Capabilities.shared.probeUnknown(displays: onlineDisplays().filter(\.active)) {
            applyAll()
        }
        // macOS wipes gamma on display changes and on wake, and reconfigurations also
        // invalidate the cached DDC service handles — so re-attach those, then reapply.
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            // beginConfigurationFlag fires before the change lands; reapplying then
            // would just be overwritten by the change itself.
            if flags.contains(.beginConfigurationFlag) { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { resyncAndApply() }
        }, nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { resyncAndApply() }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let online = onlineDisplays()
        let activeCount = online.filter(\.active).count

        // Scenes first: the one-click action people reach for most often.
        if activeCount > 0 {
            let scenesItem = NSMenuItem()
            scenesItem.view = SceneRow(frame: .zero)
            menu.addItem(scenesItem)
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

        let awake = NSMenuItem(title: "Keep Mac Awake", action: #selector(toggleKeepAwake), keyEquivalent: "")
        awake.target = self
        awake.state = KeepAwake.shared.active ? .on : .off
        awake.image = NSImage(systemSymbolName: KeepAwake.shared.active ? "cup.and.saucer.fill" : "cup.and.saucer",
                              accessibilityDescription: nil)
        awake.toolTip = "Stops the Mac and its displays from sleeping until this is turned off or DisplayWave quits"
        menu.addItem(awake)

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

        let editScenes = NSMenuItem(title: "Edit Scenes…", action: #selector(openSceneEditor), keyEquivalent: "")
        editScenes.target = self
        editScenes.toolTip = "Change what Day, Evening and Night set brightness and warmth to"
        menu.addItem(editScenes)
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
        CGDisplayRestoreColorSyncSettings()
        applyAll()
    }

    @objc private func toggleKeepAwake() {
        KeepAwake.shared.toggle()
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

    @objc private func arrangeDisplays() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
    }

    private var sceneEditor: NSWindow?

    @objc private func openSceneEditor() {
        if sceneEditor == nil {
            let view = SceneEditorView()
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.frame.size),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Edit Scenes"
            window.contentView = view
            window.isReleasedWhenClosed = false
            window.center()
            sceneEditor = window
        }
        NSApp.activate(ignoringOtherApps: true)
        sceneEditor?.makeKeyAndOrderFront(nil)
    }

    @objc private func recheckHardware() {
        Capabilities.shared.forget()
        Capabilities.shared.probeUnknown(displays: onlineDisplays().filter(\.active)) {
            applyAll()
        }
    }
}

// `DisplayWave --preview <file.png>` renders the menu's custom views to an image so
// layout can be checked without opening the menu by hand. The views have to be in a
// real window in a running app before AppKit will draw them.
final class PreviewDelegate: NSObject, NSApplicationDelegate {
    private let path: String
    private var window: NSWindow?

    init(path: String) { self.path = path }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let rows: [NSView] = [SceneRow(frame: .zero)]
            + onlineDisplays().filter(\.active)
            .map { DisplayCard(display: $0, menu: nil, canPowerOff: true) }
        let height = rows.reduce(0) { $0 + $1.frame.height + 1 }

        let canvas = FlippedView(frame: NSRect(x: 0, y: 0, width: DisplayCard.width, height: height))
        var y: CGFloat = 0
        for row in rows {
            row.setFrameOrigin(NSPoint(x: 0, y: y))
            canvas.addSubview(row)
            y += row.frame.height + 1
        }

        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let window = NSWindow(contentRect: canvas.bounds, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = canvas
        window.backgroundColor = .windowBackgroundColor
        window.setFrameOrigin(NSPoint(x: 60, y: 60))
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if let view = window.contentView, let layer = view.layer {
                let scale: CGFloat = 2
                let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
                if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                              isPlanar: false, colorSpaceName: .deviceRGB,
                                              bytesPerRow: 0, bitsPerPixel: 0),
                   let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                    // The canvas is flipped, so undo that when rendering to the bitmap.
                    ctx.cgContext.translateBy(x: 0, y: CGFloat(h))
                    ctx.cgContext.scaleBy(x: scale, y: -scale)
                    // Layer-backed controls are only captured by rendering the layer tree.
                    layer.render(in: ctx.cgContext)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: self.path))
                    }
                }
            }
            NSApp.terminate(nil)
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
