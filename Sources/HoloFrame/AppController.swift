//
//  AppController.swift — the app's lifecycle.
//
//  HoloFrame is only meaningful while the glasses are plugged in, so everything it creates
//  is tied to that. No glasses means no canvas: leaving a 7680x2160 display on the desktop
//  with nothing to show it on would scatter the user's windows across a screen they cannot
//  see. Unplugging tears it all down and returns the desktop to normal; plugging back in
//  builds it again.
//
//  Ordering matters more than it looks. The canvas has to exist before AppKit takes its
//  screen snapshot, or NSScreen ends up without it and every window we place lands on the
//  wrong display — see virtualDisplay.md. So activation waits for the canvas to actually
//  appear in NSScreen before opening the window on the glasses.
//

import AppKit
import CHoloFrame
import CoreGraphics
import Foundation
import IOKit
import IOKit.hid
import Metal

final class AppController {

    /// `activating` exists so the periodic check cannot re-enter startup while the canvas
    /// is still coming up.
    private enum State { case waiting, activating, active }

    private var state: State = .waiting
    private var activationDeadline = Date.distantPast
    private var settings: ViewConfig
    private var settingsWindow: SettingsWindow?
    private let canvasWidth: UInt32
    private let canvasHeight: UInt32
    private let canvasSerial: UInt32

    // Torn down and rebuilt with the glasses.
    private var canvas: HFVirtualDisplay?
    private var capture: DesktopCapture?
    private var view: GlassesDisplay?
    private var cursor: CursorManager?
    private var renderDevice: MTLDevice?

    // Outlive the glasses: the IMU connection is re-established on demand, but the tracker
    // keeps its calibration and bias estimate.
    private let tracker: HeadTracker
    private let sampleTap = SampleTap()
    private var glasses: XRealDevice?
    private var statusItem: StatusItem?
    private var recenterHotKey: HotKey?
    private var gestures: TrackpadGestures?
    private var needsCalibration: Bool

    private var idlePaused = false
    private var hidMonitor: IOHIDManager?

    init(canvasWidth: UInt32, canvasHeight: UInt32, canvasSerial: UInt32,
         settings: ViewConfig, forceCalibration: Bool) {
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.canvasSerial = canvasSerial
        self.settings = settings
        let stored = AxisMap.load()
        self.tracker = HeadTracker(axes: stored ?? .identity)
        self.tracker.magneticAnchorEnabled = settings.magneticAnchor
        self.needsCalibration = forceCalibration || stored == nil
        print("  axis mapping: \(stored?.summary ?? "not set — will calibrate on the glasses")")
        if settings.magneticAnchor {
            // Dormant until the magnetometer's internal offset has been measured: uncorrected,
            // it is larger than Earth's field and turns the anchor into a source of drift
            // rather than a cure for it. See HeadTracker.hardIronOffset.
            print("  magnetic anchor: off until the magnetometer is calibrated")
        }
        if let stored, let bias = StoredGyroBias.load(for: stored) {
            tracker.preset(bias: bias)
            lastSavedBias = bias
            print(String(format: "  gyro bias: %+.3f %+.3f %+.3f deg/s, from last time", bias.x, bias.y, bias.z))
        }
    }

    private var lastSavedBias: SIMD3<Double>?
    private var lastBiasSave = Date.distantPast

    /// Remember a desk-quality bias for next launch. At most once a minute: on a desk a new
    /// estimate arrives every couple of seconds, and none of them is worth a write.
    private func saveBiasIfUpdated(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastBiasSave) > 60,
              let bias = tracker.deskBias, bias != lastSavedBias,
              let axes = AxisMap.load() else { return }
        StoredGyroBias.save(bias, for: axes)
        lastSavedBias = bias
        lastBiasSave = Date()
    }

    // MARK: - detection

    /// XREAL Air identifies itself with EDID vendor 0x3647, product 0x3132.
    static func findGlassesDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first {
            CGDisplayVendorNumber($0) == 0x3647 && CGDisplayModelNumber($0) == 0x3132
        }
    }

    static func findBuiltInDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    // MARK: - lifecycle

    /// Put the view back where you are looking.
    private func recentreNow(_ how: String) {
        tracker.recenter()
        // Zoom goes back to 1:1 with it. Recentring is the one thing you reach for when
        // you have lost your bearings, so it has to restore ALL of what you changed —
        // otherwise "I am somewhere odd and everything is the wrong size" only half fixes.
        view?.resetZoom()
        view?.resetPan()
        view?.flashPositionIndicator()
        print("  recentred (\(how))")
    }

    // MARK: - trackpad zoom and pan

    /// Hold right-Option and pinch or scroll. Started without prompting: if Accessibility is
    /// not granted this quietly does nothing and the menu offers the prompt, because asking
    /// for a permission at launch, for a feature the person may never use, is how apps
    /// teach people to click Deny.
    private func startGestures() {
        gestures?.stop()
        let gestures = TrackpadGestures(
            onPinch: { [weak self] amount in
                guard let self, let view = self.view else { return }
                view.scaleZoom(by: 1 + amount * self.settings.pinchZoomGain)
            },
            onClutch: { [weak self] held in
                self?.view?.setClutched(held)
            },
            onPan: { [weak self] dx, dy in
                self?.view?.pan(byScrollX: dx, y: dy)
            })
        let running = gestures.start()
        gestures.isActive = state == .active
        self.gestures = gestures
        statusItem?.setGesturesAvailable(running)
        print(running
              ? "  right-⌥: hold to carry the canvas, scroll to pan, pinch to zoom"
              : "  trackpad zoom and pan: needs Accessibility — enable it from the menu bar")
    }

    func start() {
        statusItem = StatusItem(
            recenter: { [weak self] in self?.recentreNow("menu") },
            recalibrate: { [weak self] in self?.runCalibration() },
            settings: { [weak self] in self?.showSettings() },
            grantAccessibility: {
                // Just open the prompt. Noticing that it was granted is the job of the
                // periodic check, which watches regardless of how the grant happened.
                TrackpadGestures.requestPermission()
            },
            quit: { [weak self] in
                self?.deactivate(reason: nil)
                exit(0)
            }
        )
        recenterHotKey = HotKey(keyCode: HotKey.keyR,
                                modifiers: HotKey.command | HotKey.option) { [weak self] in
            self?.recentreNow("⌘⌥R")
        }

        startGestures()

        // Already plugged in at launch: nothing is settling, so there is no reason to wait.
        if Self.findGlassesDisplay() != nil { glassesSeenAt = .distantPast }

        // React to the glasses being plugged in or pulled out.
        CGDisplayRegisterReconfigurationCallback({ display, flags, context in
            guard let context else { return }
            let controller = Unmanaged<AppController>.fromOpaque(context).takeUnretainedValue()

            // Nothing that touches a window may happen here — see hideViewIfDisplayLost.
            // `beginConfigurationFlag` in particular fires for every reconfiguration,
            // including a mere mode change, so it is not evidence the display is leaving.
            if flags.contains(.removeFlag) || flags.contains(.disabledFlag) {
                controller.hideViewIfDisplayLost(display)
            }
            // Then tear down properly, once the configuration has settled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { controller.evaluate() }
        }, Unmanaged.passUnretained(self).toOpaque())

        // Second signal, and usually the earliest: the USB device going away. The display
        // and the HID interfaces disappear together, but not always in that order.
        watchForHIDRemoval()

        // Safety net — reconfiguration callbacks are not guaranteed for every case.
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.evaluate()
        }

        // Replaced by a status line the moment the glasses turn up.
        statusItem?.setNote(Self.waitingNote)
        evaluate()
        startHousekeeping()
    }

    /// When the glasses display was first seen in the current unbroken run of sightings.
    private var glassesSeenAt: Date?

    /// How long a freshly plugged-in display must stay put before we build on it. Right
    /// after plugging in, macOS is still applying the remembered arrangement and the
    /// glasses are still choosing a mode, and the USB interfaces for the IMU can trail the
    /// display by a moment. A window placed into that lands wherever the display was a
    /// fraction of a second ago.
    private let settleSeconds: TimeInterval = 1.5

    /// Set while the view is being rebuilt; view.start() spins the run loop, and the
    /// periodic check must not pile a second rebuild on top.
    private var rebuildingView = false

    /// Bring the app in line with whether the glasses are present.
    private func evaluate() {
        guard !rebuildingView else { return }
        let present = Self.findGlassesDisplay() != nil
        glassesSeenAt = present ? (glassesSeenAt ?? Date()) : nil

        switch (state, present) {
        case (.waiting, true):
            let settled = Date().timeIntervalSince(glassesSeenAt ?? .distantPast)
            if settled >= settleSeconds {
                beginActivation()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + settleSeconds - settled + 0.05) {
                    [weak self] in self?.evaluate()
                }
            }
        case (.activating, false): cancelActivation()
        case (.active, false):
            deactivate(reason: "glasses unplugged")
            relaunchForNextPlugIn()
        case (.active, true) where view?.isLost ?? false:
            // The view took itself off the glasses, yet the glasses are still here: a fast
            // replug, a mode change, the USB side dropping out and coming back. Sitting in
            // .active with no window is what left the glasses showing the plain desktop
            // until HoloFrame was restarted.
            //
            // Not at once, though. Unplugging drops the USB side a moment before the
            // display, and rebuilding onto a display on its way out would be wasted work.
            let lostAt = viewLostAt ?? Date()
            viewLostAt = lostAt
            let waited = Date().timeIntervalSince(lostAt)
            if waited >= settleSeconds {
                viewLostAt = nil
                rebuildView()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + settleSeconds - waited + 0.05) {
                    [weak self] in self?.evaluate()
                }
            }
        default: break
        }
    }

    /// When the view was first found lost while the glasses were still present.
    private var viewLostAt: Date?

    private var rebuilds: [Date] = []

    /// Put a fresh view on the glasses without touching the canvas, so windows on it stay
    /// exactly where they are.
    private func rebuildView() {
        guard state == .active, let canvasID = canvas?.displayID, let renderDevice,
              let glassesID = Self.findGlassesDisplay() else { return }

        // A display that keeps pulling the window away is not going to be fixed by putting
        // it back again. Start over from nothing — once it has settled.
        rebuilds = rebuilds.filter { $0.timeIntervalSinceNow > -30 } + [Date()]
        if rebuilds.count > 3 {
            print("  the view keeps losing the glasses — restarting from scratch")
            rebuilds = []
            deactivate(reason: nil)
            glassesSeenAt = Date()
            return
        }

        print("\nThe view lost the glasses display while they were still connected — putting it back.")
        rebuildingView = true
        defer { rebuildingView = false }
        cursor?.stop(); cursor = nil
        view?.stop(); view = nil
        connectGlassesHID()
        do {
            try startView(glassesID: glassesID, canvasID: canvasID, device: renderDevice)
        } catch {
            print("  \(error)")
            deactivate(reason: nil)
            glassesSeenAt = Date()
        }
    }

    /// The renderer and the pointer keeper, which both belong to one particular glasses
    /// display. The canvas and the capture outlive them.
    private func startView(glassesID: CGDirectDisplayID, canvasID: CGDirectDisplayID,
                           device: MTLDevice) throws {
        guard let capture else { return }
        let view = try GlassesDisplay(glassesDisplayID: glassesID, capture: capture,
                                      tracker: tracker, config: settings, device: device)
        try view.start(on: glassesID)
        // The renderer notices the display vanishing before any system callback we get,
        // because it is watching its own window rather than waiting to be told.
        view.onDisplayLost = { [weak self] in
            DispatchQueue.main.async { self?.evaluate() }
        }
        self.view = view
        activeGlassesID = glassesID

        cursor = CursorManager(canvasID: canvasID, builtInID: Self.findBuiltInDisplay(),
                               glassesID: glassesID, display: view, settings: settings)
        cursor?.start()
    }

    private func beginActivation() {
        guard state == .waiting else { return }
        print("\nGlasses detected — starting up.")
        statusItem?.setNote(nil)
        state = .activating

        // Mirroring makes a perfectly good display look broken in a dozen misleading ways:
        // it reports the resolution of whatever it mirrors, stays out of the active list,
        // and ignores mode changes. So it has to go before the canvas is made.
        //
        // Only here, once the glasses are actually plugged in — never at launch. Launching
        // used to do it unconditionally, which quietly un-mirrored an office projector or
        // a presentation display just because HoloFrame happened to start while it was
        // connected and the glasses were not.
        if HFVirtualDisplay.anyDisplayIsMirroring() {
            print("! Displays are mirroring; HoloFrame needs an extended desktop.")
            guard HFVirtualDisplay.disableAllMirroring() else {
                print("  FAILED — turn mirroring off in System Settings > Displays and replug.")
                state = .waiting
                statusItem?.setNote("Turn display mirroring off to use HoloFrame.")
                return
            }
            print("  released all displays from mirroring.")
            // The reconfiguration takes a moment to settle, and building the canvas into a
            // half-applied arrangement is its own source of misplaced windows.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self, self.state == .activating, self.canvas == nil else { return }
                self.state = .waiting
                if Self.findGlassesDisplay() != nil { self.beginActivation() }
            }
            return
        }

        guard let canvas = HFVirtualDisplay(width: canvasWidth, height: canvasHeight,
                                            hiDPI: false, serialNumber: canvasSerial,
                                            name: "HoloFrame Canvas") else {
            print("  failed to create the canvas — see virtualDisplay.md")
            state = .waiting
            statusItem?.setNote("HoloFrame could not create its virtual display.")
            return
        }
        self.canvas = canvas
        activationDeadline = Date().addingTimeInterval(10)
        scheduleCanvasCheck()
    }

    /// The display we are currently drawing on, so a reconfiguration callback can tell
    /// whether it concerns us.
    private var activeGlassesID: CGDirectDisplayID?

    /// Hide the view, but NEVER from inside the reconfiguration callback.
    ///
    /// This deadlocked WindowServer and dropped the user to the login screen. A display
    /// reconfiguration callback runs while the window server is mid-reconfiguration; any
    /// window call made from it round-trips straight back to the window server, which is
    /// itself waiting for the callback to return. Neither side moves, the userspace
    /// watchdog fires, and WindowServer is killed — taking the login session with it.
    ///
    /// It survived unplugging for weeks because unplugging tends to be led by the HID
    /// removal, which runs in an ordinary context. A long-press on brightness-up toggles
    /// 2D/3D, which is a MODE change: `beginConfigurationFlag` with the display still very
    /// much present, straight into the window calls, straight into the deadlock.
    ///
    /// Dispatching async costs nothing here. The callback returns immediately, the window
    /// work happens once the reconfiguration has finished, and the fast path for unplugging
    /// is still covered by the HID removal callback and by GlassesDisplay's own watchdog.
    fileprivate func hideViewIfDisplayLost(_ display: CGDirectDisplayID) {
        guard state == .active, let activeGlassesID, display == activeGlassesID else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state == .active,
                  Self.findGlassesDisplay() == nil else { return }
            self.view?.hideNow()
        }
    }

    /// Watch the USB side as well as the display side. Unplugging kills both, but the HID
    /// removal often lands first, and reacting to whichever comes first keeps the view from
    /// ever being seen on the built-in screen.
    private func watchForHIDRemoval() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x3318] as CFDictionary)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let controller = Unmanaged<AppController>.fromOpaque(context).takeUnretainedValue()
            controller.view?.hideNow()
            DispatchQueue.main.async {
                // The IMU handle is dead whether or not the display follows it out. Dropping
                // it lets the retry in tick() pick the device up again when it returns.
                controller.dropIMU()
                controller.evaluate()
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        hidMonitor = manager
    }

    private func cancelActivation() {
        print("  glasses went away during startup.")
        canvas = nil
        state = .waiting
        statusItem?.setNote(Self.waitingNote)
    }

    /// Poll from the main queue rather than a nested run loop. AppKit only refreshes
    /// NSScreen while it is processing its own events normally, so blocking here is what
    /// left the canvas missing from the screen list — and a missing canvas skews the
    /// coordinate space enough to put the glasses window on the wrong display.
    private func scheduleCanvasCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.checkCanvasReady()
        }
    }

    private func checkCanvasReady() {
        guard state == .activating, let canvas else { return }
        let id = canvas.displayID
        let live = id != 0 && CGDisplayIsActive(id) != 0 && CGDisplayPixelsWide(id) > 1
        let knownToAppKit = NSScreen.screens.contains {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == id
        }

        if live && knownToAppKit {
            finishActivation(canvasID: id)
        } else if Date() < activationDeadline {
            scheduleCanvasCheck()
        } else if live {
            print("  !! AppKit never registered the canvas; window placement may be off")
            finishActivation(canvasID: id)
        } else {
            print("  canvas never became active")
            self.canvas = nil
            state = .waiting
            statusItem?.setNote("HoloFrame could not create its virtual display.")
        }
    }

    private func finishActivation(canvasID: CGDirectDisplayID) {
        guard let canvas else { return }
        print("  canvas \(canvasID): \(Int(canvas.currentPixelSize.width)) x \(Int(canvas.currentPixelSize.height))")

        // Render on the GPU that draws the CANVAS, not the one driving the glasses.
        //
        // On a dual-GPU Mac they differ: the virtual canvas is composited on the integrated
        // GPU while the glasses hang off the discrete one. Every captured frame lives on the
        // canvas's GPU, and sampling it from the other means moving a 66 MB IOSurface across
        // the bus up to 60 times a second — which is what pinned WindowServer at a full core
        // and heated the machine until input itself turned sluggish. Rendered here instead,
        // only the finished glasses frame crosses over, and that is a tenth of the size.
        guard let glassesID = Self.findGlassesDisplay(),
              let metalDevice = (Diagnostics.renderOnGlassesGPU
                                    ? nil : CGDirectDisplayCopyCurrentMetalDevice(canvasID))
                ?? CGDirectDisplayCopyCurrentMetalDevice(glassesID) else {
            cancelActivation()
            return
        }
        print("  rendering on \(metalDevice.name)")

        // 3. IMU. Optional — without it the view simply does not pan.
        connectGlassesHID()

        // 4. Capture and render.
        do {
            capture = try DesktopCapture(device: metalDevice)
            renderDevice = metalDevice
            try startView(glassesID: glassesID, canvasID: canvasID, device: metalDevice)
        } catch {
            print("  \(error)")
            deactivate(reason: nil)
            statusItem?.setNote("HoloFrame could not start rendering:\n\(error)")
            return
        }
        // view.start() waits for AppKit with the run loop turning, and the glasses can be
        // pulled out in that time. Building on a display that is gone helps nobody.
        guard state == .activating, self.canvas != nil else {
            deactivate(reason: nil)
            return
        }

        state = .active
        gestures?.isActive = true
        idlePaused = false
        startCapture(canvasID: canvasID)

        if needsCalibration, glasses != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.runCalibration()
            }
        }
    }

    private func deactivate(reason: String?) {
        guard state == .active || canvas != nil || view != nil else { return }
        if let reason { print("\n\(reason) — shutting the canvas down.") }

        // Traced step by step: an earlier version died somewhere in here with no crash
        // report and no log, which is impossible to diagnose after the fact.
        let trace = ProcessInfo.processInfo.environment["HOLOFRAME_VERBOSE"] != nil
        func step(_ name: String) { if trace { print("    teardown: \(name)") } }

        activeGlassesID = nil
        viewLostAt = nil
        gestures?.isActive = false
        step("cursor");   cursor?.stop(); cursor = nil
        step("view");     view?.hideNow(); view?.stop(); view = nil
        step("capture");  capture?.stop(); capture = nil
        step("canvas");   canvas = nil     // releasing the object destroys the display
        step("imu");      dropIMU()
        renderDevice = nil
        // Final sweep, independent of any reference we hold: whatever happened above, no
        // render window may remain visible after this point.
        step("sweep");    RenderWindow.closeAll()
        step("done")
        state = .waiting

        statusItem?.setNote(Self.waitingNote)
    }

    /// Start over as a fresh process, ready for the next time the glasses are plugged in.
    ///
    /// A display going away leaves state behind that no API hands back: the window server
    /// keeps the old render window's surface, transparent and parked where macOS moved it,
    /// for as long as the process lives — one more with every unplug. Everything else is
    /// rebuilt on plug-in anyway, so a new process costs nothing and guarantees that the
    /// second plug-in starts exactly like the first.
    ///
    /// Relaunched through `open`, never by exec'ing the binary: LaunchServices is what makes
    /// macOS attribute Screen Recording and Accessibility to HoloFrame itself. The shell
    /// waits for this process to be gone first, or `open` would just find it still running.
    private func relaunchForNextPlugIn() {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else {
            print("  (not running from HoloFrame.app — staying up rather than relaunching)")
            return
        }
        saveBiasIfUpdated(force: true)

        var args = ["-a", bundle.path]
        // Keep writing to the same log, if there is one, and keep any diagnostics switches.
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if fcntl(STDOUT_FILENO, F_GETPATH, &buffer) != -1 {
            let log = String(cString: buffer)
            if log != "/dev/null" { args += ["--stdout", log, "--stderr", log] }
        }
        for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("HOLOFRAME_") {
            args += ["--env", "\(key)=\(value)"]
        }

        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = ["-c",
            "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \"$@\"",
            "sh"] + args
        do {
            try relauncher.run()
        } catch {
            print("  could not relaunch (\(error)) — staying up instead")
            return
        }
        print("  restarting, so the next plug-in starts clean.")
        exit(0)
    }

    static let waitingNote = "Plug in the XREAL glasses — HoloFrame starts on its own."

    private func dropIMU() {
        glasses?.stopButtons(); glasses?.stopIMU(); glasses = nil
    }

    // MARK: - pieces

    private var lastIMUAttempt = Date.distantPast
    private var imuFailureReported = false

    /// Safe to call repeatedly: does nothing while connected, and after a failure only says
    /// so once. The IMU interfaces can enumerate after the display does, and a first
    /// attempt that finds nothing must not leave the view frozen for the whole session.
    private func connectGlassesHID() {
        guard glasses == nil else { return }
        lastIMUAttempt = Date()
        do {
            let device = try XRealDevice()
            let recorder = Diagnostics.recordPath.flatMap { IMURecorder(path: $0) }
            try device.startIMU { [weak self] sample in
                self?.tracker.integrate(sample)
                self?.sampleTap.feed(sample)
                recorder?.record(sample)
            }
            // The temple buttons. Logged before they are bound to anything, because the
            // inbound message format is inferred from the outbound one and wants proof.
            device.startButtons { [weak self] msgid, data in
                if Diagnostics.statsInterval != nil, msgid != 0x6C02 {
                    print(String(format: "  mcu 0x%04X ", msgid)
                          + data.prefix(12).map { String(format: "%02x", $0) }.joined(separator: " "))
                }
                guard msgid == 0x6C05 || msgid == 0x6C04 else { return }
                self?.recentreNow("glasses button")
            }
            glasses = device
            imuFailureReported = false
            print("  IMU streaming")
        } catch {
            guard !imuFailureReported else { return }
            imuFailureReported = true
            print("  \(error)")
            print("  no head tracking yet — the view will not pan until the IMU answers.")
        }
    }

    private func startCapture(canvasID: CGDirectDisplayID) {
        guard let capture else { return }
        guard !Diagnostics.disableCapture else {
            print("  capture disabled (HOLOFRAME_NO_CAPTURE)\n")
            return
        }
        if !CGPreflightScreenCaptureAccess() {
            print("  Screen Recording: requesting — approve the dialog macOS is showing")
            _ = CGRequestScreenCaptureAccess()
        }
        let frameRate = Diagnostics.captureFrameRate ?? settings.captureFrameRate
        Task { [weak self] in
            var announced = false
            while self?.state == .active {
                do {
                    try await capture.start(displayID: canvasID, frameRate: frameRate)
                    print("  capturing canvas\n")
                    return
                } catch {
                    if !announced {
                        print("\n\(error)\n  Waiting — capture starts the moment you grant it.")
                        announced = true
                    }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
    }

    private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow(settings: settings) { [weak self] updated in
                guard let self else { return }
                self.settings = updated
                self.view?.apply(updated)     // live, while you are wearing them
                self.cursor?.apply(updated)
                if Diagnostics.captureFrameRate == nil {
                    self.capture?.setFrameRate(updated.captureFrameRate)
                }
            }
        }
        settingsWindow?.show()
    }

    private func runCalibration() {
        guard state == .active, let view, glasses != nil else { return }
        if let map = AxisCalibration.run(display: view, tap: sampleTap) {
            tracker.setAxes(map)
            needsCalibration = false
        }
    }

    // MARK: - idle and status

    private func startHousekeeping() {
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        startStats()
    }

    /// Periodic numbers for HOLOFRAME_STATS. Rates are over the interval just ended.
    private func startStats() {
        guard let interval = Diagnostics.statsInterval else { return }
        var last = (time: CACurrentMediaTime(), frames: 0, captured: 0, render: 0.0, warps: 0, skipped: 0)
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, self.state == .active, let view = self.view,
                  let capture = self.capture else { return }
            let now = CACurrentMediaTime()
            let span = max(now - last.time, 0.001)
            let frames = view.framesDrawn, captured = capture.frameCount
            let render = view.renderSeconds, warps = self.cursor?.warpCount ?? 0
            let drawn = max(frames - last.frames, 1)
            let pose = self.tracker.diagnostics
            let anchor = self.tracker.magneticStatus
            print(String(format: "  stats render %.1f fps %.2f ms (skipped %.1f/s) · capture %.1f fps · warps %.1f/s"
                         + " · yaw %+.2f pitch %+.2f · bias %+.3f %+.3f %+.3f%@ · mag %@ %+.2f",
                         Double(frames - last.frames) / span,
                         (render - last.render) / Double(drawn) * 1000,
                         Double(view.framesSkipped - last.skipped) / span,
                         Double(captured - last.captured) / span,
                         Double(warps - last.warps) / span,
                         pose.yaw, pose.pitch, pose.bias.x, pose.bias.y, pose.bias.z,
                         pose.calibrated ? "" : " (uncal)",
                         anchor.locked ? (anchor.accepted ? "ok" : "REJ") : "off",
                         anchor.error))
            last = (now, frames, captured, render, warps, view.framesSkipped)
        }
    }

    private var lastFrames = 0
    private var lastTickTime = Date()

    private func tick() {
        let now = Date()
        let elapsed = max(now.timeIntervalSince(lastTickTime), 0.001)
        lastTickTime = now

        guard state == .active, let view, let capture else {
            statusItem?.update(text: "Waiting for glasses")
            return
        }

        if glasses == nil, now.timeIntervalSince(lastIMUAttempt) > 2 {
            connectGlassesHID()
        }

        let frames = view.framesDrawn
        let fps = Double(frames - lastFrames) / elapsed
        lastFrames = frames

        // Idle: the glasses have no wear sensor we know of, so prolonged stillness stands
        // in for "taken off". Pausing drops the cost to nothing without disturbing the
        // desktop — the canvas stays, so windows are not scattered.
        if settings.idleTimeoutSeconds > 0, glasses != nil, !Diagnostics.simulateMotion {
            let idle = tracker.idleSeconds
            if !idlePaused, idle > settings.idleTimeoutSeconds {
                idlePaused = true
                view.setPaused(true)
                capture.stop()
                print("  idle — paused (move the glasses to resume)")
            } else if idlePaused, idle < 1.0 {
                idlePaused = false
                view.setPaused(false)
                if let id = canvas?.displayID { startCapture(canvasID: id) }
                print("  resumed")
            }
        }

        reportMagneticAnchor()
        saveBiasIfUpdated()

        // Accessibility can appear at any moment, and just as easily from System Settings
        // as from our own prompt — macOS sends no notification either way. Watching for it
        // here, rather than only after someone uses the menu item, is what stops the
        // outcome depending on WHICH route they took to grant it: the previous version
        // only ever noticed a grant that followed its own prompt, so permitting HoloFrame
        // directly in System Settings looked exactly like the feature being broken. One
        // function call a second, and the whole failure mode goes away.
        if gestures?.isRunning != true, TrackpadGestures.isPermitted {
            startGestures()
        }

        let size = canvas?.currentPixelSize ?? .zero
        // Zoom is shown only when it is not 1:1 — that is precisely when you might be
        // wondering why things look the way they do, and ⌘⌥R is the answer.
        let zoom = view.currentZoom
        let zoomText = abs(zoom - 1.0) > 0.01 ? String(format: " · %.2f× zoom", zoom) : ""
        statusItem?.update(text: idlePaused
            ? "Paused · \(Int(size.width)) × \(Int(size.height))"
            : String(format: "%d × %d · %.0f fps%@",
                     Int(size.width), Int(size.height), fps, zoomText))
    }

    private var anchorWasLocked = false
    private var anchorGaveUp = false

    /// Say something once when the anchor locks, and once if it decides it cannot. Silence
    /// otherwise: this settles within the first minute and then has nothing to report.
    private func reportMagneticAnchor() {
        guard settings.magneticAnchor else { return }
        let anchor = tracker.magneticStatus

        if anchor.locked, !anchorWasLocked {
            anchorWasLocked = true
            print("  magnetic anchor locked — yaw drift is now bounded")
        } else if !anchor.locked, !anchorGaveUp, anchor.failures > 0 {
            anchorGaveUp = true
            print("""
              magnetic anchor: the field here is too incoherent to use, so yaw will drift
              slowly as before. ⌘⌥R still recentres. Moving the glasses away from speakers
              or a laptop hinge and relaunching may settle it.
            """)
        }

        if ProcessInfo.processInfo.environment["HOLOFRAME_VERBOSE"] != nil, anchor.locked {
            print(String(format: "  anchor: err %+.2f°  %@",
                         anchor.error, anchor.accepted ? "accepted" : "REJECTED (field moved)"))
        }
    }
}
