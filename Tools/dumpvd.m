// dumpvd — introspect the private CGVirtualDisplay SPI via the Objective-C runtime.
//
// This is unsupported API. Its shape has drifted across macOS releases, so re-run this
// after an OS update rather than trusting a header copied off the internet.
//
// Build: clang -fobjc-arc -o dumpvd dumpvd.m -framework Foundation -framework CoreGraphics
// Run:   ./dumpvd

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static const char *ivarTypeString(Class c, const char *propName) {
    unsigned int n = 0;
    Ivar *ivars = class_copyIvarList(c, &n);
    static char buf[256];
    buf[0] = 0;
    for (unsigned i = 0; i < n; i++) {
        const char *iname = ivar_getName(ivars[i]);
        if (iname && strstr(iname, propName)) {
            const char *t = ivar_getTypeEncoding(ivars[i]);
            snprintf(buf, sizeof buf, "%s", t ? t : "?");
            break;
        }
    }
    free(ivars);
    return buf;
}

static void dumpClass(const char *name) {
    Class c = objc_getClass(name);
    if (!c) {
        printf("\n=== %s ===\n  NOT FOUND\n", name);
        return;
    }
    printf("\n=== %s ===  (superclass %s)\n", name, class_getName(class_getSuperclass(c)));

    unsigned int n = 0;
    objc_property_t *props = class_copyPropertyList(c, &n);
    if (n) printf("  -- properties --\n");
    for (unsigned i = 0; i < n; i++) {
        printf("    %-24s %s\n", property_getName(props[i]), property_getAttributes(props[i]));
    }
    free(props);

    n = 0;
    Ivar *ivars = class_copyIvarList(c, &n);
    if (n) printf("  -- ivars --\n");
    for (unsigned i = 0; i < n; i++) {
        printf("    %-24s %s\n", ivar_getName(ivars[i]), ivar_getTypeEncoding(ivars[i]));
    }
    free(ivars);

    n = 0;
    Method *ms = class_copyMethodList(c, &n);
    if (n) printf("  -- instance methods --\n");
    for (unsigned i = 0; i < n; i++) {
        char *enc = method_copyReturnType(ms[i]);
        printf("    -%-40s ret=%-8s argc=%u  sig=%s\n",
               sel_getName(method_getName(ms[i])), enc,
               method_getNumberOfArguments(ms[i]),
               method_getTypeEncoding(ms[i]));
        free(enc);
    }
    free(ms);

    n = 0;
    ms = class_copyMethodList(object_getClass(c), &n);
    if (n) printf("  -- class methods --\n");
    for (unsigned i = 0; i < n; i++) {
        printf("    +%s\n", sel_getName(method_getName(ms[i])));
    }
    free(ms);
}

int main(void) {
    @autoreleasepool {
        // Make sure the frameworks that might host these classes are resident.
        const char *libs[] = {
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            NULL
        };
        for (int i = 0; libs[i]; i++) {
            void *h = dlopen(libs[i], RTLD_NOW);
            printf("dlopen %-72s %s\n", libs[i], h ? "ok" : "FAILED");
        }

        const char *names[] = {
            "CGVirtualDisplay",
            "CGVirtualDisplayDescriptor",
            "CGVirtualDisplaySettings",
            "CGVirtualDisplayMode",
            // The SkyLight layer the CG classes are shims over. This is where the real
            // constraints live — note SLVirtualDisplayCapabilities.
            "SLVirtualDisplay",
            "SLVirtualDisplayCapabilities",
            "SLVirtualDisplaySettings",
            "SLVirtualDisplayMode",
            "SLVirtualDisplayConfiguration",
            NULL
        };
        for (int i = 0; names[i]; i++) dumpClass(names[i]);

        // Which image does each class actually come from?
        printf("\n-- provenance --\n");
        for (int i = 0; names[i]; i++) {
            Class c = objc_getClass(names[i]);
            if (!c) continue;
            Dl_info info;
            if (dladdr((__bridge const void *)c, &info)) {
                printf("  %-28s %s\n", names[i], info.dli_fname);
            }
        }
    }
    return 0;
}
