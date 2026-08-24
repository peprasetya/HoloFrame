//
//  PinchZoom.swift — hold right-Option, pinch to zoom.
//
//  The canvas is a whole desktop, so every gesture worth using is already spoken for by
//  whatever app is sitting on it. Pinch most of all: taking it globally would mean you can
//  no longer pinch in Preview exactly when Preview is the thing you are looking at. The
//  modifier is what resolves that — while right-Option is held the pinch is HoloFrame's
//  and is swallowed before any app sees it; the moment it is released pinch belongs to the
//  focused app again, unchanged.
//
//  Right-Option specifically because nothing else claims it. Held on its own it is inert
//  on macOS — it only does anything in combination with a key — and it is distinguishable
//  from left-Option, which apps do use, through the device-dependent flag bits.
//
//  This is the one part of HoloFrame that needs Accessibility permission. Swallowing an
//  event, rather than merely watching it, requires an active event tap, and there is no
//  way to have the first without the second. Everything else keeps working without it; the
//  tap simply never starts, and the menu bar says so.
//

import AppKit
import CoreGraphics
import Foundation

final class PinchZoom {

    /// Called with the pinch magnitude: positive to magnify, negative to shrink, in the
    /// system's own units where roughly ±1 is a full pinch across the trackpad.
    private let onPinch: (Double) -> Void

    /// NSEventTypeMagnify. Not in CGEventType — gesture events pass through the tap as
    /// numbered types the enum never got members for, so the mask is built by hand.
    ///
    /// 30, and the number matters more than it looks: CGEventType and NSEvent.EventType
    /// share a numbering space only by accident, and they collide. 22 is
    /// `CGEventType.scrollWheel`, not magnify — subscribing to it delivers scroll events,
    /// and asking one of those for `.magnification` throws rather than returning anything.
    private static let magnifyType: UInt32 = 30

    /// Two-finger double-tap zoom. Swallowed alongside magnify so a stray one cannot
    /// jump an app underneath while the modifier is held.
    private static let smartMagnifyType: UInt32 = 32

    /// Every trackpad gesture type, subscribed to as a set rather than picking out the two
    /// that get acted on. Asking only for magnify is the narrower, tidier thing to do and
    /// it is also the difference between this and a probe that provably received magnify
    /// events — so breadth here is not laziness, it removes a variable. Only magnify and
    /// smartMagnify are ever swallowed; the rest are passed through untouched.
    private static let gestureTypes: [UInt32] = [
        18,  // rotate
        19,  // beginGesture
        20,  // endGesture
        29,  // gesture
        30,  // magnify
        31,  // swipe
        32,  // smartMagnify
    ]

    /// Device-dependent flag bit for the RIGHT Option key. The public
    /// `CGEventFlags.maskAlternate` is set by either one and so cannot tell them apart.
    private static let rightOptionBit: UInt64 = 0x0000_0040

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// Whether right-Option is down right now, updated from the flagsChanged stream.
    private var armed = false

    init(onPinch: @escaping (Double) -> Void) {
        self.onPinch = onPinch
    }

    /// Whether macOS will let us have an event tap at all.
    static var isPermitted: Bool { AXIsProcessTrusted() }

    /// Whether the tap is actually up. `tapCreate` returns a port even when untrusted, so
    /// a non-nil result proves nothing on its own — this is only ever set after the
    /// permission check has already passed.
    var isRunning: Bool { tap != nil }

    /// Ask for Accessibility, opening the System Settings pane. Only ever called from the
    /// menu, never at launch: a permission dialog on startup for a feature you may not use
    /// is how apps train people to click Deny.
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Start watching. Returns false if Accessibility has not been granted, or if the tap
    /// could not be created — in both cases the rest of the app is unaffected.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard Self.isPermitted else { return false }

        var mask: UInt64 = 1 << UInt64(CGEventType.flagsChanged.rawValue)
        for type in Self.gestureTypes { mask |= (1 << UInt64(type)) }
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,               // active: may swallow events
            eventsOfInterest: CGEventMask(mask),
            callback: { proxy, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let zoom = Unmanaged<PinchZoom>.fromOpaque(refcon).takeUnretainedValue()
                return zoom.handle(proxy: proxy, type: type, event: event)
            },
            userInfo: context
        ) else { return false }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        tap = port
        source = runLoopSource
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        source = nil
        tap = nil
        armed = false
    }

    // MARK: - the tap

    private func handle(proxy: CGEventTapProxy,
                        type: CGEventType,
                        event: CGEvent) -> Unmanaged<CGEvent>? {

        // A slow callback gets the tap switched off by the system rather than allowed to
        // stall input. Nothing here is slow, but a machine under enough load can still
        // trip it, and a tap that is off stays off until re-enabled — which would look
        // exactly like the feature quietly breaking.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            let down = (event.flags.rawValue & Self.rightOptionBit) != 0
            armed = down
            // Always passed through: the modifier itself is not ours to take, and an app
            // that tracks modifier state would otherwise see it stick down forever.
            return Unmanaged.passUnretained(event)
        }

        guard armed else { return Unmanaged.passUnretained(event) }

        // Only a real NSEvent knows how to read the magnification field — and it is asked
        // what it IS before being asked what it contains. Trusting the raw type number is
        // what made the first version call `.magnification` on a scroll event, which does
        // not return a wrong answer, it throws.
        guard let gesture = NSEvent(cgEvent: event) else {
            return Unmanaged.passUnretained(event)
        }
        guard gesture.type == .magnify || gesture.type == .smartMagnify else {
            return Unmanaged.passUnretained(event)
        }
        let amount = gesture.type == .magnify ? Double(gesture.magnification) : 0.25
        if amount != 0 { onPinch(amount) }
        return nil      // swallowed: the app underneath never sees it
    }
}
