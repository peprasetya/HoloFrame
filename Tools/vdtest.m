// vdtest — create a CGVirtualDisplay at a given size and report what WindowServer did.
//
// The SPI has no public headers, so the interfaces below are re-declared from the runtime
// shape dumped by dumpvd.m. Verified against macOS 26.5.
//
// Build: clang -fobjc-arc -o vdtest vdtest.m -framework Foundation -framework CoreGraphics -framework AppKit
// Run:   ./vdtest [width] [height] [refresh] [hidpi] [seconds]
//        ./vdtest 7680 2160 60 0 5

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

// MARK: - private SPI, re-declared

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height refreshRate:(double)rate;
- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height refreshRate:(double)rate
             transferFunction:(uint32_t)tf;
@property(readonly) uint32_t width, height;
@property(readonly) double refreshRate;
@property(nonatomic, assign) uint32_t transferFunction;
@end

@interface CGVirtualDisplayDescriptor : NSObject
- (void)setDispatchQueue:(dispatch_queue_t)q;
- (dispatch_queue_t)dispatchQueue;
@property(nonatomic, strong) NSString *name;
@property(nonatomic, assign) CGSize sizeInMillimeters;
@property(nonatomic, assign) uint32_t maxPixelsWide, maxPixelsHigh;
@property(nonatomic, assign) uint32_t vendorID, productID, serialNum;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, copy) void (^terminationHandler)(id a, id b);
@property(nonatomic, assign) CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic, strong) NSArray<CGVirtualDisplayMode *> *modes;
@property(nonatomic, assign) uint32_t hiDPI, rotation;
@property(nonatomic, assign) double refreshDeadline;
@property(nonatomic, assign) BOOL isReference;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property(readonly) CGDirectDisplayID displayID;
@end

// MARK: -

static void listDisplays(const char *when) {
    uint32_t count = 0;
    CGGetActiveDisplayList(0, NULL, &count);
    CGDirectDisplayID ids[16];
    CGGetActiveDisplayList(16, ids, &count);
    printf("\n  active displays %s: %u\n", when, count);
    for (uint32_t i = 0; i < count; i++) {
        CGRect b = CGDisplayBounds(ids[i]);
        printf("    id %-10u %5zu x %-5zu px   bounds (%.0f,%.0f %.0fx%.0f)%s\n",
               ids[i], CGDisplayPixelsWide(ids[i]), CGDisplayPixelsHigh(ids[i]),
               b.origin.x, b.origin.y, b.size.width, b.size.height,
               CGDisplayIsBuiltin(ids[i]) ? "  [builtin]" : "");
    }
}

/// Create a virtual display at one size, report what WindowServer actually gave us,
/// then tear it down. Returns YES if the requested mode came back intact.
static BOOL trySize(uint32_t w, uint32_t h, double rate, uint32_t hidpi) {
    __block BOOL matched = NO;
    @autoreleasepool {
        CGVirtualDisplayDescriptor *desc = [[CGVirtualDisplayDescriptor alloc] init];
        desc.name = @"HoloFrame Probe";
        desc.queue = dispatch_queue_create("id.prasetya.holoframe.vd", DISPATCH_QUEUE_SERIAL);
        desc.maxPixelsWide = w;
        desc.maxPixelsHigh = h;
        desc.sizeInMillimeters = CGSizeMake(w / 110.0 * 25.4, h / 110.0 * 25.4);
        desc.vendorID = 0x3318; desc.productID = 0x484F; desc.serialNum = 0x0001;
        desc.redPrimary   = CGPointMake(0.6400, 0.3300);
        desc.greenPrimary = CGPointMake(0.3000, 0.6000);
        desc.bluePrimary  = CGPointMake(0.1500, 0.0600);
        desc.whitePoint   = CGPointMake(0.3127, 0.3290);
        desc.terminationHandler = ^(id a, id b) { (void)a; (void)b; };

        CGVirtualDisplay *vd = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
        CGVirtualDisplaySettings *st = [[CGVirtualDisplaySettings alloc] init];
        st.hiDPI = hidpi;
        st.rotation = 0;
        st.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:w height:h refreshRate:rate]];

        BOOL ok = vd ? [vd applySettings:st] : NO;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.9]];

        CGDirectDisplayID did = vd.displayID;
        size_t aw = did ? CGDisplayPixelsWide(did) : 0;
        size_t ah = did ? CGDisplayPixelsHigh(did) : 0;
        matched = (aw == w && ah == h);
        printf("  %5u x %-5u hiDPI=%u  apply=%-3s  id=%-9u got %5zu x %-5zu  %s\n",
               w, h, hidpi, ok ? "YES" : "NO", did, aw, ah,
               matched ? "OK" : (aw <= 1 ? "REJECTED" : "clamped"));

        vd = nil;
    }
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    return matched;
}

/// Seconds to wait for a mode to land. A good mode settles in ~1.2s on this machine.
static double gTimeout = 5.0;

typedef struct {
    BOOL     use4ArgInit;
    uint32_t transferFunction;
    double   refreshDeadline;   // <0 = don't set
    BOOL     isReference;
    BOOL     mainQueue;
    BOOL     manyModes;
} VDOpts;

static BOOL tryVariant(const char *label, uint32_t w, uint32_t h, uint32_t hidpi, VDOpts o) {
    BOOL matched = NO;
    @autoreleasepool {
        CGVirtualDisplayDescriptor *desc = [[CGVirtualDisplayDescriptor alloc] init];
        desc.name = @"HoloFrame Probe";
        desc.queue = o.mainQueue ? dispatch_get_main_queue()
                                 : dispatch_queue_create("id.prasetya.holoframe.vd", DISPATCH_QUEUE_SERIAL);
        desc.maxPixelsWide = w;
        desc.maxPixelsHigh = h;
        desc.sizeInMillimeters = CGSizeMake(w / 110.0 * 25.4, h / 110.0 * 25.4);
        desc.vendorID = 0x3318; desc.productID = 0x484F; desc.serialNum = 0x0001;
        desc.redPrimary   = CGPointMake(0.6400, 0.3300);
        desc.greenPrimary = CGPointMake(0.3000, 0.6000);
        desc.bluePrimary  = CGPointMake(0.1500, 0.0600);
        desc.whitePoint   = CGPointMake(0.3127, 0.3290);
        desc.terminationHandler = ^(id a, id b) { (void)a; (void)b; };

        CGVirtualDisplay *vd = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
        CGVirtualDisplaySettings *st = [[CGVirtualDisplaySettings alloc] init];
        st.hiDPI = hidpi;
        st.rotation = 0;
        if (o.refreshDeadline >= 0) st.refreshDeadline = o.refreshDeadline;
        st.isReference = o.isReference;

        CGVirtualDisplayMode *(^mk)(uint32_t, uint32_t, double) = ^(uint32_t mw, uint32_t mh, double r) {
            if (o.use4ArgInit) {
                return [[CGVirtualDisplayMode alloc] initWithWidth:mw height:mh refreshRate:r
                                                  transferFunction:o.transferFunction];
            }
            return [[CGVirtualDisplayMode alloc] initWithWidth:mw height:mh refreshRate:r];
        };
        st.modes = o.manyModes
            ? @[mk(w, h, 60), mk(1920, 1080, 60), mk(1280, 720, 60)]
            : @[mk(w, h, 60)];

        BOOL ok = vd ? [vd applySettings:st] : NO;

        // The mode does not land synchronously, and how long it takes varies a lot.
        // Poll rather than sleeping a fixed interval.
        CGDirectDisplayID did = 0;
        size_t aw = 0, ah = 0;
        double waited = 0, timeout = gTimeout, step = 0.05;
        while (waited < timeout) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:step]];
            waited += step;
            did = vd.displayID;
            if (!did) continue;
            aw = CGDisplayPixelsWide(did);
            ah = CGDisplayPixelsHigh(did);
            if (aw == w && ah == h) break;
        }
        matched = (aw == w && ah == h);
        printf("  %-34s apply=%-3s got %5zu x %-5zu after %5.2fs  %s\n",
               label, ok ? "YES" : "NO", aw, ah, waited,
               matched ? "*** OK ***" : (aw <= 1 ? "rejected (timeout)" : "clamped"));
        vd = nil;
    }
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.6]];
    return matched;
}

/// Repeat the plain baseline recipe N times to measure reliability and settling time.
static void reliability(uint32_t w, uint32_t h, uint32_t hidpi, int trials) {
    printf("\n--- baseline recipe, %ux%u hiDPI=%u, %d trials ---\n", w, h, hidpi, trials);
    int okCount = 0;
    for (int i = 0; i < trials; i++) {
        char label[64];
        snprintf(label, sizeof label, "trial %d", i + 1);
        if (tryVariant(label, w, h, hidpi, (VDOpts){.refreshDeadline = -1})) okCount++;
    }
    printf("  => %d/%d succeeded\n", okCount, trials);
}

/// Create the display first, wait for WindowServer to bring it up at its default mode,
/// and only then apply the settings. Reports the default it came up at, so a fallback
/// can never be mistaken for the mode landing.
static BOOL tryDeferredApply(uint32_t w, uint32_t h, uint32_t hidpi, int applyTimes) {
    BOOL matched = NO;
    @autoreleasepool {
        CGVirtualDisplayDescriptor *desc = [[CGVirtualDisplayDescriptor alloc] init];
        desc.name = @"HoloFrame Canvas";
        desc.queue = dispatch_queue_create("id.prasetya.holoframe.vd", DISPATCH_QUEUE_SERIAL);
        desc.maxPixelsWide = w;
        desc.maxPixelsHigh = h;
        desc.sizeInMillimeters = CGSizeMake(w / 110.0 * 25.4, h / 110.0 * 25.4);
        desc.vendorID = 0x3318; desc.productID = 0x484F; desc.serialNum = 0x0001;
        desc.redPrimary   = CGPointMake(0.6400, 0.3300);
        desc.greenPrimary = CGPointMake(0.3000, 0.6000);
        desc.bluePrimary  = CGPointMake(0.1500, 0.0600);
        desc.whitePoint   = CGPointMake(0.3127, 0.3290);
        desc.terminationHandler = ^(id a, id b) { (void)a; (void)b; };

        CGVirtualDisplay *vd = [[CGVirtualDisplay alloc] initWithDescriptor:desc];

        // 1. wait for it to exist at whatever default WindowServer picks
        double waited = 0;
        CGDirectDisplayID did = 0;
        size_t dw = 0, dh = 0;
        while (waited < 6.0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            waited += 0.05;
            did = vd.displayID;
            if (did && (dw = CGDisplayPixelsWide(did)) > 1) { dh = CGDisplayPixelsHigh(did); break; }
        }
        printf("    came up at %zu x %zu after %.2fs (id %u)\n", dw, dh, waited, did);

        // 2. now apply the mode we actually want
        CGVirtualDisplaySettings *st = [[CGVirtualDisplaySettings alloc] init];
        st.hiDPI = hidpi;
        st.rotation = 0;
        st.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:w height:h refreshRate:60]];

        for (int i = 0; i < applyTimes; i++) {
            BOOL ok = [vd applySettings:st];
            printf("    applySettings #%d -> %s\n", i + 1, ok ? "YES" : "NO");
            double w2 = 0;
            while (w2 < 4.0) {
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
                w2 += 0.05;
                if (CGDisplayPixelsWide(did) == w && CGDisplayPixelsHigh(did) == h) break;
            }
            size_t aw = CGDisplayPixelsWide(did), ah = CGDisplayPixelsHigh(did);
            matched = (aw == w && ah == h);
            printf("      -> %zu x %zu after %.2fs  %s\n", aw, ah, w2, matched ? "*** OK ***" : "no change");
            if (matched) break;
        }
        vd = nil;
    }
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.8]];
    return matched;
}

/// One attempt with fully explicit knobs, so each hypothesis can be isolated.
/// `mw`/`mh` are the descriptor's maxPixels headroom; 0 means "same as the mode".
static BOOL try2(const char *label, uint32_t w, uint32_t h, uint32_t hidpi,
                 BOOL useDispatchQueue, uint32_t mw, uint32_t mh) {
    BOOL matched = NO;
    @autoreleasepool {
        if (!mw) mw = w;
        if (!mh) mh = h;
        CGVirtualDisplayDescriptor *desc = [[CGVirtualDisplayDescriptor alloc] init];
        desc.name = @"HoloFrame Canvas";
        dispatch_queue_t q = dispatch_queue_create("id.prasetya.holoframe.vd", DISPATCH_QUEUE_SERIAL);
        if (useDispatchQueue) [desc setDispatchQueue:q]; else desc.queue = q;
        desc.maxPixelsWide = mw;
        desc.maxPixelsHigh = mh;
        desc.sizeInMillimeters = CGSizeMake(w / 110.0 * 25.4, h / 110.0 * 25.4);
        desc.vendorID = 0x3318; desc.productID = 0x484F; desc.serialNum = 0x0001;
        desc.redPrimary   = CGPointMake(0.6400, 0.3300);
        desc.greenPrimary = CGPointMake(0.3000, 0.6000);
        desc.bluePrimary  = CGPointMake(0.1500, 0.0600);
        desc.whitePoint   = CGPointMake(0.3127, 0.3290);
        desc.terminationHandler = ^(id a, id b) { (void)a; (void)b; };

        CGVirtualDisplay *vd = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
        CGVirtualDisplaySettings *st = [[CGVirtualDisplaySettings alloc] init];
        st.hiDPI = hidpi;
        st.rotation = 0;
        st.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:w height:h refreshRate:60]];
        BOOL ok = vd ? [vd applySettings:st] : NO;

        double waited = 0; size_t aw = 0, ah = 0; CGDirectDisplayID did = 0;
        while (waited < 5.0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            waited += 0.05;
            did = vd.displayID;
            if (!did) continue;
            aw = CGDisplayPixelsWide(did); ah = CGDisplayPixelsHigh(did);
            if (aw == w && ah == h) break;
        }
        matched = (aw == w && ah == h);
        printf("  %-40s got %5zu x %-5zu  %s\n", label, aw, ah,
               matched ? "*** OK ***" : (ok ? "ignored" : "apply=NO"));
        vd = nil;
    }
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.8]];
    return matched;
}

/// Exactly the selector set BetterDisplay's binary references — notably WITHOUT the
/// colour primaries, which are the one thing this tool was setting that it does not.
static BOOL tryMinimal(uint32_t w, uint32_t h, uint32_t hidpi, BOOL setPrimaries) {
    BOOL matched = NO;
    @autoreleasepool {
        CGVirtualDisplayDescriptor *desc = [[CGVirtualDisplayDescriptor alloc] init];
        desc.name = @"HoloFrame Canvas";
        [desc setDispatchQueue:dispatch_queue_create("id.prasetya.holoframe.vd", DISPATCH_QUEUE_SERIAL)];
        desc.maxPixelsWide = w;
        desc.maxPixelsHigh = h;
        desc.sizeInMillimeters = CGSizeMake(w / 110.0 * 25.4, h / 110.0 * 25.4);
        desc.vendorID = 0x3318;
        desc.productID = 0x484F;
        desc.serialNum = 0x0001;
        desc.terminationHandler = ^(id a, id b) { (void)a; (void)b; };
        if (setPrimaries) {
            desc.redPrimary   = CGPointMake(0.6400, 0.3300);
            desc.greenPrimary = CGPointMake(0.3000, 0.6000);
            desc.bluePrimary  = CGPointMake(0.1500, 0.0600);
            desc.whitePoint   = CGPointMake(0.3127, 0.3290);
        }

        CGVirtualDisplay *vd = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
        CGVirtualDisplaySettings *st = [[CGVirtualDisplaySettings alloc] init];
        st.hiDPI = hidpi;
        st.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:w height:h refreshRate:60]];
        BOOL ok = vd ? [vd applySettings:st] : NO;

        double waited = 0; size_t aw = 0, ah = 0;
        while (waited < 6.0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            waited += 0.05;
            CGDirectDisplayID did = vd.displayID;
            if (!did) continue;
            aw = CGDisplayPixelsWide(did); ah = CGDisplayPixelsHigh(did);
            if (aw == w && ah == h) break;
        }
        matched = (aw == w && ah == h);
        printf("  %5u x %-5u hiDPI=%u primaries=%-3s apply=%-3s -> %5zu x %-5zu after %5.2fs  %s\n",
               w, h, hidpi, setPrimaries ? "YES" : "no", ok ? "YES" : "NO", aw, ah, waited,
               matched ? "*** OK ***" : "ignored");
        vd = nil;
    }
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.8]];
    return matched;
}

static void minimalTest(void) {
    printf("\n--- BetterDisplay's exact recipe: are the colour primaries the blocker? ---\n");
    tryMinimal(3840, 2160, 0, YES);
    tryMinimal(3840, 2160, 0, NO);
    printf("\n--- if primaries were it, push to target ---\n");
    tryMinimal(5120, 2160, 0, NO);
    tryMinimal(7680, 2160, 0, NO);
    tryMinimal(7680, 2160, 1, NO);
}

static void matrix2(void) {
    printf("\n--- isolating why modes are ignored (target 3840x2160) ---\n");
    try2("setQueue,       max=exact",        3840, 2160, 0, NO,  0, 0);
    try2("setDispatchQueue, max=exact",      3840, 2160, 0, YES, 0, 0);
    try2("setDispatchQueue, max=16384",      3840, 2160, 0, YES, 16384, 16384);
    try2("setQueue,       max=16384",        3840, 2160, 0, NO,  16384, 16384);
    try2("setDispatchQueue, max=16384, hiDPI",3840, 2160, 1, YES, 16384, 16384);

    printf("\n--- if one works, push to the real target ---\n");
    try2("7680x2160 setDispatchQueue max16384", 7680, 2160, 0, YES, 16384, 16384);
    try2("7680x2160 setQueue max16384",         7680, 2160, 0, NO,  16384, 16384);
}

static void matrix(void) {
    const uint32_t W = 1920, H = 1080;
    printf("\n--- variant matrix at %ux%u ---\n", W, H);
    tryVariant("baseline (3-arg init)",        W, H, 0, (VDOpts){.refreshDeadline = -1});
    tryVariant("4-arg init, tf=0",             W, H, 0, (VDOpts){.use4ArgInit = YES, .transferFunction = 0, .refreshDeadline = -1});
    tryVariant("4-arg init, tf=1",             W, H, 0, (VDOpts){.use4ArgInit = YES, .transferFunction = 1, .refreshDeadline = -1});
    tryVariant("4-arg init, tf=2",             W, H, 0, (VDOpts){.use4ArgInit = YES, .transferFunction = 2, .refreshDeadline = -1});
    tryVariant("refreshDeadline=1/60",         W, H, 0, (VDOpts){.refreshDeadline = 1.0 / 60.0});
    tryVariant("refreshDeadline=0",            W, H, 0, (VDOpts){.refreshDeadline = 0});
    tryVariant("isReference=YES",              W, H, 0, (VDOpts){.isReference = YES, .refreshDeadline = -1});
    tryVariant("main queue",                   W, H, 0, (VDOpts){.mainQueue = YES, .refreshDeadline = -1});
    tryVariant("many modes",                   W, H, 0, (VDOpts){.manyModes = YES, .refreshDeadline = -1});
    tryVariant("hiDPI=1",                      W, H, 1, (VDOpts){.refreshDeadline = -1});
    tryVariant("4-arg tf=1 + deadline + hiDPI",W, H, 1, (VDOpts){.use4ArgInit = YES, .transferFunction = 1, .refreshDeadline = 1.0/60.0});
}

static void sweep(void) {
    const VDOpts base = {.refreshDeadline = -1};
    struct { uint32_t w, h; } sizes[] = {
        {2560, 1080}, {3440, 1440}, {3840, 1080}, {3840, 2160}, {4096, 2160},
        {5120, 1440}, {5120, 2160}, {6144, 2160}, {7680, 1080}, {7680, 2160},
        {8192, 2160}, {0, 0}
    };
    printf("\n--- width ladder (is the limit an axis, or total pixels?) ---\n");
    for (int i = 0; sizes[i].w; i++) {
        char label[64];
        snprintf(label, sizeof label, "%u x %u  (%.1f Mpix)",
                 sizes[i].w, sizes[i].h, sizes[i].w * sizes[i].h / 1e6);
        tryVariant(label, sizes[i].w, sizes[i].h, 0, base);
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // A virtual display is a WindowServer object. A plain CLI tool has no session
        // connection to WindowServer; without this the display registers but never gets
        // a usable mode (it comes back as 1x1).
        NSApplicationLoad();
        [NSApplication sharedApplication];

        if (argc > 1 && strcmp(argv[1], "minimal") == 0) { minimalTest(); return 0; }
        if (argc > 1 && strcmp(argv[1], "matrix2") == 0) { matrix2(); return 0; }
        if (argc > 1 && strcmp(argv[1], "deferred") == 0) {
            uint32_t w = argc > 2 ? (uint32_t)atoi(argv[2]) : 7680;
            uint32_t h = argc > 3 ? (uint32_t)atoi(argv[3]) : 2160;
            uint32_t hd = argc > 4 ? (uint32_t)atoi(argv[4]) : 0;
            printf("\n--- deferred applySettings, %u x %u hiDPI=%u ---\n", w, h, hd);
            tryDeferredApply(w, h, hd, 3);
            return 0;
        }
        if (argc > 1 && strcmp(argv[1], "reliability") == 0) {
            uint32_t w = argc > 2 ? (uint32_t)atoi(argv[2]) : 1920;
            uint32_t h = argc > 3 ? (uint32_t)atoi(argv[3]) : 1080;
            uint32_t hd = argc > 4 ? (uint32_t)atoi(argv[4]) : 0;
            int n = argc > 5 ? atoi(argv[5]) : 5;
            reliability(w, h, hd, n);
            return 0;
        }
        if (argc > 1 && strcmp(argv[1], "matrix") == 0) {
            matrix();
            return 0;
        }
        if (argc > 1 && strcmp(argv[1], "sweep") == 0) {
            listDisplays("before");
            sweep();
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
            listDisplays("after");
            return 0;
        }
        uint32_t w    = argc > 1 ? (uint32_t)atoi(argv[1]) : 7680;
        uint32_t h    = argc > 2 ? (uint32_t)atoi(argv[2]) : 2160;
        double   rate = argc > 3 ? atof(argv[3]) : 60.0;
        uint32_t hidpi= argc > 4 ? (uint32_t)atoi(argv[4]) : 0;
        double   secs = argc > 5 ? atof(argv[5]) : 5.0;

        printf("requesting %u x %u @ %.0f Hz, hiDPI=%u\n", w, h, rate, hidpi);
        listDisplays("before");

        CGVirtualDisplayDescriptor *desc = [[CGVirtualDisplayDescriptor alloc] init];
        desc.name = @"HoloFrame Canvas";
        desc.queue = dispatch_queue_create("id.prasetya.holoframe.vd", DISPATCH_QUEUE_SERIAL);
        desc.maxPixelsWide = w;
        desc.maxPixelsHigh = h;
        // ~110 dpi, so macOS picks sane default scaling
        desc.sizeInMillimeters = CGSizeMake(w / 110.0 * 25.4, h / 110.0 * 25.4);
        desc.vendorID  = 0x3318;   // borrow XREAL's, purely cosmetic
        desc.productID = 0x484F;   // 'HO'
        desc.serialNum = 0x0001;
        desc.redPrimary   = CGPointMake(0.6400, 0.3300);
        desc.greenPrimary = CGPointMake(0.3000, 0.6000);
        desc.bluePrimary  = CGPointMake(0.1500, 0.0600);
        desc.whitePoint   = CGPointMake(0.3127, 0.3290);
        desc.terminationHandler = ^(id a, id b) { (void)a; (void)b; printf("  ** terminationHandler fired **\n"); };

        CGVirtualDisplay *vd = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
        if (!vd) { printf("  FAILED: initWithDescriptor returned nil\n"); return 1; }

        CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
        settings.hiDPI = hidpi;
        settings.rotation = 0;
        settings.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:w height:h refreshRate:rate]];

        BOOL ok = [vd applySettings:settings];
        CGDirectDisplayID did = vd.displayID;
        printf("\n  applySettings -> %s\n", ok ? "YES" : "NO");
        printf("  displayID     -> %u\n", did);

        // give WindowServer a moment to reconfigure
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.2]];

        if (did) {
            printf("  actual size   -> %zu x %zu px\n", CGDisplayPixelsWide(did), CGDisplayPixelsHigh(did));
            CGRect b = CGDisplayBounds(did);
            printf("  bounds        -> (%.0f,%.0f  %.0f x %.0f)\n",
                   b.origin.x, b.origin.y, b.size.width, b.size.height);
            if (CGDisplayPixelsWide(did) != w || CGDisplayPixelsHigh(did) != h) {
                printf("  !! WindowServer clamped the mode\n");
            }
        }
        listDisplays("after");

        printf("\n  holding %.0fs, then releasing...\n", secs);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:secs]];

        vd = nil;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
        listDisplays("after release");
    }
    return 0;
}
