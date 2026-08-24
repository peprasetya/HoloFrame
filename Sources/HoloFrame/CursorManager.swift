//
//  CursorManager.swift — keeping the pointer where you can see it.
//
//  The canvas is far larger than the glasses' field of view, so the pointer can easily end
//  up somewhere you are not looking, with nothing on screen to say where it went.
//
//  Three rules:
//    * While on the canvas, the pointer is held inside the visible viewport, inset far
//      enough to stay drawn. As you turn your head the viewport moves and drags the
//      pointer along its edge, so it is always where you are looking.
//    * Driving it HARD through the viewport edge that FACES the built-in screen hands the
//      pointer over instead of clamping. That is the way out.
//    * Crossing back onto the canvas warps the pointer into the viewport immediately.
//      That is the way in.
//
//  The hand-over deliberately asks for speed, not position. Position alone cannot tell the
//  difference between the two ways a pointer ends up outside the viewport: you pushed it
//  there, or you turned your head and the viewport left without it. Turning to look up puts
//  the pointer below the viewport just as surely as swiping down does — so a position test
//  throws the pointer onto the built-in screen every time you glance up, and you have to
//  look back down to fetch it. Head motion moves the viewport and not the pointer, so it
//  contributes nothing to pointer velocity; asking for velocity toward the edge separates
//  the two cleanly, and a slow drag against the edge now rests there instead of leaving.
//
//  Coming back matters just as much. The arrangement decides where the pointer lands when
//  it crosses onto the canvas, which is essentially never inside the viewport — so under a
//  position test it arrived already "outside", was handed straight back, and the only way
//  in was to look at the canvas edge and catch it there. Entry is therefore a warp rather
//  than something the clamp is left to sort out.
//
//  Which edge faces the built-in screen comes from the display arrangement, so the canvas
//  can be placed on any side of the main screen. Nothing is done while the pointer is on
//  the built-in display, which behaves normally.
//

import AppKit
import CoreGraphics
import Foundation
import QuartzCore

final class CursorManager {

    /// How far inside the viewport edge to hold the pointer, in canvas pixels. The arrow
    /// is drawn down and to the right of its hot spot, so it needs a little room.
    var edgeInset: CGFloat = 16

    /// Pointer speed toward the escape edge, in canvas pixels per second, that counts as
    /// meaning to leave. Below this the pointer rests against the edge.
    private var escapeSpeed: CGFloat

    /// How far it has to keep travelling at that speed before the hand-over fires, in
    /// canvas pixels. Two or three ticks' worth: enough that a single noisy frame, or the
    /// tail of a flick that was aimed at the edge rather than through it, does not count.
    private let escapeTravel: CGFloat = 20

    /// Slop on "is the clamp holding it against the edge", in canvas pixels.
    private let escapeSlack: CGFloat = 2

    private enum Edge { case left, right, top, bottom }

    private let canvasID: CGDirectDisplayID
    private let builtInID: CGDirectDisplayID?
    private let glassesID: CGDirectDisplayID?
    private let display: GlassesDisplay
    private var timer: Timer?

    /// Where we left the pointer last tick, in canvas-local pixels. Because every tick ends
    /// with the pointer exactly here, the difference between this and the next tick's raw
    /// reading is precisely how far the mouse moved — with head motion excluded, since that
    /// moves the viewport rather than the pointer.
    private var lastSeen: CGPoint?
    private var lastTick: CFTimeInterval?

    /// Distance travelled outward, at speed, since the pointer last stopped pushing.
    private var pushTravel: CGFloat = 0

    /// Whether the pointer was on the canvas last tick, so an arrival can be spotted.
    private var onCanvas = false

    init(canvasID: CGDirectDisplayID,
         builtInID: CGDirectDisplayID?,
         glassesID: CGDirectDisplayID?,
         display: GlassesDisplay,
         settings: ViewConfig) {
        self.canvasID = canvasID
        self.builtInID = builtInID
        self.glassesID = glassesID
        self.display = display
        self.escapeSpeed = CGFloat(settings.cursorEscapeSpeed)
    }

    /// Pick up a settings change made while you are wearing the glasses.
    func apply(_ settings: ViewConfig) {
        escapeSpeed = CGFloat(settings.cursorEscapeSpeed)
    }

    func start() {
        // 60 Hz: fast enough that the pointer never visibly escapes, cheap enough not to
        // matter next to the render loop.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Which side of the canvas the built-in screen lies toward. Recomputed each tick so
    /// rearranging displays in System Settings takes effect immediately.
    private func escapeEdge(canvas: CGRect, builtIn: CGRect) -> Edge {
        let dx = builtIn.midX - canvas.midX
        let dy = builtIn.midY - canvas.midY
        if abs(dx) > abs(dy) { return dx > 0 ? .right : .left }
        return dy > 0 ? .bottom : .top     // CoreGraphics y grows downward
    }

    /// Is the clamp currently holding the pointer against this edge?
    private func isPressing(_ edge: Edge, point: CGPoint, inset: CGRect) -> Bool {
        switch edge {
        case .left:   return point.x <= inset.minX + escapeSlack
        case .right:  return point.x >= inset.maxX - escapeSlack
        case .top:    return point.y <= inset.minY + escapeSlack
        case .bottom: return point.y >= inset.maxY - escapeSlack
        }
    }

    /// How much of this tick's pointer movement was toward the edge. Negative means away.
    private func outward(_ edge: Edge, _ delta: CGPoint) -> CGFloat {
        switch edge {
        case .left:   return -delta.x
        case .right:  return  delta.x
        case .top:    return -delta.y
        case .bottom: return  delta.y
        }
    }

    private func fraction(_ value: CGFloat, _ lower: CGFloat, _ span: CGFloat) -> CGFloat {
        span > 0 ? min(max((value - lower) / span, 0), 1) : 0.5
    }

    /// Leaving: arrive on the far side of the built-in screen, keeping the position along
    /// the shared axis proportional so it lands roughly where it left.
    private func arrival(_ edge: Edge, point: CGPoint, viewport: CGRect, builtIn: CGRect) -> CGPoint {
        switch edge {
        case .bottom:
            let f = fraction(point.x, viewport.minX, viewport.width)
            return CGPoint(x: builtIn.minX + builtIn.width * f, y: builtIn.minY + edgeInset)
        case .top:
            let f = fraction(point.x, viewport.minX, viewport.width)
            return CGPoint(x: builtIn.minX + builtIn.width * f, y: builtIn.maxY - edgeInset)
        case .right:
            let f = fraction(point.y, viewport.minY, viewport.height)
            return CGPoint(x: builtIn.minX + edgeInset, y: builtIn.minY + builtIn.height * f)
        case .left:
            let f = fraction(point.y, viewport.minY, viewport.height)
            return CGPoint(x: builtIn.maxX - edgeInset, y: builtIn.minY + builtIn.height * f)
        }
    }

    /// Returning: come in through the viewport edge that faces the built-in screen, at the
    /// same proportional position along the shared axis, so the pointer reappears on the
    /// side it went out and roughly where it left. `global` is the raw arrival point, whose
    /// position along that axis still carries where it crossed.
    private func entry(_ edge: Edge, global: CGPoint, viewport: CGRect, builtIn: CGRect?) -> CGPoint {
        switch edge {
        case .bottom:
            let f = builtIn.map { fraction(global.x, $0.minX, $0.width) } ?? 0.5
            return CGPoint(x: viewport.minX + viewport.width * f, y: viewport.maxY - edgeInset)
        case .top:
            let f = builtIn.map { fraction(global.x, $0.minX, $0.width) } ?? 0.5
            return CGPoint(x: viewport.minX + viewport.width * f, y: viewport.minY + edgeInset)
        case .right:
            let f = builtIn.map { fraction(global.y, $0.minY, $0.height) } ?? 0.5
            return CGPoint(x: viewport.maxX - edgeInset, y: viewport.minY + viewport.height * f)
        case .left:
            let f = builtIn.map { fraction(global.y, $0.minY, $0.height) } ?? 0.5
            return CGPoint(x: viewport.minX + edgeInset, y: viewport.minY + viewport.height * f)
        }
    }

    /// Forget the pointer's history. Called whenever it is somewhere we are not tracking,
    /// so that the next reading on the canvas is treated as an arrival rather than differenced
    /// against a stale position — which would otherwise read as one enormous fake flick.
    private func forgetPointer() {
        onCanvas = false
        lastSeen = nil
        pushTravel = 0
    }

    private func tick() {
        guard let location = CGEvent(source: nil)?.location else { return }

        let now = CACurrentMediaTime()
        // Clamped: Timer can fire late, and a long gap would otherwise divide a large,
        // legitimate movement by a large interval and read as slow.
        let dt = min(max(now - (lastTick ?? now - 1.0 / 60.0), 1.0 / 240.0), 1.0 / 15.0)
        lastTick = now

        let canvasBounds = CGDisplayBounds(canvasID)

        // The glasses display is a real macOS display, so the pointer can wander onto it —
        // where it is invisible, because HoloFrame draws its own view there rather than
        // that display's desktop. Put it back in the middle of what you are looking at.
        if let glassesID, CGDisplayBounds(glassesID).contains(location) {
            let viewport = display.currentVisibleRect
            if viewport.width > 1 {
                warp(to: CGPoint(x: canvasBounds.origin.x + viewport.midX,
                                 y: canvasBounds.origin.y + viewport.midY))
            }
            forgetPointer()
            return
        }

        guard canvasBounds.contains(location) else {   // built-in: leave alone
            forgetPointer()
            return
        }

        // Intersect with the canvas: the viewport is allowed to run past the canvas edge
        // (that is what lets a corner reach the centre of your view), and clamping into
        // that overhang would park the pointer in the black beyond the desktop, where
        // there is nothing to see and no way to find it.
        let canvasRect = CGRect(origin: .zero, size: canvasBounds.size)
        let viewport = display.currentVisibleRect.intersection(canvasRect)
        guard viewport.width > 1, viewport.height > 1 else { return }

        // The inset is a distance on the glasses, not on the canvas, so it has to be
        // converted: zoomed out, 16 view pixels are worth far more canvas pixels, and an
        // un-converted inset would let the pointer sit right on the edge of vision.
        let zoom = max(display.currentZoom, 0.01)
        let insetCanvas = edgeInset / CGFloat(zoom)
        let inset = viewport.insetBy(dx: insetCanvas, dy: insetCanvas)
        guard inset.width > 0, inset.height > 0 else { return }

        // Canvas-local pixels: both CGDisplayBounds and the captured texture put the
        // origin at the top-left, so this is a plain translation.
        let local = CGPoint(x: location.x - canvasBounds.origin.x,
                            y: location.y - canvasBounds.origin.y)

        let builtIn = builtInID.map { CGDisplayBounds($0) }
        let edge = builtIn.map { escapeEdge(canvas: canvasBounds, builtIn: $0) }

        // --- arriving from the built-in screen: land inside the viewport ---
        if !onCanvas {
            onCanvas = true
            pushTravel = 0
            let landing = entry(edge ?? .bottom, global: location, viewport: viewport, builtIn: builtIn)
            warp(to: CGPoint(x: landing.x + canvasBounds.origin.x,
                             y: landing.y + canvasBounds.origin.y))
            lastSeen = landing
            display.showCursorHint(atCanvasPoint: landing)
            return
        }

        // How far the mouse itself moved since last tick. Head motion is absent from this
        // by construction: it moves the viewport, and the pointer only follows because the
        // clamp drags it, which happens after this is measured.
        let previous = lastSeen ?? local
        let delta = CGPoint(x: local.x - previous.x, y: local.y - previous.y)

        // --- hand over to the built-in screen, but only if you meant it ---
        if let builtIn, let edge {
            let travelled = outward(edge, delta)
            // Measured in view pixels for the same reason: how hard a flick feels has
            // nothing to do with how much canvas is on screen at the time.
            let viewSpeed = travelled * CGFloat(zoom) / CGFloat(dt)
            if isPressing(edge, point: local, inset: inset), viewSpeed >= escapeSpeed {
                // Capped so no single tick can ever fill the budget on its own, which forces
                // a hand-over to span at least two of them. That is not fussiness about noise:
                // a warp is not guaranteed to show up in the very next reading, and one stale
                // frame — the pre-clamp position, read after the clamp already pulled the
                // pointer back — looks exactly like a huge outward flick. Two consecutive
                // such frames cannot happen, because the warp only fires once.
                pushTravel += min(travelled * CGFloat(zoom), escapeTravel * 0.6)
            } else {
                pushTravel = 0
            }
            if pushTravel >= escapeTravel {
                warp(to: arrival(edge, point: local, viewport: viewport, builtIn: builtIn))
                forgetPointer()
                return
            }
        }

        // --- otherwise hold it inside the viewport ---
        let clamped = CGPoint(x: min(max(local.x, inset.minX), inset.maxX),
                              y: min(max(local.y, inset.minY), inset.maxY))
        if abs(clamped.x - local.x) > 0.5 || abs(clamped.y - local.y) > 0.5 {
            warp(to: CGPoint(x: clamped.x + canvasBounds.origin.x,
                             y: clamped.y + canvasBounds.origin.y))
        }

        // Flash a ring around the pointer when it moves. Clamping keeps it on screen, but
        // on a canvas this size "on screen" is not the same as "findable".
        //
        // Never while a button is held: during a drag you already know exactly where the
        // pointer is, and a ring tracking it is pure distraction over whatever you are
        // dragging.
        if NSEvent.pressedMouseButtons != 0 {
            display.clearCursorHint()
        } else if let last = lastSeen {
            let jump = hypot(clamped.x - last.x, clamped.y - last.y)
            if jump > 6 { display.showCursorHint(atCanvasPoint: clamped) }
        }
        lastSeen = clamped
    }

    /// Bring the pointer to the middle of what you are looking at.
    ///
    /// Intersected with the canvas for the same reason the clamp in `tick` is: the viewport
    /// may overhang the canvas edge, and the centre of an overhanging viewport can sit in
    /// the black past the desktop, where there is nothing to click and nothing to see.
    func centreInViewport() {
        let canvasBounds = CGDisplayBounds(canvasID)
        let canvasRect = CGRect(origin: .zero, size: canvasBounds.size)
        let viewport = display.currentVisibleRect.intersection(canvasRect)
        guard viewport.width > 1, viewport.height > 1 else { return }
        warp(to: CGPoint(x: canvasBounds.origin.x + viewport.midX,
                         y: canvasBounds.origin.y + viewport.midY))
        display.showCursorHint(atCanvasPoint: CGPoint(x: viewport.midX, y: viewport.midY))
        lastSeen = CGPoint(x: viewport.midX, y: viewport.midY)
        pushTravel = 0
        onCanvas = true
    }

    private func warp(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        // Without this the pointer stays decoupled from the mouse after a warp and drifts.
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}
