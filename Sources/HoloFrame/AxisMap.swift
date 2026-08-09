//
//  AxisMap.swift — how the IMU's raw axes map onto head motion.
//
//  The glasses do not publish their axis convention, so it is measured on first run and
//  stored here.
//
//  Canonical head frame — RIGHT-HANDED, which matters more than it looks:
//
//      +X = forward (nose)
//      +Y = left
//      +Z = up
//
//  X x Y = Z, so this is a proper rotation frame. An earlier version used X forward,
//  Y RIGHT, Z up, which is left-handed; combined with a measured axis swap that produced a
//  mapping with determinant -1 — a mirror rather than a rotation. Gyro integration and the
//  gravity correction then disagree about handedness and fight each other, which shows up
//  as pitch creeping back to one end and roll continuing past where you stopped.
//
//  Under the right-hand rule in this frame:
//      rotation about +Z = turning LEFT
//      rotation about +Y = pitching DOWN
//      rotation about +X = rolling RIGHT
//
//  Calibration measures turning left, nodding down, and tilting left, and stores for each
//  the sensor axis and the sign that makes that motion read positive.
//

import Foundation
import simd

struct AxisMap: Codable, Equatable {

    /// Bumped when the stored meaning changes, so an old file is discarded rather than
    /// silently misinterpreted. Version 1 stored signs already folded into a left-handed
    /// convention.
    static let currentVersion = 2
    var version: Int = currentVersion

    /// Sensor axis (0=X, 1=Y, 2=Z) and the sign making TURNING LEFT read positive.
    var yawAxis: Int
    var yawSign: Double
    /// ...making NODDING DOWN read positive.
    var pitchAxis: Int
    var pitchSign: Double
    /// ...making TILTING LEFT read positive.
    var rollAxis: Int
    var rollSign: Double

    static let identity = AxisMap(yawAxis: 2, yawSign: 1,
                                  pitchAxis: 1, pitchSign: 1,
                                  rollAxis: 0, rollSign: -1)

    /// Reorder a raw sensor vector into the canonical head frame.
    ///
    /// Applied to the gyro *and* the accelerometer — gravity correction has to live in the
    /// same frame as the rates, or the filter fights itself.
    func apply(_ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(
            // +X is roll RIGHT, but calibration measured roll LEFT, hence the negation.
            -rollSign * v[rollAxis],
            pitchSign * v[pitchAxis],   // +Y is pitch DOWN, measured DOWN
            yawSign * v[yawAxis]        // +Z is yaw LEFT, measured LEFT
        )
    }

    /// +1 for a proper rotation, -1 for a mirrored frame. Anything else means the axes are
    /// not a clean permutation.
    var determinant: Double {
        var m = simd_double3x3(0)
        m[rollAxis][0] = -rollSign
        m[pitchAxis][1] = pitchSign
        m[yawAxis][2] = yawSign
        return simd_determinant(m)
    }

    var isUsable: Bool {
        Set([yawAxis, pitchAxis, rollAxis]).count == 3 && version == Self.currentVersion
    }

    /// A mirrored frame is physically impossible for two right-handed frames, so it means
    /// one measured sign is wrong — usually a motion that combined two axes.
    var isRightHanded: Bool { determinant > 0 }

    var summary: String {
        let names = ["X", "Y", "Z"]
        func sign(_ s: Double) -> String { s < 0 ? "-" : "+" }
        return "yaw \(sign(yawSign))\(names[yawAxis])  "
             + "pitch \(sign(pitchSign))\(names[pitchAxis])  "
             + "roll \(sign(rollSign))\(names[rollAxis])  "
             + "det \(determinant > 0 ? "+1" : "-1")"
    }

    // MARK: persistence

    static var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HoloFrame", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("axes.json")
    }

    /// Returns nil when never calibrated on this machine, or when the stored file predates
    /// the current convention.
    static func load() -> AxisMap? {
        guard let data = try? Data(contentsOf: storeURL),
              let map = try? JSONDecoder().decode(AxisMap.self, from: data),
              map.isUsable else { return nil }
        return map
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.storeURL)
    }
}
