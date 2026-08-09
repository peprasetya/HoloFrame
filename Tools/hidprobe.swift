// hidprobe — XREAL Air HID probe (macOS / IOKit)
//
// Answers the open questions in xrealAir.md §11 on real hardware:
//   * can macOS open interfaces 3 (IMU) and 4 (MCU) without seize / Input Monitoring?
//   * what is the actual IMU packet field order? (§11.1)
//   * where do the accel + mag groups live? (§11.2)
//
// Build: swiftc -O -o hidprobe hidprobe.swift -framework IOKit -framework CoreFoundation
// Usage: hidprobe list
//        hidprobe imu [seconds]
//        hidprobe getmode
//        hidprobe setmode 2d|3d          (changes the display resolution!)

import Foundation
import IOKit
import IOKit.hid

let XREAL_VID = 0x3318

// MARK: - CRC-32/ISO-HDLC (zlib/PNG flavour), per §4

let crcTable: [UInt32] = {
    (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }
}()

func crc32(_ bytes: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for b in bytes { crc = crcTable[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
    return crc ^ 0xFFFF_FFFF
}

// MARK: - little-endian helpers

func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }

func i16(_ b: [UInt8], _ o: Int) -> Int16 {
    Int16(bitPattern: UInt16(b[o]) | (UInt16(b[o + 1]) << 8))
}
func i32(_ b: [UInt8], _ o: Int) -> Int32 {
    var v: UInt32 = 0
    for k in (0..<4).reversed() { v = (v << 8) | UInt32(b[o + k]) }
    return Int32(bitPattern: v)
}
func be16(_ b: [UInt8], _ o: Int) -> Int16 {
    Int16(bitPattern: (UInt16(b[o]) << 8) | UInt16(b[o + 1]))
}
func be32(_ b: [UInt8], _ o: Int) -> Int32 {
    var v: UInt32 = 0
    for k in 0..<4 { v = (v << 8) | UInt32(b[o + k]) }
    return Int32(bitPattern: v)
}
/// signed 24-bit little-endian
func i24(_ b: [UInt8], _ o: Int) -> Int32 {
    var v = UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16)
    if v & 0x80_0000 != 0 { v |= 0xFF00_0000 }
    return Int32(bitPattern: v)
}

func hex(_ b: [UInt8], _ range: Range<Int>) -> String {
    range.map { String(format: "%02x", b[$0]) }.joined(separator: " ")
}

// MARK: - device discovery

struct XDev {
    let device: IOHIDDevice
    let iface: Int
    let maxIn: Int
    let maxOut: Int
    let usagePage: Int
    let usage: Int
}

func intProp(_ d: IOHIDDevice, _ key: String) -> Int {
    ((IOHIDDeviceGetProperty(d, key as CFString) as? NSNumber)?.intValue) ?? -1
}

/// bInterfaceNumber lives on the IOUSBHostInterface ancestor, not on the IOHIDDevice.
func interfaceNumber(_ d: IOHIDDevice) -> Int {
    var current = IOHIDDeviceGetService(d)
    guard current != 0 else { return -1 }
    IOObjectRetain(current)
    defer { IOObjectRelease(current) }
    for _ in 0..<6 {
        if let raw = IORegistryEntryCreateCFProperty(
            current, "bInterfaceNumber" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber {
            return raw.intValue
        }
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(current, "IOService", &parent) == KERN_SUCCESS else { break }
        IOObjectRelease(current)
        current = parent
    }
    return -1
}

func discover() -> [XDev] {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: XREAL_VID] as CFDictionary)
    guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else { return [] }
    return set.map { d in
        XDev(device: d,
             iface: interfaceNumber(d),
             maxIn: intProp(d, kIOHIDMaxInputReportSizeKey),
             maxOut: intProp(d, kIOHIDMaxOutputReportSizeKey),
             usagePage: intProp(d, kIOHIDPrimaryUsagePageKey),
             usage: intProp(d, kIOHIDPrimaryUsageKey))
    }.sorted { $0.iface < $1.iface }
}

func ret(_ r: IOReturn) -> String {
    switch r {
    case kIOReturnSuccess: return "success"
    case kIOReturnNotPermitted: return "kIOReturnNotPermitted (needs Input Monitoring?)"
    case kIOReturnExclusiveAccess: return "kIOReturnExclusiveAccess (someone else holds it)"
    case kIOReturnNotOpen: return "kIOReturnNotOpen"
    case kIOReturnUnsupported: return "kIOReturnUnsupported"
    case kIOReturnNoDevice: return "kIOReturnNoDevice"
    default: return String(format: "0x%08x", UInt32(bitPattern: r))
    }
}

/// Try a plain open first; fall back to seize. Reports which one worked.
func openDevice(_ d: IOHIDDevice, label: String) -> Bool {
    var r = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
    if r == kIOReturnSuccess {
        print("  [\(label)] opened WITHOUT seize")
        return true
    }
    print("  [\(label)] plain open failed: \(ret(r))")
    r = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
    if r == kIOReturnSuccess {
        print("  [\(label)] opened WITH kIOHIDOptionsTypeSeizeDevice")
        return true
    }
    print("  [\(label)] seize open failed: \(ret(r))")
    return false
}

func find(_ devs: [XDev], iface: Int) -> XDev? { devs.first { $0.iface == iface } }

// MARK: - commands

func cmdList(_ devs: [XDev]) {
    print("XREAL HID interfaces (vid 0x3318):")
    for d in devs {
        print(String(format: "  iface %2d  usagePage 0x%04x  usage 0x%04x  maxIn %3d  maxOut %3d",
                     d.iface, d.usagePage, d.usage, d.maxIn, d.maxOut))
    }
    print("\nexpected per xrealAir.md §3: iface 3 = IMU, iface 4 = MCU\n")
    for (n, label) in [(3, "IMU"), (4, "MCU")] {
        guard let d = find(devs, iface: n) else { print("  iface \(n) (\(label)): NOT FOUND"); continue }
        if openDevice(d.device, label: label) {
            IOHIDDeviceClose(d.device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }
}

// --- IMU ---

var imuPacketCount = 0
var imuFirstDumped = false
var imuStart = Date()
var imuOtherReports = 0
var imuTotalReports = 0
var imuInbox: [[UInt8]] = []
var imuQuiet = false

/// The constant "I did not understand that" reply iface 3 sends for a malformed packet.
let cannedReject: [UInt8] = [0xaa, 0xc1, 0x7d, 0x41, 0xa9, 0x05, 0x00, 0xff, 0x01, 0x00, 0x00, 0x00]

func decodeIMU(_ b: [UInt8]) {
    imuTotalReports += 1
    guard b.count >= 54 else { print("short report: \(b.count) bytes"); return }
    guard b[0] == 0x01, b[1] == 0x02 else {
        imuOtherReports += 1
        imuInbox.append(b)
        if imuQuiet { return }
        let t = Date().timeIntervalSince(imuStart)
        let len = b.count >= 7 ? Int(b[5]) | (Int(b[6]) << 8) : -1
        let msgid = b.count >= 8 ? String(format: "0x%02x", b[7]) : "??"
        print(String(format: "  t=%6.3fs  non-data report: head=%02x len=%d msgid=%@",
                     t, b[0], len, msgid))
        print("    \(hex(b, 0..<min(32, b.count)))")
        return
    }
    imuPacketCount += 1

    // gyro group:  mul@12 (i16 LE), div@14 (i32 LE), xyz@18/21/24 (i24 LE)
    let gMul = Double(i16(b, 12)), gDiv = Double(i32(b, 14))
    let gx = Double(i24(b, 18)) * gMul / gDiv
    let gy = Double(i24(b, 21)) * gMul / gDiv
    let gz = Double(i24(b, 24)) * gMul / gDiv

    // accel group, same shape, immediately after: mul@27, div@29, xyz@33/36/39
    let aMul = Double(i16(b, 27)), aDiv = Double(i32(b, 29))
    let ax = Double(i24(b, 33)) * aMul / aDiv
    let ay = Double(i24(b, 36)) * aMul / aDiv
    let az = Double(i24(b, 39)) * aMul / aDiv

    // magnetometer: 16-bit values, mul/div BIG-endian, values in offset binary
    // (XOR 0x8000 -> two's complement). Units are gauss; |m| lands at ~0.30 G = 30 uT.
    let mMul = Double(be16(b, 42)), mDiv = Double(be32(b, 44))
    func mag(_ o: Int) -> Double {
        let raw = UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
        return Double(Int16(bitPattern: raw ^ 0x8000)) * mMul / mDiv
    }
    let mx = mag(48), my = mag(50), mz = mag(52)

    // dump a settled packet, not the all-zero initialisation one
    if !imuFirstDumped && imuPacketCount == 10 {
        imuFirstDumped = true
        print("\n--- settled data packet #10, raw 64 bytes ---")
        for row in stride(from: 0, to: b.count, by: 16) {
            print(String(format: "  %02d: %@", row, hex(b, row..<min(row + 16, b.count))))
        }
        print("""

        --- verified field map ---
          [0..2)   signature    \(hex(b, 0..<2))
          [2..4)   temperature  \(i16(b, 2))
          [4..12)  timestamp    \(hex(b, 4..<12))
          [12..14) gyro  mul    \(Int(gMul))        LE
          [14..18) gyro  div    \(Int(gDiv))   LE
          [18..27) gyro  xyz    \(hex(b, 18..<27))
          [27..29) accel mul    \(Int(aMul))          LE
          [29..33) accel div    \(Int(aDiv))   LE
          [33..42) accel xyz    \(hex(b, 33..<42))
          [42..44) mag   mul    \(Int(mMul))  (BE)  raw \(hex(b, 42..<44))
          [44..48) mag   div    \(Int(mDiv))  (BE)  raw \(hex(b, 44..<48))
          [48..54) mag   xyz    \(hex(b, 48..<54))
          [54..64) tail         \(hex(b, 54..<64))
        """)
    }

    if imuPacketCount <= 2 || imuPacketCount % 500 == 0 {
        print(String(format:
            "#%-5d gyro(%+7.3f %+7.3f %+7.3f) deg/s   accel(%+6.3f %+6.3f %+6.3f) |a|=%.3f g   mag(%+7.3f %+7.3f %+7.3f) |m|=%.3f",
            imuPacketCount, gx, gy, gz, ax, ay, az,
            (ax * ax + ay * ay + az * az).squareRoot(),
            mx, my, mz, (mx * mx + my * my + mz * mz).squareRoot()))
    }
}

/// IMU framing: AA | crc32(body) | body, where body = le16(len) | msgid | data.
/// VERIFIED: len counts the whole body *including its own two bytes* — same rule the MCU
/// interface uses. (xrealAir.md §5 documents len=3 here; the device only accepts 4.)
func imuPacket(msgid: UInt8, data: [UInt8]) -> [UInt8] {
    let body = le16(UInt16(3 + data.count)) + [msgid] + data
    return [0xAA] + le32(crc32(body)) + body
}

func sendIMU(_ dev: IOHIDDevice, msgid: UInt8, data: [UInt8], label: String, settle: Double) {
    let p = imuPacket(msgid: msgid, data: data)
    let r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0, p, p.count)
    print("\n> \(label) [msgid 0x\(String(format: "%02x", msgid))]: \(hex(p, 0..<p.count)) -> \(ret(r))")
    CFRunLoopRunInMode(.defaultMode, settle, false)
}

func cmdIMU(_ devs: [XDev], seconds: Double, withCalHandshake: Bool) {
    guard let imu = find(devs, iface: 3) else { print("IMU interface 3 not found"); exit(1) }
    guard openDevice(imu.device, label: "IMU") else { exit(1) }

    let bufSize = max(imu.maxIn, 64)
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
    buf.initialize(repeating: 0, count: bufSize)

    IOHIDDeviceRegisterInputReportCallback(imu.device, buf, bufSize, { _, _, _, _, _, report, len in
        decodeIMU(Array(UnsafeBufferPointer(start: report, count: len)))
    }, nil)
    IOHIDDeviceScheduleWithRunLoop(imu.device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    imuStart = Date()

    if withCalHandshake {
        // The reference driver walks this before starting the stream. Harmless reads —
        // all well below the firmware-update range.
        sendIMU(imu.device, msgid: 0x14, data: [], label: "GET_CAL_DATA_LENGTH", settle: 0.6)
        for i in 1...3 {
            sendIMU(imu.device, msgid: 0x15, data: [], label: "CAL_DATA_GET_NEXT_SEG #\(i)", settle: 0.4)
        }
        sendIMU(imu.device, msgid: 0x18, data: [], label: "FREE_CAL_BUFFER", settle: 0.4)
        sendIMU(imu.device, msgid: 0x1A, data: [], label: "GET_STATIC_ID", settle: 0.4)
    }

    sendIMU(imu.device, msgid: 0x19, data: [0x01], label: "START_IMU_DATA", settle: 0.3)

    print("\n  listening \(seconds)s — move the glasses to see the gyro respond")
    CFRunLoopRunInMode(.defaultMode, seconds, false)

    print("\n  data packets: \(imuPacketCount)   other reports: \(imuOtherReports)")
    if imuPacketCount > 0 {
        print("  sample rate: ~\(Int(Double(imuPacketCount) / seconds)) Hz")
    }
    sendIMU(imu.device, msgid: 0x19, data: [0x00], label: "STOP_IMU_DATA", settle: 0.2)
    IOHIDDeviceClose(imu.device, IOOptionBits(kIOHIDOptionsTypeNone))
}

/// Sweep the length field for START_IMU_DATA. The canned reject reply is constant, so
/// *any* different reply — or an actual data packet — identifies the correct encoding.
func cmdSweep(_ devs: [XDev]) {
    guard let imu = find(devs, iface: 3) else { print("IMU interface 3 not found"); exit(1) }
    guard openDevice(imu.device, label: "IMU") else { exit(1) }

    let bufSize = max(imu.maxIn, 64)
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
    buf.initialize(repeating: 0, count: bufSize)
    IOHIDDeviceRegisterInputReportCallback(imu.device, buf, bufSize, { _, _, _, _, _, report, len in
        decodeIMU(Array(UnsafeBufferPointer(start: report, count: len)))
    }, nil)
    IOHIDDeviceScheduleWithRunLoop(imu.device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    imuQuiet = true
    imuStart = Date()

    print("\nsweeping length field for START_IMU_DATA (msgid 0x19, data 0x01):")
    for len in UInt16(0)...UInt16(8) {
        imuInbox.removeAll(); imuPacketCount = 0
        let body = le16(len) + [0x19, 0x01]
        let packet: [UInt8] = [0xAA] + le32(crc32(body)) + body
        _ = IOHIDDeviceSetReport(imu.device, kIOHIDReportTypeOutput, 0, packet, packet.count)
        CFRunLoopRunInMode(.defaultMode, 0.5, false)

        let rejected = imuInbox.allSatisfy { Array($0.prefix(12)) == cannedReject }
        let verdict: String
        if imuPacketCount > 0 { verdict = "*** \(imuPacketCount) IMU DATA PACKETS ***" }
        else if imuInbox.isEmpty { verdict = "no reply" }
        else if rejected { verdict = "canned reject" }
        else { verdict = "*** DIFFERENT REPLY: \(hex(imuInbox[0], 0..<min(16, imuInbox[0].count))) ***" }
        print(String(format: "  len=%d  body=%@  ->  %@", len, hex(body, 0..<body.count), verdict))
    }

    imuQuiet = false
    IOHIDDeviceClose(imu.device, IOOptionBits(kIOHIDOptionsTypeNone))
}

// --- MCU ---

/// §6 framing: FD | crc32(body) | body, where body = len | ts | msgid | 5 reserved | data
func mcuPacket(msgid: UInt16, data: [UInt8]) -> [UInt8] {
    let length = UInt16(2 + 8 + 2 + 5 + data.count)
    let ts = UInt64(Date().timeIntervalSince1970 * 1000)
    let body = le16(length) + le64(ts) + le16(msgid) + [0, 0, 0, 0, 0] + data
    return [0xFD] + le32(crc32(body)) + body
}

var mcuReplies: [[UInt8]] = []

func cmdMCU(_ devs: [XDev], msgid: UInt16, data: [UInt8], label: String) {
    guard let mcu = find(devs, iface: 4) else { print("MCU interface 4 not found"); exit(1) }
    guard openDevice(mcu.device, label: "MCU") else { exit(1) }

    let bufSize = max(mcu.maxIn, 64)
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
    buf.initialize(repeating: 0, count: bufSize)
    IOHIDDeviceRegisterInputReportCallback(mcu.device, buf, bufSize, { _, _, _, _, _, report, len in
        mcuReplies.append(Array(UnsafeBufferPointer(start: report, count: len)))
    }, nil)
    IOHIDDeviceScheduleWithRunLoop(mcu.device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

    let packet = mcuPacket(msgid: msgid, data: data)
    print("  \(label): \(hex(packet, 0..<packet.count))  (\(packet.count) bytes)")
    let w = IOHIDDeviceSetReport(mcu.device, kIOHIDReportTypeOutput, 0, packet, packet.count)
    print("  SetReport -> \(ret(w))")

    CFRunLoopRunInMode(.defaultMode, 1.5, false)

    print("  replies: \(mcuReplies.count)")
    for r in mcuReplies.prefix(4) {
        let echo = r.count >= 17 ? String(format: "0x%04x", Int(r[15]) | (Int(r[16]) << 8)) : "??"
        print("    msgid echo \(echo)  payload \(hex(r, 0..<min(24, r.count)))")
    }
    IOHIDDeviceClose(mcu.device, IOOptionBits(kIOHIDOptionsTypeNone))
}

// MARK: - main

let args = CommandLine.arguments
let cmd = args.count > 1 ? args[1] : "list"
let devices = discover()

if devices.isEmpty {
    print("No XREAL device found (vid 0x3318). Are the glasses plugged in?")
    exit(1)
}

switch cmd {
case "list":
    cmdList(devices)
case "imu":
    cmdIMU(devices, seconds: args.count > 2 ? (Double(args[2]) ?? 3) : 3, withCalHandshake: false)
case "sweep":
    cmdSweep(devices)
case "imuinit":
    cmdIMU(devices, seconds: args.count > 2 ? (Double(args[2]) ?? 5) : 5, withCalHandshake: true)
case "getmode":
    cmdMCU(devices, msgid: 0x0007, data: [], label: "R_DISP_MODE")
case "setmode":
    guard args.count > 2, let mode = ["2d": UInt8(0x1), "3d": UInt8(0x3)][args[2]] else {
        print("usage: hidprobe setmode 2d|3d"); exit(1)
    }
    cmdMCU(devices, msgid: 0x0008, data: [mode], label: "W_DISP_MODE \(args[2])")
default:
    print("usage: hidprobe [list|imu [sec]|getmode|setmode 2d|3d]")
    exit(1)
}
