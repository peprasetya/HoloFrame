// vdisplay — create a HoloFrame canvas as a virtual display, and hold it open.
//
// Port of BetterDummy's working recipe (waydabber/BetterDisplay, branch `opensource`,
// BetterDummy/Model/Dummy.swift, MIT), adapted for an ultrawide canvas.
//
// You do NOT set a resolution on a virtual display. You publish a LADDER of same-aspect
// modes; System Settings > Displays then lets the user pick one. That is why BetterDisplay
// only asks for an aspect ratio. So this tool creates the display and holds it — choosing
// the resolution is a separate, external step.
//
// Load-bearing details that are not guessable:
//
//   1. The descriptor's "primaries" are XYZ tristimulus values, NOT xy chromaticities.
//      Their Y components sum to 1.000 and the white point is (0.950, 1.000). sRGB xy
//      values give a degenerate colorspace: the display registers but never scans out,
//      while every call still reports success.
//   2. maxPixelsWide/High must equal the LARGEST mode in the ladder.
//   3. hiDPI=1 means each mode's width/height are PIXELS and macOS presents half that in
//      points. hiDPI=0 is one point per pixel.
//
// Build: clang -fobjc-arc -o vdisplay vdisplay.m -framework Foundation -framework CoreGraphics -framework AppKit
// Run:   ./vdisplay [pointW] [pointH] [hiDPI] [holdSeconds, 0=forever]
//        ./vdisplay 7680 2160 1 0

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) id queue;
@property(retain, nonatomic) NSString *name;
@property(nonatomic) CGPoint whitePoint, redPrimary, greenPrimary, bluePrimary;
@property(nonatomic) unsigned int maxPixelsWide, maxPixelsHigh;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int serialNum, productID, vendorID;
@property(copy, nonatomic) id terminationHandler;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic) unsigned int hiDPI;
@property(retain, nonatomic) NSArray *modes;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property(readonly, nonatomic) unsigned int displayID;
@end

static void reduceAspect(unsigned w, unsigned h, unsigned *aw, unsigned *ah) {
    unsigned a = w, b = h;
    while (b) { unsigned t = a % b; a = b; b = t; }
    *aw = w / a;
    *ah = h / a;
}

/// pointW/pointH are the LARGEST desktop size the user should be offered, in points.
static CGVirtualDisplay *createCanvas(unsigned pointW, unsigned pointH, BOOL hiDPI, NSString *name) {
    unsigned scale = hiDPI ? 2 : 1;
    unsigned aw, ah;
    reduceAspect(pointW, pointH, &aw, &ah);

    // Ladder step: 4 aspect units in points, matching the 128x36 spacing a live
    // BetterDisplay 32:9 canvas advertises. Run from ~1/3 of the target up to it.
    unsigned stepW = aw * 4, stepH = ah * 4;
    unsigned maxK = pointW / stepW;
    unsigned minK = MAX(1u, maxK / 3);

    NSMutableArray *modes = [NSMutableArray array];
    for (unsigned k = minK; k <= maxK; k++) {
        unsigned pw = stepW * k * scale, ph = stepH * k * scale;
        CGVirtualDisplayMode *m = [[CGVirtualDisplayMode alloc] initWithWidth:pw height:ph refreshRate:60.0];
        if (m) [modes addObject:m];
    }
    unsigned maxPxW = stepW * maxK * scale, maxPxH = stepH * maxK * scale;

    printf("  aspect %u:%u  hiDPI=%d  %lu modes\n", aw, ah, hiDPI, (unsigned long)modes.count);
    printf("  smallest %u x %u pt   largest %u x %u pt  (%u x %u px)\n",
           stepW * minK, stepH * minK, stepW * maxK, stepH * maxK, maxPxW, maxPxH);

    CGVirtualDisplayDescriptor *desc = [[CGVirtualDisplayDescriptor alloc] init];
    desc.queue = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
    desc.name = name;
    // XYZ tristimulus from Generic RGB Profile.icc — see header note (1).
    desc.whitePoint   = CGPointMake(0.950, 1.000);
    desc.redPrimary   = CGPointMake(0.454, 0.242);
    desc.greenPrimary = CGPointMake(0.353, 0.674);
    desc.bluePrimary  = CGPointMake(0.157, 0.084);
    desc.maxPixelsWide = maxPxW;
    desc.maxPixelsHigh = maxPxH;
    double diag = (24 * 25.4) / sqrt((double)(aw * aw + ah * ah));
    desc.sizeInMillimeters = CGSizeMake(aw * diag, ah * diag);
    desc.serialNum = arc4random();
    desc.productID = (MIN(aw - 1, 255) << 8) | MIN(ah - 1, 255);
    desc.vendorID = 0xF0F0;

    CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
    if (!display) { printf("  initWithDescriptor failed\n"); return nil; }

    CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;
    settings.modes = modes;
    if (![display applySettings:settings]) { printf("  applySettings failed\n"); return nil; }
    return display;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        unsigned pw = argc > 1 ? (unsigned)atoi(argv[1]) : 7680;
        unsigned ph = argc > 2 ? (unsigned)atoi(argv[2]) : 2160;
        BOOL hiDPI  = argc > 3 ? atoi(argv[3]) != 0 : YES;
        double secs = argc > 4 ? atof(argv[4]) : 0;

        NSApplicationLoad();
        [NSApplication sharedApplication];
        setvbuf(stdout, NULL, _IOLBF, 0);

        printf("creating canvas, target %u x %u pt\n", pw, ph);
        CGVirtualDisplay *vd = createCanvas(pw, ph, hiDPI, @"HoloFrame Canvas");
        if (!vd) return 1;

        // Report what WindowServer ended up publishing, from this process's view.
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:3.0]];
        CGDirectDisplayID did = vd.displayID;
        printf("\n  displayID %u\n", did);
        CFArrayRef list = CGDisplayCopyAllDisplayModes(did, NULL);
        printf("  advertises %ld modes\n", list ? CFArrayGetCount(list) : 0);
        for (CFIndex i = 0; list && i < CFArrayGetCount(list) && i < 5; i++) {
            CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(list, i);
            printf("    %5zu x %-5zu px   %5zu x %-5zu pt\n",
                   CGDisplayModeGetPixelWidth(m), CGDisplayModeGetPixelHeight(m),
                   CGDisplayModeGetWidth(m), CGDisplayModeGetHeight(m));
        }
        if (list) CFRelease(list);

        printf("\n  holding%s — pick a resolution in System Settings > Displays\n",
               secs > 0 ? "" : " until killed");
        if (secs > 0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:secs]];
        } else {
            [[NSRunLoop currentRunLoop] run];
        }
    }
    return 0;
}
