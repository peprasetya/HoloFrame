// sldisplay — create a virtual display via SkyLight's SLVirtualDisplay SPI.
//
// CGVirtualDisplay (CoreGraphics) is the legacy path: on macOS 26 it creates a display but
// silently ignores the mode list and lands on a 1920x1080 default, and its applySettings:
// returns a bare BOOL with no reason. SLVirtualDisplay is the current layer, and every
// call reports an NSError.
//
// Interfaces re-declared from the runtime shape dumped by dumpvd.m (macOS 26.5). The
// classes are resolved with NSClassFromString so nothing needs to link against the
// private framework.
//
// Build: clang -fobjc-arc -o sldisplay sldisplay.m -framework Foundation -framework CoreGraphics -framework AppKit
// Run:   ./sldisplay [width] [height] [pointScale] [seconds]
//        ./sldisplay 7680 2160 1 20

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <dlfcn.h>

// MARK: - struct types, from the method type encodings

typedef struct { unsigned int width, height; } SLSizeU32;   // {?=II}
typedef struct { float width, height; } SLSizeF32;          // {?=ff}
typedef struct { float x, y; } SLPointF32;                  // {?=ff}
typedef struct { SLPointF32 red, green, blue, white; } SLChromaticities;

// MARK: - private SPI, re-declared

@interface SLVirtualDisplayMode : NSObject
- (instancetype)initWithSizeInPixels:(SLSizeU32)sizeInPixels
                        sizeInPoints:(SLSizeU32)sizeInPoints
                         refreshRate:(float)refreshRate
                               error:(NSError **)error;
@property(nonatomic, readonly) SLSizeU32 sizeInPixels, sizeInPoints;
@property(nonatomic, readonly) float refreshRate;
@property(nonatomic, assign) double refreshDeadline;
@property(nonatomic, assign) unsigned long long eotf, options;
@end

@interface SLVirtualDisplaySettings : NSObject
- (instancetype)initWithNativeMode:(SLVirtualDisplayMode *)nativeMode
                     preferredMode:(SLVirtualDisplayMode *)preferredMode
                     optionalModes:(NSArray *)optionalModes
                         rotations:(unsigned long long)rotations
                             error:(NSError **)error;
@end

@interface SLVirtualDisplayConfiguration : NSObject
- (instancetype)initWithName:(NSString *)name
                    vendorID:(unsigned long long)vendorID
                   productID:(unsigned long long)productID
                serialNumber:(unsigned long long)serialNumber
           sizeInMillimeters:(SLSizeF32)sizeInMillimeters
         maximumSizeInPixels:(SLSizeU32)maximumSizeInPixels
              chromaticities:(SLChromaticities)chromaticities
                       error:(NSError **)error;
@property(nonatomic, assign) unsigned long long type, options, subtype;
@property(nonatomic, strong) NSString *uti;
@end

@interface SLVirtualDisplay : NSObject
+ (id)capabilities;
- (instancetype)initWithConfiguration:(SLVirtualDisplayConfiguration *)configuration
                                error:(NSError **)error;
- (BOOL)applySettings:(SLVirtualDisplaySettings *)settings error:(NSError **)error;
- (void)destroy;
@property(nonatomic, readonly) unsigned int displayID;
@end

// MARK: -

static void listDisplays(const char *when) {
    uint32_t count = 0;
    CGDirectDisplayID ids[16];
    CGGetActiveDisplayList(16, ids, &count);
    printf("  displays %s: %u\n", when, count);
    for (uint32_t i = 0; i < count; i++) {
        CGRect b = CGDisplayBounds(ids[i]);
        printf("    id %-10u %5zu x %-5zu  at (%.0f,%.0f)%s\n",
               ids[i], CGDisplayPixelsWide(ids[i]), CGDisplayPixelsHigh(ids[i]),
               b.origin.x, b.origin.y, CGDisplayIsBuiltin(ids[i]) ? "  [builtin]" : "");
    }
}

static BOOL isActive(CGDirectDisplayID target) {
    uint32_t count = 0;
    CGDirectDisplayID ids[16];
    CGGetActiveDisplayList(16, ids, &count);
    for (uint32_t i = 0; i < count; i++) if (ids[i] == target) return YES;
    return NO;
}

/// Try one SL variant. Success is membership in the active display list — NOT
/// CGDisplayPixelsWide, which returns junk for an inactive id and produced a completely
/// misleading "clamped to 1920x1080" signal earlier.
static BOOL trySL(const char *label, uint32_t w, uint32_t h, uint32_t pointScale,
                  unsigned long long rotations, int optionalModesKind) {
    Class ConfigCls   = NSClassFromString(@"SLVirtualDisplayConfiguration");
    Class ModeCls     = NSClassFromString(@"SLVirtualDisplayMode");
    Class SettingsCls = NSClassFromString(@"SLVirtualDisplaySettings");
    Class DisplayCls  = NSClassFromString(@"SLVirtualDisplay");
    BOOL online = NO;
    @autoreleasepool {
        NSError *err = nil;
        SLSizeF32 mm = { w / 110.0f * 25.4f, h / 110.0f * 25.4f };
        SLSizeU32 maxPx = { w, h };
        SLChromaticities chroma = {{0.64f,0.33f},{0.30f,0.60f},{0.15f,0.06f},{0.3127f,0.3290f}};
        SLVirtualDisplayConfiguration *cfg =
            [[ConfigCls alloc] initWithName:@"HoloFrame Canvas" vendorID:0x3318 productID:0x484F
                               serialNumber:1 sizeInMillimeters:mm maximumSizeInPixels:maxPx
                             chromaticities:chroma error:&err];

        SLSizeU32 px = { w, h };
        SLSizeU32 pt = { w / pointScale, h / pointScale };
        SLVirtualDisplayMode *mode = [[ModeCls alloc] initWithSizeInPixels:px sizeInPoints:pt
                                                              refreshRate:60.0f error:&err];
        NSArray *opt = (optionalModesKind == 0) ? @[] : (optionalModesKind == 1 ? @[mode] : nil);
        SLVirtualDisplaySettings *st = [[SettingsCls alloc] initWithNativeMode:mode preferredMode:mode
                                                                 optionalModes:opt rotations:rotations
                                                                         error:&err];
        SLVirtualDisplay *vd = [[DisplayCls alloc] initWithConfiguration:cfg error:&err];
        NSError *applyErr = nil;
        BOOL applied = vd ? [vd applySettings:st error:&applyErr] : NO;

        double waited = 0;
        CGDirectDisplayID did = 0;
        while (waited < 4.0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            waited += 0.05;
            did = vd.displayID;
            if (did && isActive(did)) { online = YES; break; }
        }
        printf("  %-38s apply=%-3s id=%-9u online=%-3s %zux%zu  %s\n",
               label, applied ? "YES" : "NO", did, online ? "YES" : "no",
               online ? CGDisplayPixelsWide(did) : 0, online ? CGDisplayPixelsHigh(did) : 0,
               applyErr ? [[applyErr localizedDescription] UTF8String] : (online ? "*** OK ***" : ""));
        [vd destroy];
    }
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.8]];
    return online;
}

/// Create the display, wait for it to come online (it arrives at 1x1), and only then
/// apply the mode.
static BOOL trySLDeferred(uint32_t w, uint32_t h, uint32_t pointScale, unsigned long long rotations) {
    Class ConfigCls   = NSClassFromString(@"SLVirtualDisplayConfiguration");
    Class ModeCls     = NSClassFromString(@"SLVirtualDisplayMode");
    Class SettingsCls = NSClassFromString(@"SLVirtualDisplaySettings");
    Class DisplayCls  = NSClassFromString(@"SLVirtualDisplay");
    BOOL ok = NO;
    @autoreleasepool {
        NSError *err = nil;
        SLSizeF32 mm = { w / 110.0f * 25.4f, h / 110.0f * 25.4f };
        SLSizeU32 maxPx = { w, h };
        SLChromaticities chroma = {{0.64f,0.33f},{0.30f,0.60f},{0.15f,0.06f},{0.3127f,0.3290f}};
        SLVirtualDisplayConfiguration *cfg =
            [[ConfigCls alloc] initWithName:@"HoloFrame Canvas" vendorID:0x3318 productID:0x484F
                               serialNumber:1 sizeInMillimeters:mm maximumSizeInPixels:maxPx
                             chromaticities:chroma error:&err];
        SLVirtualDisplay *vd = [[DisplayCls alloc] initWithConfiguration:cfg error:&err];
        printf("  create -> %s  err=%s\n", vd ? "ok" : "nil",
               err ? [[err localizedDescription] UTF8String] : "-");

        double waited = 0;
        CGDirectDisplayID did = 0;
        while (waited < 5.0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            waited += 0.05;
            did = vd.displayID;
            if (did && isActive(did)) break;
        }
        printf("  online after %.2fs at %zu x %zu (id %u)\n",
               waited, CGDisplayPixelsWide(did), CGDisplayPixelsHigh(did), did);

        err = nil;
        SLSizeU32 px = { w, h };
        SLSizeU32 pt = { w / pointScale, h / pointScale };
        SLVirtualDisplayMode *mode = [[ModeCls alloc] initWithSizeInPixels:px sizeInPoints:pt
                                                              refreshRate:60.0f error:&err];
        SLVirtualDisplaySettings *st = [[SettingsCls alloc] initWithNativeMode:mode preferredMode:mode
                                                                 optionalModes:@[] rotations:rotations
                                                                         error:&err];
        NSError *applyErr = nil;
        BOOL applied = [vd applySettings:st error:&applyErr];
        printf("  applySettings (post-online) -> %s  err=%s\n", applied ? "YES" : "NO",
               applyErr ? [[applyErr localizedDescription] UTF8String] : "-");

        double w2 = 0;
        while (w2 < 5.0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            w2 += 0.05;
            if (CGDisplayPixelsWide(did) == w && CGDisplayPixelsHigh(did) == h) break;
        }
        ok = (CGDisplayPixelsWide(did) == w && CGDisplayPixelsHigh(did) == h);
        printf("  -> %zu x %zu after %.2fs   %s\n\n", CGDisplayPixelsWide(did),
               CGDisplayPixelsHigh(did), w2, ok ? "*** OK ***" : "!! mode did not take");
        [vd destroy];
    }
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
    return ok;
}

/// Modelled on the live BetterDisplay-created display observed on this machine:
///   - sizeInMillimeters derived from POINTS at exactly 72 dpi
///   - maximumSizeInPixels far larger than the mode (not equal to it)
///   - a ladder of optional modes, not a single mode
static BOOL trySLv2(const char *label, uint32_t w, uint32_t h, uint32_t pointScale,
                    BOOL bigMax, BOOL dpi72, BOOL ladder) {
    Class ConfigCls   = NSClassFromString(@"SLVirtualDisplayConfiguration");
    Class ModeCls     = NSClassFromString(@"SLVirtualDisplayMode");
    Class SettingsCls = NSClassFromString(@"SLVirtualDisplaySettings");
    Class DisplayCls  = NSClassFromString(@"SLVirtualDisplay");
    BOOL ok = NO;
    @autoreleasepool {
        NSError *err = nil;
        uint32_t ptW = w / pointScale, ptH = h / pointScale;
        // BetterDisplay's display: 7680pt / 2709.3mm * 25.4 == 72.0 dpi exactly
        double dpi = dpi72 ? 72.0 : 110.0;
        SLSizeF32 mm = { (float)(ptW / dpi * 25.4), (float)(ptH / dpi * 25.4) };
        SLSizeU32 maxPx = bigMax ? (SLSizeU32){16384, 16384} : (SLSizeU32){w, h};
        SLChromaticities chroma = {{0.64f,0.33f},{0.30f,0.60f},{0.15f,0.06f},{0.3127f,0.3290f}};

        SLVirtualDisplayConfiguration *cfg =
            [[ConfigCls alloc] initWithName:@"HoloFrame Canvas" vendorID:0x0896 productID:0x77E9
                               serialNumber:0x52C41D49 sizeInMillimeters:mm maximumSizeInPixels:maxPx
                             chromaticities:chroma error:&err];
        if (!cfg) { printf("  %-44s config nil: %s\n", label, [[err localizedDescription] UTF8String]); return NO; }

        SLVirtualDisplayMode *native = [[ModeCls alloc] initWithSizeInPixels:(SLSizeU32){w, h}
                                                               sizeInPoints:(SLSizeU32){ptW, ptH}
                                                                refreshRate:60.0f error:&err];
        // 32:9-style ladder around the native size, mirroring what the working display exposes
        NSMutableArray *opt = [NSMutableArray array];
        if (ladder) {
            for (uint32_t k = 4; k <= 14; k++) {
                uint32_t mw = (w * k) / 10, mh = (h * k) / 10;
                mw &= ~7u; mh &= ~7u;
                if (mw < 640 || mw == w) continue;
                SLVirtualDisplayMode *m = [[ModeCls alloc] initWithSizeInPixels:(SLSizeU32){mw, mh}
                                                                  sizeInPoints:(SLSizeU32){mw / pointScale, mh / pointScale}
                                                                   refreshRate:60.0f error:nil];
                if (m) [opt addObject:m];
            }
        }
        err = nil;
        SLVirtualDisplaySettings *st = [[SettingsCls alloc] initWithNativeMode:native preferredMode:native
                                                                 optionalModes:opt rotations:0 error:&err];
        SLVirtualDisplay *vd = [[DisplayCls alloc] initWithConfiguration:cfg error:&err];
        NSError *applyErr = nil;
        BOOL applied = vd ? [vd applySettings:st error:&applyErr] : NO;

        double waited = 0; CGDirectDisplayID did = 0; size_t pw = 0, ph = 0;
        while (waited < 6.0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            waited += 0.05;
            did = vd.displayID;
            if (!did || !isActive(did)) continue;
            CGDisplayModeRef cm = CGDisplayCopyDisplayMode(did);
            if (cm) { pw = CGDisplayModeGetPixelWidth(cm); ph = CGDisplayModeGetPixelHeight(cm); CGDisplayModeRelease(cm); }
            if (pw == w && ph == h) break;
        }
        ok = (pw == w && ph == h);
        printf("  %-44s apply=%-3s modes=%2lu -> %5zux%-5zu after %4.1fs %s%s\n",
               label, applied ? "YES" : "NO", (unsigned long)opt.count + 1, pw, ph, waited,
               ok ? "*** OK ***" : "no",
               applyErr ? [[applyErr localizedDescription] UTF8String] : "");
        [vd destroy];
    }
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
    return ok;
}

static void slV2(void) {
    printf("\n--- modelled on the live BetterDisplay display (3840x2160 test) ---\n");
    trySLv2("bigMax + 72dpi + ladder", 3840, 2160, 1, YES, YES, YES);
    trySLv2("bigMax + 72dpi, single",  3840, 2160, 1, YES, YES, NO);
    trySLv2("bigMax only",             3840, 2160, 1, YES, NO,  NO);
    trySLv2("72dpi only",              3840, 2160, 1, NO,  YES, NO);
    printf("\n--- target ---\n");
    trySLv2("7680x2160 bigMax+72dpi+ladder", 7680, 2160, 1, YES, YES, YES);
}

/// SLVirtualDisplay may only *register* the display plus its available modes. Actually
/// switching to one is the ordinary public display-configuration transaction — which
/// nothing above ever called.
static BOOL trySelectMode(uint32_t w, uint32_t h, uint32_t pointScale,
                          unsigned long long cfgType, unsigned long long cfgSubtype,
                          unsigned long long cfgOptions) {
    Class ConfigCls   = NSClassFromString(@"SLVirtualDisplayConfiguration");
    Class ModeCls     = NSClassFromString(@"SLVirtualDisplayMode");
    Class SettingsCls = NSClassFromString(@"SLVirtualDisplaySettings");
    Class DisplayCls  = NSClassFromString(@"SLVirtualDisplay");
    BOOL ok = NO;
    @autoreleasepool {
        NSError *err = nil;
        uint32_t ptW = w / pointScale, ptH = h / pointScale;
        SLSizeF32 mm = { (float)(ptW / 72.0 * 25.4), (float)(ptH / 72.0 * 25.4) };
        SLChromaticities chroma = {{0.64f,0.33f},{0.30f,0.60f},{0.15f,0.06f},{0.3127f,0.3290f}};
        SLVirtualDisplayConfiguration *cfg =
            [[ConfigCls alloc] initWithName:@"HoloFrame Canvas" vendorID:0x0896 productID:0x77E9
                               serialNumber:0x52C41D49 sizeInMillimeters:mm
                        maximumSizeInPixels:(SLSizeU32){16384, 16384}
                             chromaticities:chroma error:&err];
        cfg.type = cfgType;
        cfg.subtype = cfgSubtype;
        cfg.options = cfgOptions;

        SLVirtualDisplayMode *native = [[ModeCls alloc] initWithSizeInPixels:(SLSizeU32){w, h}
                                                               sizeInPoints:(SLSizeU32){ptW, ptH}
                                                                refreshRate:60.0f error:&err];
        SLVirtualDisplaySettings *st = [[SettingsCls alloc] initWithNativeMode:native
                                                                preferredMode:native
                                                                optionalModes:@[] rotations:0 error:&err];
        SLVirtualDisplay *vd = [[DisplayCls alloc] initWithConfiguration:cfg error:&err];
        NSError *applyErr = nil;
        printf("  create+apply -> %s\n", (vd && [vd applySettings:st error:&applyErr]) ? "ok" : "FAILED");

        double waited = 0; CGDirectDisplayID did = 0;
        while (waited < 6.0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            waited += 0.05;
            did = vd.displayID;
            if (did && isActive(did)) break;
        }
        printf("  online after %.2fs as id %u\n", waited, did);
        if (!did) { [vd destroy]; return NO; }

        // What modes does WindowServer think this display has?
        CFArrayRef modes = CGDisplayCopyAllDisplayModes(did, NULL);
        CGDisplayModeRef target = NULL;
        printf("  advertises %ld modes\n", modes ? CFArrayGetCount(modes) : 0);
        for (CFIndex i = 0; modes && i < CFArrayGetCount(modes); i++) {
            CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
            size_t pw = CGDisplayModeGetPixelWidth(m), ph = CGDisplayModeGetPixelHeight(m);
            if (i < 8) printf("    %5zu x %-5zu px\n", pw, ph);
            if (pw == w && ph == h) target = m;
        }
        if (!target) {
            printf("  !! %ux%u is not among the advertised modes\n", w, h);
        } else {
            CGDisplayConfigRef conf;
            CGError e1 = CGBeginDisplayConfiguration(&conf);
            CGError e2 = CGConfigureDisplayWithDisplayMode(conf, did, target, NULL);
            CGError e3 = CGCompleteDisplayConfiguration(conf, kCGConfigureForSession);
            printf("  begin=%d configure=%d complete=%d\n", e1, e2, e3);
            for (int t = 0; t < 6; t++) {
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
                CGDisplayModeRef cur = CGDisplayCopyDisplayMode(did);
                size_t cw = cur ? CGDisplayModeGetPixelWidth(cur) : 0;
                size_t ch = cur ? CGDisplayModeGetPixelHeight(cur) : 0;
                size_t pw = cur ? CGDisplayModeGetWidth(cur) : 0;
                size_t ph = cur ? CGDisplayModeGetHeight(cur) : 0;
                CGRect b = CGDisplayBounds(did);
                ok = (cw == w && ch == h);
                printf("  t+%ds: %zux%zu px  %zux%zu pt  bounds %.0fx%.0f  active=%d  %s\n",
                       t + 1, cw, ch, pw, ph, b.size.width, b.size.height, isActive(did),
                       ok ? "*** OK ***" : "");
                if (cur) CGDisplayModeRelease(cur);
                if (ok) break;
            }
        }
        if (modes) CFRelease(modes);
        [vd destroy];
    }
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
    return ok;
}

static void slSweep(void) {
    printf("\n--- SL variants, success = appears in active display list ---\n");
    trySL("rot=0  opt=[]    scale=1", 3840, 2160, 1, 0, 0);
    trySL("rot=1  opt=[]    scale=1", 3840, 2160, 1, 1, 0);
    trySL("rot=15 opt=[]    scale=1", 3840, 2160, 1, 15, 0);
    trySL("rot=0  opt=[m]   scale=1", 3840, 2160, 1, 0, 1);
    trySL("rot=1  opt=[m]   scale=1", 3840, 2160, 1, 1, 1);
    trySL("rot=0  opt=nil   scale=1", 3840, 2160, 1, 0, 2);
    trySL("rot=1  opt=[m]   scale=2", 3840, 2160, 2, 1, 1);
    trySL("small 1280x720 rot=1",     1280,  720, 1, 1, 1);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // One display per process: the display id gets recycled, so a second attempt in the
        // same process reads the previous display's modes while it is still tearing down.
        if (argc > 1 && strcmp(argv[1], "select") == 0) {
            dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW);
            NSApplicationLoad();
            [NSApplication sharedApplication];
            uint32_t sw = argc > 2 ? (uint32_t)atoi(argv[2]) : 3840;
            uint32_t sh = argc > 3 ? (uint32_t)atoi(argv[3]) : 2160;
            uint32_t sp = argc > 4 ? (uint32_t)atoi(argv[4]) : 1;
            unsigned long long ty = argc > 5 ? strtoull(argv[5], NULL, 0) : 0;
            unsigned long long su = argc > 6 ? strtoull(argv[6], NULL, 0) : 0;
            unsigned long long op = argc > 7 ? strtoull(argv[7], NULL, 0) : 0;
            printf("\n--- %u x %u  pointScale=%u  type=%llu subtype=%llu options=%llu ---\n",
                   sw, sh, sp, ty, su, op);
            trySelectMode(sw, sh, sp, ty, su, op);
            return 0;
        }
        if (argc > 1 && strcmp(argv[1], "v2") == 0) { dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW); NSApplicationLoad(); [NSApplication sharedApplication]; slV2(); return 0; }
        if (argc > 1 && strcmp(argv[1], "deferred") == 0) {
            dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW);
            NSApplicationLoad();
            [NSApplication sharedApplication];
            printf("\n--- 3840x2160 ---\n");  trySLDeferred(3840, 2160, 1, 0);
            printf("--- 7680x2160 ---\n");    trySLDeferred(7680, 2160, 1, 0);
            return 0;
        }
        if (argc > 1 && strcmp(argv[1], "sweep") == 0) {
            dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW);
            NSApplicationLoad();
            [NSApplication sharedApplication];
            slSweep();
            return 0;
        }
        uint32_t w = argc > 1 ? (uint32_t)atoi(argv[1]) : 7680;
        uint32_t h = argc > 2 ? (uint32_t)atoi(argv[2]) : 2160;
        // 1 = one point per pixel; 2 = HiDPI (points are half the pixels)
        uint32_t pointScale = argc > 3 ? (uint32_t)atoi(argv[3]) : 1;
        double secs = argc > 4 ? atof(argv[4]) : 15.0;

        if (!dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)) {
            printf("could not load SkyLight\n");
            return 1;
        }
        NSApplicationLoad();
        [NSApplication sharedApplication];

        Class ConfigCls   = NSClassFromString(@"SLVirtualDisplayConfiguration");
        Class ModeCls     = NSClassFromString(@"SLVirtualDisplayMode");
        Class SettingsCls = NSClassFromString(@"SLVirtualDisplaySettings");
        Class DisplayCls  = NSClassFromString(@"SLVirtualDisplay");
        if (!ConfigCls || !ModeCls || !SettingsCls || !DisplayCls) {
            printf("SLVirtualDisplay classes missing\n");
            return 1;
        }

        printf("capabilities: %s\n\n", [[[DisplayCls capabilities] description] UTF8String]);
        printf("requesting %u x %u px, %u x %u pt\n\n", w, h, w / pointScale, h / pointScale);
        listDisplays("before");

        NSError *err = nil;

        // ---- configuration ----
        SLSizeF32 mm = { w / 110.0f * 25.4f, h / 110.0f * 25.4f };
        SLSizeU32 maxPx = { w, h };
        SLChromaticities chroma = {
            .red   = {0.6400f, 0.3300f},
            .green = {0.3000f, 0.6000f},
            .blue  = {0.1500f, 0.0600f},
            .white = {0.3127f, 0.3290f},
        };
        SLVirtualDisplayConfiguration *config =
            [[ConfigCls alloc] initWithName:@"HoloFrame Canvas"
                                   vendorID:0x3318
                                  productID:0x484F
                               serialNumber:0x0001
                          sizeInMillimeters:mm
                        maximumSizeInPixels:maxPx
                             chromaticities:chroma
                                      error:&err];
        printf("config      -> %s%s\n", config ? "ok" : "nil",
               err ? [[NSString stringWithFormat:@"  error: %@", err] UTF8String] : "");
        if (!config) return 1;

        // ---- mode ----
        err = nil;
        SLSizeU32 px = { w, h };
        SLSizeU32 pt = { w / pointScale, h / pointScale };
        SLVirtualDisplayMode *mode = [[ModeCls alloc] initWithSizeInPixels:px
                                                             sizeInPoints:pt
                                                              refreshRate:60.0f
                                                                    error:&err];
        printf("mode        -> %s%s\n", mode ? "ok" : "nil",
               err ? [[NSString stringWithFormat:@"  error: %@", err] UTF8String] : "");
        if (!mode) return 1;

        // ---- settings ----
        err = nil;
        SLVirtualDisplaySettings *settings = [[SettingsCls alloc] initWithNativeMode:mode
                                                                      preferredMode:mode
                                                                      optionalModes:@[]
                                                                          rotations:0
                                                                              error:&err];
        printf("settings    -> %s%s\n", settings ? "ok" : "nil",
               err ? [[NSString stringWithFormat:@"  error: %@", err] UTF8String] : "");
        if (!settings) return 1;

        // ---- display ----
        err = nil;
        SLVirtualDisplay *vd = [[DisplayCls alloc] initWithConfiguration:config error:&err];
        printf("display     -> %s%s\n", vd ? "ok" : "nil",
               err ? [[NSString stringWithFormat:@"  error: %@", err] UTF8String] : "");
        if (!vd) return 1;

        err = nil;
        BOOL applied = [vd applySettings:settings error:&err];
        printf("applySettings -> %s%s\n", applied ? "YES" : "NO",
               err ? [[NSString stringWithFormat:@"  error: %@", err] UTF8String] : "");

        // poll for the mode to land
        double waited = 0;
        size_t aw = 0, ah = 0;
        CGDirectDisplayID did = 0;
        while (waited < 8.0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            waited += 0.05;
            did = vd.displayID;
            if (!did) continue;
            aw = CGDisplayPixelsWide(did);
            ah = CGDisplayPixelsHigh(did);
            if (aw == w && ah == h) break;
        }
        printf("\n  displayID %u -> %zu x %zu after %.2fs   %s\n",
               did, aw, ah, waited, (aw == w && ah == h) ? "*** OK ***" : "!! not the requested mode");
        listDisplays("after");

        if (secs > 0) {
            printf("\n  holding %.0fs...\n", secs);
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:secs]];
        }
        [vd destroy];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
        listDisplays("after destroy");
    }
    return 0;
}
