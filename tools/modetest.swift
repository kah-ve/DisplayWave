// Lists every usable mode per display; with `set <id> <w> <h> <hz>` switches to
// that mode, waits three seconds, and switches back. Used to verify the mode-set
// path DisplayWave's dropdowns use.
import CoreGraphics
import Foundation

func modes(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
    let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue!] as CFDictionary
    let all = CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode] ?? []
    return all.filter { $0.isUsableForDesktopGUI() }
}

func set(_ id: CGDirectDisplayID, _ mode: CGDisplayMode) -> Bool {
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
    guard CGConfigureDisplayWithDisplayMode(config, id, mode, nil) == .success,
          CGCompleteDisplayConfiguration(config, .permanently) == .success else {
        CGCancelDisplayConfiguration(config)
        return false
    }
    return true
}

var ids = [CGDirectDisplayID](repeating: 0, count: 16)
var count: UInt32 = 0
CGGetOnlineDisplayList(16, &ids, &count)
let online = Array(ids.prefix(Int(count)))

let args = CommandLine.arguments
if args.count >= 5, args[1] == "set" {
    let id = CGDirectDisplayID(UInt32(args[2])!)
    let w = Int(args[3])!, h = Int(args[4])!
    let hz = args.count > 5 ? Double(args[5])! : 0
    guard let original = CGDisplayCopyDisplayMode(id) else { fatalError("no current mode") }
    let target = modes(id).filter { $0.width == w && $0.height == h }
        .filter { hz == 0 || abs($0.refreshRate - hz) < 1 }
        .max { $0.pixelWidth < $1.pixelWidth }
    guard let target else { fatalError("no such mode") }
    print("switching \(id) to \(target.width)x\(target.height)@\(Int(target.refreshRate)) (pixels \(target.pixelWidth)x\(target.pixelHeight))")
    print(set(id, target) ? "switch OK" : "switch FAILED")
    Thread.sleep(forTimeInterval: 3)
    print(set(id, original) ? "revert OK" : "revert FAILED")
    let now = CGDisplayCopyDisplayMode(id)!
    print("final mode: \(now.width)x\(now.height)@\(Int(now.refreshRate))")
} else {
    for id in online {
        let cur = CGDisplayCopyDisplayMode(id)
        print("display \(id): current \(cur?.width ?? 0)x\(cur?.height ?? 0)@\(Int(cur?.refreshRate ?? 0))")
        var seen = Set<String>()
        for m in modes(id).sorted(by: { $0.width * $0.height > $1.width * $1.height }) {
            let key = "\(m.width)x\(m.height)@\(Int(m.refreshRate.rounded())) px\(m.pixelWidth)"
            if seen.insert(key).inserted {
                print("  \(m.width) x \(m.height) @ \(Int(m.refreshRate.rounded())) Hz  (pixels \(m.pixelWidth) x \(m.pixelHeight))")
            }
        }
    }
}
