//
//  main.swift — HoloFrame
//
//  A large virtual desktop you look around by turning your head, shown on XREAL Air
//  glasses.
//
//  This file only bootstraps; AppController owns the lifecycle. Background worth reading
//  before changing either subsystem:
//    xrealAir.md       — the USB HID protocol, including two corrections to the published
//                        reverse-engineering notes
//    virtualDisplay.md — the private virtual-display SPI, the mirroring trap, and why the
//                        canvas must exist before AppKit takes its screen snapshot
//

import AppKit
import CHoloFrame
import CoreGraphics
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

print("HoloFrame")
print("=========")

let settings = ViewConfig.loadOrCreate()
let controller = AppController(canvasWidth: 7680,
                               canvasHeight: 2160,
                               canvasSerial: 0x484F_1A01,
                               settings: settings,
                               forceCalibration: CommandLine.arguments.contains("axes"))

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon, never steals focus
app.finishLaunching()

controller.start()
controller.showInitialWaitingIfNeeded()

print("""

Settings: \(ViewConfig.storeURL.path)
Recentre with ⌘⌥R. Quit from the glasses icon in the menu bar.
""")

// The canvas is destroyed with the app, but be explicit about the signal paths so an
// interrupted run does not leave a stray display behind.
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig) { _ in
        print("\nshutting down...")
        exit(0)
    }
}

app.run()
