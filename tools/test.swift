import CoreGraphics
import Foundation

func name(_ id: CGDirectDisplayID) -> String {
    if let d = CoreDisplay_DisplayCreateInfoDictionary(id)?.takeRetainedValue() as NSDictionary?,
       let n = d["DisplayProductName"] as? [String: String], let v = n["en_US"] ?? n.first?.value { return v }
    return "Display \(id)"
}

func set(_ id: CGDirectDisplayID, _ on: Bool) -> Bool {
    var c: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&c) == .success, let c else { return false }
    guard CGSConfigureDisplayEnabled(c, id, on) == .success else { CGCancelDisplayConfiguration(c); return false }
    guard CGCompleteDisplayConfiguration(c, .forSession) == .success else { CGCancelDisplayConfiguration(c); return false }
    return true
}

setvbuf(stdout, nil, _IONBF, 0)
var ids = [CGDirectDisplayID](repeating: 0, count: 16)
var n: UInt32 = 0
CGGetOnlineDisplayList(16, &ids, &n)
guard let target = ids.prefix(Int(n)).first(where: { name($0).contains("S34J55") }) else {
    print("Samsung not found"); exit(1)
}
print("target: \(name(target)) id=\(target) active=\(CGDisplayIsActive(target) != 0)")

// Always restore, even on unexpected exit.
defer {
    if CGDisplayIsActive(target) == 0 {
        print("restoring…")
        _ = set(target, true)
    }
}

print("disabling…  ok=\(set(target, false))")
usleep(1_500_000)
print("after disable: active=\(CGDisplayIsActive(target) != 0)")
usleep(3_000_000)
print("re-enabling… ok=\(set(target, true))")
usleep(2_000_000)
print("after enable: active=\(CGDisplayIsActive(target) != 0)")
