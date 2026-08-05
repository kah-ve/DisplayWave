import CoreGraphics
import Foundation

func displayName(_ id: CGDirectDisplayID) -> String {
    if let dict = CoreDisplay_DisplayCreateInfoDictionary(id)?.takeRetainedValue() as NSDictionary?,
       let names = dict["DisplayProductName"] as? [String: String],
       let name = names["en_US"] ?? names.first?.value {
        return name
    }
    return CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)"
}

var ids = [CGDirectDisplayID](repeating: 0, count: 16)
var count: UInt32 = 0
CGGetOnlineDisplayList(16, &ids, &count)
print("online displays: \(count)")
for id in ids.prefix(Int(count)) {
    print("  id=\(id) name=\(displayName(id)) active=\(CGDisplayIsActive(id) != 0) builtin=\(CGDisplayIsBuiltin(id) != 0) main=\(CGMainDisplayID() == id)")
}
