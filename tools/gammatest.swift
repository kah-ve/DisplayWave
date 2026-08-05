// Tests whether the gamma/transfer-table APIs actually apply on this Mac.
// Gamma is the only route to brightness/warmth on displays without working DDC,
// and these APIs are reported broken on macOS Tahoe with M5-series chips.
import CoreGraphics
import Foundation

func nm(_ id: CGDirectDisplayID) -> String {
    if let d = CoreDisplay_DisplayCreateInfoDictionary(id)?.takeRetainedValue() as NSDictionary?,
       let n = d["DisplayProductName"] as? [String: String], let v = n["en_US"] ?? n.first?.value { return v }
    return "Display \(id)"
}

setvbuf(stdout, nil, _IONBF, 0)
var ids = [CGDirectDisplayID](repeating: 0, count: 16)
var n: UInt32 = 0
CGGetOnlineDisplayList(16, &ids, &n)

for id in ids.prefix(Int(n)) {
    print("--- \(nm(id)) (id \(id)) ---")
    let cap = CGDisplayGammaTableCapacity(id)
    print("  gamma table capacity: \(cap)")

    // Save the current table so it can be restored exactly.
    var r = [CGGammaValue](repeating: 0, count: Int(cap))
    var g = [CGGammaValue](repeating: 0, count: Int(cap))
    var b = [CGGammaValue](repeating: 0, count: Int(cap))
    var got: UInt32 = 0
    let readErr = CGGetDisplayTransferByTable(id, cap, &r, &g, &b, &got)
    print("  read table: err=\(readErr.rawValue) entries=\(got)")

    // Apply an unmistakable change: half brightness via formula.
    let setErr = CGSetDisplayTransferByFormula(id, 0, 0.5, 1.0, 0, 0.5, 1.0, 0, 0.5, 1.0)
    print("  set formula (50% max): err=\(setErr.rawValue)")
    usleep(400_000)

    // Read back to see whether the change actually took effect.
    var r2 = [CGGammaValue](repeating: 0, count: Int(cap))
    var g2 = [CGGammaValue](repeating: 0, count: Int(cap))
    var b2 = [CGGammaValue](repeating: 0, count: Int(cap))
    var got2: UInt32 = 0
    CGGetDisplayTransferByTable(id, cap, &r2, &g2, &b2, &got2)
    let changed = zip(r.prefix(Int(got)), r2.prefix(Int(got2))).contains { abs($0 - $1) > 0.001 }
    print("  readback differs from original: \(changed)")
    if got > 0, got2 > 0 {
        let mid = Int(got) / 2
        print("  midpoint red: before=\(r[mid]) after=\(r2[mid])")
    }
    usleep(600_000)
    CGDisplayRestoreColorSyncSettings()
    usleep(200_000)
}
print("\nrestored all displays")
