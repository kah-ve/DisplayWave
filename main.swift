import AppKit
import CoreGraphics
import Foundation

// A single menu for controlling every display:
//
//   Power    — connects/disconnects the display at the OS level via the private
//              CGSConfigureDisplayEnabled SPI. The monitor loses signal and enters
//              standby on its own, so this needs no DDC support from the monitor.
//   Brightness / warmth
//            — applied through the display's gamma transfer table, which is handled
//              by the GPU rather than the monitor. This also works without DDC, which
//              matters here because only one of the three monitors answers DDC at all.
//
// macOS resets gamma whenever the display configuration changes or the machine wakes,
// so settings are reapplied from a reconfiguration callback.

struct Settings {
    var brightness: Double = 1.0
    var warmth: Double = 0.0
}

struct Display {
    let id: CGDirectDisplayID
    let name: String
    let active: Bool
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
    return ids.prefix(Int(count)).map {
        Display(id: $0, name: displayName($0), active: CGDisplayIsActive($0) != 0)
    }
}

// MARK: - Settings store

final class Store {
    static let shared = Store()
    private let key = "displaySettings"
    private var cache: [String: Settings]

    private init() {
        cache = [:]
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
            let raw = cache.mapValues { [$0.brightness, $0.warmth] }
            UserDefaults.standard.set(raw, forKey: key)
        }
    }

    func reset() {
        cache = [:]
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - Gamma

// Brightness scales the whole output; warmth pulls down green and blue so the
// remaining output skews red. The brightness floor keeps a screen from going fully
// black, which would leave no way to see the menu to bring it back.
func applyGamma(_ id: CGDirectDisplayID, _ s: Settings) {
    let b = Float(max(0.15, min(1.0, s.brightness)))
    let w = Float(max(0.0, min(1.0, s.warmth)))
    let red = b
    let green = b * (1.0 - 0.18 * w)
    let blue = b * (1.0 - 0.45 * w)
    CGSetDisplayTransferByFormula(id, 0, red, 1.0, 0, green, 1.0, 0, blue, 1.0)
}

func applyAll() {
    for d in onlineDisplays() where d.active {
        applyGamma(d.id, Store.shared[d.name])
    }
}

// MARK: - Power

// kCGConfigureForSession keeps this out of the permanent display configuration, so a
// restart always brings every display back even if something goes wrong.
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

// MARK: - Slider row

final class SliderRow: NSView {
    let displayID: CGDirectDisplayID
    let name: String
    let isWarmth: Bool
    let slider = NSSlider()

    init(displayID: CGDirectDisplayID, name: String, isWarmth: Bool, value: Double) {
        self.displayID = displayID
        self.name = name
        self.isWarmth = isWarmth
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 26))

        let icon = NSImageView(frame: NSRect(x: 20, y: 5, width: 16, height: 16))
        icon.image = NSImage(systemSymbolName: isWarmth ? "thermometer.sun" : "sun.max",
                             accessibilityDescription: isWarmth ? "Warmth" : "Brightness")
        icon.contentTintColor = .secondaryLabelColor
        addSubview(icon)

        slider.frame = NSRect(x: 44, y: 3, width: 200, height: 20)
        slider.minValue = isWarmth ? 0.0 : 0.15
        slider.maxValue = 1.0
        slider.doubleValue = value
        slider.target = self
        slider.action = #selector(changed)
        slider.isContinuous = true
        addSubview(slider)
    }

    required init?(coder: NSCoder) { nil }

    @objc func changed() {
        var s = Store.shared[name]
        if isWarmth { s.warmth = slider.doubleValue } else { s.brightness = slider.doubleValue }
        Store.shared[name] = s
        applyGamma(displayID, s)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    // A disconnected display disappears from the online list, so its ID has to be
    // remembered or there would be no way to reconnect it.
    let offKey = "disconnectedDisplays"
    var offDisplays: [String: CGDirectDisplayID] {
        get { (UserDefaults.standard.dictionary(forKey: offKey) as? [String: UInt32]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: offKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Displays")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        applyAll()
        // macOS wipes gamma on display changes and on wake, so reapply afterwards.
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            // beginConfigurationFlag fires before the change lands; reapplying then
            // would be overwritten by the change itself.
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

        for d in online {
            let header = NSMenuItem(title: d.name, action: #selector(togglePower(_:)), keyEquivalent: "")
            header.target = self
            header.representedObject = d.id
            header.state = d.active ? .on : .off
            // Refuse to turn off the only screen left — there would be nothing to
            // click to turn it back on.
            if d.active, activeCount <= 1 {
                header.action = nil
                header.toolTip = "Can't turn off the last active display"
            }
            menu.addItem(header)

            if d.active {
                let s = Store.shared[d.name]
                for isWarmth in [false, true] {
                    let row = NSMenuItem()
                    row.view = SliderRow(displayID: d.id, name: d.name, isWarmth: isWarmth,
                                         value: isWarmth ? s.warmth : s.brightness)
                    menu.addItem(row)
                }
            }
            menu.addItem(.separator())
        }

        // Displays we turned off no longer enumerate, so list them from what we saved.
        let stillOff = offDisplays.filter { entry in !online.contains { $0.id == entry.value } }
        for (name, id) in stillOff.sorted(by: { $0.key < $1.key }) {
            let item = NSMenuItem(title: name, action: #selector(togglePower(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = .off
            menu.addItem(item)
        }
        if !stillOff.isEmpty {
            let all = NSMenuItem(title: "Turn All On", action: #selector(turnAllOn), keyEquivalent: "")
            all.target = self
            menu.addItem(all)
            menu.addItem(.separator())
        }

        let reset = NSMenuItem(title: "Reset Brightness & Warmth", action: #selector(resetAll), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func togglePower(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? CGDirectDisplayID else { return }
        let name = sender.title
        let turnOn = sender.state == .off
        guard setDisplay(id, enabled: turnOn) else {
            NSSound.beep()
            return
        }
        var off = offDisplays
        if turnOn { off.removeValue(forKey: name) } else { off[name] = id }
        offDisplays = off
        if turnOn {
            // The display takes a moment to come back before gamma will stick.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { applyAll() }
        }
    }

    @objc func turnAllOn() {
        for (_, id) in offDisplays { _ = setDisplay(id, enabled: true) }
        offDisplays = [:]
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { applyAll() }
    }

    @objc func resetAll() {
        Store.shared.reset()
        CGDisplayRestoreColorSyncSettings()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
