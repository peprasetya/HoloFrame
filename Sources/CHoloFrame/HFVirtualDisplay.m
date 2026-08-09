//
//  HFVirtualDisplay.m
//
//  Port of BetterDummy's working recipe (waydabber/BetterDisplay, branch `opensource`,
//  BetterDummy/Model/Dummy.swift, MIT).
//

#import "include/HFVirtualDisplay.h"
#import <AppKit/AppKit.h>

#pragma mark - private SPI, re-declared from the runtime (see Tools/dumpvd.m)

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

#pragma mark -

@implementation HFVirtualDisplay {
    CGVirtualDisplay *_display;
    uint32_t _targetPixelWidth, _targetPixelHeight;
}

static void HFReduceAspect(uint32_t w, uint32_t h, uint32_t *aw, uint32_t *ah) {
    uint32_t a = w, b = h;
    while (b) { uint32_t t = a % b; a = b; b = t; }
    *aw = w / a;
    *ah = h / a;
}

- (nullable instancetype)initWithWidth:(uint32_t)width
                                height:(uint32_t)height
                                 hiDPI:(BOOL)hiDPI
                          serialNumber:(uint32_t)serialNumber
                                  name:(NSString *)name {
    self = [super init];
    if (!self) return nil;

    // Deliberately NOT calling NSApplicationLoad() here. Initialising AppKit before the
    // display exists makes NSScreen cache a list without it, and that stale list then
    // misplaces every window we create. The caller brings AppKit up afterwards instead.
    uint32_t scale = hiDPI ? 2 : 1;
    uint32_t aw, ah;
    HFReduceAspect(width, height, &aw, &ah);

    // Publish a ladder of same-aspect modes rather than a single mode: macOS picks from
    // it (System Settings > Displays), and a lone mode is not reliably accepted. The
    // 4-aspect-unit step matches what a live BetterDisplay 32:9 canvas advertises.
    uint32_t stepW = aw * 4, stepH = ah * 4;
    uint32_t maxK = width / stepW;
    uint32_t minK = MAX(1u, maxK / 3);
    if (maxK == 0) return nil;

    NSMutableArray *modes = [NSMutableArray array];
    for (uint32_t k = minK; k <= maxK; k++) {
        CGVirtualDisplayMode *m = [[CGVirtualDisplayMode alloc] initWithWidth:stepW * k * scale
                                                                      height:stepH * k * scale
                                                                 refreshRate:60.0];
        if (m) [modes addObject:m];
    }
    _targetPixelWidth  = stepW * maxK * scale;
    _targetPixelHeight = stepH * maxK * scale;

    CGVirtualDisplayDescriptor *desc = [[CGVirtualDisplayDescriptor alloc] init];
    desc.queue = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
    desc.name = name;
    // These are XYZ tristimulus values, NOT xy chromaticities — their Y components sum to
    // 1.000. Passing sRGB xy values here yields a degenerate colorspace and the display
    // publishes only a 1x1 mode, while every call still reports success.
    desc.whitePoint   = CGPointMake(0.950, 1.000);
    desc.redPrimary   = CGPointMake(0.454, 0.242);
    desc.greenPrimary = CGPointMake(0.353, 0.674);
    desc.bluePrimary  = CGPointMake(0.157, 0.084);
    // Must equal the largest mode in the ladder.
    desc.maxPixelsWide = _targetPixelWidth;
    desc.maxPixelsHigh = _targetPixelHeight;
    // Nominal 24" diagonal, as BetterDummy does.
    double diag = (24 * 25.4) / sqrt((double)(aw * aw + ah * ah));
    desc.sizeInMillimeters = CGSizeMake(aw * diag, ah * diag);
    // Stable across launches, so macOS remembers this display's resolution and where the
    // user put it. A random value here means rearranging the desktop every run.
    desc.serialNum = serialNumber;
    desc.productID = (MIN(aw - 1, 255u) << 8) | MIN(ah - 1, 255u);
    desc.vendorID  = 0xF0F0;

    _display = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
    if (!_display) return nil;

    CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;
    settings.modes = modes;
    if (![_display applySettings:settings]) return nil;

    return self;
}

- (CGDirectDisplayID)displayID {
    return _display ? _display.displayID : 0;
}

- (CGSize)currentPixelSize {
    CGDirectDisplayID did = self.displayID;
    if (!did) return CGSizeZero;
    CGDisplayModeRef m = CGDisplayCopyDisplayMode(did);
    if (!m) return CGSizeZero;
    CGSize s = CGSizeMake(CGDisplayModeGetPixelWidth(m), CGDisplayModeGetPixelHeight(m));
    CGDisplayModeRelease(m);
    return s;
}

- (BOOL)selectLargestMode {
    CGDirectDisplayID did = self.displayID;
    if (!did) return NO;
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(did, NULL);
    if (!modes) return NO;

    CGDisplayModeRef best = NULL;
    size_t bestPixels = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(modes); i++) {
        CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        if (!CGDisplayModeIsUsableForDesktopGUI(m)) continue;
        size_t px = CGDisplayModeGetPixelWidth(m) * CGDisplayModeGetPixelHeight(m);
        if (px > bestPixels) { bestPixels = px; best = m; }
    }
    BOOL ok = NO;
    if (best) {
        CGDisplayConfigRef config;
        if (CGBeginDisplayConfiguration(&config) == kCGErrorSuccess) {
            CGConfigureDisplayWithDisplayMode(config, did, best, NULL);
            ok = CGCompleteDisplayConfiguration(config, kCGConfigurePermanently) == kCGErrorSuccess;
        }
    }
    CFRelease(modes);
    return ok;
}

+ (BOOL)anyDisplayIsMirroring {
    uint32_t n = 0;
    CGDirectDisplayID ids[32];
    if (CGGetOnlineDisplayList(32, ids, &n) != kCGErrorSuccess) return NO;
    for (uint32_t i = 0; i < n; i++) {
        if (CGDisplayMirrorsDisplay(ids[i]) != kCGNullDirectDisplay) return YES;
    }
    return NO;
}

+ (BOOL)disableAllMirroring {
    uint32_t n = 0;
    CGDirectDisplayID ids[32];
    if (CGGetOnlineDisplayList(32, ids, &n) != kCGErrorSuccess) return NO;
    CGDisplayConfigRef config;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) return NO;
    for (uint32_t i = 0; i < n; i++) {
        CGConfigureDisplayMirrorOfDisplay(config, ids[i], kCGNullDirectDisplay);
    }
    return CGCompleteDisplayConfiguration(config, kCGConfigurePermanently) == kCGErrorSuccess;
}

@end
