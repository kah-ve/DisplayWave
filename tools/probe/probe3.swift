// Samsung frame-alignment probe: request luminance, read 64 bytes, scan for a valid DDC frame
import Foundation
import IOKit

func checksum(chk: UInt8, data: [UInt8], start: Int, end: Int) -> UInt8 {
    var c = chk
    for i in start ... end { c ^= data[i] }
    return c
}

func getSamsungService() -> IOAVService? {
    let root = IORegistryGetRootEntry(kIOMainPortDefault)
    defer { IOObjectRelease(root) }
    var iterator = io_iterator_t()
    guard IORegistryEntryCreateIterator(root, "IOService", IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iterator) }
    var isSamsung = false
    let nameBuf = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_name_t>.size)
    defer { nameBuf.deallocate() }
    while true {
        let entry = IOIteratorNext(iterator)
        guard entry != IO_OBJECT_NULL else { break }
        defer { IOObjectRelease(entry) }
        guard IORegistryEntryGetName(entry, nameBuf) == KERN_SUCCESS else { continue }
        let name = String(cString: nameBuf)
        if name.contains("AppleCLCD2") || name.contains("IOMobileFramebufferShim") {
            isSamsung = false
            if let attrsU = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0),
               let attrs = attrsU.takeRetainedValue() as? NSDictionary,
               let product = attrs.value(forKey: "ProductAttributes") as? NSDictionary,
               let pname = product.value(forKey: "ProductName") as? String {
                isSamsung = pname.contains("S34J55")
            }
        } else if name.contains("DCPAVServiceProxy"), isSamsung {
            if let locU = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0),
               let loc = locU.takeRetainedValue() as? String, loc == "External" {
                return IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue()
            }
        }
    }
    return nil
}

setvbuf(stdout, nil, _IONBF, 0)
guard let svc = getSamsungService() else { print("Samsung service not found"); exit(1) }

let send: [UInt8] = [0x10]
var packet: [UInt8] = [UInt8(0x80 | (send.count + 1)), UInt8(send.count)] + send + [0]
packet[packet.count - 1] = checksum(chk: 0x37 << 1 ^ 0x51, data: packet, start: 0, end: packet.count - 2)

for round in 1 ... 3 {
    usleep(20000)
    _ = IOAVServiceWriteI2C(svc, 0x37, 0x51, &packet, UInt32(packet.count))
    usleep(60000)
    var buf = [UInt8](repeating: 0, count: 64)
    let ret = IOAVServiceReadI2C(svc, 0x37, 0, &buf, UInt32(buf.count))
    print("round \(round) read ret=\(ret)")
    print(buf.map { String(format: "%02X", $0) }.joined(separator: " "))
    // scan for valid 11-byte DDC frame at any offset: [len|0x80][0x02][0x00][0x10]... with valid checksum
    for off in 0 ..< buf.count - 11 {
        let window = Array(buf[off ..< off + 11])
        if window[0] == 0x88, window[1] == 0x02,
           checksum(chk: 0x50, data: window, start: 0, end: 9) == window[10] {
            let cur = UInt16(window[7]) * 256 + UInt16(window[8])
            print("  -> valid frame at offset \(off + 1)! luminance≈\(cur)")
        }
        // also standard alignment check (source byte stripped): reply[0]=0x88? or classic: [0x6E]?
        if window[0] == 0x6E {
            print("  -> 0x6E marker at offset \(off)")
        }
    }
}
