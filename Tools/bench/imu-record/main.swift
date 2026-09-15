import Foundation

// Record raw IMU samples alongside a running HoloFrame. Both processes open the HID
// interfaces without seizing them, so both receive every report. Never sends STOP on exit,
// so HoloFrame's stream is left running.
setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
guard args.count >= 3, let seconds = Double(args[2]) else {
    print("usage: imurec <out.bin> <seconds>"); exit(2)
}
guard let recorder = IMURecorder(path: args[1]) else { print("cannot open \(args[1])"); exit(1) }

let device: XRealDevice
do { device = try XRealDevice() } catch { print("\(error)"); exit(1) }

let lock = NSLock()
var count = 0
do {
    try device.startIMU { sample in
        lock.lock(); count += 1; lock.unlock()
        recorder.record(sample)
    }
} catch { print("\(error)"); exit(1) }

let start = Date()
while Date().timeIntervalSince(start) < seconds {
    RunLoop.current.run(until: Date().addingTimeInterval(30))
    lock.lock(); let c = count; lock.unlock()
    print(String(format: "%.0fs  %d samples", Date().timeIntervalSince(start), c))
}
// Flush on the IMU thread's behalf: stop taking samples first by leaving the process.
lock.lock()
recorder.flush()
print("wrote \(count) samples")
exit(0)
