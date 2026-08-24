//
//  GlassesDisplay.swift — what you actually see.
//
//  A borderless window covering the glasses' display, showing a 1920x1080 window onto the
//  much larger canvas. Head yaw and pitch move that window; head roll counter-rotates it
//  so the desktop stays level.
//
//  The sampling is dot-to-dot: one canvas pixel to one glasses pixel, no scaling. The pan
//  offset is rounded to whole pixels so text lands on exact texels instead of shimmering
//  between them.
//

import AppKit
import Foundation
import Metal
import MetalKit
import QuartzCore
import simd

/// Everything about how the view feels. Comfort settings differ per person, so these are
/// stored as JSON next to the axis calibration rather than compiled in — edit the file and
/// relaunch.
struct ViewConfig: Codable {
    /// Horizontal field of view of the glasses, degrees. XREAL Air is ~46 degrees
    /// diagonal, which at 16:9 works out to about 40 horizontal.
    var horizontalFOV: Double = 40.0
    /// Scales head motion to canvas motion. 1.0 is physically correct — the canvas sits
    /// still in the world and you look around it. Above 1.0 reaches the edges with less
    /// neck movement, at the cost of the illusion.
    var panGain: Double = 1.0
    /// Counter-rotate the image against head roll so the desktop stays level.
    var compensateRoll = true

    // The canvas is fixed in the world and you look around it, so the view must move WITH
    // your head: turn left and you see the canvas's left side. All three come out reversed
    // against the measured axis convention on XREAL Air, so all three are flipped here.
    // All three verified against the hardware rather than derived — the measured axis
    // convention does not match the obvious one.
    var invertYaw = false
    var invertPitch = false
    var invertRoll = false

    /// Take the glasses display away from macOS entirely with CGDisplayCapture.
    ///
    /// Off by default, and probably should stay off: capturing removes the display from
    /// the desktop, so AppKit stops treating its coordinates as a valid window location
    /// and relocates our window onto another screen — leaving the glasses showing an empty
    /// shield. Covering the display with a window at CGShieldingWindowLevel hides
    /// everything behind it just as effectively, and CursorManager keeps the pointer off.
    var captureDisplay = false
    /// How far past the canvas edge the view may travel, as a fraction of the view size.
    /// 0 puts a canvas corner exactly at the centre of the glasses; larger values let you
    /// overshoot into black, which some people find more comfortable to aim with.
    var edgeOverscan: Double = 0.0

    // Damping. Lower minCutoff = steadier when still; higher beta = less lag when turning.
    // 1.0 / 0.007 is roughly "hold nearly rock steady while reading, and be indistinguishable
    // from unfiltered once you actually turn your head".
    var smoothingMinCutoff: Double = 1.0
    var smoothingBeta: Double = 0.007
    /// Below this angular speed (deg/s) the view is treated as at rest and snapped to whole
    /// pixels for crisp text. Above it, sub-pixel sampling keeps motion smooth instead of
    /// stepping.
    var pixelSnapBelowSpeed: Double = 4.0

    /// How far ahead to extrapolate head motion, seconds. Roughly one frame at 60 Hz.
    /// Cancels the latency between latching the pose and photons arriving. 0 disables it.
    var predictionSeconds: Double = 0.016
    /// Ceiling on that extrapolation, degrees — overshoot on a fast flick reads worse than
    /// a little lag.
    var predictionMaxDegrees: Double = 8.0

    /// Width in pixels of a fade at the canvas boundary. Off by default: softening that
    /// edge means blending across it, which dims the outermost pixels of real content.
    var edgeFeather: Double = 0.0

    /// Show a small map of where you are on the canvas after the view moves, and on
    /// recentre. Fades out once you settle.
    var showPositionIndicator = true
    var indicatorFadeSeconds: Double = 1.4
    /// Opacity of the lit rectangle showing the visible region. Kept low: it sits over
    /// content you may be reading, and it only has to be findable, not prominent.
    var indicatorViewportOpacity: Double = 0.30
    /// Opacity of the surrounding map, for the sense of scale.
    var indicatorBackgroundOpacity: Double = 0.26

    /// How long the ring around the pointer stays visible after it moves. 0 disables it.
    var cursorHintSeconds: Double = 0.9
    /// Radius of that ring, in canvas pixels.
    var cursorHintRadius: Double = 34
    /// Peak opacity of the ring. Slightly translucent so it reads as a hint over content
    /// rather than something drawn on top of it.
    var cursorHintOpacity: Double = 0.72

    /// How fast the pointer must be moving toward the built-in screen, in canvas pixels per
    /// second, for the viewport edge to let it through rather than hold it. A deliberate
    /// flick clears this easily; nudging up against the edge, or turning your head so the
    /// viewport leaves the pointer behind, does not. Lower it if getting out is a fight,
    /// raise it if the pointer keeps escaping when you did not mean it to.
    var cursorEscapeSpeed: Double = 900

    /// Stop drawing and capturing after the glasses have been motionless this long. Set 0
    /// to keep running regardless.
    var idleTimeoutSeconds: Double = 90

    /// Ceiling on magnification. Past about 4x you are looking at very large blurry
    /// pixels: the canvas is captured at its own resolution, so magnifying stretches what
    /// was already drawn rather than re-rendering text bigger. For a lasting size change,
    /// pick a smaller canvas resolution in System Settings instead — that re-lays-out the
    /// desktop and redraws text sharp.
    var zoomMax: Double = 4.0

    /// How much of a trackpad pinch turns into zoom, while right-Option is held. 1.0 is
    /// the raw system magnification — Apple's own value, calibrated for pinching a photo
    /// across an unbounded range. This range is bounded and small by comparison (0.25x to
    /// 4x is the whole of it), so the same gain crosses the entire span in one gesture,
    /// which is what makes it feel uncontrollable. Well under 1 is right here.
    var pinchZoomGain: Double = 0.5

    /// Anchor yaw to the local magnetic field, which is the only thing that can bound drift
    /// rather than merely slow it. Set false to fly on gyro and gravity alone — the anchor
    /// disables itself anyway if the field here turns out to be incoherent.
    var magneticAnchor = true


    // MARK: persistence

    static var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HoloFrame", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("view.json")
    }

    /// Load the stored settings, writing defaults out first if there are none — so the file
    /// always exists to be edited, and a partial file still works.
    ///
    /// The merge is not politeness, it is the only thing making that last part true.
    /// Synthesized `Codable` treats every key as REQUIRED: a property's default value is
    /// used when you construct the struct and never when you decode it. Decoding a file
    /// written before some key existed therefore throws, and the obvious response — fall
    /// back to defaults and save them — silently overwrites the user's tuning with the very
    /// file that failed to load. Adding one property would quietly reset everything else.
    /// So: encode the defaults, overlay whatever the file does carry, decode that.
    static func loadOrCreate() -> ViewConfig {
        let defaults = ViewConfig()
        guard let data = try? Data(contentsOf: storeURL) else {
            try? defaults.save()
            return defaults
        }
        guard let base = try? JSONEncoder().encode(defaults),
              var merged = (try? JSONSerialization.jsonObject(with: base)) as? [String: Any],
              let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return defaults }

        // Unknown keys ride along harmlessly; the decoder ignores what it has no property
        // for, which keeps a file from a NEWER build readable by an older one.
        for (key, value) in stored { merged[key] = value }

        guard let combined = try? JSONSerialization.data(withJSONObject: merged),
              let config = try? JSONDecoder().decode(ViewConfig.self, from: combined)
        else { return defaults }   // deliberately not saved: never overwrite a file we failed to read
        return config
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.storeURL)
    }
}

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 canvasSize;
    float2 viewSize;
    float2 center;      // canvas pixel coordinates shown at the centre of the view
    float  roll;        // radians
    float  feather;         // pixels of fade at the canvas boundary; 0 = hard edge
    float  indicator;       // 0..1 fade of the position map
    float  indicatorView;   // opacity of the visible-region rectangle
    float  indicatorBack;   // opacity of the surrounding map
    float2 cursor;          // pointer position in canvas pixels
    float  cursorAlpha;     // 0..1 fade of the locator ring
    float  cursorRadius;    // view pixels
    float  zoom;            // >1 magnifies, <1 shows more canvas; 1 is dot-to-dot
};

vertex float4 vsMain(uint vid [[vertex_id]]) {
    // One oversized triangle covering the viewport — cheaper than a quad, no seam.
    float2 uv = float2((vid << 1) & 2, vid & 2);
    return float4(uv * 2.0 - 1.0, 0.0, 1.0);
}

fragment float4 fsMain(float4 pos [[position]],
                       constant Uniforms &u [[buffer(0)]],
                       texture2d<float> canvas [[texture(0)]]) {
    constexpr sampler smp(filter::linear, address::clamp_to_edge);

    float2 fromCentre = pos.xy - u.viewSize * 0.5;
    float c = cos(u.roll), s = sin(u.roll);

    // View pixels to canvas pixels. At zoom 1 this is the identity and the sampling is
    // dot-to-dot; above 1 one canvas pixel covers several view pixels, below 1 the
    // reverse.
    float2 rotated = float2(fromCentre.x * c - fromCentre.y * s,
                            fromCentre.x * s + fromCentre.y * c);
    float2 canvasPx = rotated / u.zoom + u.center;

    // Past the edge of the canvas, show black rather than smearing the edge pixels.
    float4 colour = float4(0.0, 0.0, 0.0, 1.0);
    bool onCanvas = canvasPx.x >= 0.0 && canvasPx.y >= 0.0 &&
                    canvasPx.x < u.canvasSize.x && canvasPx.y < u.canvasSize.y;
    if (onCanvas) {
        // Zoomed out, one view pixel covers 1/zoom canvas pixels, and a single tap picks
        // one of them arbitrarily — which turns text into noise that crawls as the view
        // moves, because a fraction of a pixel of pan changes WHICH pixel gets picked.
        // Averaging over the footprint is what the texture's absent mip chain would have
        // done. Capture textures come straight from the IOSurface and cannot carry mips
        // without a full-canvas copy every frame, so it is done here instead: at 4x4 the
        // cost lands only when zoomed right out, and n is 1 at or above 1:1, so
        // magnifying pays nothing at all.
        int n = clamp(int(ceil(1.0 / u.zoom)), 1, 4);
        if (n == 1) {
            colour = canvas.sample(smp, canvasPx / u.canvasSize);
        } else {
            float inv = 1.0 / float(n);
            float3 sum = float3(0.0);
            for (int j = 0; j < n; ++j) {
                for (int i = 0; i < n; ++i) {
                    // Offsets span one view pixel, so after the divide they span exactly
                    // the canvas footprint that view pixel covers.
                    float2 o = (float2(float(i), float(j)) + 0.5) * inv - 0.5;
                    float2 f = fromCentre + o;
                    float2 r = float2(f.x * c - f.y * s, f.x * s + f.y * c);
                    sum += canvas.sample(smp, (r / u.zoom + u.center) / u.canvasSize).rgb;
                }
            }
            colour = float4(sum * inv * inv, 1.0);
        }
        if (u.feather > 0.5) {
            // Distance to the nearest canvas edge, faded over `feather` pixels. This
            // necessarily dims real content, which is why it defaults to off.
            float2 d = min(canvasPx, u.canvasSize - canvasPx);
            float edge = min(d.x, d.y);
            colour.rgb *= clamp(edge / u.feather, 0.0, 1.0);
        }
    }

    // Locator ring around the pointer. Measured in canvas space, so it needs no inverse
    // transform and stays correct however the view is rotated by roll compensation.
    if (u.cursorAlpha > 0.002 && onCanvas) {
        // Scaled into view pixels: a ring measured in canvas pixels would balloon as you
        // magnify and shrink to nothing as you zoom out, when what it has to do is stay
        // the same size in front of your eye.
        float d = distance(canvasPx, u.cursor) * u.zoom;
        float band = 1.0 - smoothstep(u.cursorRadius - 4.0, u.cursorRadius, abs(d - u.cursorRadius));
        if (band > 0.001) {
            colour.rgb = mix(colour.rgb, float3(1.0, 0.95, 0.45), band * u.cursorAlpha);
        }
    }

    // Position map: where the visible window sits on the whole canvas. Only drawn while
    // fading in or out, so it costs nothing at rest.
    if (u.indicator > 0.002) {
        float mapW = u.viewSize.x * 0.20;
        float mapH = mapW * (u.canvasSize.y / u.canvasSize.x);
        float2 origin = float2((u.viewSize.x - mapW) * 0.5,
                               u.viewSize.y - mapH - u.viewSize.y * 0.07);
        float2 p = pos.xy - origin;

        if (p.x >= 0.0 && p.y >= 0.0 && p.x <= mapW && p.y <= mapH) {
            float2 scale = float2(mapW, mapH) / u.canvasSize;
            // Not named `half` — that is a Metal type, and the shader is compiled at
            // runtime, so the failure would be an app that starts and shows black.
            float2 reach = u.viewSize * 0.5 / u.zoom;
            float2 viewMin = (u.center - reach) * scale;
            float2 viewMax = (u.center + reach) * scale;
            bool inView = p.x >= viewMin.x && p.x <= viewMax.x &&
                          p.y >= viewMin.y && p.y <= viewMax.y;

            float3 tint = inView ? float3(0.50, 0.80, 1.0) : float3(0.06, 0.08, 0.12);
            float alpha = (inView ? u.indicatorView : u.indicatorBack) * u.indicator;
            colour.rgb = mix(colour.rgb, tint, alpha);
        }
    }
    return colour;
}
"""

/// A window AppKit is not allowed to move.
///
/// NSWindow normally constrains a new frame to fit a screen it knows about. Right after
/// the canvas is created AppKit's screen list is still stale, so it decides the glasses'
/// coordinates are invalid and silently relocates the window to the main display — which
/// is why the view kept appearing on the MacBook screen. Returning the rect unchanged
/// puts it exactly where we ask.
final class RenderWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Close every render window this process owns — by class, not by reference.
    ///
    /// Chasing a stored `window` reference cannot clean up an instance that leaked, and a
    /// leaked one is exactly the case that hurts: it stays on screen at level 1000 with
    /// nothing pointing at it. NSApp.windows is the authoritative list, so sweep that.
    /// Returns how many were closed.
    /// Hide without touching geometry.
    ///
    /// Deliberately no setFrame: moving a window off-screen starts an
    /// `_NSWindowTransformAnimation`, which outlives this call and dereferences the window
    /// later during a CoreAnimation commit. Combined with a release it is a segfault.
    func makeInvisible() {
        alphaValue = 0
        ignoresMouseEvents = true
        orderOut(nil)
    }

    /// The one render window this process ever creates.
    ///
    /// Reused rather than recreated per session. A closed NSWindow with
    /// `isReleasedWhenClosed = false` is still retained by AppKit's window list, so making
    /// a fresh one on every plug-in leaks one window per cycle — invisible, because
    /// makeInvisible() zeroes its alpha, but accumulating for as long as the app runs.
    /// One window, hidden and shown, has none of that.
    private static var shared: RenderWindow?

    static func obtain(frame: NSRect) -> RenderWindow {
        if let existing = shared {
            existing.setFrame(frame, display: false)
            existing.alphaValue = 1
            return existing
        }
        let window = RenderWindow(contentRect: frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
        // MUST be false when an NSWindow is held in a Swift strong property. It defaults
        // to true, meaning close() releases the window on top of ARC's own release. That
        // double release leaves a zombie: gone from NSApp.windows, but its window-server
        // surface still on screen and unreachable — and AppKit later touches the freed
        // memory during a CoreAnimation commit and the process dies with EXC_BAD_ACCESS.
        window.isReleasedWhenClosed = false
        shared = window
        return window
    }

    @discardableResult
    static func closeAll(verbose: Bool = false) -> Int {
        var closed = 0
        for case let window as RenderWindow in NSApp.windows {
            window.makeInvisible()
            closed += 1
        }
        if verbose {
            print("    NSApp.windows (\(NSApp.windows.count)):")
            for w in NSApp.windows {
                print("      \(type(of: w))  level=\(w.level.rawValue) visible=\(w.isVisible) "
                      + "\(Int(w.frame.width))x\(Int(w.frame.height)) at "
                      + "\(Int(w.frame.origin.x)),\(Int(w.frame.origin.y))")
            }
        }
        return closed
    }
}

private struct Uniforms {
    var canvasSize: SIMD2<Float>
    var viewSize: SIMD2<Float>
    var center: SIMD2<Float>
    var roll: Float
    var feather: Float
    var indicator: Float
    var indicatorView: Float
    var indicatorBack: Float
    var cursor: SIMD2<Float>
    var cursorAlpha: Float
    var cursorRadius: Float
    var zoom: Float
}

final class GlassesDisplay: NSObject {

    private let capture: DesktopCapture
    private let tracker: HeadTracker
    private var config: ViewConfig

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let metalLayer: CAMetalLayer

    private var window: RenderWindow?
    private var displayLink: CADisplayLink?
    private var capturedDisplay: CGDirectDisplayID?
    private(set) var framesDrawn = 0

    private var smoother: PoseSmoother
    private var lastFrameTime: CFTimeInterval?
    private var paused = false
    /// The position map is shown while moving and briefly after, then fades out.
    private var indicatorUntil: CFTimeInterval = 0

    private var glassesDisplayID: CGDirectDisplayID = 0
    private var watchdog: Timer?
    private var abandoned = false
    /// Called when the display this window lives on has gone away.
    var onDisplayLost: (() -> Void)?

    /// Is our window still on the display it was made for?
    ///
    /// Checked on a timer rather than in the render loop, because the CADisplayLink is
    /// bound to the glasses display — when that display disappears the link simply stops
    /// firing, so anything inside `render()` never runs. Which is precisely the case that
    /// matters.
    private func displayStillPresent() -> Bool {
        guard glassesDisplayID != 0 else { return false }
        guard CGDisplayIsActive(glassesDisplayID) != 0 else { return false }
        // AppKit relocates a window whose display vanished, so a mismatch means it has
        // already been dumped onto another screen.
        guard let screen = window?.screen else { return false }
        return Self.screenID(screen) == glassesDisplayID
    }

    private func checkDisplay() {
        guard !abandoned, window != nil else { return }
        guard !displayStillPresent() else { return }
        abandoned = true
        hideNow()
        onDisplayLost?()
    }

    /// Get the window off screen this instant, without the rest of the teardown.
    ///
    /// When a display is unplugged macOS immediately relocates any window on it to another
    /// screen. Full teardown takes a moment, and in that gap the view appears on the
    /// built-in display — so this runs synchronously from the display-reconfiguration
    /// callback, before AppKit gets the chance.
    func hideNow() {
        paused = true
        onMain {
            self.watchdog?.invalidate()
            self.watchdog = nil
            self.displayLink?.invalidate()
            self.displayLink = nil
            // orderOut alone is not enough: NSApp retains every window in its window list,
            // so dropping our own reference leaves it on screen. close() takes it out of
            // that list. Sweeping by class rather than by reference also catches any
            // earlier instance that leaked — which is what kept the renderer visible on the
            // built-in display after unplugging.
            // Detach the Metal layer before dropping the window. A CAMetalLayer with a
            // presented drawable can keep the window-server surface alive past the
            // NSWindow, which is one way a window outlives NSApp.windows.
            self.metalLayer.isHidden = true
            self.metalLayer.removeFromSuperlayer()
            self.window?.contentView = nil

            // Hide rather than close: the window is reused next time the glasses appear.
            self.window?.makeInvisible()
            self.window = nil
            let verbose = ProcessInfo.processInfo.environment["HOLOFRAME_VERBOSE"] != nil
            let hidden = RenderWindow.closeAll(verbose: verbose)
            if verbose { print("    render windows hidden: \(hidden)") }
        }
    }

    /// AppKit calls must be on the main thread, and some of the callers here are
    /// system callbacks with no such guarantee.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
    }

    /// Adopt new settings while running, so the settings panel can be judged by wearing
    /// the glasses rather than by relaunching.
    func apply(_ updated: ViewConfig) {
        config = updated
        smoother = PoseSmoother(minCutoff: updated.smoothingMinCutoff, beta: updated.smoothingBeta)
        lastFrameTime = nil
    }

    /// Stop drawing without tearing anything down, so resuming is instant.
    func setPaused(_ value: Bool) {
        paused = value
        if !value { smoother.reset(); lastFrameTime = nil }
    }

    // MARK: - zoom

    /// Canvas pixels per view pixel. 1 is dot-to-dot, the only value where text is drawn
    /// at exactly the resolution it was rendered at. Above 1 magnifies; below 1 fits more
    /// canvas into the view.
    ///
    /// Sustained rather than momentary: you set it and it stays, because how big you want
    /// text is not a decision you make several times a minute. Recentring puts it back to
    /// 1, which doubles as the way out if you ever lose track of where you are.
    private var zoom: Double = 1.0
    /// Where the pinch has asked the zoom to go. `zoom` chases this rather than jumping to
    /// it, so a burst of gesture events becomes one continuous movement instead of a
    /// staircase.
    private var zoomTarget: Double = 1.0
    private let zoomLock = NSLock()

    /// How long the zoom takes to catch up with the pinch. Short enough not to feel like
    /// lag, long enough to absorb the fact that gesture events arrive in clumps.
    private let zoomSmoothingSeconds = 0.06

    var currentZoom: Double {
        zoomLock.lock()
        defer { zoomLock.unlock() }
        return zoom
    }

    /// Multiply the zoom by `factor`, clamped. Multiplicative because that is what makes
    /// a pinch feel linear: the same finger movement should be worth the same proportion
    /// of the current scale whether you are at 0.3x or 3x.
    ///
    /// The per-event clamp matters more than it looks. Magnification arrives as a stream
    /// of small deltas that compound, so the scale grows EXPONENTIALLY with how far your
    /// fingers travel: the first millimetres do almost nothing, and by the time the change
    /// is large enough to notice it is already running away from you. That reads as sluggish
    /// and jumpy at the same time, which sounds contradictory and is in fact one symptom.
    /// Bounding each step keeps a single outsized event from lurching the view.
    func scaleZoom(by factor: Double) {
        let bounded = min(max(factor, 0.9), 1.1)
        zoomLock.lock()
        zoomTarget = min(max(zoomTarget * bounded, zoomFloor), config.zoomMax)
        zoomLock.unlock()
        flashPositionIndicator()
    }

    func resetZoom() {
        zoomLock.lock()
        let changed = abs(zoom - 1.0) > 0.0001
        zoom = 1.0
        zoomTarget = 1.0
        zoomLock.unlock()
        // The anchor goes with it: recentring means "put everything back", and an offset
        // left behind would park the view somewhere your head is not pointing.
        zoomAnchorOffset = .zero
        lastRenderedZoom = 1.0
        if changed { flashPositionIndicator() }
    }

    /// Advance the smoothed zoom one frame toward the target, in log space so a step feels
    /// the same size at 0.3x as at 3x.
    private func advanceZoom(dt: Double) -> Double {
        zoomLock.lock()
        defer { zoomLock.unlock() }
        guard abs(zoom - zoomTarget) > 0.0001 else { return zoom }
        let alpha = 1 - exp(-dt / zoomSmoothingSeconds)
        let stepped = exp(log(zoom) + (log(zoomTarget) - log(zoom)) * alpha)
        zoom = abs(log(zoomTarget / stepped)) < 0.0005 ? zoomTarget : stepped
        return zoom
    }

    /// Keeps whatever is at the middle of the view at the middle of the view while the
    /// zoom changes. Without it the pan term is scaled by zoom, so the view slides toward
    /// the canvas centre as you magnify — you aim at something, zoom, and it drifts off.
    private var zoomAnchorOffset = SIMD2<Double>(0, 0)
    private var lastRenderedZoom: Double = 1.0

    /// Zooming out past the point where the whole canvas already fits shows nothing but a
    /// smaller picture surrounded by more black, so that is the floor. Recomputed from the
    /// live canvas because the resolution can be changed underneath us.
    private var zoomFloor: Double {
        let canvas = capture.texture
        let viewWidth = Double(metalLayer.drawableSize.width)
        let viewHeight = Double(metalLayer.drawableSize.height)
        guard let canvas, viewWidth > 1, viewHeight > 1 else { return 0.25 }
        let fit = min(viewWidth / Double(canvas.width), viewHeight / Double(canvas.height))
        return min(max(fit, 0.1), 1.0)
    }

    /// Show the position map for a moment — on recentre, so you can see where you landed.
    func flashPositionIndicator() {
        indicatorUntil = CACurrentMediaTime() + config.indicatorFadeSeconds
    }

    private var cursorPoint = CGPoint.zero
    private var cursorUntil: CFTimeInterval = 0

    /// Ring the pointer briefly. Called when it moves, so you can find it again on a
    /// canvas far larger than the view.
    func showCursorHint(atCanvasPoint point: CGPoint) {
        cursorPoint = point
        cursorUntil = CACurrentMediaTime() + config.cursorHintSeconds
    }

    /// Drop the ring immediately — used while a button is held, where you already know
    /// exactly where the pointer is and a ring following the drag is only a distraction.
    func clearCursorHint() {
        cursorUntil = 0
    }

    /// The part of the canvas currently visible, in canvas pixels. The cursor manager
    /// uses this to keep the pointer where you can actually see it.
    private(set) var visibleRect = CGRect.zero
    private let visibleRectLock = NSLock()

    var currentVisibleRect: CGRect {
        visibleRectLock.lock()
        defer { visibleRectLock.unlock() }
        return visibleRect
    }

    // On-glasses text, layered over the canvas. Calibration and first-run guidance use
    // this rather than a second window: this one is known to appear on the glasses, and a
    // separate AppKit window silently did not.
    private let headingLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var scrim: NSView?

    init(glassesDisplayID: CGDirectDisplayID,
         capture: DesktopCapture,
         tracker: HeadTracker,
         config: ViewConfig,
         device: MTLDevice) throws {
        self.capture = capture
        self.tracker = tracker
        self.config = config
        self.device = device
        self.smoother = PoseSmoother(minCutoff: config.smoothingMinCutoff,
                                     beta: config.smoothingBeta)

        guard let queue = device.makeCommandQueue() else {
            throw RendererError.metalSetupFailed("could not create a command queue")
        }
        self.queue = queue

        // Compiled at runtime so there is no .metallib to plumb through SwiftPM resources.
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vsMain")
        descriptor.fragmentFunction = library.makeFunction(name: "fsMain")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        // Two drawables keeps latency down; three would buffer an extra frame of lag.
        layer.maximumDrawableCount = 2
        self.metalLayer = layer

        super.init()
    }

    enum RendererError: Error, CustomStringConvertible {
        case metalSetupFailed(String)
        case screenNotFound(CGDirectDisplayID)

        var description: String {
            switch self {
            case .metalSetupFailed(let why): return "Metal setup failed: \(why)"
            case .screenNotFound(let id): return "No NSScreen matches display \(id)."
            }
        }
    }

    /// AppKit's global origin is the bottom-left of the main display; CoreGraphics uses
    /// top-left. Deriving the frame this way avoids NSScreen, whose cached list is stale
    /// right after the canvas is created — which is what put this window on the built-in
    /// display instead of the glasses.
    private static func appKitFrame(of displayID: CGDirectDisplayID) -> NSRect {
        let bounds = CGDisplayBounds(displayID)
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        return NSRect(x: bounds.origin.x,
                      y: primaryHeight - bounds.maxY,
                      width: bounds.width,
                      height: bounds.height)
    }

    private static func screenID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Block until AppKit's screen list agrees with CoreGraphics about where this display
    /// is.
    ///
    /// NSScreen is a cached snapshot refreshed from the run loop, and creating the canvas
    /// invalidates it. Placing a window before it catches up puts the window at coordinates
    /// AppKit resolves against stale geometry — it lands on the wrong physical display
    /// while still *reporting* the right frame, which is maddening to debug.
    private static func settledScreen(for displayID: CGDirectDisplayID,
                                      timeout: TimeInterval = 8) -> NSScreen? {
        let expected = appKitFrame(of: displayID)
        let deadline = Date().addingTimeInterval(timeout)
        var candidate: NSScreen?
        repeat {
            candidate = NSScreen.screens.first { screenID($0) == displayID }
            if let candidate, candidate.frame == expected { return candidate }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return candidate
    }

    /// Put a borderless, click-through window over the glasses' display and start drawing.
    func start(on glassesDisplayID: CGDirectDisplayID) throws {
        let expected = Self.appKitFrame(of: glassesDisplayID)
        let screen = Self.settledScreen(for: glassesDisplayID)
        if let screen, screen.frame != expected {
            print("  !! AppKit still disagrees: NSScreen \(screen.frame) vs CG-derived \(expected)")
        }
        // Prefer AppKit's own geometry — it is what the compositor actually places against.
        let frame = screen?.frame ?? expected
        guard frame.width > 1, frame.height > 1 else {
            throw RendererError.screenNotFound(glassesDisplayID)
        }

        // Take the display away from the desktop, so nothing but HoloFrame can appear on
        // it. Released in stop() and by the exit handlers in main.
        if config.captureDisplay {
            let result = CGDisplayCapture(glassesDisplayID)
            capturedDisplay = (result == .success) ? glassesDisplayID : nil
            if result != .success {
                print("  (could not take over the glasses display: \(result.rawValue);"
                      + " windows and the pointer may still land on it)")
            }
        }

        // Anything left from a previous session cannot be reached by reference, so clear
        // by class before making a new one.
        RenderWindow.closeAll()

        let window = RenderWindow.obtain(frame: frame)
        // The shielding level is only composited on a CAPTURED display; used on an ordinary
        // one the window is positioned correctly and never drawn, which looks exactly like
        // the app running on the wrong screen. .screenSaver sits above normal windows and
        // renders.
        window.level = config.captureDisplay
            ? NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            : .screenSaver
        window.backgroundColor = .black
        window.isOpaque = true
        window.ignoresMouseEvents = true          // the desktop lives on the canvas, not here
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenNone]
        window.setFrame(frame, display: true)
        print("  glasses window at \(Int(frame.origin.x)),\(Int(frame.origin.y)) "
              + "\(Int(frame.width))x\(Int(frame.height))")
        // Container rather than using the Metal layer as the view's own layer, so text can
        // sit above it.
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        metalLayer.frame = view.bounds
        metalLayer.drawableSize = frame.size
        view.layer?.addSublayer(metalLayer)

        buildOverlay(in: view)

        window.contentView = view
        window.orderFrontRegardless()
        window.setFrame(frame, display: true)     // reassert after ordering front
        self.window = window
        // Placement has been the single most misleading part of this app to debug, so it
        // reports itself — but only shouts when something is actually wrong.
        let landedOn = Self.screenID(window.screen ?? NSScreen())
        let misplaced = landedOn != glassesDisplayID || window.frame != frame
        if misplaced || ProcessInfo.processInfo.environment["HOLOFRAME_VERBOSE"] != nil {
            print("  window \(Int(window.frame.origin.x)),\(Int(window.frame.origin.y)) "
                  + "\(Int(window.frame.width))x\(Int(window.frame.height))"
                  + "  on display \(landedOn) (want \(glassesDisplayID))"
                  + (misplaced ? "   !! MISPLACED" : ""))
            for s in NSScreen.screens {
                print("    screen \(Self.screenID(s))  \(Int(s.frame.origin.x)),\(Int(s.frame.origin.y)) "
                      + "\(Int(s.frame.width))x\(Int(s.frame.height))")
            }
        }

        let link = view.displayLink(target: self, selector: #selector(render))
        link.add(to: .main, forMode: .common)
        self.displayLink = link

        // 10 Hz is far below anything measurable — two integer lookups and a pointer
        // compare — but bounds the window's time on the wrong screen to ~100 ms.
        self.glassesDisplayID = glassesDisplayID
        abandoned = false
        let watchdog = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.checkDisplay()
        }
        RunLoop.main.add(watchdog, forMode: .common)
        self.watchdog = watchdog
    }

    func stop() {
        hideNow()          // does the window teardown, on the main thread
        releaseDisplay()
    }

    /// Hand the glasses display back to macOS. Must run before the process dies, or the
    /// display stays black and unusable until something else releases it.
    func releaseDisplay() {
        guard let captured = capturedDisplay else { return }
        CGDisplayRelease(captured)
        capturedDisplay = nil
    }

    // MARK: on-glasses text

    private func buildOverlay(in container: NSView) {
        let scrim = NSView(frame: container.bounds)
        scrim.autoresizingMask = [.width, .height]
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = NSColor.black.cgColor
        scrim.isHidden = true
        container.addSubview(scrim)
        self.scrim = scrim

        // Large type: the glasses give ~48 pixels per degree, so this stays legible near
        // the centre, where the optics are sharpest.
        for (label, size, weight, colour) in [
            (headingLabel, CGFloat(64), NSFont.Weight.semibold, NSColor.white),
            (bodyLabel, CGFloat(44), .regular, NSColor(white: 0.88, alpha: 1)),
            (statusLabel, CGFloat(34), .regular, NSColor(white: 0.55, alpha: 1)),
        ] {
            label.font = .systemFont(ofSize: size, weight: weight)
            label.textColor = colour
            label.alignment = .center
            label.maximumNumberOfLines = 4
            label.lineBreakMode = .byWordWrapping
            label.translatesAutoresizingMaskIntoConstraints = false
            scrim.addSubview(label)
        }

        NSLayoutConstraint.activate([
            headingLabel.centerXAnchor.constraint(equalTo: scrim.centerXAnchor),
            headingLabel.centerYAnchor.constraint(equalTo: scrim.centerYAnchor, constant: 130),
            headingLabel.widthAnchor.constraint(equalTo: scrim.widthAnchor, multiplier: 0.8),

            bodyLabel.centerXAnchor.constraint(equalTo: scrim.centerXAnchor),
            bodyLabel.topAnchor.constraint(equalTo: headingLabel.bottomAnchor, constant: 44),
            bodyLabel.widthAnchor.constraint(equalTo: scrim.widthAnchor, multiplier: 0.8),

            statusLabel.centerXAnchor.constraint(equalTo: scrim.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 50),
            statusLabel.widthAnchor.constraint(equalTo: scrim.widthAnchor, multiplier: 0.8),
        ])
    }

    /// Show text on the glasses, hiding the canvas behind it.
    func showMessage(heading: String, body: String = "", status: String = "") {
        headingLabel.stringValue = heading
        bodyLabel.stringValue = body
        statusLabel.stringValue = status
        scrim?.isHidden = false
        scrim?.needsDisplay = true
    }

    func hideMessage() {
        scrim?.isHidden = true
    }

    // MARK: drawing

    @objc private func render() {
        guard !paused,
              let canvas = capture.texture,
              let drawable = metalLayer.nextDrawable(),
              let commandBuffer = queue.makeCommandBuffer() else { return }

        let viewWidth = Double(metalLayer.drawableSize.width)
        let viewHeight = Double(metalLayer.drawableSize.height)
        let canvasWidth = Double(canvas.width)
        let canvasHeight = Double(canvas.height)

        // Pose is latched here, as late as possible before encoding, to keep
        // motion-to-photon latency down.
        // Extrapolated forward, so what reaches your eye matches where your head will be
        // by the time it gets there rather than where it was when we read the sensor.
        let raw = config.predictionSeconds > 0
            ? tracker.predictedEulerDegrees(ahead: config.predictionSeconds,
                                            maxDegrees: config.predictionMaxDegrees)
            : tracker.eulerDegrees

        let now = CACurrentMediaTime()
        let dt = lastFrameTime.map { min(max(now - $0, 1.0 / 240.0), 0.1) } ?? 1.0 / 60.0
        lastFrameTime = now
        let euler = smoother(yaw: raw.yaw, pitch: raw.pitch, roll: raw.roll, dt: dt)

        let zoom = advanceZoom(dt: dt)

        // Dot-to-dot: the glasses show `viewWidth` pixels across `horizontalFOV` degrees,
        // so one degree of head turn moves the canvas by this many pixels.
        //
        // Divided by zoom because what the FOV spans is the VISIBLE canvas width, which
        // zoom changes. Keeping it this way is what makes the canvas stay put in the
        // world while magnified: it behaves like a larger object at the same distance,
        // scanned at the same angular rate, so small head movements become fine
        // adjustments exactly where you need them. The trade is that crossing the whole
        // canvas at high magnification takes more neck than you have — the answer to
        // which is to zoom out, move, and zoom back in, the same as every map.
        let pixelsPerDegree = viewWidth / config.horizontalFOV / zoom

        // The canvas is fixed in the world, so the view moves WITH your head: turning left
        // (+yaw) shows the canvas's left side, which means moving the window left — a
        // smaller centre. Looking up (+pitch) shows the canvas's top, and canvas y grows
        // downward, so that is a smaller centre too. Hence both negative.
        let yawSign: Double = config.invertYaw ? 1 : -1
        let pitchSign: Double = config.invertPitch ? 1 : -1

        var panX = yawSign * euler.yaw * pixelsPerDegree * config.panGain
        var panY = pitchSign * euler.pitch * pixelsPerDegree * config.panGain

        // Zoom about the middle of the view rather than the middle of the canvas.
        //
        // The pan term is divided by zoom, so changing zoom changes it — which means that
        // anywhere except dead centre, magnifying drags the canvas sideways underneath
        // you. You aim at something, pinch, and it slides out of view. Absorbing the
        // difference into an offset holds the canvas point at the centre of the view
        // exactly still, and head movement afterwards pans correctly at the new scale.
        if abs(zoom - lastRenderedZoom) > 1e-9 {
            let base = viewWidth / config.horizontalFOV
            let previousX = yawSign * euler.yaw * (base / lastRenderedZoom) * config.panGain
            let previousY = pitchSign * euler.pitch * (base / lastRenderedZoom) * config.panGain
            zoomAnchorOffset.x += previousX - panX
            zoomAnchorOffset.y += previousY - panY
            lastRenderedZoom = zoom
        }
        panX += zoomAnchorOffset.x
        panY += zoomAnchorOffset.y

        var centerX = canvasWidth / 2 + panX
        var centerY = canvasHeight / 2 + panY

        // Let the view travel all the way to the canvas edge rather than stopping when
        // the edge reaches the edge of vision. That way any corner can be brought to the
        // centre of the glasses, where the optics are sharpest and text is easiest to
        // read. Past the canvas the shader draws black.
        //
        // Once an axis of the canvas fits entirely within the view there is nowhere left
        // to pan on it, and letting it drift would only slide the picture around in the
        // surrounding black. Pin it instead, so fully zoomed out is a steady overview
        // rather than something that wanders off when you move your head.
        let visibleWidth = viewWidth / zoom
        let visibleHeight = viewHeight / zoom
        let marginX = visibleWidth * config.edgeOverscan
        let marginY = visibleHeight * config.edgeOverscan
        centerX = visibleWidth >= canvasWidth
            ? canvasWidth / 2
            : min(max(centerX, -marginX), canvasWidth + marginX)
        centerY = visibleHeight >= canvasHeight
            ? canvasHeight / 2
            : min(max(centerY, -marginY), canvasHeight + marginY)

        // Snap to whole pixels only while nearly still, so text sits on exact texels when
        // you are reading. Snapping during motion is what makes panning look like it is
        // stepping rather than sliding, so above the threshold sample at sub-pixel
        // precision and let the bilinear filter carry it.
        let atRest = smoother.speed < config.pixelSnapBelowSpeed
        let sampleX = atRest ? centerX.rounded() : centerX
        let sampleY = atRest ? centerY.rounded() : centerY

        // Show the map while actually moving, and let it linger briefly afterwards so you
        // can see where you ended up.
        if config.showPositionIndicator, smoother.speed > config.pixelSnapBelowSpeed * 2 {
            indicatorUntil = now + config.indicatorFadeSeconds
        }
        let remaining = indicatorUntil - now
        let indicator = config.showPositionIndicator
            ? Float(min(max(remaining / config.indicatorFadeSeconds, 0), 1))
            : 0

        let rollSign: Double = config.invertRoll ? -1 : 1
        var uniforms = Uniforms(
            canvasSize: SIMD2(Float(canvasWidth), Float(canvasHeight)),
            viewSize: SIMD2(Float(viewWidth), Float(viewHeight)),
            center: SIMD2(Float(sampleX), Float(sampleY)),
            roll: config.compensateRoll ? Float(rollSign * euler.roll * .pi / 180.0) : 0,
            feather: Float(config.edgeFeather),
            indicator: indicator,
            indicatorView: Float(config.indicatorViewportOpacity),
            indicatorBack: Float(config.indicatorBackgroundOpacity),
            cursor: SIMD2(Float(cursorPoint.x), Float(cursorPoint.y)),
            cursorAlpha: config.cursorHintSeconds > 0
                ? Float(min(max((cursorUntil - now) / config.cursorHintSeconds, 0), 1)
                        * config.cursorHintOpacity)
                : 0,
            cursorRadius: Float(config.cursorHintRadius),
            zoom: Float(zoom)
        )

        visibleRectLock.lock()
        visibleRect = CGRect(x: sampleX - visibleWidth / 2,
                             y: sampleY - visibleHeight / 2,
                             width: visibleWidth, height: visibleHeight)
        visibleRectLock.unlock()

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(canvas, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
        framesDrawn += 1
    }
}
