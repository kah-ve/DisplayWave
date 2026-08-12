import CoreGraphics
import Foundation
import IOKit

// DDC/CI — talking to the monitor over the video cable to drive its actual backlight.
//
// This is the only way to genuinely dim a monitor; everything else just darkens the
// image the GPU sends. Not all monitors answer: some have DDC disabled in their
// on-screen menu, and many adapters and hubs don't pass the I2C lines through.
//
// A monitor that doesn't answer is not merely slow. `IOAVServiceWriteI2C` can block
// inside the kernel for over a minute on a dead channel, and killing a thread partway
// through a transaction can drop the display off the system until it is physically
// replugged. So the rules here are:
//
//   * probe once per monitor, cache the answer, and never probe again unasked
//   * probe on a detached thread that is abandoned rather than killed on timeout
//   * never retry a channel that has already failed

private let ddcAddress: UInt8 = 0x37
private let ddcDataAddress: UInt8 = 0x51
let vcpLuminance: UInt8 = 0x10

/// How many times to re-walk the I/O registry when it changes underneath us. Enough
/// to outlast the churn of a display being plugged in, which is the case that matters.
private let walkAttempts = 12

private func checksum(_ seed: UInt8, _ data: [UInt8], _ range: Range<Int>) -> UInt8 {
    var c = seed
    for i in range { c ^= data[i] }
    return c
}

/// Sends one DDC command. `reply` is filled when a response is expected.
private func transact(_ service: IOAVService, send: [UInt8], expectReply: Bool) -> [UInt8]? {
    var packet: [UInt8] = [UInt8(0x80 | (send.count + 1)), UInt8(send.count)] + send + [0]
    // The checksum covers the whole frame as it appears on the wire, which includes the
    // two address bytes the controller prepends and this buffer never sees: the 0x37
    // chip address shifted into its write form, and the 0x51 source address.
    //
    // Reads used to seed with only the first of those. Monitors that don't verify the
    // checksum on an incoming message answered anyway, so DDC looked like it worked —
    // but a monitor that does verify stays silent, the probe reads that as "no DDC
    // channel here", and the monitor is written off to gamma dimming for good.
    let seed = ddcAddress << 1 ^ ddcDataAddress
    packet[packet.count - 1] = checksum(seed, packet, 0 ..< packet.count - 1)

    usleep(10000)
    guard IOAVServiceWriteI2C(service, UInt32(ddcAddress), UInt32(ddcDataAddress),
                              &packet, UInt32(packet.count)) == 0 else { return nil }
    guard expectReply else { return [] }

    usleep(50000)
    var reply = [UInt8](repeating: 0, count: 11)
    guard IOAVServiceReadI2C(service, UInt32(ddcAddress), 0, &reply, UInt32(reply.count)) == 0,
          checksum(0x50, reply, 0 ..< reply.count - 1) == reply[reply.count - 1]
    else { return nil }
    return reply
}

func ddcRead(_ service: IOAVService, vcp: UInt8) -> (current: Int, max: Int)? {
    guard let reply = transact(service, send: [vcp], expectReply: true) else { return nil }
    let max = Int(reply[6]) * 256 + Int(reply[7])
    let current = Int(reply[8]) * 256 + Int(reply[9])
    guard max > 0 else { return nil }
    return (current, max)
}

@discardableResult
func ddcWrite(_ service: IOAVService, vcp: UInt8, value: Int) -> Bool {
    let v = UInt16(clamping: value)
    return transact(service, send: [vcp, UInt8(v >> 8), UInt8(v & 0xFF)], expectReply: false) != nil
}

// MARK: - Finding a monitor's DDC channel

/// One monitor's DDC channel as found in the I/O registry.
typealias DDCService = (name: String, serial: Int64, service: IOAVService)

/// Walks the I/O registry pairing each display's framebuffer with its AV service.
/// This only reads the registry — no I2C traffic — so it is safe for any monitor.
///
/// The walk visits every IOService entry on the machine — a few thousand of them,
/// costing on the order of ten milliseconds — so it is done once and the result
/// matched against every display, never once per display.
func ddcServices() -> [DDCService] {
    var found: [DDCService] = []
    let root = IORegistryGetRootEntry(kIOMainPortDefault)
    defer { IOObjectRelease(root) }
    var iterator = io_iterator_t()
    guard IORegistryEntryCreateIterator(root, "IOService",
                                        IOOptionBits(kIORegistryIterateRecursively),
                                        &iterator) == KERN_SUCCESS else { return found }
    defer { IOObjectRelease(iterator) }

    let nameBuf = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_name_t>.size)
    defer { nameBuf.deallocate() }

    // IOKit invalidates a registry iterator the moment anything else modifies the
    // registry mid-walk, and then just stops early — no error, no partial-result
    // flag, simply a short list. The registry churns constantly around displays,
    // most of all in the seconds after one is plugged in, which is exactly when this
    // runs. A truncated walk is indistinguishable from "this monitor has no DDC
    // channel", so the cost of ignoring it is a perfectly capable monitor silently
    // losing its backlight control for the rest of the session.
    //
    // `IOIteratorIsValid` reports it after the fact and `IOIteratorReset` makes the
    // iterator usable again, so the walk is simply repeated until one pass gets all
    // the way through a registry that held still.
    for attempt in 0 ..< walkAttempts {
        found.removeAll(keepingCapacity: true)
        var name = "", serial: Int64 = 0
        IOIteratorReset(iterator)

        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(entry) }
            guard IORegistryEntryGetName(entry, nameBuf) == KERN_SUCCESS else { continue }
            let node = String(cString: nameBuf)

            if node.contains("AppleCLCD2") || node.contains("IOMobileFramebufferShim") {
                name = ""
                serial = 0
                if let attrs = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString,
                                                               kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? NSDictionary,
                   let product = attrs.value(forKey: "ProductAttributes") as? NSDictionary {
                    name = product.value(forKey: "ProductName") as? String ?? ""
                    serial = product.value(forKey: "SerialNumber") as? Int64 ?? 0
                }
            } else if node.contains("DCPAVServiceProxy"), !name.isEmpty {
                if let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString,
                                                                  kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String, location == "External",
                   let service = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?
                    .takeRetainedValue() {
                    found.append((name, serial, service))
                }
            }
        }

        if IOIteratorIsValid(iterator) != 0 { return found }
        // Still settling. Back off briefly rather than spinning against the churn —
        // this always runs off the main thread, so waiting costs nothing on screen.
        if attempt < walkAttempts - 1 { usleep(30000) }
    }
    // Every attempt was cut short. Returning what little was found is safe: callers
    // treat a display with no channel as simply not classified yet, and try again
    // on the next reconfiguration rather than writing it off.
    return found
}

func displaySerial(_ id: CGDirectDisplayID) -> Int64 {
    guard let dict = CoreDisplay_DisplayCreateInfoDictionary(id)?.takeRetainedValue() as NSDictionary?
    else { return 0 }
    return dict[kDisplaySerialNumber] as? Int64 ?? 0
}

/// Matches a display to its DDC channel within a registry snapshot, by product name,
/// disambiguating identical models by serial number. A display can expose several AV
/// services; they behave alike, so the first is used.
func ddcService(for display: Display, in services: [DDCService]) -> IOAVService? {
    let candidates = services.filter {
        $0.name.caseInsensitiveCompare(display.name) == .orderedSame
    }
    guard !candidates.isEmpty else { return nil }
    if candidates.count > 1 {
        let serial = displaySerial(display.id)
        if serial != 0, let exact = candidates.first(where: { $0.serial == serial }) {
            return exact.service
        }
    }
    return candidates[0].service
}

/// The same lookup for a single display, walking the registry for it. Only worth it
/// when there's one display to resolve; for several, walk once and match in bulk.
func ddcService(for display: Display) -> IOAVService? {
    ddcService(for: display, in: ddcServices())
}

// MARK: - Capability detection

enum BrightnessMode: String {
    case hardware  // the monitor's own backlight, over DDC
    case software  // the GPU's gamma table
}

/// Remembers which monitors answer DDC. Probing is expensive and mildly risky, so a
/// result is cached permanently and only redone when the user explicitly asks.
final class Capabilities {
    static let shared = Capabilities()
    private let key = "brightnessMode"
    private let maxKey = "brightnessMax"
    private let lock = NSLock()
    private var modes: [String: BrightnessMode] = [:]
    private var maxima: [String: Int] = [:]
    private var servicesByName: [String: IOAVService] = [:]

    private init() {
        if let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: String] {
            modes = raw.compactMapValues { BrightnessMode(rawValue: $0) }
        }
        maxima = (UserDefaults.standard.dictionary(forKey: maxKey) as? [String: Int]) ?? [:]
    }

    func mode(for name: String) -> BrightnessMode {
        lock.lock(); defer { lock.unlock() }
        return modes[name] ?? .software
    }

    func service(for name: String) -> IOAVService? {
        lock.lock(); defer { lock.unlock() }
        return servicesByName[name]
    }

    /// The largest luminance value this monitor says it accepts. Most report 100,
    /// but the standard doesn't require it, and writing past a monitor's own
    /// maximum is out of spec.
    func maxLuminance(for name: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        let max = maxima[name] ?? 0
        return max > 0 ? max : 100
    }

    private func store(_ name: String, _ mode: BrightnessMode, _ service: IOAVService?, max: Int? = nil) {
        lock.lock()
        modes[name] = mode
        if let service { servicesByName[name] = service }
        if let max, max > 0 { maxima[name] = max }
        let snapshot = modes.mapValues(\.rawValue)
        let maxSnapshot = maxima
        lock.unlock()
        UserDefaults.standard.set(snapshot, forKey: key)
        UserDefaults.standard.set(maxSnapshot, forKey: maxKey)
    }

    private func isKnown(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return modes[name] != nil
    }

    /// Brings the table in line with what's actually plugged in, and the only entry
    /// point that needs calling: it re-resolves the channel for every monitor already
    /// known to answer DDC, and probes any monitor never seen before.
    ///
    /// Both jobs used to be separate passes, and only the first ran when the display
    /// configuration changed — so a monitor plugged in after launch was never probed
    /// and stayed stuck on gamma-only dimming for the rest of the session. Doing them
    /// together fixes that, and means one registry walk covers every display instead
    /// of one walk apiece.
    ///
    /// Runs entirely off the main thread, and always calls `completion` on it.
    func sync(displays: [Display], completion: @escaping () -> Void) {
        // A monitor already known not to answer is left completely alone — its
        // channel is never touched again, which is the whole point of caching.
        let pending = displays.filter { !isKnown($0.name) || mode(for: $0.name) == .hardware }
        guard !pending.isEmpty else { DispatchQueue.main.async(execute: completion); return }
        DispatchQueue.global(qos: .utility).async {
            let registry = ddcServices()
            for display in pending {
                let service = ddcService(for: display, in: registry)
                if self.isKnown(display.name) {
                    // Known to answer DDC, so this is only ever a re-attach. A handle
                    // missing right now usually means the display is still settling
                    // after a reconfiguration, so the verdict is left alone and tried
                    // again next time rather than demoted to software for good.
                    if let service { self.store(display.name, .hardware, service) }
                    continue
                }
                // Never seen before. No AV service at all is left unrecorded rather
                // than written off as software: the registry can come up short while
                // a display is still settling, and that shouldn't permanently cost a
                // monitor its backlight control. Costs nothing to retry — it's a
                // filter over a list already in hand, with no DDC traffic behind it.
                guard let service else { continue }
                if let max = Self.probe(service) {
                    self.store(display.name, .hardware, service, max: max)
                } else {
                    // It had a channel and didn't answer on it. That's a real verdict,
                    // paid for with a real probe, so it's recorded and never retried.
                    self.store(display.name, .software, nil)
                }
            }
            DispatchQueue.main.async(execute: completion)
        }
    }

    /// One read attempt, with a watchdog; returns the monitor's reported maximum
    /// luminance, or nil if it doesn't answer. On timeout the thread is left to
    /// finish on its own — killing it mid-transaction is what strands a display.
    private static func probe(_ service: IOAVService) -> Int? {
        final class Box { var max: Int? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            box.max = ddcRead(service, vcp: vcpLuminance)?.max
            done.signal()
        }
        return done.wait(timeout: .now() + 2.5) == .success ? box.max : nil
    }

    /// For one display, synchronously — used to retry a write that just failed.
    func reattach(name: String, id: CGDirectDisplayID) -> IOAVService? {
        guard mode(for: name) == .hardware else { return nil }
        let placeholder = Display(id: id, name: name, active: true, width: 0, height: 0, refresh: 0)
        guard let service = ddcService(for: placeholder) else { return nil }
        store(name, .hardware, service)
        return service
    }

    /// Clears everything so monitors are re-probed — for after a cable or setting change.
    func forget() {
        lock.lock()
        modes = [:]
        maxima = [:]
        servicesByName = [:]
        lock.unlock()
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: maxKey)
    }
}

// MARK: - Throttled backlight writes

/// A DDC write takes tens of milliseconds, far slower than a slider emits changes.
/// Values are coalesced per display so dragging stays smooth and the monitor always
/// ends up at the value the slider was left on.
///
/// Each display drains on its own queue. They used to share one, which meant a write
/// to a slow monitor held up every other monitor behind it — and since a channel that
/// stops answering can block inside the kernel for a very long time, one sulking
/// monitor could take the brightness of the whole desk with it. Separate queues also
/// let a preset apply to every display at once instead of one after another.
final class Backlight {
    static let shared = Backlight()
    private let lock = NSLock()
    private var queues: [CGDirectDisplayID: DispatchQueue] = [:]
    private var latest: [CGDirectDisplayID: Int] = [:]
    private var busy: Set<CGDirectDisplayID> = []

    /// The caller must hold `lock`.
    private func queue(for id: CGDirectDisplayID) -> DispatchQueue {
        if let existing = queues[id] { return existing }
        let queue = DispatchQueue(label: "displaywave.ddc.\(id)", qos: .userInitiated)
        queues[id] = queue
        return queue
    }

    /// `ceiling` is the monitor's own reported maximum; values are scaled into its
    /// range and never sent past it.
    func set(percent: Double, id: CGDirectDisplayID, name: String, service: IOAVService, ceiling: Int) {
        let value = Swift.max(0, Swift.min(ceiling, Int((max(0, min(1, percent)) * Double(ceiling)).rounded())))
        lock.lock()
        latest[id] = value
        let alreadyDraining = busy.contains(id)
        if !alreadyDraining { busy.insert(id) }
        let queue = queue(for: id)
        lock.unlock()
        guard !alreadyDraining else { return }
        queue.async { self.drain(id: id, name: name, service: service) }
    }

    private func drain(id: CGDirectDisplayID, name: String, service: IOAVService) {
        var service = service
        var reattached = false
        while true {
            lock.lock()
            guard let value = latest.removeValue(forKey: id) else {
                busy.remove(id)
                lock.unlock()
                return
            }
            lock.unlock()
            if !ddcWrite(service, vcp: vcpLuminance, value: value), !reattached {
                // A failed write usually means the service went stale after a display
                // reconfiguration. Re-resolve it once and retry; this only runs for
                // monitors that have already proven they answer DDC.
                reattached = true
                if let fresh = Capabilities.shared.reattach(name: name, id: id) {
                    service = fresh
                    ddcWrite(service, vcp: vcpLuminance, value: value)
                }
            }
        }
    }
}
