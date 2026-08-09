//
//  ViewSmoothing.swift — taking the shake out without adding lag.
//
//  The view follows head pose one-to-one at roughly 48 pixels per degree, so involuntary
//  motion — breathing, pulse, the desk being knocked — moves the image several pixels and
//  reads as jitter. A fixed low-pass filter removes it, but at the cost of lag on real
//  movement, which is worse: a laggy view feels detached from your head and is the classic
//  route to discomfort.
//
//  The One Euro filter (Casiez, Roussel & Vogel, CHI 2012) solves exactly this. Its cutoff
//  frequency rises with the speed of the signal, so it filters heavily when you are nearly
//  still — where jitter is all there is to see — and barely at all when you turn, where lag
//  would be felt and jitter would not be noticed.
//

import Foundation

/// Exponential smoothing with a cutoff that adapts to how fast the value is changing.
struct OneEuroFilter {

    /// Cutoff in Hz while stationary. Lower means steadier but slower to start moving.
    var minCutoff: Double
    /// How much the cutoff opens up with speed. Higher means less lag when turning.
    var beta: Double
    /// Cutoff for the speed estimate itself, so a noisy derivative cannot flap the cutoff.
    var derivativeCutoff: Double = 1.0

    private var previous: Double?
    private var previousDerivative = 0.0

    init(minCutoff: Double, beta: Double) {
        self.minCutoff = minCutoff
        self.beta = beta
    }

    private func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2 * .pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    mutating func callAsFunction(_ value: Double, dt: Double) -> Double {
        guard dt > 0 else { return previous ?? value }
        guard let last = previous else {
            previous = value
            return value
        }

        let rate = (value - last) / dt
        let smoothedRate = alpha(cutoff: derivativeCutoff, dt: dt) * rate
            + (1 - alpha(cutoff: derivativeCutoff, dt: dt)) * previousDerivative
        previousDerivative = smoothedRate

        // The whole trick: open the cutoff in proportion to speed.
        let cutoff = minCutoff + beta * abs(smoothedRate)
        let a = alpha(cutoff: cutoff, dt: dt)
        let smoothed = a * value + (1 - a) * last
        previous = smoothed
        return smoothed
    }

    mutating func reset() {
        previous = nil
        previousDerivative = 0
    }

    /// Speed of the filtered signal, in units per second. Used to decide when the view is
    /// still enough to snap to whole pixels.
    var speed: Double { abs(previousDerivative) }
}

/// Three One Euro filters, with yaw unwrapped so crossing the ±180° seam does not register
/// as a 360°/frame lurch and blow the cutoff wide open.
struct PoseSmoother {

    private var yawFilter: OneEuroFilter
    private var pitchFilter: OneEuroFilter
    private var rollFilter: OneEuroFilter
    private var unwrappedYaw: Double?

    init(minCutoff: Double, beta: Double) {
        yawFilter = OneEuroFilter(minCutoff: minCutoff, beta: beta)
        pitchFilter = OneEuroFilter(minCutoff: minCutoff, beta: beta)
        rollFilter = OneEuroFilter(minCutoff: minCutoff, beta: beta)
    }

    /// Highest angular speed across the three axes, degrees/second.
    var speed: Double { max(yawFilter.speed, max(pitchFilter.speed, rollFilter.speed)) }

    mutating func callAsFunction(yaw: Double, pitch: Double, roll: Double, dt: Double)
        -> (yaw: Double, pitch: Double, roll: Double) {
        // Accumulate yaw continuously rather than filtering the wrapped value.
        var continuous = yaw
        if let last = unwrappedYaw {
            var delta = yaw - last.truncatingRemainder(dividingBy: 360)
            while delta > 180 { delta -= 360 }
            while delta < -180 { delta += 360 }
            continuous = last + delta
        }
        unwrappedYaw = continuous

        let smoothedYaw = yawFilter(continuous, dt: dt)
        return (smoothedYaw, pitchFilter(pitch, dt: dt), rollFilter(roll, dt: dt))
    }

    mutating func reset() {
        yawFilter.reset()
        pitchFilter.reset()
        rollFilter.reset()
        unwrappedYaw = nil
    }
}
