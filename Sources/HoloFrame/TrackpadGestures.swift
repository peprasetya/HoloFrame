//
//  TrackpadGestures.swift — hold right-Option: pinch to zoom, two-finger scroll to pan.
//
//  The canvas is a whole desktop, so every gesture worth using is already spoken for by
//  whatever app is sitting on it. Pinch and scroll most of all: taking them globally would
//  mean you can no longer pinch in Preview or scroll a web page exactly when that is the
//  thing you are looking at. The modifier is what resolves that — while right-Option is held
//  the gesture is HoloFrame's and is swallowed before any app sees it; the moment it is
//  released the gesture belongs to the focused app again, unchanged.
//
//  Right-Option specifically because nothing else claims it. Held on its own it is inert
//  on macOS — it only does anything in combination with a key — and it is distinguishable
//  from left-Option, which apps do use, through the device-dependent flag bits.
//
//  Pan exists because head tracking and recentring are both coarse. Recentring moves
//  everything to wherever you happen to be looking, which is more than you wanted when all
//  you meant was "a little to the left"; two fingers nudge the canvas exactly as far as you
//  drag it, like moving a map. (Five-finger gestures were considered and rejected: macOS
//  reserves four- and five-finger swipes and pinches for Mission Control, Launchpad and Show
//  Desktop, and does not deliver them to an event tap reliably.)
//
//  This is the one part of HoloFrame that needs Accessibility permission. Swallowing an
//  event, rather than merely watching it, requires an active event tap, and there is no
//  way to have the first without the second. Everything else keeps working without it; the
//  taps simply never start, and the menu bar says so.
//
//  An active tap is the most dangerous thing this app does, and the first version proved
//  it. The window server delivers input as ONE ordered stream, and an active tap holds that
//  stream until its callback returns — not just for the events it asked for, but for every
//  event queued behind them. The trackpad emits gesture events continuously whenever a
//  finger is on it, so a tap on gestures is in the path of nearly everything you do. That
//  tap lived on the main thread, next to the renderer and the cursor clamp, and whenever
//  the main thread fell behind — load, heat, a slow frame — the whole system's input
//  waited for it: key-ups arriving late enough that macOS took the key as held and opened
//  the accent picker, keystrokes dropped, the pointer stalling and lurching.
//
//  Two rules now keep it out of the way:
//    * The taps run on a thread of their own that does nothing else, so no amount of work
//      elsewhere in HoloFrame can make them slow to answer.
//    * The gesture tap is switched OFF except while right-Option is actually held. A
//      separate listen-only tap watches the modifier; listen-only taps are told about events
//      after the fact and never hold the stream. So in normal use HoloFrame is not in the
//      input path at all — only for the moments you are deliberately zooming or panning.
//

import AppKit
import CoreGraphics
import Foundation
import os

final class TrackpadGestures {

    /// Called on the main thread with the pinch magnitude: positive to magnify, negative to
    /// shrink, in the system's own units where roughly ±1 is a full pinch across the trackpad.
    private let onPinch: (Double) -> Void

    /// Called on the main thread with a scroll delta in points, already in the direction the
    /// system's natural-scrolling setting says content should move.
    private let onPan: (Double, Double) -> Void

    /// Every trackpad gesture type plus scroll, subscribed to as a set rather than picking
    /// out magnify. A tap asking for magnify alone did not receive it in testing, while this
    /// set did. Only magnify, smartMagnify and scroll are ever swallowed.
    ///
    /// These are NSEvent.EventType numbers, and they are written out because CGEventType
    /// has no members for most of them — and because the two numberings collide. 22 is
    /// `CGEventType.scrollWheel`, not magnify; subscribing to it delivers scroll events, and
    /// asking one of those for `.magnification` throws rather than returning anything.
    private static let gestureTypes: [UInt32] = [
        18,  // rotate
        19,  // beginGesture
        20,  // endGesture
        22,  // scrollWheel (the same number in both enums)
        29,  // gesture
        30,  // magnify
        31,  // swipe
        32,  // smartMagnify
    ]

    /// Device-dependent flag bit for the RIGHT Option key. The public
    /// `CGEventFlags.maskAlternate` is set by either one and so cannot tell them apart.
    private static let rightOptionBit: UInt64 = 0x0000_0040

    private var flagsTap: CFMachPort?
    private var gestureTap: CFMachPort?
    private var thread: Thread?
    private var runLoop: CFRunLoop?

    /// Whether right-Option is down. Only ever read and written on the tap thread.
    private var armed = false

    private let activeState = OSAllocatedUnfairLock(initialState: false)

    /// Whether there is a canvas for gestures to act on. While false, right-⌥ gestures are
    /// left alone rather than swallowed — without glasses plugged in, eating a pinch or a
    /// scroll and doing nothing with it would just look like the trackpad broke. Set from
    /// the main thread, read on the tap thread.
    var isActive: Bool {
        get { activeState.withLock { $0 } }
        set { activeState.withLock { $0 = newValue } }
    }

    init(onPinch: @escaping (Double) -> Void, onPan: @escaping (Double, Double) -> Void) {
        self.onPinch = onPinch
        self.onPan = onPan
    }

    /// Whether macOS will let us have an event tap at all.
    static var isPermitted: Bool { AXIsProcessTrusted() }

    /// Whether the taps are actually up. `tapCreate` returns a port even when untrusted, so
    /// a non-nil result proves nothing on its own — this is only ever set after the
    /// permission check has already passed.
    var isRunning: Bool { flagsTap != nil }

    /// Ask for Accessibility, opening the System Settings pane. Only ever called from the
    /// menu, never at launch: a permission dialog on startup for a feature you may not use
    /// is how apps train people to click Deny.
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Start watching. Returns false if Accessibility has not been granted, or if a tap
    /// could not be created — in both cases the rest of the app is unaffected.
    @discardableResult
    func start() -> Bool {
        guard flagsTap == nil else { return true }
        guard Self.isPermitted else { return false }

        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let flags = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,               // told afterwards; never holds input
            eventsOfInterest: CGEventMask(1 << UInt64(CGEventType.flagsChanged.rawValue)),
            callback: { _, type, event, refcon in
                if let refcon {
                    Unmanaged<TrackpadGestures>.fromOpaque(refcon).takeUnretainedValue()
                        .modifiersChanged(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else { return false }

        var mask: UInt64 = 0
        for type in Self.gestureTypes { mask |= (1 << UInt64(type)) }
        guard let gestures = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,               // active: may swallow events
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<TrackpadGestures>.fromOpaque(refcon).takeUnretainedValue()
                    .gesture(type: type, event: event)
            },
            userInfo: context
        ) else {
            CFMachPortInvalidate(flags)
            return false
        }
        // Off until right-Option goes down. Taps come into existence enabled.
        CGEvent.tapEnable(tap: gestures, enable: false)

        flagsTap = flags
        gestureTap = gestures

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()
            for port in [flags, gestures] {
                CFRunLoopAddSource(loop, CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0),
                                   .commonModes)
            }
            runLoop = loop
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "id.prasetya.holoframe.gestures"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        self.thread = thread
        return true
    }

    func stop() {
        // Invalidating is what actually removes a tap from the window server; merely
        // disabling it and dropping the reference can leave it registered.
        for port in [gestureTap, flagsTap].compactMap({ $0 }) {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
        gestureTap = nil
        flagsTap = nil
        runLoop = nil
        thread = nil
    }

    // MARK: - the taps (tap thread)

    private func modifiersChanged(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let flagsTap { CGEvent.tapEnable(tap: flagsTap, enable: true) }
            // A key change may have been missed while it was off, so ask rather than guess.
            setArmed(CGEventSource.flagsState(.combinedSessionState).rawValue & Self.rightOptionBit != 0)
            return
        }
        guard type == .flagsChanged else { return }
        setArmed(event.flags.rawValue & Self.rightOptionBit != 0)
    }

    private func setArmed(_ down: Bool) {
        guard down != armed else { return }
        armed = down
        if let gestureTap { CGEvent.tapEnable(tap: gestureTap, enable: down && isActive) }
    }

    private func gesture(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system switches off a tap it considers slow, and it stays off until re-enabled.
        // Only re-enable if the modifier is still held; otherwise off is where it belongs.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if armed, let gestureTap { CGEvent.tapEnable(tap: gestureTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard armed, isActive else { return Unmanaged.passUnretained(event) }

        if type == .scrollWheel {
            // Momentum — the glide after the fingers lift — is swallowed but not applied.
            // Panning is for placing the canvas precisely, and a view that keeps sliding
            // after you have stopped is the opposite of that.
            if event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0 {
                let dy = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
                let dx = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
                if dx != 0 || dy != 0 {
                    DispatchQueue.main.async { [onPan] in onPan(dx, dy) }
                }
            }
            return nil
        }

        // Only a real NSEvent knows how to read the magnification field — and it is asked
        // what it IS before being asked what it contains. Trusting the raw type number is
        // what made the first version call `.magnification` on a scroll event, which does
        // not return a wrong answer, it throws.
        guard let gesture = NSEvent(cgEvent: event),
              gesture.type == .magnify || gesture.type == .smartMagnify else {
            return Unmanaged.passUnretained(event)
        }
        let amount = gesture.type == .magnify ? Double(gesture.magnification) : 0.25
        if amount != 0 {
            // Hand off rather than call in: view state belongs to the main thread, and
            // waiting on it here is exactly the stall this thread exists to avoid.
            DispatchQueue.main.async { [onPinch] in onPinch(amount) }
        }
        return nil      // swallowed: the app underneath never sees it
    }
}
