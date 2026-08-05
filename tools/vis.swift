import CoreGraphics
import Foundation
setvbuf(stdout, nil, _IONBF, 0)
var ids = [CGDirectDisplayID](repeating: 0, count: 16)
var n: UInt32 = 0
CGGetOnlineDisplayList(16, &ids, &n)
print("dimming ALL displays to 40% for 4 seconds…")
for id in ids.prefix(Int(n)) {
    _ = CGSetDisplayTransferByFormula(id, 0, 0.4, 1.0, 0, 0.4, 1.0, 0, 0.4, 1.0)
}
usleep(4_000_000)
print("applying strong RED tint for 4 seconds…")
for id in ids.prefix(Int(n)) {
    _ = CGSetDisplayTransferByFormula(id, 0, 1.0, 1.0, 0, 0.35, 1.0, 0, 0.35, 1.0)
}
usleep(4_000_000)
CGDisplayRestoreColorSyncSettings()
print("restored")
