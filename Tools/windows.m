//
//  windows.m — list an app's windows as the WINDOW SERVER sees them.
//
//  This is the tool that settled the unplug bug, after several rounds of reasoning about
//  the wrong layer. AppKit's NSApp.windows is bookkeeping: a window released twice
//  disappears from it while its window-server surface stays on screen, so the app reports
//  "no windows" while you are looking at one. CGWindowListCopyWindowInfo asks the window
//  server directly and cannot be fooled by that.
//
//  Reach for this whenever "the window is gone" and the screen disagree.
//
//  Build: clang -fobjc-arc -o windows windows.m -framework Foundation -framework CoreGraphics
//  Run:   ./windows [name-fragment]        default: HoloFrame
//
//  layer 1000 is NSWindow.Level.screenSaver — HoloFrame's renderer.
//  alpha 0 means present but invisible: hidden, not destroyed.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *match = argc > 1 ? @(argv[1]) : @"HoloFrame";
        CFArrayRef list = CGWindowListCopyWindowInfo(
            kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements, kCGNullWindowID);

        printf("%-8s %-7s %-6s %-9s %-13s %s\n",
               "winID", "pid", "layer", "onscreen", "size", "position   alpha");
        int found = 0;
        for (NSDictionary *w in (__bridge NSArray *)list) {
            NSString *owner = w[(id)kCGWindowOwnerName];
            if (![owner containsString:match]) continue;
            NSDictionary *b = w[(id)kCGWindowBounds];
            printf("%-8d %-7d %-6d %-9s %5.0fx%-7.0f %5.0f,%-6.0f %.2f\n",
                   [w[(id)kCGWindowNumber] intValue],
                   [w[(id)kCGWindowOwnerPID] intValue],
                   [w[(id)kCGWindowLayer] intValue],
                   w[(id)kCGWindowIsOnscreen] ? "yes" : "no",
                   [b[@"Width"] doubleValue], [b[@"Height"] doubleValue],
                   [b[@"X"] doubleValue], [b[@"Y"] doubleValue],
                   [w[(id)kCGWindowAlpha] doubleValue]);
            found++;
        }
        if (!found) printf("(no windows matching \"%s\")\n", [match UTF8String]);
        CFRelease(list);
    }
    return 0;
}
