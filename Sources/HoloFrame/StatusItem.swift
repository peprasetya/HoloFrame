//
//  StatusItem.swift — the menu bar item.
//
//  HoloFrame is an LSUIElement app: no Dock icon, no window on the desktop, never takes
//  focus. Without this there is no way to quit it, recentre without remembering the
//  shortcut, or recalibrate — short of killing it from a terminal, which is not something
//  to ask of anyone.
//

import AppKit

final class StatusItem {

    private let item: NSStatusItem
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    /// Actions are supplied by main, which owns the tracker and the display.
    init(recenter: @escaping () -> Void,
         recalibrate: @escaping () -> Void,
         settings: @escaping () -> Void,
         quit: @escaping () -> Void) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "eyeglasses",
                                     accessibilityDescription: "HoloFrame")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()

        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        let recentreItem = NSMenuItem(title: "Recentre View",
                                      action: #selector(Target.recenter), keyEquivalent: "r")
        recentreItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(recentreItem)

        menu.addItem(NSMenuItem(title: "Settings…",
                                action: #selector(Target.settings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Recalibrate Head Tracking…",
                                action: #selector(Target.recalibrate), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit HoloFrame",
                                action: #selector(Target.quit), keyEquivalent: "q"))

        let target = Target(recenter: recenter, recalibrate: recalibrate,
                            settings: settings, quit: quit)
        for entry in menu.items where entry.action != nil {
            entry.target = target
        }
        self.target = target
        item.menu = menu
    }

    private var target: Target?

    /// One line of live state at the top of the menu.
    func update(text: String) {
        statusLine.title = text
    }

    /// NSMenuItem needs an ObjC target; closures cannot be selectors.
    private final class Target: NSObject {
        private let recenterAction: () -> Void
        private let recalibrateAction: () -> Void
        private let settingsAction: () -> Void
        private let quitAction: () -> Void

        init(recenter: @escaping () -> Void,
             recalibrate: @escaping () -> Void,
             settings: @escaping () -> Void,
             quit: @escaping () -> Void) {
            self.recenterAction = recenter
            self.recalibrateAction = recalibrate
            self.settingsAction = settings
            self.quitAction = quit
        }

        @objc func recenter() { recenterAction() }
        @objc func recalibrate() { recalibrateAction() }
        @objc func settings() { settingsAction() }
        @objc func quit() { quitAction() }
    }
}
