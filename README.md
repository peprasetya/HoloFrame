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

`make-app.sh` signs ad-hoc unless it finds a certificate, which gives the bundle a **fresh
code hash on every build** — and TCC permissions are bound to that hash, so every rebuild
silently revokes *both* Screen Recording (capture stops) and Accessibility (trackpad zoom
and pan stop). Create a self-signed certificate once:

> Keychain Access → Certificate Assistant → Create a Certificate…
> Name `HoloFrame Dev`, Identity Type **Self Signed Root**, Certificate Type **Code Signing**

Nothing to export — the script finds it by name. Both grants then survive every rebuild.

Two things about that certificate are counter-intuitive enough to be worth stating, because
between them they cost a working setup several days of ad-hoc rebuilds:

* **It will never appear in `security find-identity -v`.** A self-signed root is not
  "valid" to the trust policy, so the `-v` listing reports *zero identities* and hides it
  completely. The script searches without `-v` and signs by SHA-1 rather than by name.
* **Trust is not required and does not need granting.** `codesign` only needs the private
  key, and the signature it produces passes `--verify --deep --strict`. What matters is the
  designated requirement, which becomes `identifier "id.prasetya.holoframe" and certificate
  leaf = H"…"` — with no cdhash in it. That is what TCC records, and it no longer changes
  when the binary does.

If a grant ever gets stuck: `tccutil reset ScreenCapture id.prasetya.holoframe`, or
`tccutil reset Accessibility id.prasetya.holoframe`.

## Using it

| | |
|---|---|
| **⌘⌥R** | Recentre: makes where you are looking the middle of the canvas, and drops zoom and pan |
| **Hold right-⌥** | Carry the canvas: the view stays put while you turn your head, so the canvas comes with you |
| **Right-⌥ + two-finger scroll** | Nudge the canvas without moving your head, like dragging a map |
| **Right-⌥ + pinch** | Zoom the canvas. Release the key and pinch and scroll belong to your apps again |
| **Menu bar** | Glasses icon — recentre, recalibrate, settings, quit, and live status |

### Plugging in and out

HoloFrame follows the glasses. Everything it creates is tied to them being present:

- **No glasses at launch** — it waits, showing a panel on your main screen. No canvas is
  created. Leaving a 7680×2160 display on the desktop with no way to see it would scatter
  your windows across a screen you cannot look at.
- **Unplugged while running** — the canvas is destroyed, capture and rendering stop, and
  the desktop returns to normal. A panel offers to quit.
- **Plugged back in** — it rebuilds automatically. Calibration is remembered.
- **Mirroring** — the canvas needs an extended desktop, so display mirroring is switched off
  when the glasses connect. Only then: launching HoloFrame with no glasses attached leaves a
  mirrored projector or office display alone.

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
| `pinchZoomGain` | 0.5 | How much a right-⌥ pinch moves the zoom |
| `scrollPanGain` | 2.0 | View pixels a right-⌥ scroll moves the canvas, per point of scroll |
| `zoomMax` | 4.0 | Ceiling on magnification |
| `cursorEscapeSpeed` | 900 | View px/s toward the built-in screen before the pointer is handed over |
| `idleTimeoutSeconds` | 90 | 0 keeps it running regardless |
| `invertYaw` / `invertPitch` / `invertRoll` | false | Direction flips, verified against the hardware |

### Zoom and pan

Hold **right-Option** and pinch on the trackpad. Zoom is sustained — it stays where you put
it — and **⌘⌥R** resets it to 1:1 along with your heading, which is the way out if you lose
track of how big things got.

**Hold right-Option to carry the canvas.** While the key is down the view stays exactly as
it is, so turning your head brings the canvas with you; let go and head tracking resumes
from wherever you left it. It is a clutch, the way you lift a mouse to reposition it, and it
covers what recentring is too coarse for — recentring moves everything to wherever you
happen to be looking, when all you meant was "that window, a little more to the left". It
cannot carry the view past the canvas edge, and ⌘⌥R drops it along with zoom. Pinching while
the key is held zooms as usual.

**Or scroll with two fingers** while holding it, for when you would rather not move your
head: the canvas moves exactly as far as you drag, in the direction documents scroll. The
glide after your fingers lift is ignored, so it stops when you do, and scrolling while
carrying the canvas moves what you are carrying. Five-finger gestures were considered first
and rejected — macOS reserves four- and five-finger swipes and pinches for Mission Control,
Launchpad and Show Desktop.

The modifier is the whole design. The canvas is a real desktop, so pinch is already spoken
for by whatever app is sitting on it; taking it globally would mean you could no longer
pinch in Preview exactly when Preview is what you are looking at. While right-Option is
down the pinch is HoloFrame's and is swallowed before any app sees it. Release it and pinch
goes back to the focused app, untouched. Right-Option specifically because nothing else
claims it — held alone it is inert on macOS, and it is distinguishable from left-Option,
which apps *do* use, through the device-dependent flag bits.

Head panning stays world-fixed while zoomed: the field of view spans the *visible* canvas
width, so magnifying makes the canvas behave like a larger object at the same distance,
scanned at the same angular rate. Small head movements become fine adjustments, which is
what you want when you have magnified something to read it. The trade is that crossing the
whole canvas at 4× takes more neck than you have — zoom out, move, zoom back in, the same
as any map. Once an axis fits entirely in view, panning on it is pinned, so fully zoomed
out is a steady overview rather than a picture that wanders in surrounding black.

Zooming out averages across the footprint each view pixel covers, up to 4×4. Without it,
which canvas pixel gets sampled changes with a fraction of a pixel of pan, so text turns
into noise that crawls as you move. That is the job a mip chain would normally do, but
capture textures come straight from the IOSurface and cannot carry mips without a
full-canvas copy every frame — so it is done in the shader, where it costs nothing at or
above 1:1.

For a *lasting* size change, prefer a smaller canvas resolution in System Settings. That
re-lays-out the desktop and redraws text at native sharpness; magnifying can only stretch
pixels that were already drawn.

This is the one feature that needs **Accessibility** permission. Swallowing an event rather
than merely watching it requires an active event tap, and there is no way to have the first
without the second. Everything else works without it — the tap just never starts, and the
menu bar offers the prompt.

### The magnetic anchor

**Currently dormant.** The magnetometer in these glasses carries an offset of its own — the
field of the magnets inside them, turning with your head — and fitting a sphere to real
readings taken through many orientations put it at about **0.25 G against a true field of
about 0.16 G**. Two separate recordings agreed. An offset larger than the field bends the
apparent heading by tens of degrees depending on where you face, and worn, the anchor
logged 23–32° of "error" on a head that had not drifted, then pulled the view toward it:
the canvas turning steadily one way. It stays off until that offset is measured and
subtracted, which needs a short guided calibration that does not exist yet. What follows
describes how it works once calibrated.

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
- **It corrects the gyro bias too, not only the heading.** A heading nudge capped at a
  crawl cannot keep up with a bias that is a few tenths of a deg/s off; the view slides and
  the anchor trails behind. A persistent heading error *is* a measurement of that bias
  error, so a slow, slew-limited share of it is folded back into the bias — the integral
  half of a PI controller.
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

### Yaw drift, and how it was measured

Drift cannot be judged by wearing the glasses for a minute, so it was measured offline.
The glasses were left on a desk while every raw IMU sample was recorded — real bias, real
bias wander, real noise, the real magnetic field — and a scripted head motion with a
**known** orientation was superimposed on the recording: the rates it implies added to the
gyro, gravity and the field rotated into the moving head frame. The unmodified `HeadTracker`
is fed the result and its yaw compared against the truth, over as many minutes as wanted.
The scenarios are a head holding still with natural sway, glances between windows, reading
line by line, and a deliberately asymmetric slow-out/fast-back.

What that found, six minutes per run, worst yaw error with the anchor working — on a
magnetometer assumed calibrated, which the real one is not yet (see the anchor section; with
the anchor dormant, the gyro-only figures for a remembered bias were under 1° for holding
still and glancing, and about 2° for reading):

| | holding still | glancing between windows | reading |
|---|---|---|---|
| Before | 64° | 24° | 18° |
| Bias learned only from desk-still windows, corrected by the anchor | 4° | 4° | 2° |
| …remembered from the last session, deadband 0.4 → 0.15 | **0.2°** | **0.2°** | **0.2°** |

The single largest cause was the bias estimator: a head holding still passes a test on
*average* rate, but a two-second slice of its sway does not average to zero, and each
accepted window taught the estimate some real head motion. Sway shows in the *spread* of
the samples, which on a desk sits at 0.14 deg/s and on a head never does. The recorder,
the simulator and how to run them are in `Tools/bench/README.md`.

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
moves, so it is always where you are looking.

Getting out is a **speed** test, not a position test — flick the pointer hard through the
viewport edge that *faces* your built-in screen and it hands over. Position alone cannot
tell the difference between the two ways the pointer ends up outside the viewport: you
pushed it there, or you turned your head and the viewport left without it. Glancing up
puts the pointer below the viewport exactly as swiping down does, so a position test throws
it onto the built-in screen every time you look around, and you have to look back down to
fetch it. Head motion moves the viewport and not the pointer, so it registers zero pointer
velocity and the test separates the two cleanly. Resting against the edge, or easing into
it, now stays. *Pointer escape* in Settings sets how hard is hard enough.

Coming back is a warp: crossing onto the canvas puts the pointer wherever the display
arrangement says, essentially never inside the viewport — so it must be placed there
deliberately. It re-enters through the edge it left by, at the same position along that
edge.

**Screen edges stay reachable.** When you look all the way to a canvas edge that has no
display beyond it, the inset is dropped on that side and the pointer can touch the very last
pixel — which is what a hidden Dock needs to appear, on whichever side it lives, and what
hot corners need to fire. This is decided per point along the edge, not per edge, because a
neighbour usually covers only part of one: with a laptop screen under the middle of the
canvas, the bottom edge above the laptop keeps its inset (so crossing is still a flick),
while the stretches either side of it reach the edge. The glasses' own display counts as a
wall rather than a neighbour; pushing into it puts the pointer back on the canvas edge.

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

A **busy** desktop is a different picture, and it is the one that heats the machine. With
three browsers, a video player, chat apps and a streaming terminal window all on the
canvas, the desktop changed about 41 times a second. Averaged over three interleaved rounds
of simulated head motion (`Tools/bench`):

| | WindowServer | kernel_task | HoloFrame | Intel GPU | AMD GPU |
|---|---|---|---|---|---|
| Capturing at 60 fps | 99% | 15% | 16% | 47% | 45% |
| Capture capped at 30 fps | 94% | 13% | 14% | 40% | 47% |
| Capture capped at 20 fps | 95% | 12% | 13% | 36% | 44% |
| Not capturing at all | 70% | 8% | 6% | 21% | 0% |

So about 70% of a core is macOS drawing that desktop whether or not anyone looks at it, and
capturing and presenting it to the glasses adds the rest. Capping the rate helps only a
little, which is why it is a setting (*Capture rate*) and not the default.

What did **not** matter, measured and ruled out: dragging the pointer along with the view,
and leaving the pointer out of captured frames. What mattered a great deal: **which GPU
renders**. On this dual-GPU Mac the virtual canvas is composited on the integrated GPU while
the glasses hang off the discrete one. Rendering on the glasses' GPU means pulling each
66 MB captured frame across the bus, and it measured 5–7 ms per frame and an effective
30 fps. Rendering on the canvas's GPU measured 0.12 ms per frame at 60. HoloFrame picks the
canvas's GPU and says so in the log.

HoloFrame's own 16% is mostly handling a thousand IMU reports a second and the Metal and
capture machinery: sampled, its own code — the tracker and the report decoder — barely
registers. Frames whose texture and view are identical to the last are not drawn again,
which helps while the desktop is static and you are holding still; on a desktop changing 40
times a second nearly every frame differs, so there it does little.

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
| `Sources/HoloFrame/TrackpadGestures.swift` | Right-⌥: hold to carry the canvas, scroll to pan, pinch to zoom — via event taps on their own thread, only in the input path while the key is held. |
| `Sources/HoloFrame/Diagnostics.swift` | Environment switches for measuring without wearing the glasses. |
| `Tools/` | `make-app.sh`, `make-icon.sh`, and the probes used to reverse-engineer both subsystems. |
| `Tools/bench/` | Measuring without wearing: event-tap latency, IMU recorder, the yaw-drift simulator, the load benchmark. |
| `Design/` | Icon sources. |

Environment variable: `HOLOFRAME_VERBOSE=1` adds window placement detail. Normal runs are
quiet.

For measuring rather than wearing, `Diagnostics.swift` documents a set of switches, all off
unless set: `HOLOFRAME_SIM=1` drives the view from a synthetic head sweep and never
idle-pauses, `HOLOFRAME_STATS=<s>` logs render and capture rates, render time, pointer warps
and the tracker's bias and anchor state, and `HOLOFRAME_RECORD=<path>` writes every raw IMU
sample to a file for replaying through the tracker offline. Pass them through `open`:

```bash
open -a HoloFrame.app --env HOLOFRAME_SIM=1 --env HOLOFRAME_STATS=5 \
     --stdout /tmp/holoframe.log --stderr /tmp/holoframe.log
```

## Tried and rejected

Two features were built, measured against real use, and removed. Both are recorded because
the reasons are not obvious and the ideas are tempting.

**Lean to zoom** — lean in to magnify, sit back for the overview. Three designs failed, and
zoom is now on right-⌥ + pinch instead. An
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
you do, which means thresholds, which means false triggers and misses. Nothing that has to
guess whether you meant it has survived here. What replaced them — the temple buttons, which
report themselves over the MCU interface (`P_BUTTON_PRESSED`, `0x6C05`), and a modifier key
— share the property of being unambiguous by construction rather than by tuning.

### A trap worth naming

`CGEventType` and `NSEvent.EventType` share a numbering space, and they **collide**.
`CGEventType.scrollWheel` is 22; `NSEvent.EventType.magnify` is 30. Subscribing an event
tap to 22 believing it is magnify delivers scroll events instead — and then asking one of
those for `.magnification` does not return a wrong value, it raises
`NSInternalInconsistencyException` and takes the process with it. Ask the `NSEvent` what it
*is* before asking what it contains.

The tap also subscribes to every gesture type rather than only the ones it acts on. That is
not tidiness lost: a narrow mask was one of the differences between this and a probe that
provably received magnify events, and removing variables mattered more than removing bits.

### A second trap: an active event tap is in everyone's input path

The window server delivers input as **one ordered stream**, and an active (`.defaultTap`)
tap holds that stream until its callback returns — not just for the events it subscribed
to, but for everything queued behind them. The trackpad emits gesture events continuously
while a finger rests on it, so a gesture tap is in the path of nearly all input. The first
version ran its tap on the main thread beside the renderer, and whenever the main thread
fell behind under load, the whole machine's input waited: key-ups arrived late enough that
macOS treated keys as held and opened the accent picker, keystrokes went missing, and the
pointer stalled. The window server's own statistics show it — `CGGetEventTapList` reports
each tap's latency. Now the taps live on a dedicated thread, and the active one is switched
off except while right-⌥ is physically down; a listen-only tap, which never holds the
stream, watches for the key.

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

- **Yaw has no outside reference at the moment**, so it can still walk slowly — from bias
  that changes while the glasses are worn and warming, which cannot be re-measured on a head.
  ⌘⌥R or the temple button puts it back. The magnetic anchor would bound it, but only once
  the magnetometer's internal offset (≈0.25 G, larger than Earth's field) is calibrated out;
  a guided "turn the glasses through every direction" calibration is the next step.
- The drift deadband (0.15 deg/s) damps rotation slower than about half a degree per
  second a little; above 1 deg/s it is under 2%.
- No stereo. The glasses stay in 2D mode. Stereo/SBS and VR video are a separate project;
  the sketch is a per-surface stereo layout rather than a single desktop plane.
- `panGain` (1.0, physically exact) and `horizontalFOV` (40°, the Air's spec) in
  `ViewConfig` are the two comfort knobs, not yet exposed in the UI.
