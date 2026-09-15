//
//  Diagnostics.swift — switches for measuring HoloFrame without wearing it.
//
//  Everything here is off unless an environment variable turns it on, so an ordinary launch
//  behaves exactly as if this file did not exist. Launch with, for example:
//
//      open -a HoloFrame.app --env HOLOFRAME_SIM=1 --env HOLOFRAME_STATS=10 \
//           --stdout /tmp/holoframe.log --stderr /tmp/holoframe.log
//
//    HOLOFRAME_SIM=1 | hold     drive the view from a synthetic head sweep (or a head holding
//                               still, for measuring the reading case) instead of the
//                               IMU, and never idle-pause — so the render, capture and
//                               pointer paths run under realistic load with the glasses
//                               sitting on a desk
//    HOLOFRAME_STATS=<seconds>  log render/capture rates, render CPU time, pointer warps and
//                               the tracker's raw yaw, bias and magnetic anchor state
//    HOLOFRAME_RECORD=<path>    append every raw IMU sample to a binary file (10 doubles per
//                               sample: timestamp ns, gyro xyz, accel xyz, mag xyz), for
//                               replaying through the tracker offline
//    HOLOFRAME_GPU=glasses      render on the glasses' GPU rather than the canvas's
//    HOLOFRAME_CAPTURE_FPS=<n>  override the capture-rate setting. The canvas itself stays at
//                               60 Hz: a virtual display offering only 30 Hz modes never
//                               becomes active
//    HOLOFRAME_NO_SKIP=1        draw every frame, even ones identical to the last
//    HOLOFRAME_CAPTURE_CURSOR=0 leave the pointer out of the captured frames
//    HOLOFRAME_NO_CAPTURE=1     never start capture, to measure what the canvas costs the
//                               window server on its own
//

import Foundation
import QuartzCore
import simd

enum Diagnostics {
    private static let env = ProcessInfo.processInfo.environment

    static let simulateMotion = env["HOLOFRAME_SIM"] != nil
    /// HOLOFRAME_SIM=hold: a head holding still to read — sub-pixel tremor and nothing else.
    private static let simulateHold = env["HOLOFRAME_SIM"] == "hold"
    /// HOLOFRAME_SIM=right / left / up / down: turned all the way to that canvas edge and held.
    private static let simulateEdge = env["HOLOFRAME_SIM"].flatMap { mode -> (Double, Double)? in
        switch mode {
        case "right": return (-179, 0)
        case "left":  return (179, 0)
        case "up":    return (0, 89)
        case "down":  return (0, -89)
        default:      return nil
        }
    }
    static let statsInterval: Double? = env["HOLOFRAME_STATS"].flatMap(Double.init)
    static let recordPath: String? = env["HOLOFRAME_RECORD"]
    static let renderOnGlassesGPU = env["HOLOFRAME_GPU"] == "glasses"
    /// Overrides the capture-rate setting when set.
    static let captureFrameRate: Double? = env["HOLOFRAME_CAPTURE_FPS"].flatMap(Double.init)
    static let disableFrameSkip = env["HOLOFRAME_NO_SKIP"] != nil
    static let captureCursor = env["HOLOFRAME_CAPTURE_CURSOR"] != "0"
    static let disableCapture = env["HOLOFRAME_NO_CAPTURE"] != nil

    /// A head that never stops moving: a slow wide sweep with a quicker small glance on top,
    /// on periods that do not share a multiple, so the view keeps visiting new canvas.
    static func simulatedPose(at t: CFTimeInterval) -> (yaw: Double, pitch: Double, roll: Double) {
        let tau = 2 * Double.pi
        if let edge = simulateEdge { return (yaw: edge.0, pitch: edge.1, roll: 0) }
        if simulateHold {
            return (yaw: 0.02 * sin(tau * t * 1.1), pitch: 0.02 * sin(tau * t * 0.8), roll: 0.01 * sin(tau * t * 0.6))
        }
        return (yaw: 30 * sin(tau * t / 11) + 6 * sin(tau * t / 2.3),
                pitch: 9 * sin(tau * t / 7) + 2 * sin(tau * t / 1.9),
                roll: 2 * sin(tau * t / 5))
    }
}

/// Raw IMU samples to a file. Called only from the IMU thread.
final class IMURecorder {
    private let handle: FileHandle
    private var buffer: [Double] = []

    init?(path: String) {
        guard FileManager.default.createFile(atPath: path, contents: nil),
              let handle = FileHandle(forWritingAtPath: path) else { return nil }
        self.handle = handle
        buffer.reserveCapacity(10_000)
    }

    func record(_ s: IMUSample) {
        buffer.append(contentsOf: [Double(s.timestamp),
                                   s.gyro.x, s.gyro.y, s.gyro.z,
                                   s.accel.x, s.accel.y, s.accel.z,
                                   s.mag.x, s.mag.y, s.mag.z])
        if buffer.count >= 10_000 { flush() }
    }

    func flush() {
        buffer.withUnsafeBytes { handle.write(Data($0)) }
        buffer.removeAll(keepingCapacity: true)
    }

    deinit { flush() }
}
