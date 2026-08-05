// Creates the same power assertion DisplayWave's Keep Mac Awake uses, holds it
// briefly so `pmset -g assertions` can see it, then releases it.
import Foundation
import IOKit.pwr_mgt

var id = IOPMAssertionID(0)
let r = IOPMAssertionCreateWithName("PreventUserIdleDisplaySleep" as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "DisplayWave awake test" as CFString, &id)
print(r == kIOReturnSuccess ? "assertion created (id \(id))" : "FAILED: \(r)")
Thread.sleep(forTimeInterval: 5)
IOPMAssertionRelease(id)
print("released")
