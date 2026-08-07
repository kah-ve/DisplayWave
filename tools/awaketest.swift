// Exercises the Keep Mac Awake state machine against the real power-management
// assertion: timed start, +/- adjustments, the 24h cap, expiry auto-release, and
// that powerd agrees at each step.
import Foundation
import IOKit.pwr_mgt

final class KeepAwake {
    static let maxHours: Double = 24
    private var assertion = IOPMAssertionID(0)
    private var timer: Timer?
    private(set) var active = false
    private(set) var expiry: Date?

    var stateDescription: String {
        guard active else { return "Off" }
        guard let expiry else { return "No limit" }
        let seconds = max(0, Int(expiry.timeIntervalSinceNow.rounded(.up)))
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        if hours == 0 { return "\(max(1, minutes))m left" }
        return minutes == 0 ? "\(hours)h left" : "\(hours)h \(minutes)m left"
    }

    func start(hours: Double?) {
        if !active {
            guard IOPMAssertionCreateWithName("PreventUserIdleDisplaySleep" as CFString,
                                              IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                              "DisplayWave: Keep Mac Awake" as CFString,
                                              &assertion) == kIOReturnSuccess else { return }
            active = true
        }
        expiry = hours.map { Date(timeIntervalSinceNow: $0 * 3600) }
        rearm()
    }

    func stop() {
        guard active else { return }
        IOPMAssertionRelease(assertion)
        active = false
        expiry = nil
        rearm()
    }

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

/// Asks powerd directly whether our assertion is registered. (Shelling out to
/// `pmset` works from a terminal but returns nothing under a sandbox, so this uses
/// the same data source pmset itself reads.)
func assertionHeld() -> Bool {
    var assertions: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&assertions) == kIOReturnSuccess,
          let byProcess = assertions?.takeRetainedValue() as? [AnyHashable: Any] else { return false }
    for (_, value) in byProcess {
        guard let list = value as? [[String: Any]] else { continue }
        for entry in list where (entry["AssertName"] as? String)?.contains("Keep Mac Awake") == true {
            return true
        }
    }
    return false
}

var failures = 0
func check(_ label: String, _ condition: Bool) {
    print("\(condition ? "ok  " : "FAIL") \(label)")
    if !condition { failures += 1 }
}

let k = KeepAwake()
check("starts off", !k.active && k.stateDescription == "Off")
check("no assertion while off", !assertionHeld())

k.adjust(hours: -1)
check("minus while off does nothing", !k.active)

k.adjust(hours: 1)
check("plus while off starts a timed session", k.active && k.stateDescription == "1h left")
check("assertion held once active", assertionHeld())

k.adjust(hours: 5)
check("+5h accumulates", k.stateDescription == "6h left")

k.adjust(hours: -5)
check("-5h subtracts", k.stateDescription == "1h left")

k.adjust(hours: -1)
check("removing the last hour turns it off", !k.active && k.stateDescription == "Off")
check("assertion released", !assertionHeld())

k.start(hours: nil)
check("Always has no limit", k.active && k.stateDescription == "No limit")
k.adjust(hours: -5)
check("adjusting a no-limit session is ignored", k.stateDescription == "No limit")

k.start(hours: 20)
k.adjust(hours: 5)
check("capped at 24h", k.stateDescription.hasPrefix("24h"))
k.stop()
check("stop releases", !k.active && !assertionHeld())

// Expiry fires on its own: a 10-second session, run the loop past it.
k.start(hours: 10.0 / 3600)
check("short session active", k.active && assertionHeld())
RunLoop.main.run(until: Date(timeIntervalSinceNow: 11))
check("auto-released at expiry", !k.active)
check("assertion gone after expiry", !assertionHeld())

print(failures == 0 ? "\nall passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
