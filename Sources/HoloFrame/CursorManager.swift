//
//  CursorManager.swift — keeping the pointer where you can see it.
//
//  The canvas is far larger than the glasses' field of view, so the pointer can easily end
//  up somewhere you are not looking, with nothing on screen to say where it went.
//
//  Two rules:
//    * While on the canvas, the pointer is held inside the visible viewport, inset far
//      enough to stay drawn. As you turn your head the viewport moves and drags the
//      pointer along its edge, so it is always where you are looking.
//    * Pushing through the viewport edge that FACES the built-in screen hands the pointer
//      over instead of clamping. That is the way out; coming back is automatic, because
//      crossing onto the canvas lands somewhere arbitrary and the clamp immediately pulls
//      it into the viewport.
//
//  Which edge that is comes from the display arrangement, so the canvas can be placed on
//  any side of the main screen. Nothing is done while the pointer is on the built-in
//  display, which behaves normally.
//

import AppKit
import CoreGraphics
import Foundation

final class CursorManager {

    /// How far inside the viewport edge to hold the pointer, in canvas pixels. The arrow
    /// is drawn down and to the right of its hot spot, so it needs a little room.
    var edgeInset: CGFloat = 16

    /// How far past the edge counts as "pushing through" rather than "resting against".
    private let escapeSlack: CGFloat = 2

    private enum Edge { case left, right, top, bottom }

    private let canvasID: CGDirectDisplayID
    private let builtInID: CGDirectDisplayID?
    private let glassesID: CGDirectDisplayID?
    private let display: GlassesDisplay
    private var timer: Timer?

    init(canvasID: CGDirectDisplayID,
         builtInID: CGDirectDisplayID?,
         glassesID: CGDirectDisplayID?,
         display: GlassesDisplay) {
        self.canvasID = canvasID
        self.builtInID = builtInID
        self.glassesID = glassesID
        self.display = display
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

    private func hasPushedThrough(_ edge: Edge, point: CGPoint, viewport: CGRect) -> Bool {
        switch edge {
        case .left:   return point.x < viewport.minX - escapeSlack
        case .right:  return point.x > viewport.maxX + escapeSlack
        case .top:    return point.y < viewport.minY - escapeSlack
        case .bottom: return point.y > viewport.maxY + escapeSlack
        }
    }

    /// Arrive on the far side of the built-in screen, keeping the position along the
    /// shared axis proportional so it lands roughly where it left.
    private func arrival(_ edge: Edge, point: CGPoint, viewport: CGRect, builtIn: CGRect) -> CGPoint {
        func fraction(_ value: CGFloat, _ lower: CGFloat, _ span: CGFloat) -> CGFloat {
            span > 0 ? min(max((value - lower) / span, 0), 1) : 0.5
        }
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

    private func tick() {
        guard let location = CGEvent(source: nil)?.location else { return }

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
            return
        }

        guard canvasBounds.contains(location) else { return }   // built-in: leave alone

        // Intersect with the canvas: the viewport is allowed to run past the canvas edge
        // (that is what lets a corner reach the centre of your view), and clamping into
        // that overhang would park the pointer in the black beyond the desktop, where
        // there is nothing to see and no way to find it.
        let canvasRect = CGRect(origin: .zero, size: canvasBounds.size)
        let viewport = display.currentVisibleRect.intersection(canvasRect)
        guard viewport.width > 1, viewport.height > 1 else { return }

        // Canvas-local pixels: both CGDisplayBounds and the captured texture put the
        // origin at the top-left, so this is a plain translation.
        let local = CGPoint(x: location.x - canvasBounds.origin.x,
                            y: location.y - canvasBounds.origin.y)

        // --- hand over to the built-in screen ---
        if let builtInID {
            let builtIn = CGDisplayBounds(builtInID)
            let edge = escapeEdge(canvas: canvasBounds, builtIn: builtIn)
            if hasPushedThrough(edge, point: local, viewport: viewport) {
                warp(to: arrival(edge, point: local, viewport: viewport, builtIn: builtIn))
                return
            }
        }

        // --- otherwise hold it inside the viewport ---
        let inset = viewport.insetBy(dx: edgeInset, dy: edgeInset)
        guard inset.width > 0, inset.height > 0 else { return }

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

    private var lastSeen: CGPoint?

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
    }

    private func warp(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        // Without this the pointer stays decoupled from the mouse after a warp and drifts.
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}
