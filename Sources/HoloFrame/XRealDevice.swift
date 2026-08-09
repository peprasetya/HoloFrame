//
//  XRealDevice.swift — talking to XREAL Air glasses over USB HID.
//
//  Protocol details, including the two corrections to the published notes, are in
//  xrealAir.md. The essentials:
//
//    * interface 3 = IMU, interface 4 = MCU. Match on bInterfaceNumber, which lives on the
//      IOUSBHostInterface ancestor — usage page does not discriminate (3, 4 and 5 all
//      report 0x0041).
//    * both open with a plain IOHIDDeviceOpen. No seize, no Input Monitoring, no hidapi.
//    * every message is CRC-32/ISO-HDLC (zlib) over a body whose length field counts
//      ITSELF plus the payload. Getting that wrong yields one constant 12-byte reply.
//

import Foundation
import IOKit
import IOKit.hid
import simd

// MARK: - samples

struct IMUSample {
    /// Device timestamp, nanoseconds.
    let timestamp: UInt64
    /// Angular rate, degrees/second.
    let gyro: SIMD3<Double>
    /// Acceleration, g. Reads ~1.0 magnitude at rest.
    let accel: SIMD3<Double>
    /// Magnetic field, gauss. Reads ~0.3 magnitude (30 µT) in a clean environment.
    let mag: SIMD3<Double>
}

// MARK: - errors

enum XRealError: Error, CustomStringConvertible {
    case notFound
    case interfaceMissing(Int)
    case openFailed(Int, IOReturn)
    case writeFailed(IOReturn)

    var description: String {
        switch self {
        case .notFound:
            return "No XREAL device found (vendor 0x3318). Are the glasses plugged in?"
        case .interfaceMissing(let n):
            return "XREAL HID interface \(n) not found."
        case .openFailed(let n, let r):
            return "Could not open XREAL interface \(n) (IOReturn 0x\(String(format: "%08x", UInt32(bitPattern: r)))). "
                 + "If another process owns the glasses — XREAL's Nebula, for instance — quit it first."
        case .writeFailed(let r):
            return "HID write failed (IOReturn 0x\(String(format: "%08x", UInt32(bitPattern: r)))"
        }
    }
}

// MARK: - CRC-32/ISO-HDLC

private let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
    var c = UInt32(i)
    for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
    return c
}

private func crc32(_ bytes: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for b in bytes { crc = crcTable[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
    return crc ^ 0xFFFF_FFFF
}

private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
private func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }

// MARK: - device

final class XRealDevice {

    /// Display modes the glasses accept via MCU message 0x08 (W_DISP_MODE).
    ///
    /// The side-by-side modes are what make stereo possible: the glasses take a
    /// 3840x1080 signal and give each eye its own 1920x1080 half.
    enum DisplayMode: UInt8 {
        case mono1080p60  = 0x1
        case sbs3D60      = 0x3   // 3840x1080 @ 60, side-by-side
        case sbs3D72      = 0x4
        case mono1080p72  = 0x5
        case sbs3D90      = 0x9
        case mono1080p90  = 0xA
        case mono1080p120 = 0xB

        var isStereo: Bool {
            switch self {
            case .sbs3D60, .sbs3D72, .sbs3D90: return true
            default: return false
            }
        }
    }

    private static let vendorID = 0x3318
    private static let imuInterface = 3
    private static let mcuInterface = 4

    private let imu: IOHIDDevice
    private let mcu: IOHIDDevice
    private var mcuBuffer: UnsafeMutablePointer<UInt8>?
    private var buttonHandler: ((UInt16, [UInt8]) -> Void)?

    private var imuThread: Thread?
    private var imuRunLoop: CFRunLoop?
    private var imuBuffer: UnsafeMutablePointer<UInt8>?
    private var streaming = false
    private let threadFinished = DispatchSemaphore(value: 0)

    /// Set before starting the stream; called on the IMU thread at ~1000 Hz.
    private var sampleHandler: ((IMUSample) -> Void)?

    // MARK: init

    init() throws {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: Self.vendorID] as CFDictionary)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devices.isEmpty else {
            throw XRealError.notFound
        }

        var byInterface: [Int: IOHIDDevice] = [:]
        for device in devices {
            if let n = Self.interfaceNumber(of: device) { byInterface[n] = device }
        }
        guard let imu = byInterface[Self.imuInterface] else {
            throw XRealError.interfaceMissing(Self.imuInterface)
        }
        guard let mcu = byInterface[Self.mcuInterface] else {
            throw XRealError.interfaceMissing(Self.mcuInterface)
        }
        self.imu = imu
        self.mcu = mcu

        for (n, device) in [(Self.imuInterface, imu), (Self.mcuInterface, mcu)] {
            let r = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            guard r == kIOReturnSuccess else { throw XRealError.openFailed(n, r) }
        }
    }

    deinit {
        stopIMU()
        IOHIDDeviceClose(imu, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDDeviceClose(mcu, IOOptionBits(kIOHIDOptionsTypeNone))
        imuBuffer?.deallocate()
    }

    /// bInterfaceNumber is a property of the IOUSBHostInterface ancestor, not of the
    /// IOHIDDevice. Usage page cannot be used instead — interfaces 3, 4 and 5 all report
    /// usage page 0x0041, usage 0x0000.
    private static func interfaceNumber(of device: IOHIDDevice) -> Int? {
        var current = IOHIDDeviceGetService(device)
        guard current != 0 else { return nil }
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        for _ in 0..<6 {
            if let raw = IORegistryEntryCreateCFProperty(
                current, "bInterfaceNumber" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? NSNumber {
                return raw.intValue
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, "IOService", &parent) == KERN_SUCCESS else { return nil }
            IOObjectRelease(current)
            current = parent
        }
        return nil
    }

    // MARK: MCU — display mode

    /// MCU framing: FD | crc32(body) | body, body = len(2) | timestamp(8) | msgid(2) |
    /// reserved(5) | data. `len` counts itself onward.
    private func mcuPacket(msgid: UInt16, data: [UInt8]) -> [UInt8] {
        let length = UInt16(2 + 8 + 2 + 5 + data.count)
        let ts = UInt64(Date().timeIntervalSince1970 * 1000)
        let body = le16(length) + le64(ts) + le16(msgid) + [0, 0, 0, 0, 0] + data
        return [0xFD] + le32(crc32(body)) + body
    }

    @discardableResult
    func setDisplayMode(_ mode: DisplayMode) throws -> Bool {
        let packet = mcuPacket(msgid: 0x0008, data: [mode.rawValue])
        let r = IOHIDDeviceSetReport(mcu, kIOHIDReportTypeOutput, 0, packet, packet.count)
        guard r == kIOReturnSuccess else { throw XRealError.writeFailed(r) }
        return true
    }

    // MARK: buttons

    /// Listen for the physical buttons on the temple.
    ///
    /// The glasses push `P_BUTTON_PRESSED` (0x6C05) and `P_DISPLAY_TOGGLED` (0x6C04) on the
    /// MCU interface whenever the wearer presses one. This is worth far more than it looks:
    /// it is a real button, reported by the firmware, with no threshold to tune and nothing
    /// to mistake it for. Every attempt here to infer intent from the accelerometer —
    /// taps, leans — foundered on the same rock, that a sensor watching for a gesture is
    /// also watching everything else you do.
    ///
    /// Scheduled on the main run loop rather than its own thread: these arrive when a
    /// finger moves, not at 1 kHz.
    func startButtons(_ handler: @escaping (UInt16, [UInt8]) -> Void) {
        guard mcuBuffer == nil else { return }
        buttonHandler = handler

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        buffer.initialize(repeating: 0, count: 64)
        mcuBuffer = buffer

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(mcu, buffer, 64, { ctx, _, _, _, _, report, length in
            guard let ctx else { return }
            let device = Unmanaged<XRealDevice>.fromOpaque(ctx).takeUnretainedValue()
            device.handleMCUReport(UnsafeBufferPointer(start: report, count: length))
        }, context)
        IOHIDDeviceScheduleWithRunLoop(mcu, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    /// Unregister before the callback's context can outlive us — the same use-after-free
    /// that `stopIMU` guards against, and the reason this is not left to deinit.
    func stopButtons() {
        guard let buffer = mcuBuffer else { return }
        IOHIDDeviceRegisterInputReportCallback(mcu, buffer, 64, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(mcu, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        buffer.deallocate()
        mcuBuffer = nil
        buttonHandler = nil
    }

    private func handleMCUReport(_ b: UnsafeBufferPointer<UInt8>) {
        // Inbound framing mirrors outbound: FD | crc32 | len(2) | ts(8) | msgid(2) | ...
        // Confirmed rather than assumed — 0x6C02 (P_START_HEARTBEAT) arrives at exactly
        // this offset, which is a documented constant landing where the parse expects it.
        guard b.count >= 17, b[0] == 0xFD else { return }
        let msgid = UInt16(b[15]) | (UInt16(b[16]) << 8)
        let data = Array(b[min(22, b.count)...])
        DispatchQueue.main.async { [buttonHandler] in buttonHandler?(msgid, data) }
    }

    // MARK: IMU

    /// IMU framing: AA | crc32(body) | body, body = len(2) | msgid(1) | data.
    /// `len` counts itself — 4 for START_IMU_DATA, not the 3 the published notes claim.
    private func imuPacket(msgid: UInt8, data: [UInt8]) -> [UInt8] {
        let body = le16(UInt16(3 + data.count)) + [msgid] + data
        return [0xAA] + le32(crc32(body)) + body
    }

    /// Begin streaming at ~1000 Hz. `handler` is invoked on a dedicated high-priority
    /// thread — keep it allocation-free and do not block.
    func startIMU(_ handler: @escaping (IMUSample) -> Void) throws {
        guard !streaming else { return }
        streaming = true
        sampleHandler = handler

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        buffer.initialize(repeating: 0, count: 64)
        imuBuffer = buffer

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(imu, buffer, 64, { ctx, _, _, _, _, report, length in
            guard let ctx else { return }
            let device = Unmanaged<XRealDevice>.fromOpaque(ctx).takeUnretainedValue()
            device.handleReport(UnsafeBufferPointer(start: report, count: length))
        }, context)

        let thread = Thread { [weak self] in
            guard let self else { return }
            self.imuRunLoop = CFRunLoopGetCurrent()
            IOHIDDeviceScheduleWithRunLoop(self.imu, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            let start = self.imuPacket(msgid: 0x19, data: [0x01])
            IOHIDDeviceSetReport(self.imu, kIOHIDReportTypeOutput, 0, start, start.count)
            while self.streaming && CFRunLoopRunInMode(.defaultMode, 0.25, false) != .stopped {}
            self.threadFinished.signal()
        }
        thread.name = "id.prasetya.holoframe.imu"
        thread.qualityOfService = .userInteractive
        thread.start()
        imuThread = thread
    }

    func stopIMU() {
        guard streaming else { return }
        streaming = false

        let stop = imuPacket(msgid: 0x19, data: [0x00])
        IOHIDDeviceSetReport(imu, kIOHIDReportTypeOutput, 0, stop, stop.count)

        // Tear the callback down and wait for the thread to actually be gone before
        // returning.
        //
        // The input-report callback holds an UNRETAINED pointer to self. If this object is
        // released while a report is still in flight — which is exactly what unplugging
        // does — that is a use-after-free, and the process dies with no crash report and
        // nothing in the log. Unregistering and joining here is what makes teardown safe.
        if let runLoop = imuRunLoop {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [self] in
                if let buffer = imuBuffer {
                    IOHIDDeviceRegisterInputReportCallback(imu, buffer, 64, nil, nil)
                }
                IOHIDDeviceUnscheduleFromRunLoop(imu, runLoop, CFRunLoopMode.defaultMode.rawValue)
            }
            CFRunLoopWakeUp(runLoop)
            CFRunLoopStop(runLoop)
        }
        // The thread signals this on its way out; a timeout keeps a wedged device from
        // hanging shutdown.
        _ = threadFinished.wait(timeout: .now() + 1.0)

        imuThread = nil
        imuRunLoop = nil
        sampleHandler = nil
    }

    // MARK: decoding

    private func handleReport(_ b: UnsafeBufferPointer<UInt8>) {
        // Reports can still arrive between stopIMU() beginning and the callback actually
        // being unregistered.
        guard streaming else { return }
        // Non-0x0102 reports are acks or the "did not parse" reject; ignore them.
        guard b.count >= 54, b[0] == 0x01, b[1] == 0x02 else { return }

        func i16(_ o: Int) -> Int16 { Int16(bitPattern: UInt16(b[o]) | (UInt16(b[o + 1]) << 8)) }
        func i32(_ o: Int) -> Int32 {
            var v: UInt32 = 0
            for k in (0..<4).reversed() { v = (v << 8) | UInt32(b[o + k]) }
            return Int32(bitPattern: v)
        }
        func i24(_ o: Int) -> Int32 {
            var v = UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16)
            if v & 0x80_0000 != 0 { v |= 0xFF00_0000 }
            return Int32(bitPattern: v)
        }
        func be16(_ o: Int) -> Int16 { Int16(bitPattern: (UInt16(b[o]) << 8) | UInt16(b[o + 1])) }
        func be32(_ o: Int) -> Int32 {
            var v: UInt32 = 0
            for k in 0..<4 { v = (v << 8) | UInt32(b[o + k]) }
            return Int32(bitPattern: v)
        }

        var timestamp: UInt64 = 0
        for k in (0..<8).reversed() { timestamp = (timestamp << 8) | UInt64(b[4 + k]) }

        // Each sensor group is multiplier, divisor, then values — not the other way round.
        let gScale = Double(i16(12)) / Double(i32(14))
        let gyro = SIMD3(Double(i24(18)), Double(i24(21)), Double(i24(24))) * gScale

        let aScale = Double(i16(27)) / Double(i32(29))
        let accel = SIMD3(Double(i24(33)), Double(i24(36)), Double(i24(39))) * aScale

        // Magnetometer: 16-bit, offset binary (XOR 0x8000), and its multiplier/divisor are
        // big-endian where every other group is little-endian.
        let mScale = Double(be16(42)) / Double(be32(44))
        func mag(_ o: Int) -> Double {
            let raw = UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
            return Double(Int16(bitPattern: raw ^ 0x8000))
        }
        let magnet = SIMD3(mag(48), mag(50), mag(52)) * mScale

        // The first packet or two after START arrive with every field zeroed.
        guard accel != .zero else { return }

        sampleHandler?(IMUSample(timestamp: timestamp, gyro: gyro, accel: accel, mag: magnet))
    }
}
