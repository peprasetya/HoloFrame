//
//  AxisCalibration.swift — work out how the IMU's axes map to head motion.
//
//  The glasses do not publish their axis convention, and guessing produces exactly the
//  symptom this was written for: nodding rotates the image instead of panning it, because
//  physical pitch lands on the roll axis.
//
//  This runs inside the normal app on first launch, showing its instructions on the
//  glasses through GlassesDisplay — nobody should have to open a terminal to make the
//  thing work. Each phase asks for one unambiguous motion and integrates signed rate over
//  the window: a sustained turn accumulates while tremor cancels out, giving both the axis
//  and the direction convention.
//

import AppKit
import Foundation
import simd

/// Lets calibration listen to raw, un-remapped IMU samples while the tracker also consumes
/// them. Calibration must see the sensor's own axes, not the canonical ones.
final class SampleTap {
    private let lock = NSLock()
    private var sink: ((IMUSample) -> Void)?

    func set(_ sink: ((IMUSample) -> Void)?) {
        lock.lock(); self.sink = sink; lock.unlock()
    }

    func feed(_ sample: IMUSample) {
        lock.lock(); let sink = self.sink; lock.unlock()
        sink?(sample)
    }
}

enum AxisCalibration {

    private struct Phase {
        let heading: String
        let instruction: String
    }

    /// The three motions AxisMap is defined against. Each stores the sensor axis and the
    /// sign that makes THAT motion read positive; converting to the canonical frame is
    /// AxisMap's job, not this one's.
    private static let phases = [
        Phase(heading: "Turn LEFT",
              instruction: "Slowly turn your head to the left,\nlike saying “no”, and hold."),
        Phase(heading: "Look DOWN",
              instruction: "Slowly nod your head down,\nchin toward chest, and hold."),
        Phase(heading: "Tilt LEFT",
              instruction: "Slowly tilt your head to the left,\nleft ear toward left shoulder, and hold."),
    ]

    private static let axisNames = ["X", "Y", "Z"]
    private static let minimumDegrees = 15.0
    private static let maxAttempts = 4

    /// Drives the whole sequence on the main run loop. Must be called after the glasses
    /// window exists, so its overlay can be drawn.
    static func run(display: GlassesDisplay, tap: SampleTap) -> AxisMap? {
        let lock = NSLock()
        var integral = SIMD3<Double>.zero
        var latestRate = 0.0
        var collecting = false

        tap.set { sample in
            lock.lock()
            if collecting { integral += sample.gyro * 0.001 }
            latestRate = simd_length(sample.gyro)
            lock.unlock()
        }
        defer { tap.set(nil) }

        /// Pump the run loop so the overlay redraws and IMU callbacks land.
        func wait(_ seconds: Double) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }

        // --- wait until the glasses are actually on a head ---
        display.showMessage(heading: "Set up head tracking",
                            body: "Put the glasses on,\nthen shake your head to begin.",
                            status: "waiting")
        print("\n  Calibration: put the glasses on and shake your head to begin.")

        let started = Date()
        while true {
            wait(0.1)
            lock.lock(); let rate = latestRate; lock.unlock()
            if rate > 60 { break }
            if Date().timeIntervalSince(started) > 180 {
                display.showMessage(heading: "Skipped", body: "No movement detected.", status: "")
                print("  Calibration: timed out waiting for movement.")
                wait(2.0)
                display.hideMessage()
                return nil
            }
        }

        display.showMessage(heading: "Here we go",
                            body: "Three movements.\nMove slowly and hold each one.",
                            status: "")
        wait(2.5)

        // --- the three phases ---
        var measured: [(phase: Phase, axis: Int, value: Double)] = []

        for (index, phase) in phases.enumerated() {
            let step = "\(index + 1) of \(phases.count)"
            var accepted: (axis: Int, value: Double)?

            for attempt in 1...maxAttempts {
                for n in stride(from: 3, through: 1, by: -1) {
                    display.showMessage(heading: phase.heading, body: phase.instruction,
                                        status: "\(step)   ·   get ready \(n)")
                    wait(1.0)
                }

                lock.lock(); integral = .zero; collecting = true; lock.unlock()
                display.showMessage(heading: phase.heading, body: phase.instruction,
                                    status: "\(step)   ·   MOVE NOW")
                wait(4.0)
                lock.lock(); collecting = false; let captured = integral; lock.unlock()

                let magnitudes = [abs(captured.x), abs(captured.y), abs(captured.z)]
                let dominant = magnitudes.firstIndex(of: magnitudes.max()!)!
                print(String(format: "  [%@] %@: X %+7.1f  Y %+7.1f  Z %+7.1f  ->  %@ %@",
                             step, phase.heading, captured.x, captured.y, captured.z,
                             axisNames[dominant], captured[dominant] < 0 ? "negative" : "positive"))

                if abs(captured[dominant]) >= minimumDegrees {
                    accepted = (dominant, captured[dominant])
                    display.showMessage(heading: phase.heading, body: "Good.", status: "\(step)   ·   done")
                    wait(1.2)
                    break
                }

                // Retry rather than abort — the usual cause is simply not having started
                // to move yet, and discarding good phases for that is needless.
                display.showMessage(heading: "Bigger movement",
                                    body: phase.instruction,
                                    status: attempt < maxAttempts ? "too small — again" : "still too small")
                wait(2.5)
            }

            guard let accepted else {
                display.showMessage(heading: "Couldn’t measure that",
                                    body: "Skipping head-tracking setup.\nYou can redo it any time.",
                                    status: "")
                print("  Calibration: gave up on \(phase.heading).")
                wait(3.0)
                display.hideMessage()
                return nil
            }
            measured.append((phase, accepted.axis, accepted.value))
        }

        // --- build and store ---
        /// The factor that makes this measured motion read positive.
        func sign(_ m: (phase: Phase, axis: Int, value: Double)) -> Double {
            m.value < 0 ? -1 : 1
        }

        let map = AxisMap(yawAxis: measured[0].axis, yawSign: sign(measured[0]),
                          pitchAxis: measured[1].axis, pitchSign: sign(measured[1]),
                          rollAxis: measured[2].axis, rollSign: sign(measured[2]))

        // Two right-handed frames cannot differ by a mirror, so a negative determinant
        // means a measured sign is wrong — almost always a motion that combined two axes.
        // Storing it anyway makes the filter fight itself in ways that look like drift.
        if !map.isRightHanded {
            display.showMessage(heading: "Didn’t work",
                                body: "The movements came out mirrored.\nTry again, keeping each one clean and separate.",
                                status: "")
            print("  Calibration: mirrored frame (det -1) — \(map.summary)")
            wait(4.0)
            display.hideMessage()
            return nil
        }

        guard map.isUsable else {
            display.showMessage(heading: "Didn’t work",
                                body: "Two movements came out the same.\nTry again, keeping each one separate.",
                                status: "")
            print("  Calibration: two motions mapped to the same axis.")
            wait(4.0)
            display.hideMessage()
            return nil
        }

        do {
            try map.save()
            print("  Calibration: \(map.summary) — saved to \(AxisMap.storeURL.path)")
            display.showMessage(heading: "All set", body: "Head tracking is calibrated.", status: map.summary)
        } catch {
            print("  Calibration: could not save — \(error)")
            display.showMessage(heading: "All set", body: "Calibrated, but couldn’t save.", status: "\(error)")
        }
        wait(2.5)
        display.hideMessage()
        return map
    }
}
