// Samsung-focused probe: tries protocol variants (data address, reply delay, chip address)
import Foundation
import IOKit

typealias Svc = IOAVService

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
print("Samsung service acquired")

let chipAddrs: [UInt8] = [0x37, 0xB7]
let dataAddrs: [UInt8] = [0x51, 0x50]
let readWaits: [UInt32] = [50000, 200_000]

for chip in chipAddrs {
    for dataAddr in dataAddrs {
        for rw in readWaits {
            let send: [UInt8] = [0x10]
            var packet: [UInt8] = [UInt8(0x80 | (send.count + 1)), UInt8(send.count)] + send + [0]
            packet[packet.count - 1] = checksum(chk: chip << 1 ^ dataAddr, data: packet, start: 0, end: packet.count - 2)
            var ok = false
            var raw = ""
            for _ in 0 ..< 3 {
                usleep(20000)
                _ = IOAVServiceWriteI2C(svc, UInt32(chip), UInt32(dataAddr), &packet, UInt32(packet.count))
                usleep(rw)
                var reply = [UInt8](repeating: 0, count: 11)
                if IOAVServiceReadI2C(svc, UInt32(chip), 0, &reply, UInt32(reply.count)) == 0 {
                    raw = reply.map { String(format: "%02X", $0) }.joined(separator: " ")
                    if checksum(chk: 0x50, data: reply, start: 0, end: reply.count - 2) == reply[reply.count - 1], reply[2] == 0x02 {
                        let cur = UInt16(reply[8]) * 256 + UInt16(reply[9])
                        print("chip=0x\(String(chip, radix: 16)) data=0x\(String(dataAddr, radix: 16)) wait=\(rw / 1000)ms: OK luminance=\(cur)")
                        ok = true
                        break
                    }
                }
            }
            if !ok {
                print("chip=0x\(String(chip, radix: 16)) data=0x\(String(dataAddr, radix: 16)) wait=\(rw / 1000)ms: fail  raw=[\(raw)]")
            }
        }
    }
}
