// DDC probe: enumerates every external display port and attempts checksum-verified
// DDC reads/writes using MonitorControl's Arm64DDC communication logic.
import Foundation
import IOKit

let DDC_7BIT_ADDRESS: UInt8 = 0x37
let DDC_DATA_ADDRESS: UInt8 = 0x51

struct PortService {
    var productName: String = "?"
    var manufacturerID: String = "?"
    var location: String = ""
    var service: IOAVService?
}

func checksum(chk: UInt8, data: [UInt8], start: Int, end: Int) -> UInt8 {
    var chkd: UInt8 = chk
    for i in start ... end { chkd ^= data[i] }
    return chkd
}

// Port of Arm64DDC.performDDCCommunication with tunable timing
func ddcComm(service: IOAVService?, send: [UInt8], readReply: Bool,
             writeSleep: UInt32, readSleep: UInt32, retries: Int, retrySleep: UInt32) -> (ok: Bool, reply: [UInt8]) {
    guard let service else { return (false, []) }
    var reply = [UInt8](repeating: 0, count: readReply ? 11 : 0)
    var packet: [UInt8] = [UInt8(0x80 | (send.count + 1)), UInt8(send.count)] + send + [0]
    packet[packet.count - 1] = checksum(
        chk: send.count == 1 ? DDC_7BIT_ADDRESS << 1 : DDC_7BIT_ADDRESS << 1 ^ DDC_DATA_ADDRESS,
        data: packet, start: 0, end: packet.count - 2)
    var success = false
    for _ in 0 ..< retries {
        for _ in 0 ..< 2 {
            usleep(writeSleep)
            success = IOAVServiceWriteI2C(service, UInt32(DDC_7BIT_ADDRESS), UInt32(DDC_DATA_ADDRESS), &packet, UInt32(packet.count)) == 0
        }
        if readReply {
            usleep(readSleep)
            if IOAVServiceReadI2C(service, UInt32(DDC_7BIT_ADDRESS), 0, &reply, UInt32(reply.count)) == 0 {
                success = checksum(chk: 0x50, data: reply, start: 0, end: reply.count - 2) == reply[reply.count - 1]
            } else {
                success = false
            }
        }
        if success { return (true, reply) }
        usleep(retrySleep)
    }
    return (false, reply)
}

func getPorts() -> [PortService] {
    var ports: [PortService] = []
    let root = IORegistryGetRootEntry(kIOMasterPortDefault)
    defer { IOObjectRelease(root) }
    var iterator = io_iterator_t()
    guard IORegistryEntryCreateIterator(root, "IOService", IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return ports }
    defer { IOObjectRelease(iterator) }
    var current = PortService()
    let nameBuf = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_name_t>.size)
    defer { nameBuf.deallocate() }
    while true {
        let entry = IOIteratorNext(iterator)
        guard entry != IO_OBJECT_NULL else { break }
        guard IORegistryEntryGetName(entry, nameBuf) == KERN_SUCCESS else { IOObjectRelease(entry); continue }
        let name = String(cString: nameBuf)
        if name.contains("AppleCLCD2") || name.contains("IOMobileFramebufferShim") {
            current = PortService()
            if let attrsU = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0),
               let attrs = attrsU.takeRetainedValue() as? NSDictionary,
               let product = attrs.value(forKey: "ProductAttributes") as? NSDictionary {
                current.productName = product.value(forKey: "ProductName") as? String ?? "?"
                current.manufacturerID = product.value(forKey: "ManufacturerID") as? String ?? "?"
            }
        } else if name.contains("DCPAVServiceProxy") {
            if let locU = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0),
               let loc = locU.takeRetainedValue() as? String {
                current.location = loc
                if loc == "External" {
                    current.service = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue()
                }
            }
            ports.append(current)
        }
        IOObjectRelease(entry)
    }
    return ports
}

setvbuf(stdout, nil, _IONBF, 0)

let profiles: [(label: String, w: UInt32, r: UInt32, retries: Int, rs: UInt32)] = [
    ("standard 10ms", 10000, 50000, 3, 20000),
    ("slow 50ms", 50000, 50000, 3, 50000),
]

let ports = getPorts()
print("Found \(ports.count) port(s)\n")
for (i, p) in ports.enumerated() {
    print("[\(i)] \(p.manufacturerID) \(p.productName) (location: \(p.location), service: \(p.service != nil ? "yes" : "no"))")
    guard p.service != nil else { continue }
    for prof in profiles {
        let t0 = DispatchTime.now()
        let res = ddcComm(service: p.service, send: [0x10], readReply: true,
                          writeSleep: prof.w, readSleep: prof.r, retries: prof.retries, retrySleep: prof.rs)
        let secs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
        if res.ok {
            let maxV = UInt16(res.reply[6]) * 256 + UInt16(res.reply[7])
            let curV = UInt16(res.reply[8]) * 256 + UInt16(res.reply[9])
            print(String(format: "    %@: OK  luminance=%d/%d  (%.1fs)", prof.label, curV, maxV, secs))
            break
        } else {
            print(String(format: "    %@: no valid reply  (%.1fs)", prof.label, secs))
        }
    }
}
