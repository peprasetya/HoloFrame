//
//  HFVirtualDisplay.h — the HoloFrame canvas, as a macOS virtual display.
//
//  Wraps the private CGVirtualDisplay SPI. Everything about why this is shaped the way it
//  is — the XYZ primaries, the mode ladder, and the mirroring trap — is in
//  virtualDisplay.md at the repo root. Read that before changing anything here.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface HFVirtualDisplay : NSObject

/// Create a canvas whose largest offered mode is `width` x `height`.
///
/// `hiDPI` NO gives one point per pixel — the most desktop real estate, and a quarter of
/// the capture bandwidth of the 2x equivalent. YES makes each mode's pixel size double its
/// point size.
///
/// `serialNumber` must be **stable across launches**. macOS identifies a display by
/// vendor/product/serial and keys its remembered resolution and arrangement off that, so a
/// random serial makes the user rearrange their desktop every single run.
///
/// Returns nil if the display could not be created. The canvas lives exactly as long as
/// this object.
- (nullable instancetype)initWithWidth:(uint32_t)width
                                height:(uint32_t)height
                                 hiDPI:(BOOL)hiDPI
                          serialNumber:(uint32_t)serialNumber
                                  name:(NSString *)name;

/// 0 until the display registers.
@property(readonly, nonatomic) CGDirectDisplayID displayID;

/// Pixel size of the mode currently selected, or 0x0 if the display is not active.
@property(readonly, nonatomic) CGSize currentPixelSize;

/// Select the largest mode this canvas offers. macOS otherwise leaves the choice to the
/// user in System Settings, which may land on a small one.
- (BOOL)selectLargestMode;

/// YES if any online display is mirroring another.
///
/// Check this before trusting anything about a display's mode: a mirroring display reports
/// the resolution of the display it mirrors, is absent from the active list, and silently
/// ignores CGConfigureDisplayWithDisplayMode. Misreading that state cost this project
/// hours.
+ (BOOL)anyDisplayIsMirroring;

/// Release every online display from mirroring, in one configuration transaction.
///
/// Releasing only the main display is not enough — the others keep mirroring it.
+ (BOOL)disableAllMirroring;

@end

NS_ASSUME_NONNULL_END
