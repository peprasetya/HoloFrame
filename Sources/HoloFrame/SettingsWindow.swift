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
        let detail: String
        let range: ClosedRange<Double>
        let value: (ViewConfig) -> Double
        let apply: (inout ViewConfig, Double) -> Void
        let format: String
    }

    private var definitions: [Row] {
        [
            Row(label: "Pan amount", detail: "1.0 matches real head movement; higher reaches the edges sooner",
                range: 0.5...2.5, value: { $0.panGain },
                apply: { $0.panGain = $1 }, format: "%.2f×"),
            Row(label: "Field of view", detail: "The glasses' horizontal FOV; sets the dot-to-dot pan rate",
                range: 30...55, value: { $0.horizontalFOV },
                apply: { $0.horizontalFOV = $1 }, format: "%.0f°"),
            Row(label: "Steadiness", detail: "Lower is steadier when still, but slower to start moving",
                range: 0.2...6.0, value: { $0.smoothingMinCutoff },
                apply: { $0.smoothingMinCutoff = $1 }, format: "%.2f Hz"),
            Row(label: "Responsiveness", detail: "Higher gives less lag when you turn your head",
                range: 0.0...0.05, value: { $0.smoothingBeta },
                apply: { $0.smoothingBeta = $1 }, format: "%.3f"),
            Row(label: "Prediction", detail: "Extrapolates ahead to cancel display latency; 0 turns it off",
                range: 0.0...0.04, value: { $0.predictionSeconds },
                apply: { $0.predictionSeconds = $1 }, format: "%.0f ms"),
            Row(label: "Map opacity", detail: "The position map's highlighted region",
                range: 0.0...1.0, value: { $0.indicatorViewportOpacity },
                apply: { $0.indicatorViewportOpacity = $1 }, format: "%.2f"),
            Row(label: "Pointer ring", detail: "How long the ring around the pointer lingers; 0 turns it off",
                range: 0.0...3.0, value: { $0.cursorHintSeconds },
                apply: { $0.cursorHintSeconds = $1 }, format: "%.1f s"),
            Row(label: "Idle timeout", detail: "Pause drawing after this long motionless; 0 never pauses",
                range: 0...300, value: { $0.idleTimeoutSeconds },
                apply: { $0.idleTimeoutSeconds = $1 }, format: "%.0f s"),
        ]
    }

    private func build() {
        let width: CGFloat = 520
        let rowHeight: CGFloat = 62
        let height = CGFloat(definitions.count) * rowHeight + 130

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "HoloFrame Settings"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        var y = height - 46

        let heading = NSTextField(labelWithString: "Changes apply immediately — wear the glasses while adjusting.")
        heading.font = .systemFont(ofSize: 11)
        heading.textColor = .secondaryLabelColor
        heading.frame = NSRect(x: 20, y: y, width: width - 40, height: 18)
        content.addSubview(heading)
        y -= 24

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
