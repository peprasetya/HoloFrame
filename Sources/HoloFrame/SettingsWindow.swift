//
//  SettingsWindow.swift — the control panel.
//
//  Every value here is a comfort setting that differs per person and is only judgeable by
//  wearing the glasses, so they apply LIVE as you drag. Making someone edit JSON, relaunch,
//  put the glasses back on and then discover the number was wrong is not a way to tune
//  anything.
//
//  Shown on the built-in display, never on the glasses — you need to see the control and
//  the effect at the same time.
//
//  Each row carries a one-line summary and a longer tooltip. The summary says what the
//  control does; the tooltip says what it costs, how to tell it is set wrong, and which
//  other control to reach for instead — which is the part nobody can guess from a slider,
//  and the part that decides whether tuning converges or wanders.
//

import AppKit

final class SettingsWindow: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var settings: ViewConfig
    private let onChange: (ViewConfig) -> Void
    private var rows: [(NSSlider, NSTextField, (inout ViewConfig, Double) -> Void)] = []

    init(settings: ViewConfig, onChange: @escaping (ViewConfig) -> Void) {
        self.settings = settings
        self.onChange = onChange
        super.init()
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        build()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - construction

    private struct Row {
        let label: String
        /// One line, always visible.
        let detail: String
        /// The long form, on hover: trade-offs, symptoms of a wrong value, what to try first.
        let help: String
        let range: ClosedRange<Double>
        let value: (ViewConfig) -> Double
        let apply: (inout ViewConfig, Double) -> Void
        let format: String
    }

    private var definitions: [Row] {
        [
            Row(label: "Pan amount", detail: "1.0 matches real head movement; higher reaches the edges sooner",
                help: """
                How far the view travels for a given head turn.

                1.0 is physically correct: the canvas stands still in the world and you \
                look around it. Turn 10° and the view moves 10° of canvas — the only \
                setting where the desktop feels like a real object hanging in front of you.

                Above 1.0 you reach the canvas edges with less neck movement, but the \
                canvas slides with you instead of staying put, and some people find that \
                unsettling. At 1.0 a 7680-wide canvas needs about ±60° of yaw to reach \
                both ends; at 2.0, about ±30°.

                This is comfort. Field of view is calibration. Set Field of view first.
                """,
                range: 0.5...2.5, value: { $0.panGain },
                apply: { $0.panGain = $1 }, format: "%.2f×"),

            Row(label: "Field of view", detail: "The glasses' horizontal FOV; sets the dot-to-dot pan rate",
                help: """
                What your glasses' horizontal field of view actually is. Not a preference \
                — a measurement, and the only one that decides how many canvas pixels a \
                degree of head rotation is worth.

                Set it with Pan amount at 1.00, then turn your head side to side and watch \
                a window:
                  • content drifts along WITH your head → too high, lower it
                  • content overshoots and swings past → too low, raise it
                  • content sits still in space → correct

                XREAL Air is about 46° diagonal, which works out near 40° horizontal. \
                Get this wrong and no amount of Pan amount will make the canvas feel fixed.
                """,
                range: 30...55, value: { $0.horizontalFOV },
                apply: { $0.horizontalFOV = $1 }, format: "%.0f°"),

            Row(label: "Steadiness", detail: "Lower is steadier when still, but slower to start moving",
                help: """
                How hard the view is filtered while your head is still.

                Lower is calmer: small tremors and sensor noise stop reaching the screen, \
                so text holds still enough to read. The cost is that the view is also \
                slower to notice you have started turning.

                Lower it if text shimmers or the view creeps while you read.

                If the view feels sluggish to start moving, raise Responsiveness first \
                rather than this — Responsiveness buys speed without giving up stillness, \
                and this one cannot.
                """,
                range: 0.2...6.0, value: { $0.smoothingMinCutoff },
                apply: { $0.smoothingMinCutoff = $1 }, format: "%.2f Hz"),

            Row(label: "Responsiveness", detail: "Higher gives less lag when you turn your head",
                help: """
                How quickly the filter gets out of the way once you are actually moving.

                The filter watches head speed: the faster you turn, the less it smooths. \
                This sets how strongly it reacts. Higher means a turn feels immediate, \
                while stillness stays exactly as steady as Steadiness makes it — which is \
                why this is the first thing to try when the view feels laggy.

                Too high and fast turns carry noise through with them, so quick movements \
                look swimmy rather than sharp.
                """,
                range: 0.0...0.05, value: { $0.smoothingBeta },
                apply: { $0.smoothingBeta = $1 }, format: "%.3f"),

            Row(label: "Prediction", detail: "Extrapolates ahead to cancel display latency; 0 turns it off",
                help: """
                Guesses where your head will be by the time the light reaches your eye.

                Reading the sensor, drawing the frame and lighting the panel all take time \
                — roughly one frame's worth — so a pose that was true when it was measured \
                is stale when you see it. This extrapolates forward to cancel that.

                Too low: the canvas trails behind your head on a fast turn.
                Too high: it overshoots and settles back, which reads worse than lag.

                Extrapolation is capped at 8° internally, so a violent flick cannot throw \
                the view across the canvas. 0 disables it.
                """,
                range: 0.0...0.04, value: { $0.predictionSeconds },
                apply: { $0.predictionSeconds = $1 }, format: "%.0f ms"),

            Row(label: "Map opacity", detail: "The position map's highlighted region",
                help: """
                Brightness of the lit rectangle on the little position map.

                After the view moves, a small map of the whole canvas appears showing \
                which part of it you are looking at, then fades. This sets how strongly \
                the current viewport is marked on it.

                Kept dim on purpose: the map sits over content you may be reading, and it \
                only has to be findable, not prominent. At 0 the map still draws, just \
                without a highlighted region.

                How long it lingers, and whether it appears at all, are in view.json.
                """,
                range: 0.0...1.0, value: { $0.indicatorViewportOpacity },
                apply: { $0.indicatorViewportOpacity = $1 }, format: "%.2f"),

            Row(label: "Pointer ring", detail: "How long the ring around the pointer lingers; 0 turns it off",
                help: """
                A ring flashes around the pointer when it moves, then fades over this long.

                The pointer is always held inside what you are looking at, but on a canvas \
                this size being on screen is not the same as being findable — the ring is \
                what makes it catch your eye.

                Never drawn while a mouse button is held: mid-drag you already know where \
                the pointer is, and a ring following it just covers what you are dragging.

                0 turns it off.
                """,
                range: 0.0...3.0, value: { $0.cursorHintSeconds },
                apply: { $0.cursorHintSeconds = $1 }, format: "%.1f s"),

            Row(label: "Pointer escape", detail: "How hard to push the pointer past the edge to send it to the built-in screen",
                help: """
                How fast the pointer must be moving to leave the glasses for your \
                built-in screen.

                It has to be pressed against the viewport edge that faces that screen AND \
                moving toward it at least this fast. A speed test, not a position test — \
                and deliberately so: turning your head moves the viewport but not the \
                pointer, so head movement registers no speed at all and can never hand the \
                pointer away. That is what stops the pointer disappearing to the laptop \
                every time you glance somewhere else.

                Lower it if getting the pointer out is a fight. Raise it if the pointer \
                leaves when you did not mean it to.

                Trackpad and mouse speed settings change what a given flick is worth here, \
                so this may need retuning if you change pointing device.
                """,
                range: 300...2500, value: { $0.cursorEscapeSpeed },
                apply: { $0.cursorEscapeSpeed = $1 }, format: "%.0f px/s"),

            Row(label: "Pinch zoom", detail: "How much a right-⌥ pinch changes the zoom; ⌘⌥R puts it back to 1:1",
                help: """
                How far a trackpad pinch moves the zoom while right-Option is held.

                Pinch is only HoloFrame's while that key is down — release it and pinch \
                goes back to whatever app you are in, untouched. That is the whole reason \
                for the modifier: the canvas is a real desktop, so pinch is already \
                spoken for by the apps sitting on it.

                Zoom stays where you put it, and it zooms about the middle of your view, \
                so whatever you were looking at stays where it is. Recentre (⌘⌥R, or the \
                glasses button) resets it to exactly 1:1 along with your heading — worth \
                using, because 1:1 is the only setting where text is drawn at the \
                resolution it was rendered at.

                Turn it DOWN if the zoom runs away from you. Magnification compounds, so \
                the scale grows exponentially with finger travel: too high a value does \
                nothing at first and then overshoots, which feels sluggish and jumpy at \
                once.

                For a lasting size change, prefer a smaller canvas resolution in System \
                Settings: that re-lays-out the desktop and redraws text sharp, where \
                magnifying can only stretch pixels that were already drawn.

                Needs Accessibility permission — the menu bar offers it if it is missing.
                """,
                range: 0.15...1.5, value: { $0.pinchZoomGain },
                apply: { $0.pinchZoomGain = $1 }, format: "%.2f×"),

            Row(label: "Scroll pan", detail: "How far a right-⌥ two-finger scroll moves the canvas; ⌘⌥R undoes it",
                help: """
                How far the canvas moves when you hold right-Option and scroll with two \
                fingers.

                This is the fine adjustment that recentring is not. Recentre moves the whole \
                canvas to wherever you happen to be looking; a scroll nudges it exactly as \
                far as you drag, like moving a map, and head tracking carries on normally \
                from wherever you leave it. The canvas follows your fingers in the same \
                direction documents do, so the system's scroll-direction setting applies.

                1.0 moves the canvas exactly with your fingers. The canvas is four views \
                wide, so something above that saves a lot of swiping. Turn it DOWN if \
                placing things precisely is fiddly, UP if crossing the canvas takes too many \
                swipes. The glide after your fingers lift is ignored on purpose, so the \
                canvas stops the moment you do.

                Recentre (⌘⌥R, or the glasses button) drops the pan along with zoom and \
                heading. Needs the same Accessibility permission as pinch zoom.
                """,
                range: 0.5...6, value: { $0.scrollPanGain },
                apply: { $0.scrollPanGain = $1 }, format: "%.1f×"),

            Row(label: "Capture rate", detail: "Most times a second the desktop is re-captured; head movement stays smooth regardless",
                help: """
                The most times per second HoloFrame picks up changes on the desktop.

                This is NOT how smoothly the view follows your head — that is always \
                redrawn at the glasses' full rate from the latest capture. It is how smoothly \
                things moving on the desktop itself reach you: scrolling, video, a cursor \
                blinking, text appearing as you type. Nothing is captured while the desktop \
                is not changing, whatever this is set to.

                Lowering it saves a little heat, not a lot. Measured on a 2019 16" MacBook \
                Pro with a busy desktop: 30 fps took about 5 points off the window server's \
                CPU and 7 off the integrated GPU, compared with 60. Most of the window \
                server's work is drawing a 7680×2160 desktop at all, which this cannot touch.

                Leave it at 60 for video. Try 30 if the fans bother you while you mostly read \
                and type.
                """,
                range: 15...60, value: { $0.captureFrameRate },
                apply: { $0.captureFrameRate = ($1 / 5).rounded() * 5 }, format: "%.0f fps"),

            Row(label: "Idle timeout", detail: "Pause drawing after this long motionless; 0 never pauses",
                help: """
                Stop drawing and capturing once the glasses have not moved for this long.

                Meant for taking the glasses off without quitting: a head that is on a \
                head is never truly motionless, so this should not fire while you are \
                wearing them. It resumes the instant the glasses move, and the menu bar \
                shows when it is paused.

                Raise it if it ever pauses on you. 0 keeps everything running regardless.
                """,
                range: 0...300, value: { $0.idleTimeoutSeconds },
                apply: { $0.idleTimeoutSeconds = $1 }, format: "%.0f s"),
        ]
    }

    private func build() {
        let width: CGFloat = 520
        let rowHeight: CGFloat = 62
        let height = CGFloat(definitions.count) * rowHeight + 146

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "HoloFrame Settings"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        var y = height - 46

        let heading = NSTextField(labelWithString: "Changes apply immediately — wear the glasses while adjusting.\nHover a control for what it costs and how to tell it is set wrong.")
        heading.maximumNumberOfLines = 2
        heading.font = .systemFont(ofSize: 11)
        heading.textColor = .secondaryLabelColor
        heading.frame = NSRect(x: 20, y: y - 16, width: width - 40, height: 34)
        content.addSubview(heading)
        y -= 40

        for (index, row) in definitions.enumerated() {
            y -= rowHeight

            let label = NSTextField(labelWithString: row.label)
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.frame = NSRect(x: 20, y: y + 38, width: 220, height: 18)
            content.addSubview(label)

            let readout = NSTextField(labelWithString: "")
            readout.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            readout.textColor = .secondaryLabelColor
            readout.alignment = .right
            readout.frame = NSRect(x: width - 120, y: y + 38, width: 100, height: 18)
            content.addSubview(readout)

            let detail = NSTextField(labelWithString: row.detail)
            detail.font = .systemFont(ofSize: 10)
            detail.textColor = .tertiaryLabelColor
            detail.frame = NSRect(x: 20, y: y + 22, width: width - 40, height: 14)
            content.addSubview(detail)

            let slider = NSSlider(value: row.value(settings),
                                  minValue: row.range.lowerBound,
                                  maxValue: row.range.upperBound,
                                  target: self, action: #selector(sliderMoved(_:)))
            slider.tag = index
            slider.isContinuous = true
            slider.frame = NSRect(x: 20, y: y, width: width - 40, height: 20)
            content.addSubview(slider)

            // On every part of the row, not just the label: a tooltip you have to hunt for
            // is a tooltip nobody finds. The slider especially — that is where the hand
            // already is when the question "what does this cost me?" comes up.
            for view in [label, readout, detail, slider] as [NSView] {
                view.toolTip = row.help
            }

            rows.append((slider, readout, row.apply))
            updateReadout(index: index, value: row.value(settings))
        }

        let reset = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetAll))
        reset.bezelStyle = .rounded
        reset.frame = NSRect(x: 20, y: 20, width: 160, height: 30)
        content.addSubview(reset)

        let note = NSTextField(labelWithString: "Saved automatically")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        note.alignment = .right
        note.frame = NSRect(x: width - 220, y: 26, width: 200, height: 16)
        content.addSubview(note)

        window.contentView = content
        self.window = window
    }

    // MARK: - live updates

    @objc private func sliderMoved(_ sender: NSSlider) {
        let index = sender.tag
        guard index < rows.count else { return }
        rows[index].2(&settings, sender.doubleValue)
        updateReadout(index: index, value: sender.doubleValue)
        onChange(settings)
        try? settings.save()
    }

    @objc private func resetAll() {
        settings = ViewConfig()
        for (index, row) in definitions.enumerated() {
            rows[index].0.doubleValue = row.value(settings)
            updateReadout(index: index, value: row.value(settings))
        }
        onChange(settings)
        try? settings.save()
    }

    private func updateReadout(index: Int, value: Double) {
        let row = definitions[index]
        // Milliseconds read better than fractions of a second for prediction.
        let shown = row.format.contains("ms") ? value * 1000 : value
        rows[index].1.stringValue = String(format: row.format, shown)
    }
}
