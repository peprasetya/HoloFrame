# macOS virtual displays — findings

Everything learned trying to create a 7680×2160 canvas from our own process on
**macOS 26.5, Intel MacBookPro16,1**. Same tagging convention as `xrealAir.md`.

---

## 1. There are two SPIs, and the old one is a shim

| Layer | Framework | Classes |
|---|---|---|
| legacy | CoreGraphics | `CGVirtualDisplay`, `CGVirtualDisplayDescriptor`, `CGVirtualDisplaySettings`, `CGVirtualDisplayMode` |
| current | SkyLight | `SLVirtualDisplay`, `SLVirtualDisplayConfiguration`, `SLVirtualDisplaySettings`, `SLVirtualDisplayMode`, `SLVirtualDisplayCapabilities` |

CoreDisplay additionally carries `VirtualDisplayClient` / `VirtualDisplayServer` /
`CDVirtualDisplayConnect`, and QuartzCore has `CAWindowServerVirtualDisplay` — an
apparent scanout layer, **not yet investigated**. **[verified]**

The SL layer is the better target: every call takes an `NSError **`, where the CG
shim's `applySettings:` returns a bare `BOOL`. Dump the current shape with
`Tools/dumpvd.m` after any OS update — these have no headers.

## 2. Hard limits — the resolution is not the problem

`[SLVirtualDisplay capabilities]` on this machine. **[verified]**

```
MaximumSizeInPixels     16384 × 16384
MaximumPixelsPerPoint   4 × 4
MinimumPixelsPerPoint   0.25 × 0.25
MinimumRefreshRate      24
```

7680×2160 is far inside every limit. Any failure at that size is a bad call, not a cap.

## 3. Measuring success — the trap that cost hours

**`CGDisplayPixelsWide()` returns garbage for a display id that is not active.** For a
registered-but-offline virtual display it returned a plausible-looking `1920x1080`, which
reads exactly like "WindowServer clamped my mode" and is entirely fiction.

Check **membership in `CGGetActiveDisplayList`** first, and only then read the mode. Note
`CGDisplayIsOnline` can be 1 while `CGDisplayIsActive` is 0 — that combination means
*mirroring*, not "working". **[verified]**

Also: the virtual display id is a recycled slot (`4128832` / `4128833` here). Two attempts
in one process will have the second read the first's still-tearing-down state. **One
display per process** when testing.

## 4. The working recipe (BetterDummy, MIT)

From `waydabber/BetterDisplay` branch `opensource`, `BetterDummy/Model/Dummy.swift`.
Ported in `Tools/vdisplay.m`.

The non-obvious part — **the "primaries" are XYZ tristimulus values, not xy
chromaticities**:

```objc
desc.whitePoint   = CGPointMake(0.950, 1.000);   // NOT (0.3127, 0.3290)
desc.redPrimary   = CGPointMake(0.454, 0.242);
desc.greenPrimary = CGPointMake(0.353, 0.674);
desc.bluePrimary  = CGPointMake(0.157, 0.084);
```

The Y components sum to exactly 1.000. Passing sRGB xy values gives a degenerate
colorspace; the display then registers and never scans out, while every call still
reports success. **[verified as a real defect in our code; not verified as the sole cause]**

The rest:

- `descriptor.queue` = a **global** queue (`QOS_CLASS_USER_INTERACTIVE`)
- `maxPixelsWide/High` = the **largest mode in the ladder**, not the target alone
- `modes` = a ladder of same-aspect modes across a multiplier range, not one mode
- `sizeInMillimeters` from a nominal 24" diagonal at the target aspect
- `settings.hiDPI` = 1 for Retina, **0 for one point per pixel**
- `vendorID` 0xF0F0, `productID` derived from aspect, `serialNum` random

## 5. RESOLVED — it was mirroring

`Tools/vdisplay.m` creates a working **7680×2160 non-HiDPI** canvas. **[verified]**

```
id 4128832  online=1 active=1 main=0 mirror-of=0  7680x2160  (2709.3 x 762.0 mm)
```

Two independent faults stacked, and the second masked the first:

1. **The XYZ-vs-xy primaries bug in §4.** Real, and on its own enough to stop the display
   publishing a usable mode list. Fixing it took the display from advertising a single
   `1x1` mode to advertising the full 41-mode ladder.
2. **The whole display configuration was in mirror mode.** Every display —
   built-in, the XREAL, ours, and BetterDisplay's — reported `mirror-of=<built-in>` and
   the built-in's resolution. That is what produced the "display comes online at 1×1 /
   never takes its mode" symptom, and it is why `CGConfigureDisplayWithDisplayMode`
   returned success and changed nothing: you cannot set the mode of a mirroring display.

**The diagnostic that would have caught it immediately** is `CGDisplayMirrorsDisplay()`.
Check it before concluding anything about a virtual display's mode:

```objc
CGDisplayIsOnline(d)          // registered
CGDisplayIsActive(d)          // 0 while mirroring
CGDisplayMirrorsDisplay(d)    // non-zero == mirroring THAT display  <-- check this
```

Releasing every online display from mirroring in one transaction is what made it work:

```objc
CGGetOnlineDisplayList(16, ids, &n);
CGBeginDisplayConfiguration(&c);
for (uint32_t i = 0; i < n; i++)
    CGConfigureDisplayMirrorOfDisplay(c, ids[i], kCGNullDirectDisplay);
CGCompleteDisplayConfiguration(c, kCGConfigurePermanently);
```

Un-mirroring only the *main* display is not enough — the others keep mirroring it. The app
should assert on `CGDisplayMirrorsDisplay()` at startup and offer to clear it.

**Also confirmed:** not a slot limit (works alongside BetterDisplay's own virtual display),
and `hiDPI=0` virtual displays **are** supported — the earlier doubt in this file was the
mirroring, not a platform restriction. macOS never offered a non-HiDPI option through
BetterDisplay's UI, but the SPI accepts it directly.

### What "success" actually means here

You do **not** set a resolution on a virtual display. You supply a *ladder* of modes and
something else selects one — System Settings → Displays lists them, which is why
BetterDisplay exposes only an aspect ratio and no resolution field. So a fresh display
sitting at a default mode is not necessarily a failure; nothing has chosen yet. Tested
both `hiDPI=0` and `hiDPI=1` with the correct recipe — neither yields a selectable
ladder. **[verified]**

Note also that virtual displays created by BetterDisplay are always **HiDPI**, and macOS
offers no non-HiDPI option for them. Whether 1:1 (`hiDPI=0`) virtual displays are
supported at all on this OS is **an open question**, and matters: a 2× canvas costs 4× the
capture bandwidth.

### The display is real, it just never gets a mode

While our half-created display exists it **displaces the live display configuration** — on
this machine it pushed the built-in panel into mirroring. Destroying it restores
everything automatically. So the object is genuinely registered with WindowServer and
participating in configuration; only mode acquisition fails. **[verified]**

### Side effect worth knowing

A half-created virtual display **destabilises the display configuration**: on this machine
it put the built-in panel into mirroring (`online=1 active=0`, reporting the XREAL's
size). Recovery, which works cleanly:

```objc
CGBeginDisplayConfiguration(&c);
CGConfigureDisplayMirrorOfDisplay(c, builtin, kCGNullDirectDisplay);
CGConfigureDisplayOrigin(c, builtin, 0, 0);       // origin 0,0 == main display
CGCompleteDisplayConfiguration(c, kCGConfigurePermanently);
```

Then reselect the native mode with `CGConfigureDisplayWithDisplayMode`. Keep this handy
before experimenting further. **[verified]**

## 6. Tools

| File | Purpose |
|---|---|
| `Tools/dumpvd.m` | Dump the CG and SL class shapes from the ObjC runtime |
| `Tools/vdtest.m` | Legacy `CGVirtualDisplay` experiments |
| `Tools/sldisplay.m` | `SLVirtualDisplay` implementation with full error reporting |
| `Tools/vdisplay.m` | Faithful BetterDummy port — closest to working |
