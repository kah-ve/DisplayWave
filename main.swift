import AppKit
import CoreGraphics
import Foundation

// DisplayWave — menu bar control for external monitors.
//
//   Power    — connects/disconnects the display at the OS level via the private
//              CGSConfigureDisplayEnabled SPI. The monitor loses signal and enters
//              standby on its own, so this needs no DDC support from the monitor.
//   Brightness / warmth
//            — applied through the GPU's gamma transfer table rather than by asking
//              the monitor to change its own settings. Also works without DDC, which
//              matters because most monitors on this desk don't answer DDC at all.
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

let brightnessPresets: [Double] = [0.25, 0.50, 0.75, 1.0]
let warmthPresets: [Double] = [0.0, 0.25, 0.50, 0.75, 1.0]

// One-click combinations applied to every display at once.
struct Scene {
    let name: String
    let brightness: Double
    let warmth: Double
}

let scenes = [
    Scene(name: "Day", brightness: 1.0, warmth: 0.0),
    Scene(name: "Evening", brightness: 0.70, warmth: 0.40),
    Scene(name: "Night", brightness: 0.40, warmth: 0.80),
]

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
func applyGamma(_ id: CGDirectDisplayID, _ s: Settings) {
    let b = Float(max(0.15, min(1.0, s.brightness)))
    let w = Float(max(0.0, min(1.0, s.warmth)))
    CGSetDisplayTransferByFormula(id,
                                  0, b, 1.0,
                                  0, b * (1.0 - 0.18 * w), 1.0,
                                  0, b * (1.0 - 0.45 * w), 1.0)
}

func applyAll() {
    for d in onlineDisplays() where d.active {
        applyGamma(d.id, Store.shared[d.name])
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
    static let height: CGFloat = 186

    private let display: Display
    private weak var hostMenu: NSMenu?

    private let brightnessSlider = NSSlider()
    private let warmthSlider = NSSlider()
    private let brightnessReadout: NSTextField
    private let warmthReadout: NSTextField
    private let brightnessPresetControl: NSSegmentedControl
    private let warmthPresetControl: NSSegmentedControl

    init(display: Display, menu: NSMenu?, canPowerOff: Bool) {
        self.display = display
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

        let name = label(display.name, size: 13, weight: .semibold)
        name.frame = NSRect(x: pad, y: y, width: contentWidth - 28, height: 17)
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

        let mode = label(display.modeDescription, size: 11, color: .secondaryLabelColor)
        mode.frame = NSRect(x: pad, y: y, width: contentWidth, height: 14)
        addSubview(mode)
        y += 22

        y = addControlGroup(title: "Brightness", icon: "sun.max",
                            slider: brightnessSlider, minValue: 0.15, value: s.brightness,
                            readout: brightnessReadout, action: #selector(brightnessChanged),
                            presets: brightnessPresetControl, presetAction: #selector(brightnessPresetPicked),
                            presetValues: brightnessPresets, current: s.brightness,
                            y: y, pad: pad, contentWidth: contentWidth)
        y += 10
        _ = addControlGroup(title: "Warmth", icon: "moon.fill",
                            slider: warmthSlider, minValue: 0.0, value: s.warmth,
                            readout: warmthReadout, action: #selector(warmthChanged),
                            presets: warmthPresetControl, presetAction: #selector(warmthPresetPicked),
                            presetValues: warmthPresets, current: s.warmth,
                            y: y, pad: pad, contentWidth: contentWidth)
    }

    required init?(coder: NSCoder) { nil }

    /// Lays out a labelled control: caption row with the current value, the slider
    /// beneath it, and the preset buttons under that.
    private func addControlGroup(title: String, icon: String, slider: NSSlider,
                                 minValue: Double, value: Double, readout: NSTextField,
                                 action: Selector, presets: NSSegmentedControl,
                                 presetAction: Selector, presetValues: [Double], current: Double,
                                 y: CGFloat, pad: CGFloat, contentWidth: CGFloat) -> CGFloat {
        var y = y
        let iconView = NSImageView(frame: NSRect(x: pad, y: y + 1, width: 13, height: 13))
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
        iconView.contentTintColor = .secondaryLabelColor
        addSubview(iconView)

        let caption = label(title, size: 11, weight: .medium, color: .secondaryLabelColor)
        caption.frame = NSRect(x: pad + 18, y: y, width: contentWidth - 60, height: 14)
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
        slider.frame = NSRect(x: pad, y: y, width: contentWidth, height: 19)
        addSubview(slider)
        y += 21

        presets.segmentDistribution = .fillEqually
        presets.controlSize = .small
        presets.font = .systemFont(ofSize: 10)
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
        applyGamma(display.id, s)
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
        control = NSSegmentedControl(labels: scenes.map(\.name), trackingMode: .momentary,
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
        let scene = scenes[control.selectedSegment]
        for d in onlineDisplays() where d.active {
            var s = Store.shared[d.name]
            s.brightness = scene.brightness
            s.warmth = scene.warmth
            Store.shared[d.name] = s
            applyGamma(d.id, s)
        }
        AppDelegate.shared?.refreshVisibleCards()
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
        statusItem.button?.image = NSImage(systemSymbolName: "moon.stars", accessibilityDescription: "DisplayWave")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        applyAll()
        // macOS wipes gamma on display changes and on wake, so reapply afterwards.
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            // beginConfigurationFlag fires before the change lands; reapplying then
            // would just be overwritten by the change itself.
            if flags.contains(.beginConfigurationFlag) { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { applyAll() }
        }, nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { applyAll() }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let online = onlineDisplays()
        let activeCount = online.filter(\.active).count

        visibleCards.removeAll()
        for d in online where d.active {
            let card = DisplayCard(display: d, menu: menu, canPowerOff: activeCount > 1)
            visibleCards.append(card)
            let item = NSMenuItem()
            item.view = card
            menu.addItem(item)
            menu.addItem(.separator())
        }

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

        if activeCount > 0 {
            let scenesItem = NSMenuItem()
            scenesItem.view = SceneRow(frame: .zero)
            menu.addItem(scenesItem)
            menu.addItem(.separator())
        }

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
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { applyAll() }
        }
    }

    @objc private func turnOn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? CGDirectDisplayID else { return }
        setPower(id: id, name: sender.title.trimmingCharacters(in: .whitespaces), on: true)
    }

    @objc private func resetAll() {
        Store.shared.reset()
        CGDisplayRestoreColorSyncSettings()
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
        let rows: [NSView] = onlineDisplays().filter(\.active)
            .map { DisplayCard(display: $0, menu: nil, canPowerOff: true) }
            + [SceneRow(frame: .zero)]
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
