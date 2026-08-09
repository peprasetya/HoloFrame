# HoloFrame

A large virtual desktop you look around by turning your head, shown on XREAL Air glasses,
on an Intel Mac.

The Mac gets a 7680×2160 virtual display. The glasses get a 1920×1080 window onto it,
sampled **dot-to-dot** — one canvas pixel to one glasses pixel, no scaling — that pans with
your head.

## What this was built and tested on

Everything here was developed against exactly one combination, and the parts that were hard
to get right were hard *because* they depend on undocumented behaviour of that combination.

| | |
|---|---|
| **Mac** | 2019 16" MacBook Pro — Intel i9-9880H, Radeon Pro 5500M |
| **macOS** | Darwin 25.x |
| **Glasses** | XREAL Air (formerly nreal Air), USB PID `0x0424` |
| **Toolchain** | Swift Package Manager, no Xcode project |

**Everything else is unknown, not unsupported.** Nobody has run it elsewhere; there is no
list of what breaks. Specifically:

- **Apple Silicon** — untested. Nothing here is knowingly Intel-only, but the app leans on
  a private `CGVirtualDisplay` SPI with no headers and no compatibility promise, and that
  is the sort of thing that differs quietly between architectures and OS versions. Expect
  to debug the canvas first.
- **XREAL Air 2 / Air 2 Pro / Air 2 Ultra** — their USB product IDs are in `xrealAir.md`
  and the interface layout is believed to match for the Air 2 family, but none has been
  plugged in. The Ultra is known to differ (interfaces 2/0, 512-byte reports).
- **Other brands** — Rokid, Viture and the rest speak entirely different protocols. The
  head-tracking half would need rewriting; the virtual-display and rendering halves would
  not.
- **The display-mode toggle** — long-pressing brightness-up switches the glasses to 3D
  side-by-side. HoloFrame does not use stereo and does not expect that mode.

Version numbering is the release date: `YYYYMMDD`.

## Build and run

```bash
Tools/make-app.sh
open -a HoloFrame.app
```

**Launch with `open -a`, not the binary directly.** Running
`HoloFrame.app/Contents/MacOS/HoloFrame` from a shell makes TCC attribute the Screen
Recording request to the *parent* process, so the app's own grant is ignored and capture
fails with a permission error no amount of re-granting will fix. To see logs while still
launching properly:

```bash
open -a HoloFrame.app --stdout /tmp/holoframe.log --stderr /tmp/holoframe.log
```

### Code signing

`make-app.sh` signs ad-hoc unless told otherwise, which gives the bundle a **fresh code
hash on every build** — and Screen Recording permission is bound to that hash, so every
rebuild silently revokes it. Create a self-signed certificate once:

> Keychain Access → Certificate Assistant → Create a Certificate…
> Name `HoloFrame Dev`, Identity Type **Self Signed Root**, Certificate Type **Code Signing**

```bash
export HOLOFRAME_SIGN_IDENTITY="HoloFrame Dev"
```

Then the grant survives rebuilds. If it ever gets stuck:
`tccutil reset ScreenCapture id.prasetya.holoframe`.

## Using it

| | |
|---|---|
| **⌘⌥R** | Recentre: makes where you are looking the middle of the canvas |
| **Menu bar** | Glasses icon — recentre, recalibrate, settings, quit, and live status |

### Plugging in and out

HoloFrame follows the glasses. Everything it creates is tied to them being present:

- **No glasses at launch** — it waits, showing a panel on your main screen. No canvas is
  created. Leaving a 7680×2160 display on the desktop with no way to see it would scatter
  your windows across a screen you cannot look at.
- **Unplugged while running** — the canvas is destroyed, capture and rendering stop, and
  the desktop returns to normal. A panel offers to quit.
- **Plugged back in** — it rebuilds automatically. Calibration is remembered.

### Comfort and motion

- **Damping.** Head tremor at ~48 px/degree is several pixels of visible shake. A One Euro
  filter smooths heavily while you are still and backs off as you move, so jitter goes
  without adding lag to real movement — lag is the worse problem, since a view trailing
  your head feels detached.
- **Pixel snapping.** The sample centre snaps to whole pixels only while nearly still, for
  crisp text. Snapping *during* motion is what makes panning look like it is stepping, so
  above the threshold it samples at sub-pixel precision.
- **Prediction.** The pose is extrapolated ~16 ms forward to cancel the latency between
  reading the sensor and photons arriving, capped at 8° so a fast flick cannot overshoot.
- **Position map.** A small map of where you are on the canvas appears while moving and on
  recentre, then fades.
- **Idle.** After 90 s motionless, drawing and capture pause; any movement resumes them.
  The canvas stays up so your windows are not disturbed.

### Settings

`~/Library/Application Support/HoloFrame/view.json`, written with defaults on first run.
Edit and relaunch. Every key has a default, so a partial file is fine.

| key | default | |
|---|---|---|
| `panGain` | 1.0 | 1.0 is physically exact; raise it to reach the canvas edges with less neck movement |
| `horizontalFOV` | 40 | The Air's spec; sets the dot-to-dot pan rate |
| `smoothingMinCutoff` | 1.0 | Lower is steadier at rest, slower to start moving |
| `smoothingBeta` | 0.007 | Higher gives less lag when turning |
| `predictionSeconds` | 0.016 | 0 disables prediction |
| `edgeFeather` | 0 | Pixels of fade at the canvas boundary. Off deliberately — softening that edge means blending across it, which dims the outermost pixels of real content |
| `idleTimeoutSeconds` | 90 | 0 keeps it running regardless |
| `invertYaw` / `invertPitch` / `invertRoll` | false | Direction flips, verified against the hardware |

### The magnetic anchor

It is not a compass and never asks where north is. Ten seconds after startup it records
where the field points **in the world frame** and treats that as the anchor; afterwards,
any rotation of the measured field away from it, in the horizontal plane, is yaw the gyro
invented. A field bent 40° off true north by the laptop's own magnets works exactly as
well, because the only thing required of it is to be the same field a minute later.

That matters, because magnetic distortion beside a laptop is **static and spatial** rather
than fluctuating — a steady wrong reading that changes with where your head is, since the
field falls off as 1/r³ and your head swings through the gradient. The obvious filter
(trust steady readings, reject sudden ones) would therefore trust precisely the error and
reject transients that correct themselves. Three things defend against it instead:

- **Field strength** and **inclination** are both checked against what was measured when
  the anchor was set, never against textbook values for Earth's field. A permanently
  distorted but uniform field is fine; a field that *changed* is rejected. Inclination —
  the angle between the field and gravity — is the stronger test, since it cross-checks
  against an independent sensor and yaw cannot influence it.
- **Correction is slow enough to average out** what remains: 0.05 deg/s while you are
  still (under three pixels a second), rising to 2 deg/s while your head is moving, where
  it is hidden by the motion. Ordinary use erases accumulated error invisibly.
- If the field proves **incoherent** during the learning pass, no anchor is set and the
  tracker behaves exactly as it did without one. Set `magneticAnchor` to false to force
  that.

First launch runs **head-tracking calibration on the glasses themselves** — put them on,
shake your head to begin, then follow three prompts (turn left, look down, tilt left). The
result is stored in `~/Library/Application Support/HoloFrame/axes.json` and reused
thereafter. Redo it any time from the menu bar.

Recentring is deliberately manual. It redefines which physical direction maps to the middle
of the canvas, so doing it automatically would fight you the moment you wanted to hold your
gaze off-centre — on the top-left corner, say, to read code there. It zeroes yaw *and*
pitch (the glasses sit at an angle on your nose, so "comfortably straight ahead" is not
level), but never roll — the desktop should stay level with the real horizon.

### Setting the resolution

HoloFrame does not force a resolution. It publishes a ladder of same-aspect, **non-HiDPI**
modes, and macOS lets you pick one in System Settings → Displays; the app adapts. HiDPI is
never offered — it would quadruple capture bandwidth (66 MB/frame becomes 265 MB) and buy
nothing, because the glasses sample the canvas dot-to-dot anyway. The canvas uses a fixed
serial number, so macOS remembers its resolution and arrangement between runs.

The canvas can sit on any side of your main screen; the pointer logic derives its geometry
from the arrangement.

### The pointer

Held inside the visible viewport with a 16 px inset, and dragged along as the viewport
moves, so it is always where you are looking. Push it through the viewport edge that
*faces* your built-in screen and it hands over; coming back is automatic.

## Measured cost

2019 16" MacBook Pro (i9-9880H, Radeon Pro 5500M), 7680×2160 canvas, desktop static:

| | |
|---|---|
| HoloFrame | **7.7%** of one core, 27 MB |
| WindowServer | **55%** of one core |
| Drawn | ~58 fps |
| Captured | **0 fps** |

100% = one core on an 8-core/16-thread part, so together roughly 4% of the machine.

That `0 fps captured` is the whole design. ScreenCaptureKit only delivers a frame when the
desktop content actually changes, and turning your head does not change it — panning costs
one textured draw against a texture already resident in VRAM. The capture path is
zero-copy throughout: IOSurface-backed `CVPixelBuffer` → `CVMetalTextureCache` →
`MTLTexture`, pixels never touching the CPU. WindowServer's share is the inherent price of
compositing a 7680×2160 desktop, not something HoloFrame adds.

## Layout

| | |
|---|---|
| `Sources/CHoloFrame/` | The canvas. Private `CGVirtualDisplay` SPI, in ObjC because it has no headers. |
| `Sources/HoloFrame/XRealDevice.swift` | USB HID: IMU stream and MCU display-mode control. |
| `Sources/HoloFrame/HeadTracker.swift` | Complementary filter, gyro-bias estimation, recentre. |
| `Sources/HoloFrame/AxisMap.swift` | Sensor→head axis mapping, and why it must be right-handed. |
| `Sources/HoloFrame/AxisCalibration.swift` | First-run calibration, shown on the glasses. |
| `Sources/HoloFrame/DesktopCapture.swift` | ScreenCaptureKit → `MTLTexture`, zero-copy. |
| `Sources/HoloFrame/GlassesDisplay.swift` | Metal renderer, the window on the glasses, on-glasses text. |
| `Sources/HoloFrame/CursorManager.swift` | Keeps the pointer visible; hands it between displays. |
| `Tools/` | `make-app.sh`, `make-icon.sh`, and the probes used to reverse-engineer both subsystems. |
| `Design/` | Icon sources. |

Environment variable: `HOLOFRAME_VERBOSE=1` adds per-5s frame/pose logging and window
placement detail. Normal runs are quiet.

## Tried and rejected

Two features were built, measured against real use, and removed. Both are recorded because
the reasons are not obvious and the ideas are tempting.

**Lean to zoom** — lean in to magnify, sit back for the overview. Three designs failed. An
accelerometer cannot tell you that you *are* leaning: once you have leaned in and settled
it reads pure gravity again, identical to sitting upright, so absolute position is absent
from the signal rather than merely noisy. Integrating twice needs a zero-velocity update to
fire often, which needs genuine stillness, which a neck almost never provides — the
estimate drifted onto its clamp within seconds. Treating each lean as a discrete step was
drift-free but still wrong, because a lean is *biphasic*: you accelerate, then you brake,
both phases cross the threshold, and one lean scores +1 then −1. And the gate that
suppressed rotation artefacts (turning your head swings the glasses on a ~12 cm arc, whose
centripetal term always points backward) was consuming the very signal it protected.

**Tap the frame** — tap to recentre. Detecting a tap is easy; *counting* taps is not, since
one tap is not one spike and its ringing has to be told from the next deliberate tap. It
was made to work reliably enough to log correct traces and still did not feel dependable in
use.

The common thread: both inferred intent from a sensor that is also watching everything else
you do, which means thresholds, which means false triggers and misses. The physical buttons
on the temple report themselves over the MCU interface (`P_BUTTON_PRESSED`, `0x6C05`) and
need no threshold at all. That is the direction worth pursuing.

## Background

Two documents carry what was learned the hard way. Read them before changing either
subsystem.

- **`xrealAir.md`** — the USB HID protocol. Includes two corrections to the published
  reverse-engineering notes: the IMU length field must count itself (the documented value
  is rejected outright), and the full IMU field map including the magnetometer's `0x8000`
  XOR mask.
- **`virtualDisplay.md`** — the private virtual-display SPI. The descriptor's colour
  "primaries" are XYZ tristimulus values, not xy chromaticities, and mirroring will make a
  perfectly good virtual display look broken in a dozen misleading ways.

Traps worth knowing before touching this code, all of which cost real time here:

1. **`CGDisplayPixelsWide()` returns junk for an inactive display.** Check membership in
   `CGGetActiveDisplayList` first. `CGDisplayIsOnline == 1` with `CGDisplayIsActive == 0`
   means *mirroring*, not "working".
2. **Create the virtual display before AppKit initialises.** `NSScreen` is a cached
   snapshot; a display this process creates afterwards may never appear in it, leaving
   AppKit's coordinate space disagreeing with the window server's — so windows land on the
   wrong physical display while still reporting the frame you asked for.
3. **`CGShieldingWindowLevel()` only composites on a display you have captured.** On an
   ordinary display the window is positioned correctly and never drawn, which looks exactly
   like being on the wrong screen.
4. **Set `isReleasedWhenClosed = false` on any NSWindow held in a Swift property.** It
   defaults to `true`, so `close()` releases the window on top of ARC's own release. The
   double release leaves a zombie — **gone from `NSApp.windows` while its window-server
   surface stays on screen**, so nothing walking that list can reach it — and AppKit later
   dereferences the freed memory during a CoreAnimation commit, killing the process with
   `EXC_BAD_ACCESS` and no console output. This produced days of misleading symptoms that
   all looked like "unplug detection is broken" when detection had been working the whole
   time. `CGWindowListCopyWindowInfo` is what settles such questions: it shows the truth
   the window server holds, independent of AppKit's bookkeeping.
5. **Reuse one render window rather than creating one per session.** A closed window with
   `isReleasedWhenClosed = false` is still retained by AppKit's window list, so recreating
   leaks one per plug/unplug cycle — invisible if you zero its alpha, but unbounded.
6. **Synthesized `Codable` has no such thing as an optional key.** A property default is
   used when you *construct* the struct and never when you *decode* it, so every key is
   required. Adding one property to `ViewConfig` makes every previously written file throw
   on load — and the natural handler, "fall back to defaults and save them", then
   overwrites the user's settings with the very file that failed to read. Silent, and it
   looks like the app forgot rather than like a decoder error. `loadOrCreate` overlays the
   stored JSON onto encoded defaults instead, and never writes back a file it could not
   parse.

## Known gaps

- Yaw is anchored to the local magnetic field, which is what bounds the drift. Gyro-bias
  estimation and the deadband only ever made the walk slower — nothing without an outside
  reference can stop it. The one visible cost of the deadband is that rotation slower than
  ~1 deg/s is damped, so a *very* slow deliberate pan lags slightly; above 3 deg/s it is
  untouched.
- No stereo. The glasses stay in 2D mode. Stereo/SBS and VR video are a separate project;
  the sketch is a per-surface stereo layout rather than a single desktop plane.
- `panGain` (1.0, physically exact) and `horizontalFOV` (40°, the Air's spec) in
  `ViewConfig` are the two comfort knobs, not yet exposed in the UI.
