//
//  HeadTracker.swift — 3DoF orientation from the glasses' IMU.
//
//  A complementary filter: integrate the gyro for responsiveness, and lean on gravity to
//  stop pitch and roll drifting. Yaw has no such reference, so its defences are an accurate
//  gyro bias, a magnetic anchor that bounds what is left, and an explicit recentre.
//
//  Bias is the single highest-value part. The glasses read roughly (+0.85, +0.57, -0.74)
//  deg/s at rest; left uncorrected that is over 45 degrees of yaw drift per minute. Three
//  things keep the estimate honest, each found by replaying real recordings of the sensor
//  with a scripted head of known orientation (Tools/bench/drift-sim):
//
//    * it is only learned from windows that are still like a DESK, not still like a head —
//      a head's sway averaged into the estimate was worth over 80 degrees in four minutes;
//    * it is remembered between launches, because the first estimate is the fragile one
//      and this sensor's bias barely moves from one session to the next;
//    * the magnetic anchor corrects the bias itself, not just the heading, so whatever error
//      remains is removed rather than chased.
//

import Foundation
import simd

final class HeadTracker {

    // MARK: tuning

    /// The parameters worth varying when testing the filter offline against recorded data.
    /// The defaults are what ships; each is documented where it is used below.
    struct Tuning {
        var stillnessRateThreshold = 1.0
        var stillnessNoiseLimit = 0.3
        var driftDeadband = 0.15
        var magSlowRate = 0.05
        var magFastRate = 2.0
        var magGain = 0.1
        var magBiasGain = 0.02
    }
    private let tuning: Tuning

    /// How strongly gravity pulls pitch/roll back per second. Higher tracks gravity
    /// faster but makes the view swim under linear acceleration.
    private let gravityGain = 0.4

    // Yaw has no absolute reference, so its only defence against drift is an accurate gyro
    // bias — and the bias moves as the glasses warm up.
    //
    // The gate is on the *bias-corrected* rate, asking "does this reading agree with the
    // offset we already believe", and it is deliberately tight. A loose gate is worse than
    // no gate at all: a slow deliberate head turn sits underneath it and gets averaged in
    // as though it were zero-offset. That closes a feedback loop — the view drifts, you
    // turn slowly to follow it, your turn is learned as bias, and the drift grows. The
    // symptom is drift that worsens the longer you sit still rather than settling.
    /// A sample only counts as still below this bias-corrected rate, in deg/s.
    private var stillnessRateThreshold: Double { tuning.stillnessRateThreshold }
    /// Before any bias is known the corrected rate *is* the raw rate — around 1.2 deg/s on
    /// these glasses — so the first estimate needs a looser gate or it is never made.
    private let initialStillnessThreshold = 2.5
    /// ...and only if the accelerometer is within this much of 1 g.
    private let stillnessAccelTolerance = 0.08
    /// Samples of continuous stillness before the estimate is trusted (~2 s at 1 kHz).
    /// Long, because the quantity being measured is a few hundredths of a deg/s.
    private let samplesToCalibrate = 2000
    /// Rates below this, in deg/s, are faded toward zero before they are integrated.
    ///
    /// Whatever bias survives estimation still integrates, and 0.05 deg/s left running for
    /// three minutes is nine degrees of canvas walking away from you. Scaling the rate by
    /// speed²/(speed² + deadband²) leaves the rotation *axis* untouched and only ever
    /// touches the angle, crushing what sits near zero.
    ///
    /// It is not free, and it used to be 0.4. The loss depends on speed, so it does not
    /// cancel: reading drifts slowly along a line and snaps back fast, losing a larger share
    /// of the slow half every time. Replayed against real sensor data, a reading head lost
    /// 14 degrees in six minutes at 0.4 and 2 at 0.15 — the view creeping sideways while you
    /// read. Now that bias is remembered between sessions and corrected by the magnetic
    /// anchor, far less residual bias reaches this point, so it can afford to be small: 2%
    /// off at 1 deg/s, a quarter of a percent at 3.
    private var driftDeadband: Double { tuning.driftDeadband }

    // --- magnetic anchor ---
    //
    // Not a compass. It never asks where north is: on startup it records where the field
    // points in the WORLD frame and treats that as the anchor. A field bent 40 degrees off
    // true north by the laptop's own magnets serves just as well, because the only thing
    // required of it is to be the same field a minute later. Any rotation of the measured
    // field away from that anchor, in the horizontal plane, is yaw the gyro invented.
    //
    // This is what bounds the drift. Bias estimation and the deadband only make the walk
    // slower; nothing without an outside reference can stop it.

    /// Samples averaged before the anchor is fixed (~10 s at 1 kHz). Deliberately spans
    /// ordinary head movement rather than demanding stillness, so the anchor is the field
    /// averaged over where your head actually goes, not the field at one spot.
    private let magSamplesToAnchor = 10_000
    /// Reject a sample whose strength differs from the anchor's by more than this fraction.
    private let magStrengthTolerance = 0.15
    /// ...or whose inclination differs by more than this, in degrees. Inclination is the
    /// angle between the field and gravity, so this cross-checks the magnetometer against
    /// a wholly independent sensor, and rotating about yaw cannot change it — which makes
    /// it a test of field integrity that the thing being measured cannot contaminate.
    private let magInclinationTolerance = 10.0
    /// Below this heading error, in degrees, leave it alone rather than hunt.
    private let magDeadzone = 0.5
    /// Correction authority while still, deg/s. Small enough to be invisible: at 48 px per
    /// degree this is under three pixels a second.
    private var magSlowRate: Double { tuning.magSlowRate }
    /// ...and while the head is moving, where a correction is hidden by the motion itself.
    private var magFastRate: Double { tuning.magFastRate }
    /// Proportional gain, per second. The caps above do most of the shaping.
    private var magGain: Double { tuning.magGain }


    // MARK: state

    private let lock = NSLock()

    /// How the IMU's raw axes map onto head motion. Measured on first run; without it,
    /// nodding rotates the view instead of panning it.
    private var axes: AxisMap

    init(axes: AxisMap = AxisMap.load() ?? .identity, tuning: Tuning = Tuning()) {
        self.axes = axes
        self.tuning = tuning
    }

    /// Adopt a freshly measured mapping without restarting. The old orientation was built
    /// in the wrong frame, so the filter is reseeded rather than carried over.
    func setAxes(_ map: AxisMap) {
        lock.lock()
        defer { lock.unlock() }
        axes = map
        q = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        seeded = false
        yawOffset = 0
        pitchOffset = 0
        gyroBias = .zero
        biasAccumulator = .zero
        biasSquares = .zero
        deskBiasEstimate = nil
        stillSamples = 0
        calibrated = false
        lastTimestamp = 0
        stillnessRate = .zero
        secondsSinceBiasUpdate = 0
        // The anchor was recorded in the old frame, so it means nothing in the new one.
        magReference = nil
        magAccumulator = .zero
        magStrengthAccumulator = 0
        magInclinationAccumulator = 0
        magSamples = 0
        magAccepted = false
        magError = 0
        magFailures = 0
    }

    /// Orientation of the head in the world frame.
    private var q = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    private var gyroBias = SIMD3<Double>.zero
    private var biasAccumulator = SIMD3<Double>.zero
    private var biasSquares = SIMD3<Double>.zero
    /// The bias as of the last window that was still like a desk, and so trustworthy
    /// enough to remember for next launch.
    private var deskBiasEstimate: SIMD3<Double>?
    private var stillSamples = 0
    private var calibrated = false
    private var lastTimestamp: UInt64 = 0
    private var seeded = false
    /// Bias-corrected angular velocity in the body frame, rad/s. Kept so the renderer can
    /// predict forward and cancel the frame of latency between reading the pose and
    /// photons reaching your eye.
    private var angularVelocity = SIMD3<Double>.zero
    /// Bias-corrected rate, smoothed over ~100 ms. The stillness gate reads this rather
    /// than the instantaneous rate: at 1 kHz, noise alone would trip a 1 deg/s threshold
    /// often enough that a two-second window of "continuous" stillness never completed.
    private var stillnessRate = SIMD3<Double>.zero
    /// Lets the gate relax again if the estimate has gone stale. See `updateBias`.
    private var secondsSinceBiasUpdate = 0.0

    /// Set false to fly on gyro and gravity alone.
    var magneticAnchorEnabled = true

    /// The magnetometer's own offset, in gauss, in the head frame: the field of the magnets
    /// inside the glasses, which turns with them. Nil means uncalibrated, and then the anchor
    /// does not run at all.
    ///
    /// That is not caution for its own sake. Fitted from real recordings of the glasses being
    /// turned through many orientations, this offset measured about 0.25 G — against a true
    /// field of about 0.16 G. An offset larger than the thing being measured bends the
    /// apparent heading by tens of degrees depending on where you face, and the anchor then
    /// pulls the view toward a heading that is simply wrong: logged at 23-32 degrees of
    /// "error" on a head that had not drifted, and felt as the canvas turning steadily away.
    private var hardIronOffset: SIMD3<Double>?

    /// Adopt a measured magnetometer offset (or nil to switch the anchor off). The anchor is
    /// re-learned, because a reference recorded through the old offset is meaningless.
    func setHardIronOffset(_ offset: SIMD3<Double>?) {
        lock.lock()
        defer { lock.unlock() }
        hardIronOffset = offset
        magReference = nil
        magAccumulator = .zero
        magStrengthAccumulator = 0
        magInclinationAccumulator = 0
        magSamples = 0
        magAccepted = false
        magError = 0
    }
    /// Unit field direction in the world frame, once learned. Nil means still learning, or
    /// that the field was too incoherent to anchor to — in which case nothing below runs
    /// and the tracker behaves exactly as it did before.
    private var magReference: SIMD3<Double>?
    private var magReferenceStrength = 0.0
    private var magReferenceInclination = 0.0
    private var magAccumulator = SIMD3<Double>.zero
    private var magStrengthAccumulator = 0.0
    private var magInclinationAccumulator = 0.0
    private var magSamples = 0
    /// Whether the most recent sample passed the gates, and by how much yaw disagrees.
    private var magAccepted = false
    private var magError = 0.0
    /// Learning passes that ended without a coherent enough field to anchor to. Counted
    /// because the pass resets itself to try again, so progress alone cannot show failure.
    private var magFailures = 0

    /// Seconds of continuous near-stillness. The glasses have no wear sensor we know of, so
    /// this stands in for "taken off and put down".
    private var idleAccumulator = 0.0
    // Subtracted from the reported angles, so recentring never disturbs the filter itself.
    //
    // Pitch is included as well as yaw. Gravity fixes what "level" means in the world, but
    // not where the canvas should sit relative to your face: the glasses rest at an angle
    // on your nose, so looking comfortably straight ahead is several degrees off level and
    // the canvas ends up too low. Roll is deliberately NOT offset — you always want the
    // desktop level with the real horizon.
    private var yawOffset = 0.0
    private var pitchOffset = 0.0

    // MARK: input

    /// Fold one IMU sample into the estimate. Called on the IMU thread at ~1000 Hz.
    func integrate(_ raw: IMUSample) {
        // Into the canonical frame first. The accelerometer is remapped too — gravity
        // correction must live in the same frame as the rates or the filter fights itself.
        let s = IMUSample(timestamp: raw.timestamp,
                          gyro: axes.apply(raw.gyro),
                          accel: axes.apply(raw.accel),
                          mag: axes.apply(raw.mag))

        lock.lock()
        defer { lock.unlock() }

        // Device timestamps are nanoseconds. Guard the first sample and any hiccup.
        var dt = 0.001
        if lastTimestamp != 0, s.timestamp > lastTimestamp {
            dt = Double(s.timestamp - lastTimestamp) * 1e-9
            if dt <= 0 || dt > 0.1 { dt = 0.001 }
        }
        lastTimestamp = s.timestamp

        // Starting from identity means several seconds of visible swim on every launch
        // while gravity pulls the estimate into place. Snap straight to the measured
        // attitude on the first usable sample instead; the filter then only has to
        // maintain it. Yaw is arbitrary here, which is fine — it has no reference anyway.
        if !seeded {
            let magnitude = simd_length(s.accel)
            if abs(magnitude - 1.0) < 0.2 {
                q = simd_quatd(from: simd_normalize(s.accel), to: SIMD3<Double>(0, 0, 1))
                seeded = true
            }
        }

        let corrected = s.gyro - gyroBias                // deg/s
        stillnessRate = simd_mix(stillnessRate, corrected, SIMD3(repeating: 0.01))
        secondsSinceBiasUpdate += dt

        // Anything on a head shows constant small motion; a desk does not.
        if simd_length(corrected) > 3.0 {
            idleAccumulator = 0
        } else {
            idleAccumulator += dt
        }

        updateBias(s)

        // --- predict from the gyro ---
        // Fade out what is too slow to be a real head turn, so residual bias stops
        // accumulating while you sit and read. The denominator can never be zero, so the
        // scale needs no guard against a stationary head.
        var rate = corrected * (.pi / 180.0)             // deg/s -> rad/s
        let measuredSpeed = simd_length(rate)
        let deadband = driftDeadband * (.pi / 180.0)
        rate *= (measuredSpeed * measuredSpeed)
            / (measuredSpeed * measuredSpeed + deadband * deadband)

        // Lightly smoothed, so prediction is driven by real motion rather than sensor noise.
        angularVelocity = simd_mix(angularVelocity, rate, SIMD3(repeating: 0.05))
        let angle = simd_length(rate) * dt
        if angle > 1e-9 {
            let axis = simd_normalize(rate)
            q = simd_normalize(q * simd_quatd(angle: angle, axis: axis))
        }

        updateMagneticAnchor(s, dt: dt)

        // --- correct pitch and roll against gravity ---
        // Only when the accelerometer is plausibly measuring gravity alone; during real
        // head movement it is measuring movement too and would drag the view around.
        let magnitude = simd_length(s.accel)
        guard abs(magnitude - 1.0) < 0.2 else { return }

        // An accelerometer at rest measures specific force, which points UP, not down.
        // Comparing it against world-down gives two anti-parallel vectors whose cross
        // product is ~0, so the correction quietly does nothing and pitch/roll drift.
        let measuredUp = simd_normalize(s.accel)
        // Where the filter currently thinks "up" is, expressed in the body frame.
        let expectedUp = q.inverse.act(SIMD3<Double>(0, 0, 1))
        // The correction is applied as q' = q * R, so R must rotate measuredUp onto
        // expectedUp — not the other way round. That double inverse is easy to get
        // backwards, and getting it backwards drives the estimate away instead of
        // toward the measurement.
        let correctionAxis = simd_cross(measuredUp, expectedUp)
        let sinAngle = simd_length(correctionAxis)
        if sinAngle > 1e-9 {
            let correction = asin(min(1.0, sinAngle)) * gravityGain * dt
            q = simd_normalize(q * simd_quatd(angle: correction, axis: correctionAxis / sinAngle))
        }
    }

    /// Track the gyro's zero offset whenever the glasses are held still.
    private func updateBias(_ s: IMUSample) {
        // The gate is tight once a bias is known, but relaxes the longer it has been since
        // a window was accepted. A first estimate taken while the glasses were being lifted
        // onto your face can be wrong by more than the tight gate is wide, and the gate is
        // measured against that same estimate — so without this it would lock the door on
        // its own correction and drift forever.
        let staleness = min(secondsSinceBiasUpdate / 60.0, 3.0)
        let gate = calibrated
            ? stillnessRateThreshold * (1 + staleness)
            : initialStillnessThreshold

        let still = simd_length(stillnessRate) < gate
            && abs(simd_length(s.accel) - 1.0) < stillnessAccelTolerance
        guard still else {
            stillSamples = 0
            biasAccumulator = .zero
            biasSquares = .zero
            return
        }
        // Raw, not corrected: bias is an absolute zero-offset, not an adjustment to the
        // estimate we already hold.
        biasAccumulator += s.gyro
        biasSquares += s.gyro * s.gyro
        stillSamples += 1
        guard stillSamples >= samplesToCalibrate else { return }

        let measured = biasAccumulator / Double(stillSamples)

        // Still means still like a desk, not still like a head.
        //
        // The rate gate above asks whether the window's AVERAGE is small, and a head that is
        // holding still passes it: the small involuntary sway of breathing, pulse and posture
        // is well under a degree per second. But a two-second slice of that sway does not
        // average to zero, and every accepted window taught the estimate a few tenths of a
        // deg/s of genuine head motion as though it were sensor offset. That residual then
        // integrated without end. Replayed against real sensor data with a scripted head, a
        // gently swaying head drifted over 80 degrees in four minutes while an unmoving one
        // drifted none — which is the "yaw keeps moving the longer I wear them" symptom.
        //
        // Sway is visible in the SPREAD of the samples even when their mean is small; sensor
        // noise on a desk is several times tighter than any head. So once a first estimate
        // exists, a window is only learned from if its spread looks like noise. The first
        // estimate keeps the loose gate, so glasses plugged in while already on your face
        // still calibrate — anything is better than the raw bias, which walks over a degree
        // a second.
        let variance = biasSquares / Double(stillSamples) - measured * measured
        let spread = (max(variance.x, 0) + max(variance.y, 0) + max(variance.z, 0)).squareRoot()
        guard !calibrated || spread < tuning.stillnessNoiseLimit else {
            stillSamples = 0
            biasAccumulator = .zero
            biasSquares = .zero
            return
        }
        // Ease toward the new estimate rather than snapping, so a marginal window cannot
        // jolt the view. Heavier than it looks: windows are two seconds and the gate now
        // keeps deliberate motion out of them, so each one is worth leaning on.
        gyroBias = calibrated ? simd_mix(gyroBias, measured, SIMD3(repeating: 0.25)) : measured
        calibrated = true
        if spread < tuning.stillnessNoiseLimit { deskBiasEstimate = gyroBias }
        stillSamples = 0
        biasAccumulator = .zero
        biasSquares = .zero
        secondsSinceBiasUpdate = 0
    }

    /// Nudge yaw back toward the magnetic anchor. Called with the lock held.
    private func updateMagneticAnchor(_ s: IMUSample, dt: Double) {
        guard magneticAnchorEnabled, seeded, let hardIronOffset else { return }
        let field = s.mag - hardIronOffset
        let strength = simd_length(field)
        guard strength > 1e-9 else { return }

        let world = q.act(field / strength)
        let horizontal = simd_length(SIMD2(world.x, world.y))
        // A near-vertical field carries almost no heading: the horizontal component is
        // what encodes yaw, and dividing by one this small amplifies noise without bound.
        guard horizontal > 0.15 else {
            magAccepted = false
            return
        }
        let inclination = atan2(-world.z, horizontal)

        guard let reference = magReference else {
            // Wait for a trustworthy attitude before deciding what "the field" is —
            // anchoring to a pose the filter has not settled into bakes in that error.
            guard calibrated else { return }
            magAccumulator += world
            magStrengthAccumulator += strength
            magInclinationAccumulator += inclination
            magSamples += 1
            guard magSamples >= magSamplesToAnchor else { return }

            let mean = magAccumulator / Double(magSamples)
            let coherence = simd_length(mean)
            // Averaging unit vectors: a mean much shorter than the samples that formed it
            // means they disagreed about direction, so there is no single field here to
            // anchor to. Better to stay on gyro alone than to nail yaw to a fiction.
            if coherence > 0.9 {
                magReference = mean / coherence
                magReferenceStrength = magStrengthAccumulator / Double(magSamples)
                magReferenceInclination = magInclinationAccumulator / Double(magSamples)
            } else {
                magFailures += 1
            }
            magSamples = 0
            magAccumulator = .zero
            magStrengthAccumulator = 0
            magInclinationAccumulator = 0
            return
        }

        // Both gates compare against what was measured when the anchor was set, never
        // against textbook values for Earth's field. A permanently distorted but uniform
        // field is fine; a field that has CHANGED is not, and that is the real distinction.
        let strengthOff = abs(strength - magReferenceStrength) / magReferenceStrength
        let inclinationOff = abs(inclination - magReferenceInclination) * 180 / .pi
        guard strengthOff < magStrengthTolerance, inclinationOff < magInclinationTolerance
        else {
            magAccepted = false
            return
        }
        magAccepted = true

        var error = atan2(reference.y, reference.x) - atan2(world.y, world.x)
        while error > .pi { error -= 2 * .pi }
        while error < -.pi { error += 2 * .pi }
        magError = error * 180 / .pi

        // The anchor also corrects the BIAS, not only the heading.
        //
        // Nudging the heading alone cannot keep up with a bias that is off: the correction
        // is capped at a crawl while you hold still, so that it stays invisible, and a bias
        // error of a few tenths of a deg/s outruns it — the view slides steadily and the
        // anchor trails behind. A persistent heading error IS a measurement of that bias
        // error, so folding a little of it into the bias removes the cause rather than
        // chasing the symptom. This is the integral half of a PI controller; the heading
        // nudge below is the proportional half. It is slew-limited, because a field that is
        // subtly wrong in some directions — the glasses' own speaker magnets — would
        // otherwise be able to teach it something wrong quickly.
        if tuning.magBiasGain > 0 {
            let vertical = q.inverse.act(SIMD3<Double>(0, 0, 1))
            let maxSlew = 0.02                                   // deg/s of bias per second
            let adjust = max(-maxSlew, min(maxSlew, tuning.magBiasGain * magError)) * dt
            gyroBias -= vertical * adjust
        }

        guard abs(magError) > magDeadzone else { return }

        // Correct faster while the head is moving. A degree per second of yaw correction is
        // invisible mid-turn and glaring when you are holding still on a line of text, so
        // the authority follows the motion that hides it — which also means ordinary use
        // erases accumulated error long before it becomes visible.
        let speed = simd_length(angularVelocity) * 180 / .pi
        let limit = (magSlowRate + (magFastRate - magSlowRate) * min(1, speed / 20)) * .pi / 180
        let step = max(-limit * dt, min(limit * dt, error * magGain * dt))
        // Pre-multiplied: this is a rotation about the WORLD's vertical, not the head's.
        // Post-multiplying would tilt the horizon whenever you were not upright.
        q = simd_normalize(simd_quatd(angle: step, axis: SIMD3(0, 0, 1)) * q)
    }

    // MARK: output

    /// Current orientation, without recentring applied. Safe from any thread.
    var orientation: simd_quatd {
        lock.lock()
        defer { lock.unlock() }
        return q
    }

    /// What the magnetic anchor is doing. `locked` false with `progress` stuck at 0 after
    /// the first few seconds means the field here was too incoherent to anchor to.
    var magneticStatus: (locked: Bool, accepted: Bool, error: Double, failures: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (magReference != nil, magAccepted, magError, magFailures)
    }

    /// Raw yaw and pitch in degrees, WITHOUT the recentre offsets, plus the bias estimate.
    /// For watching drift: a recentre would otherwise show up as a jump.
    var diagnostics: (yaw: Double, pitch: Double, bias: SIMD3<Double>, calibrated: Bool) {
        lock.lock()
        let o = q, bias = gyroBias, known = calibrated
        lock.unlock()
        let w = o.real, x = o.imag.x, y = o.imag.y, z = o.imag.z
        let yaw = atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z)) * 180 / .pi
        let pitch = -asin(max(-1, min(1, 2 * (w * y - z * x)))) * 180 / .pi
        return (yaw, pitch, bias, known)
    }

    /// Start from a bias measured in an earlier session instead of estimating one now.
    ///
    /// The first estimate is the fragile one. It has to be allowed with a loose stillness
    /// test, or glasses plugged in while already being worn would never calibrate at all —
    /// and a head is never still, so a first estimate taken on one soaks up its sway and
    /// keeps it for good. This sensor's bias barely moves between sessions, so the value
    /// from the last time the glasses lay on a desk is a far better start than anything
    /// measurable on a face. Ignored if an estimate already exists.
    func preset(bias: SIMD3<Double>) {
        lock.lock()
        defer { lock.unlock() }
        guard !calibrated else { return }
        gyroBias = bias
        calibrated = true
        secondsSinceBiasUpdate = 0
    }

    /// The most recent desk-quality bias, for remembering across launches.
    var deskBias: SIMD3<Double>? {
        lock.lock()
        defer { lock.unlock() }
        return deskBiasEstimate
    }

    var isBiasCalibrated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return calibrated
    }

    /// Seconds the glasses have been essentially motionless.
    var idleSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return idleAccumulator
    }

    /// False until the first usable sample has been folded in.
    var hasSamples: Bool {
        lock.lock()
        defer { lock.unlock() }
        return seeded
    }

    /// Yaw/pitch/roll in degrees, for display and for the renderer's mapping.
    var eulerDegrees: (yaw: Double, pitch: Double, roll: Double) {
        euler(of: orientation)
    }

    /// Where the head will be `seconds` from now, assuming it keeps turning at the current
    /// rate.
    ///
    /// There is roughly a frame between latching the pose and photons arriving, and over
    /// that gap a real head turn has moved on. Extrapolating closes most of it, which is
    /// what makes the canvas feel nailed to the room rather than dragged behind you.
    /// Prediction is capped so a fast flick cannot overshoot wildly — overshoot reads far
    /// worse than a little lag.
    func predictedEulerDegrees(ahead seconds: Double, maxDegrees: Double = 8.0)
        -> (yaw: Double, pitch: Double, roll: Double) {
        lock.lock()
        let current = q
        let rate = angularVelocity
        lock.unlock()

        let speed = simd_length(rate)
        guard speed > 1e-6, seconds > 0 else { return euler(of: current) }

        let limit = maxDegrees * .pi / 180.0
        let angle = min(speed * seconds, limit)
        let predicted = simd_normalize(current * simd_quatd(angle: angle, axis: rate / speed))
        return euler(of: predicted)
    }

    private func euler(of o: simd_quatd) -> (yaw: Double, pitch: Double, roll: Double) {
        let w = o.real, x = o.imag.x, y = o.imag.y, z = o.imag.z

        // Frame is X forward, Y left, Z up (right-handed). By the right-hand rule that
        // makes rotation about +Y a pitch DOWN, so it is negated here to report the more
        // natural "positive means looking up".
        let yaw = atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z))
        let sinPitch = 2 * (w * y - z * x)
        let pitchDown = abs(sinPitch) >= 1 ? copysign(.pi / 2, sinPitch) : asin(sinPitch)
        let roll = atan2(2 * (w * x + y * z), 1 - 2 * (x * x + y * y))

        let toDegrees = 180.0 / Double.pi
        lock.lock()
        let yawZero = yawOffset, pitchZero = pitchOffset
        lock.unlock()

        // Wrap yaw into -180...180 so crossing the seam does not fling the view across
        // the canvas.
        var relativeYaw = yaw * toDegrees - yawZero
        while relativeYaw > 180 { relativeYaw -= 360 }
        while relativeYaw < -180 { relativeYaw += 360 }

        return (relativeYaw, -pitchDown * toDegrees - pitchZero, roll * toDegrees)
    }

    /// Make wherever you are looking now the centre of the canvas.
    ///
    /// Takes yaw and pitch, so this fixes both "the canvas is off to one side" and "the
    /// canvas sits too low". Roll is left alone — the desktop should stay level with the
    /// real world however you tilt your head.
    func recenter() {
        lock.lock()
        let w = q.real, x = q.imag.x, y = q.imag.y, z = q.imag.z
        yawOffset = 0
        pitchOffset = 0
        lock.unlock()

        let toDegrees = 180.0 / Double.pi
        let yaw = atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z)) * toDegrees
        let sinPitch = 2 * (w * y - z * x)
        let pitchDown = (abs(sinPitch) >= 1 ? copysign(.pi / 2, sinPitch) : asin(sinPitch)) * toDegrees

        lock.lock()
        yawOffset = yaw
        pitchOffset = -pitchDown
        lock.unlock()
    }
}

/// The gyro bias from the last time the glasses lay still, remembered across launches. Tied
/// to the axis mapping it was measured under, because the bias is stored in the head frame
/// and means nothing under a different one.
enum StoredGyroBias {
    private struct Record: Codable {
        var axes: String
        var bias: [Double]
        var saved: Date
    }

    private static var url: URL {
        AxisMap.storeURL.deletingLastPathComponent().appendingPathComponent("gyro-bias.json")
    }

    static func load(for axes: AxisMap) -> SIMD3<Double>? {
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.axes == axes.summary, record.bias.count == 3 else { return nil }
        return SIMD3(record.bias[0], record.bias[1], record.bias[2])
    }

    static func save(_ bias: SIMD3<Double>, for axes: AxisMap) {
        let record = Record(axes: axes.summary, bias: [bias.x, bias.y, bias.z], saved: Date())
        if let data = try? JSONEncoder().encode(record) { try? data.write(to: url) }
    }
}
