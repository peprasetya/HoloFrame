import Foundation
import simd

// Offline yaw-drift test for HeadTracker.
//
// Takes a real recording of the glasses lying still — genuine gyro bias, bias wander with
// temperature, sensor noise, and the real magnetic field — and superimposes a scripted head
// motion with a KNOWN true orientation. The tracker cannot tell the difference, and because
// the truth is known, its yaw error can be measured exactly over as long as we like.

setvbuf(stdout, nil, _IOLBF, 0)

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: driftsim <recording.bin> [minutes] [scenario...]"); exit(2) }
let minutes = args.count >= 3 ? Double(args[2]) ?? 20 : 20
let only = Set(args.dropFirst(3))

// MARK: recording

struct Recording {
    var t: [Double] = []
    var gyro: [SIMD3<Double>] = []
    var accel: [SIMD3<Double>] = []
    var mag: [SIMD3<Double>] = []
    var duration: Double { (t.last ?? 0) + 0.001 }
}

func load(_ path: String, axes: AxisMap) -> Recording {
    let data = try! Data(contentsOf: URL(fileURLWithPath: path))
    let n = data.count / 80
    var values = [Double](repeating: 0, count: n * 10)
    values.withUnsafeMutableBytes { _ = data.copyBytes(to: $0) }
    var r = Recording()
    let t0 = values[0]
    for i in 0..<n {
        let b = i * 10
        r.t.append((values[b] - t0) * 1e-9)
        r.gyro.append(axes.apply(SIMD3(values[b + 1], values[b + 2], values[b + 3])))
        r.accel.append(axes.apply(SIMD3(values[b + 4], values[b + 5], values[b + 6])))
        r.mag.append(axes.apply(SIMD3(values[b + 7], values[b + 8], values[b + 9])))
    }
    return r
}

let axes = AxisMap.load() ?? .identity
let rec = load(args[1], axes: axes)
let n = rec.t.count
print(String(format: "recording: %d samples, %.1f s, %.0f Hz", n, rec.duration, Double(n) / rec.duration))

// The desk attitude and the field, from the recording's average.
let meanAccel = rec.accel.reduce(.zero, +) / Double(n)
let meanMag = rec.mag.reduce(.zero, +) / Double(n)
let meanGyro = rec.gyro.reduce(.zero, +) / Double(n)
let deskAttitude = simd_quatd(from: simd_normalize(meanAccel), to: SIMD3(0, 0, 1))
let worldField = deskAttitude.act(meanMag)
print(String(format: "static gyro mean %+.3f %+.3f %+.3f deg/s   |accel| %.3f g   |mag| %.3f G  inclination %.1f°",
             meanGyro.x, meanGyro.y, meanGyro.z, simd_length(meanAccel), simd_length(meanMag),
             atan2(-worldField.z, simd_length(SIMD2(worldField.x, worldField.y))) * 180 / .pi))

// Bias wander across the recording: one-minute means.
var minuteLine = "gyro-z bias per minute:"
var k = 0
while k < n {
    let end = min(n, k + 60_000)
    let m = rec.gyro[k..<end].reduce(.zero, +) / Double(end - k)
    minuteLine += String(format: " %+.3f", m.z)
    k = end
}
print(minuteLine)

// How tight the sensor is when nothing moves: the spread of 2 s windows, the same quantity
// the tracker's stillness test uses.
func spreads(_ gyro: [SIMD3<Double>], window: Int = 2000) -> [Double] {
    var out: [Double] = []
    var j = 0
    while j + window <= gyro.count {
        var sum = SIMD3<Double>.zero, sq = SIMD3<Double>.zero
        for g in gyro[j..<(j + window)] { sum += g; sq += g * g }
        let m = sum / Double(window)
        let v = sq / Double(window) - m * m
        out.append((max(v.x, 0) + max(v.y, 0) + max(v.z, 0)).squareRoot())
        j += window
    }
    return out.sorted()
}
let staticSpreads = spreads(rec.gyro)
func pct(_ a: [Double], _ p: Double) -> Double { a[min(a.count - 1, Int(Double(a.count) * p))] }
print(String(format: "static 2 s gyro spread: min %.3f  median %.3f  p99 %.3f  max %.3f deg/s",
             staticSpreads.first ?? 0, pct(staticSpreads, 0.5), pct(staticSpreads, 0.99), staticSpreads.last ?? 0))

var tuning = HeadTracker.Tuning()
let env = ProcessInfo.processInfo.environment
if let v = env["NOISE_LIMIT"].flatMap(Double.init) { tuning.stillnessNoiseLimit = v }
if let v = env["DEADBAND"].flatMap(Double.init) { tuning.driftDeadband = v }
if let v = env["RATE_GATE"].flatMap(Double.init) { tuning.stillnessRateThreshold = v }
if let v = env["MAG_SLOW"].flatMap(Double.init) { tuning.magSlowRate = v }
if let v = env["MAG_FAST"].flatMap(Double.init) { tuning.magFastRate = v }
if let v = env["MAG_GAIN"].flatMap(Double.init) { tuning.magGain = v }
if let v = env["MAG_KI"].flatMap(Double.init) { tuning.magBiasGain = v }
/// Start the tracker from a remembered bias, off by this much on z (deg/s) — the warm-up or
/// session-to-session change the stored value will not know about.
let presetError: Double? = env["PRESET_ERR"].flatMap(Double.init)
print("preset bias: \(presetError.map { String(format: "yes, z off by %+.2f deg/s", $0) } ?? "no")")
print("tuning: \(tuning)")

// MARK: motion

/// Deterministic, so every variant of the tracker sees exactly the same head.
struct SplitMix {
    var state: UInt64
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double(z ^ (z >> 31)) / Double(UInt64.max)
    }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
}

func minJerk(_ u: Double) -> Double {
    let x = min(max(u, 0), 1)
    return x * x * x * (10 - 15 * x + 6 * x * x)
}

typealias Pose = (yaw: Double, pitch: Double, roll: Double)

/// A piecewise script of moves: go to (yaw, pitch) over `move` seconds, then hold for
/// `hold` seconds with a small wobble on top.
struct Script {
    struct Step { let start: Double; let move: Double; let from: Pose; let to: Pose }
    var steps: [Step] = []
    var wobble: Double = 0

    func pose(_ t: Double) -> Pose {
        var lo = 0, hi = steps.count - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if steps[mid].start <= t { lo = mid } else { hi = mid - 1 } }
        let s = steps[lo]
        let u = minJerk((t - s.start) / s.move)
        let w = wobble
        return (s.from.yaw + (s.to.yaw - s.from.yaw) * u + w * (1.2 * sin(0.9 * t) + 0.5 * sin(2.7 * t + 1)),
                s.from.pitch + (s.to.pitch - s.from.pitch) * u + w * (0.6 * sin(0.7 * t + 2) + 0.3 * sin(3.1 * t)),
                s.from.roll + (s.to.roll - s.from.roll) * u + w * 0.4 * sin(0.5 * t))
    }
}

func buildScript(_ name: String, seconds: Double) -> Script {
    var rng = SplitMix(state: 42)
    var script = Script()
    var t = 0.0
    var at: Pose = (0, 0, 0)
    func add(_ to: Pose, move: Double, hold: Double) {
        script.steps.append(.init(start: t, move: move, from: at, to: to))
        t += move + hold
        at = to
    }
    add((0, 0, 0), move: 0.01, hold: 4)     // put on and settle
    switch name {
    case "still":
        add((0, 0, 0), move: 0.01, hold: seconds)
    case "wobble":
        // Only the small involuntary motion of a head holding still.
        script.wobble = 1
        add((0, 0, 0), move: 0.01, hold: seconds)
    case "work", "glances":
        // Glances between windows, dwelling to read, with natural wobble ("glances": none).
        script.wobble = name == "work" ? 1 : 0
        while t < seconds {
            add((rng.range(-35, 35), rng.range(-14, 10), rng.range(-3, 3)),
                move: rng.range(0.25, 0.9), hold: rng.range(2, 14))
        }
    case "reading":
        // Line by line: a slow drift right along the line, a quick return, the next line down.
        script.wobble = 0.3
        var line = 0
        while t < seconds {
            let pitch = 8 - Double(line % 20) * 0.9
            add((-12, pitch, 0), move: 0.25, hold: 0.2)
            add((12, pitch, 0), move: rng.range(4, 7), hold: 0.3)
            line += 1
        }
    case "asym":
        // Worst case for anything speed-dependent: out slowly, back fast.
        while t < seconds {
            add((25, 0, 0), move: 12, hold: 3)
            add((0, 0, 0), move: 0.4, hold: 5)
        }
    default:
        fatalError("unknown scenario \(name)")
    }
    return script
}

func quaternion(_ p: Pose) -> simd_quatd {
    let d = Double.pi / 180
    // Matches HeadTracker.euler: ZYX, with its pitch reported positive-up (about -Y).
    return simd_quatd(angle: p.yaw * d, axis: SIMD3(0, 0, 1))
        * simd_quatd(angle: -p.pitch * d, axis: SIMD3(0, 1, 0))
        * simd_quatd(angle: p.roll * d, axis: SIMD3(1, 0, 0))
}

func wrap(_ a: Double) -> Double {
    var x = a
    while x > 180 { x -= 360 }
    while x < -180 { x += 360 }
    return x
}

// MARK: run

struct Result { let final: Double; let maxAbs: Double; let rms: Double; let trace: [Double]; let biasTrace: [Double] }

func run(scenario: String, magnetic: Bool, hardIron: SIMD3<Double>) -> Result {
    let seconds = minutes * 60
    let script = buildScript(scenario, seconds: seconds)
    let tracker = HeadTracker(axes: .identity, tuning: tuning)
    tracker.magneticAnchorEnabled = magnetic
    // "mag" variants model a CALIBRATED magnetometer: the tracker is told the offset is zero,
    // and any hard iron added below is error the calibration missed.
    if magnetic { tracker.setHardIronOffset(.zero) }
    if let presetError { tracker.preset(bias: meanGyro + SIMD3(0, 0, presetError)) }

    let dt = 0.001
    var previous = quaternion(script.pose(0))
    var offset: Double?
    var maxAbs = 0.0, sumSq = 0.0, count = 0
    var trace: [Double] = []
    var biasTrace: [Double] = []
    let total = Int(seconds / dt)
    for i in 0..<total {
        let t = Double(i) * dt
        let r = i % n
        let truth = quaternion(script.pose(t))
        // Body rate from the change in true orientation over this step.
        let delta = previous.inverse * truth
        previous = truth
        let angle = delta.angle
        let rate = angle > 1e-12 ? delta.axis * (angle / dt) * (180 / .pi) : .zero

        let gyro = rate + rec.gyro[r]
        let accel = truth.inverse.act(SIMD3(0, 0, 1)) + (rec.accel[r] - meanAccel)
        let mag = truth.inverse.act(worldField) + hardIron + (rec.mag[r] - meanMag)
        tracker.integrate(IMUSample(timestamp: UInt64((t + 1) * 1e9), gyro: gyro, accel: accel, mag: mag))

        if i % 100 == 0 {
            let trueYaw = script.pose(t).yaw
            let yaw = tracker.diagnostics.yaw
            if t >= 4, offset == nil { offset = wrap(yaw - trueYaw) }
            if let offset {
                let err = wrap(yaw - trueYaw - offset)
                maxAbs = max(maxAbs, abs(err))
                sumSq += err * err
                count += 1
                if i % 60_000 == 0 { trace.append(err); biasTrace.append(tracker.diagnostics.bias.z - meanGyro.z) }
            }
        }
    }
    let finalErr = wrap(tracker.diagnostics.yaw - script.pose(seconds).yaw - (offset ?? 0))
    return Result(final: finalErr, maxAbs: maxAbs, rms: sqrt(sumSq / Double(max(count, 1))), trace: trace,
                  biasTrace: biasTrace)
}

let scenarios = ["still", "wobble", "glances", "work", "reading", "asym"].filter { only.isEmpty || only.contains($0) }
let fieldStrength = simd_length(worldField)
let variants: [(String, Bool, SIMD3<Double>)] = [
    ("gyro only", false, .zero),
    ("mag clean", true, .zero),
    ("mag +15% hard-iron", true, SIMD3(0.15 * fieldStrength, 0, 0)),
    ("mag +35% hard-iron", true, SIMD3(0.25 * fieldStrength, 0.25 * fieldStrength, 0)),
]
print(String(format: "\n%.0f minutes per run. Yaw error in degrees (tracker minus truth); trace is one value per minute.", minutes))
for scenario in scenarios {
    for (label, magnetic, hardIron) in variants {
        let r = run(scenario: scenario, magnetic: magnetic, hardIron: hardIron)
        print(String(format: "%-8@ %-20@ final %+7.2f  max %6.2f  rms %6.2f   ", scenario as NSString, label as NSString,
                     r.final, r.maxAbs, r.rms)
              + r.trace.map { String(format: "%+.1f", $0) }.joined(separator: " ")
              + "   | bias-z error " + r.biasTrace.map { String(format: "%+.2f", $0) }.joined(separator: " "))
    }
}
