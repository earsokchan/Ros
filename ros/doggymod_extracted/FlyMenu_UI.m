#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#include <libkern/OSAtomic.h>
#include <time.h>

#include "embedded_scripts.h"
#import "embedded_header_png.h"
#import "embedded_donate_jpeg.h"

#define sel(s) sel_registerName(s)
#define cls(c) objc_getClass(c)

extern void *objc_autoreleasePoolPush(void);
extern void objc_autoreleasePoolPop(void *pool);

struct CGPoint { double x; double y; };
typedef struct CGPoint CGPoint;

struct CGSize { double width; double height; };
typedef struct CGSize CGSize;

struct CGRect { CGPoint origin; CGSize size; };
typedef struct CGRect CGRect;

static inline CGRect CGRectMake(double x, double y, double w, double h) {
    CGRect r; r.origin.x = x; r.origin.y = y; r.size.width = w; r.size.height = h; return r;
}
static inline CGPoint CGPointMake(double x, double y) {
    CGPoint p; p.x = x; p.y = y; return p;
}

// Strictly-typed objc_msgSend function pointers for ARM64 ABI
typedef id (*msgSend_id_id)(id, SEL, id);
typedef id (*msgSend_id_long)(id, SEL, long);
typedef id (*msgSend_id_id_long)(id, SEL, id, long);
typedef id (*msgSend_id_id_id)(id, SEL, id, id);
typedef id (*msgSend_id_id_sel_id_bool)(id, SEL, double, id, SEL, id, BOOL);
typedef id (*msgSend_id_double4)(id, SEL, double, double, double, double);
typedef id (*msgSend_id_double)(id, SEL, double);
typedef void (*msgSend_void_double)(id, SEL, double);
typedef void (*msgSend_void_rect)(id, SEL, CGRect);
typedef id (*msgSend_id_rect)(id, SEL, CGRect);
typedef CGRect (*msgSend_rect)(id, SEL);
typedef CGPoint (*msgSend_pt_id)(id, SEL, id);
typedef void (*msgSend_void_pt_id)(id, SEL, CGPoint, id);
typedef CGPoint (*msgSend_pt)(id, SEL);
typedef void (*msgSend_void_pt)(id, SEL, CGPoint);
typedef void (*msgSend_void_pt_pt)(id, SEL, CGPoint, CGPoint);
typedef void (*msgSend_void_long)(id, SEL, long);
typedef void (*msgSend_void_id)(id, SEL, id);
typedef void (*msgSend_void_id_long)(id, SEL, id, long);
typedef void (*msgSend_void_id_sel_long)(id, SEL, id, SEL, long);
typedef void (*msgSend_void_ulong)(id, SEL, unsigned long);
typedef void (*msgSend_void_bool)(id, SEL, BOOL);

static id g_uiMgr = NULL;
static id g_panel = NULL;
static id g_floatBtn = NULL;
static id (*orig_pathForResource)(id self, SEL _cmd, id name, id ext) = NULL;

// References to native core buttons + custom VIP buttons
#define NUM_BUTTONS 12
static id g_coreBtns[NUM_BUTTONS] = { NULL };    // 0:Fly, 1:Up, 2:Down, 3:Aim, 4:Esp, 5:Info, 6:1Hit, 7:Speed, 8:Recoil, 9:Wallhack, 10:AimSmooth, 11:FlyHud
static id g_rowPills[NUM_BUTTONS] = { NULL };    // Toggle switch indicators
static id g_rowKnobs[NUM_BUTTONS] = { NULL };    // Inner sliding thumb knob
static id g_rowLabels[NUM_BUTTONS] = { NULL };   // Clean titles
static id g_tabBtns[4] = { NULL };              // 0:Aim, 1:Esp, 2:Fly, 3:Info
static id g_tabIcons[4] = { NULL };             // Vector CAShapeLayer icons
static id g_tabLabels[4] = { NULL };            // Clean tab text labels
static int g_selectedTab = -1;                  // -1 = Show All

static void updateRowStates(void);

// Rich ESP Overlay Globals
static id g_espOverlay = NULL;
static id g_espRedLineLayer = NULL;
static id g_espGreenLineLayer = NULL;
static id g_espRedBoxLayer = NULL;
static id g_espGreenBoxLayer = NULL;
#define MAX_ESP_LABELS 32
static id g_espTextLayers[MAX_ESP_LABELS] = { NULL };
static id g_infoModal = NULL;

// On-screen Floating Fly HUD Globals
static id g_flyHudView = NULL;
static id g_flyHudToggleBtn = NULL;
static id g_flyHudUpBtn = NULL;
static id g_flyHudDownBtn = NULL;
static void ensureFloatingFlyHUD(id win);

// On-screen Floating Aim Smooth HUD Globals
static id g_aimHudView = NULL;
static id g_aimHudToggleBtn = NULL;
static void ensureFloatingAimHUD(id win);
static void createFloatingAimHUD(id win);
static int checkPlayerHoldingGun(void);

// Helper to get app Documents path using pure Objective-C runtime
static id getDocumentsPath(const char *filename) {
    Class fmCls = cls("NSFileManager");
    Class strCls = cls("NSString");
    if (fmCls && strCls) {
        id fm = ((id (*)(id, SEL))objc_msgSend)((id)fmCls, sel("defaultManager"));
        if (fm) {
            id urls = ((id (*)(id, SEL, unsigned long, unsigned long))objc_msgSend)(fm, sel("URLsForDirectory:inDomains:"), 9, 1);
            if (urls) {
                long count = (long)((long (*)(id, SEL))objc_msgSend)(urls, sel("count"));
                if (count > 0) {
                    id docUrl = ((msgSend_id_long)objc_msgSend)(urls, sel("objectAtIndex:"), 0);
                    if (docUrl) {
                        id docPathObj = ((id (*)(id, SEL))objc_msgSend)(docUrl, sel("path"));
                        if (docPathObj) {
                            const char *docStr = (const char *)((id (*)(id, SEL))objc_msgSend)(docPathObj, sel("UTF8String"));
                            if (docStr) {
                                char fullPath[1024];
                                snprintf(fullPath, sizeof(fullPath), "%s/%s", docStr, filename);
                                return ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)strCls, sel("alloc")), sel("initWithUTF8String:"), fullPath);
                            }
                        }
                    }
                }
            }
        }
    }
    const char *home = getenv("HOME");
    if (!home) home = "/var/mobile";
    char fullPath[1024];
    snprintf(fullPath, sizeof(fullPath), "%s/Documents/%s", home, filename);
    return ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)cls("NSString"), sel("alloc")), sel("initWithUTF8String:"), fullPath);
}

// Ensures script is on disk and returns absolute path as NSString
static id ensureAndGetScriptPath(const char *filename, const unsigned char *data, unsigned int len) {
    Class nsString = cls("NSString");

    // 1. Check main bundle
    Class nsBundle = cls("NSBundle");
    if (nsBundle) {
        id mb = ((id (*)(id, SEL))objc_msgSend)((id)nsBundle, sel("mainBundle"));
        if (mb) {
            id bPath = ((id (*)(id, SEL))objc_msgSend)(mb, sel("bundlePath"));
            if (bPath) {
                const char *bStr = (const char *)((id (*)(id, SEL))objc_msgSend)(bPath, sel("UTF8String"));
                if (bStr) {
                    char buf[1024];
                    snprintf(buf, sizeof(buf), "%s/%s", bStr, filename);
                    if (access(buf, R_OK) == 0) {
                        return ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel("alloc")), sel("initWithUTF8String:"), buf);
                    }
                }
            }
        }
    }

    // 2. Check existing tweak locations
    const char *candPaths[] = {
        "/Library/Application Support/ROS_Doggymod",
        "/var/jb/Library/Application Support/ROS_Doggymod",
        "/var/jb/usr/lib/TweakInject",
        "/usr/lib/TweakInject",
        "/Library/MobileSubstrate/DynamicLibraries",
        "/var/jb/Library/MobileSubstrate/DynamicLibraries",
        NULL
    };
    for (int i = 0; candPaths[i]; i++) {
        char buf[1024];
        snprintf(buf, sizeof(buf), "%s/%s", candPaths[i], filename);
        if (access(buf, R_OK) == 0) {
            return ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel("alloc")), sel("initWithUTF8String:"), buf);
        }
    }

    // 3. Write embedded script to Documents directory (100% writable inside app sandbox)
    id docPathObj = getDocumentsPath(filename);
    if (docPathObj) {
        const char *cPath = (const char *)((id (*)(id, SEL))objc_msgSend)(docPathObj, sel("UTF8String"));
        if (cPath) {
            FILE *f = fopen(cPath, "wb");
            if (f) {
                fwrite(data, 1, len, f);
                fclose(f);
            }
            return docPathObj;
        }
    }
    return NULL;
}

// 100% crash-safe -[NSBundle pathForResource:ofType:] swizzle
static id custom_pathForResource(id self, SEL _cmd, id name, id ext) {
    id orig = NULL;
    if (orig_pathForResource) {
        orig = orig_pathForResource(self, _cmd, name, ext);
    }
    if (orig != NULL) return orig;

    if (name != NULL && ext != NULL) {
        Class strCls = cls("NSString");
        if (strCls &&
            (long)((long (*)(id, SEL, id))objc_msgSend)(name, sel("isKindOfClass:"), (id)strCls) &&
            (long)((long (*)(id, SEL, id))objc_msgSend)(ext, sel("isKindOfClass:"), (id)strCls)) {
            
            const char *extStr = (const char *)((id (*)(id, SEL))objc_msgSend)(ext, sel("UTF8String"));
            if (extStr && strcmp(extStr, "py") == 0) {
                const char *nameStr = (const char *)((id (*)(id, SEL))objc_msgSend)(name, sel("UTF8String"));
                if (nameStr) {
                    if (strcmp(nameStr, "ros_fly") == 0) {
                        return ensureAndGetScriptPath("ros_fly.py", EMBEDDED_ROS_FLY_PY, EMBEDDED_ROS_FLY_PY_LEN);
                    } else if (strcmp(nameStr, "ros_combat") == 0) {
                        return ensureAndGetScriptPath("ros_combat.py", EMBEDDED_ROS_COMBAT_PY, EMBEDDED_ROS_COMBAT_PY_LEN);
                    }
                }
            }
        }
    }
    return orig;
}

static id getActiveWindow(void) {
    Class uiApp = cls("UIApplication");
    if (!uiApp) return NULL;
    id app = ((id (*)(id, SEL))objc_msgSend)((id)uiApp, sel("sharedApplication"));
    if (!app) return NULL;

    // Window MUST have a rootViewController to be valid and avoid launch crash
    id keyWin = ((id (*)(id, SEL))objc_msgSend)(app, sel("keyWindow"));
    if (keyWin && ((id (*)(id, SEL))objc_msgSend)(keyWin, sel("rootViewController"))) {
        return keyWin;
    }

    id windows = ((id (*)(id, SEL))objc_msgSend)(app, sel("windows"));
    if (windows) {
        long count = (long)((long (*)(id, SEL))objc_msgSend)(windows, sel("count"));
        for (long i = 0; i < count; i++) {
            id w = ((msgSend_id_long)objc_msgSend)(windows, sel("objectAtIndex:"), i);
            if (w && ((id (*)(id, SEL))objc_msgSend)(w, sel("rootViewController"))) {
                return w;
            }
        }
    }
    return NULL;
}

// Suppress and remove on-screen UI from ROS.deb (caidan / menuView1, FPSDisplay)
// while keeping DLG and DoggyMod VIP Menu 100% visible and functional.
static void dummyNoOp(id self, SEL _cmd, ...) {}

static void suppressROSDebUI(void) {
    // 1. Neuter the ROS.deb Chinese menu generator: -[NSObject caidan]
    Class nsObj = cls("NSObject");
    if (nsObj) {
        Method mCaidan = class_getInstanceMethod(nsObj, sel("caidan"));
        if (mCaidan) method_setImplementation(mCaidan, (IMP)dummyNoOp);
    }

    // 2. Neuter ROS.deb FPSDisplay label without returning nil from shareFPSDisplay
    Class fpsCls = cls("FPSDisplay");
    if (fpsCls) {
        Method mFpsInit = class_getInstanceMethod(fpsCls, sel("initDisplayLabel"));
        if (mFpsInit) method_setImplementation(mFpsInit, (IMP)dummyNoOp);
        Method mFpsLink = class_getInstanceMethod(fpsCls, sel("initCADisplayLink"));
        if (mFpsLink) method_setImplementation(mFpsLink, (IMP)dummyNoOp);
    }
}

static void purgeROSDebViews(void) {
    // 1. Hide and detach the global _menuView1 from ROS.deb if it was ever allocated
    id *pMenuView = (id *)dlsym(RTLD_DEFAULT, "menuView1");
    if (pMenuView && *pMenuView) {
        id mv = *pMenuView;
        Class uiViewCls = cls("UIView");
        if (uiViewCls && ((long (*)(id, SEL, id))objc_msgSend)(mv, sel("isKindOfClass:"), (id)uiViewCls)) {
            ((msgSend_void_long)objc_msgSend)(mv, sel("setHidden:"), 1);
            ((id (*)(id, SEL))objc_msgSend)(mv, sel("removeFromSuperview"));
        }
        *pMenuView = NULL;
    }

    // 2. Safely hide and detach FPSDisplay's label (FPSDisplay is an NSObject, NOT a UIView)
    Class fpsCls = cls("FPSDisplay");
    if (fpsCls) {
        id fpsInst = ((id (*)(id, SEL))objc_msgSend)((id)fpsCls, sel("shareFPSDisplay"));
        if (fpsInst) {
            id lbl = ((id (*)(id, SEL))objc_msgSend)(fpsInst, sel("displayLabel"));
            if (lbl) {
                ((msgSend_void_long)objc_msgSend)(lbl, sel("setHidden:"), 1);
                ((id (*)(id, SEL))objc_msgSend)(lbl, sel("removeFromSuperview"));
            }
        }
    }
}

// Direct memory hook for FlyMenu_core's panel pointer at offset 0xc070
static id getCoreFlyPanelFromMemory(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "FlyMenu_core")) {
            intptr_t slide = _dyld_get_image_vmaddr_slide(i);
            // 0xc070 is the static id g_panel inside FlyMenu_core.dylib
            id *pPanel = (id *)(slide + 0xc070);
            if (pPanel && *pPanel) {
                return *pPanel;
            }
            break;
        }
    }
    return NULL;
}

// Comprehensive search for FlyMenu_core's panel across memory and all UIWindows
// Note: DLGMem views are preserved untouched so DLG operates smoothly alongside FlyMenu.
static id findFlyPanel(void) {
    // 1. Direct memory pointer from FlyMenu_core.dylib (instant, 100% reliable)
    id memPanel = getCoreFlyPanelFromMemory();
    if (memPanel) {
        ((msgSend_void_long)objc_msgSend)(memPanel, sel("setHidden:"), 1);
        return memPanel;
    }

    // 2. Fallback search across active windows and hierarchies
    Class uiApp = cls("UIApplication");
    if (!uiApp) return NULL;
    id app = ((id (*)(id, SEL))objc_msgSend)((id)uiApp, sel("sharedApplication"));
    if (!app) return NULL;
    Class btnCls = cls("UIButton");
    if (!btnCls) return NULL;

    id windows = ((id (*)(id, SEL))objc_msgSend)(app, sel("windows"));
    long winCount = windows ? (long)((long (*)(id, SEL))objc_msgSend)(windows, sel("count")) : 0;
    id keyWin = ((id (*)(id, SEL))objc_msgSend)(app, sel("keyWindow"));

    for (long w = -1; w < winCount; w++) {
        id win = (w == -1) ? keyWin : ((msgSend_id_long)objc_msgSend)(windows, sel("objectAtIndex:"), w);
        if (!win) continue;
        id subviews = ((id (*)(id, SEL))objc_msgSend)(win, sel("subviews"));
        if (!subviews) continue;
        long count = (long)((long (*)(id, SEL))objc_msgSend)(subviews, sel("count"));
        for (long i = 0; i < count; i++) {
            id v = ((msgSend_id_long)objc_msgSend)(subviews, sel("objectAtIndex:"), i);
            if (!v || v == g_floatBtn || v == g_espOverlay) continue;

            // Never interfere with DLG views
            const char *cname = object_getClassName(v);
            if (cname && (strstr(cname, "DLG") != NULL || strstr(cname, "dlg") != NULL)) continue;

            id innerSubs = ((id (*)(id, SEL))objc_msgSend)(v, sel("subviews"));
            if (!innerSubs) continue;
            long innerCount = (long)((long (*)(id, SEL))objc_msgSend)(innerSubs, sel("count"));
            if (innerCount < 5) continue;

            for (long j = 0; j < innerCount; j++) {
                id sub = ((msgSend_id_long)objc_msgSend)(innerSubs, sel("objectAtIndex:"), j);
                if (!sub) continue;
                if ((long)((long (*)(id, SEL, id))objc_msgSend)(sub, sel("isKindOfClass:"), (id)btnCls)) {
                    id title = ((msgSend_id_long)objc_msgSend)(sub, sel("titleForState:"), 0);
                    if (title) {
                        const char *utf = (const char *)((id (*)(id, SEL))objc_msgSend)(title, sel("UTF8String"));
                        if (utf && (strstr(utf, "FLY") != NULL || strstr(utf, "ESP") != NULL || strstr(utf, "AIM") != NULL)) {
                            ((msgSend_void_long)objc_msgSend)(v, sel("setHidden:"), 1);
                            return v;
                        }
                    }
                }
            }
        }
    }
    return NULL;
}

// 100% reliable logo image loader with embedded in-memory fallback
static id loadLogoImage(void) {
    Class uiImg = cls("UIImage");
    Class nsString = cls("NSString");
    Class nsData = cls("NSData");
    if (!uiImg) return NULL;

    const char *candPaths[] = {
        "/Library/MobileSubstrate/DynamicLibraries/D79oM.bundle/header.png",
        "/var/jb/Library/MobileSubstrate/DynamicLibraries/D79oM.bundle/header.png",
        "/var/jb/usr/lib/TweakInject/D79oM.bundle/header.png",
        "/usr/lib/TweakInject/D79oM.bundle/header.png",
        "/Library/Application Support/ROS_Doggymod/header.png",
        "/var/jb/Library/Application Support/ROS_Doggymod/header.png",
        "/Library/MobileSubstrate/DynamicLibraries/D79oM.bundle/back.png",
        "/var/jb/Library/MobileSubstrate/DynamicLibraries/D79oM.bundle/back.png",
        "/var/jb/usr/lib/TweakInject/D79oM.bundle/back.png",
        NULL
    };
    for (int k = 0; candPaths[k]; k++) {
        if (access(candPaths[k], R_OK) == 0 && nsString) {
            id p = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel("alloc")), sel("initWithUTF8String:"), candPaths[k]);
            if (p) {
                id img = ((msgSend_id_id)objc_msgSend)((id)uiImg, sel("imageWithContentsOfFile:"), p);
                if (img) return img;
            }
        }
    }

    id mb = ((id (*)(id, SEL))objc_msgSend)((id)cls("NSBundle"), sel("mainBundle"));
    if (mb && nsString) {
        id bPath = ((id (*)(id, SEL))objc_msgSend)(mb, sel("bundlePath"));
        if (bPath) {
            const char *bStr = (const char *)((id (*)(id, SEL))objc_msgSend)(bPath, sel("UTF8String"));
            if (bStr) {
                char buf[1024];
                snprintf(buf, sizeof(buf), "%s/header.png", bStr);
                if (access(buf, R_OK) == 0) {
                    id p = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel("alloc")), sel("initWithUTF8String:"), buf);
                    if (p) {
                        id img = ((msgSend_id_id)objc_msgSend)((id)uiImg, sel("imageWithContentsOfFile:"), p);
                        if (img) return img;
                    }
                }
                snprintf(buf, sizeof(buf), "%s/D79oM.bundle/header.png", bStr);
                if (access(buf, R_OK) == 0) {
                    id p = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel("alloc")), sel("initWithUTF8String:"), buf);
                    if (p) {
                        id img = ((msgSend_id_id)objc_msgSend)((id)uiImg, sel("imageWithContentsOfFile:"), p);
                        if (img) return img;
                    }
                }
            }
        }
    }

    // Direct in-memory embedded fallback: 100% guaranteed to return user's logo on all devices
    if (nsData) {
        id data = ((id (*)(id, SEL, const void *, unsigned long))objc_msgSend)((id)nsData, sel("dataWithBytes:length:"), EMBEDDED_HEADER_PNG, EMBEDDED_HEADER_PNG_LEN);
        if (data) {
            id img = ((msgSend_id_id)objc_msgSend)((id)uiImg, sel("imageWithData:"), data);
            if (img) return img;
        }
    }
    return NULL;
}

// Clean vector icons for tabs (AIM, ESP, FLY, INFO) — ZERO emojis
static id createTabIconLayer(int tabIndex, id color) {
    Class shapeCls = cls("CAShapeLayer");
    Class bPathCls = cls("UIBezierPath");
    if (!shapeCls || !bPathCls) return NULL;

    id layer = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)shapeCls, sel("alloc")), sel("init"));
    if (!layer) return NULL;

    id path = ((id (*)(id, SEL))objc_msgSend)((id)bPathCls, sel("bezierPath"));
    if (!path) return NULL;

    Class uiColor = cls("UIColor");
    id clearColor = uiColor ? ((id (*)(id, SEL))objc_msgSend)((id)uiColor, sel("clearColor")) : NULL;
    id cgClear = clearColor ? ((id (*)(id, SEL))objc_msgSend)(clearColor, sel("CGColor")) : NULL;
    id cgColor = color ? ((id (*)(id, SEL))objc_msgSend)(color, sel("CGColor")) : NULL;

    if (tabIndex == 0) {
        // Tab 0: AIM — Precision Crosshair Reticle
        id circlePath = ((msgSend_id_rect)objc_msgSend)((id)bPathCls, sel("bezierPathWithOvalInRect:"), CGRectMake(2.5, 2.5, 9.0, 9.0));
        if (circlePath) ((msgSend_void_id)objc_msgSend)(path, sel("appendPath:"), circlePath);

        // 4 Reticle Ticks
        ((msgSend_void_pt)objc_msgSend)(path, sel("moveToPoint:"), CGPointMake(0.0, 7.0));
        ((msgSend_void_pt)objc_msgSend)(path, sel("addLineToPoint:"), CGPointMake(2.5, 7.0));

        ((msgSend_void_pt)objc_msgSend)(path, sel("moveToPoint:"), CGPointMake(11.5, 7.0));
        ((msgSend_void_pt)objc_msgSend)(path, sel("addLineToPoint:"), CGPointMake(14.0, 7.0));

        ((msgSend_void_pt)objc_msgSend)(path, sel("moveToPoint:"), CGPointMake(7.0, 0.0));
        ((msgSend_void_pt)objc_msgSend)(path, sel("addLineToPoint:"), CGPointMake(7.0, 2.5));

        ((msgSend_void_pt)objc_msgSend)(path, sel("moveToPoint:"), CGPointMake(7.0, 11.5));
        ((msgSend_void_pt)objc_msgSend)(path, sel("addLineToPoint:"), CGPointMake(7.0, 14.0));

        // Center dot
        id dotPath = ((msgSend_id_rect)objc_msgSend)((id)bPathCls, sel("bezierPathWithOvalInRect:"), CGRectMake(6.0, 6.0, 2.0, 2.0));
        if (dotPath) ((msgSend_void_id)objc_msgSend)(path, sel("appendPath:"), dotPath);

        ((msgSend_void_id)objc_msgSend)(layer, sel("setFillColor:"), cgClear);
        ((msgSend_void_id)objc_msgSend)(layer, sel("setStrokeColor:"), cgColor);
        ((msgSend_void_double)objc_msgSend)(layer, sel("setLineWidth:"), 1.2);
    } else if (tabIndex == 1) {
        // Tab 1: ESP — Vision Eye / Scanner
        ((msgSend_void_pt)objc_msgSend)(path, sel("moveToPoint:"), CGPointMake(1.0, 7.0));
        ((msgSend_void_pt_pt)objc_msgSend)(path, sel("addQuadCurveToPoint:controlPoint:"), CGPointMake(13.0, 7.0), CGPointMake(7.0, 1.5));
        ((msgSend_void_pt_pt)objc_msgSend)(path, sel("addQuadCurveToPoint:controlPoint:"), CGPointMake(1.0, 7.0), CGPointMake(7.0, 12.5));

        // Pupil
        id pupilPath = ((msgSend_id_rect)objc_msgSend)((id)bPathCls, sel("bezierPathWithOvalInRect:"), CGRectMake(5.0, 5.0, 4.0, 4.0));
        if (pupilPath) ((msgSend_void_id)objc_msgSend)(path, sel("appendPath:"), pupilPath);

        ((msgSend_void_id)objc_msgSend)(layer, sel("setFillColor:"), cgClear);
        ((msgSend_void_id)objc_msgSend)(layer, sel("setStrokeColor:"), cgColor);
        ((msgSend_void_double)objc_msgSend)(layer, sel("setLineWidth:"), 1.2);
    } else if (tabIndex == 2) {
        // Tab 2: FLY — Supersonic Jet / Wing
        ((msgSend_void_pt)objc_msgSend)(path, sel("moveToPoint:"), CGPointMake(7.0, 1.0));
        ((msgSend_void_pt)objc_msgSend)(path, sel("addLineToPoint:"), CGPointMake(13.5, 12.5));
        ((msgSend_void_pt)objc_msgSend)(path, sel("addLineToPoint:"), CGPointMake(7.0, 9.5));
        ((msgSend_void_pt)objc_msgSend)(path, sel("addLineToPoint:"), CGPointMake(0.5, 12.5));
        ((id (*)(id, SEL))objc_msgSend)(path, sel("closePath"));

        ((msgSend_void_id)objc_msgSend)(layer, sel("setFillColor:"), cgClear);
        ((msgSend_void_id)objc_msgSend)(layer, sel("setStrokeColor:"), cgColor);
        ((msgSend_void_double)objc_msgSend)(layer, sel("setLineWidth:"), 1.2);
    } else {
        // Tab 3: INFO — Clean Info Glyph
        id circlePath = ((msgSend_id_rect)objc_msgSend)((id)bPathCls, sel("bezierPathWithOvalInRect:"), CGRectMake(1.0, 1.0, 12.0, 12.0));
        if (circlePath) ((msgSend_void_id)objc_msgSend)(path, sel("appendPath:"), circlePath);

        // Dot
        id dotPath = ((msgSend_id_rect)objc_msgSend)((id)bPathCls, sel("bezierPathWithOvalInRect:"), CGRectMake(6.2, 3.2, 1.6, 1.6));
        if (dotPath) ((msgSend_void_id)objc_msgSend)(path, sel("appendPath:"), dotPath);

        // Stem
        ((msgSend_void_pt)objc_msgSend)(path, sel("moveToPoint:"), CGPointMake(7.0, 6.2));
        ((msgSend_void_pt)objc_msgSend)(path, sel("addLineToPoint:"), CGPointMake(7.0, 10.2));

        ((msgSend_void_id)objc_msgSend)(layer, sel("setFillColor:"), cgClear);
        ((msgSend_void_id)objc_msgSend)(layer, sel("setStrokeColor:"), cgColor);
        ((msgSend_void_double)objc_msgSend)(layer, sel("setLineWidth:"), 1.2);
    }

    id cgPath = ((id (*)(id, SEL))objc_msgSend)(path, sel("CGPath"));
    if (cgPath) ((msgSend_void_id)objc_msgSend)(layer, sel("setPath:"), cgPath);

    ((msgSend_void_rect)objc_msgSend)(layer, sel("setFrame:"), CGRectMake(6, 6, 14, 14));
    return layer;
}

static void handleFloatPan_imp(id self, SEL _cmd, id recognizer) {
    if (!recognizer) return;
    id view = ((id (*)(id, SEL))objc_msgSend)(recognizer, sel("view"));
    if (!view) return;
    id superview = ((id (*)(id, SEL))objc_msgSend)(view, sel("superview"));
    if (!superview) return;
    CGPoint trans = ((msgSend_pt_id)objc_msgSend)(recognizer, sel("translationInView:"), superview);
    CGPoint center = ((msgSend_pt)objc_msgSend)(view, sel("center"));
    center.x += trans.x;
    center.y += trans.y;
    ((msgSend_void_pt)objc_msgSend)(view, sel("setCenter:"), center);
    ((msgSend_void_pt_id)objc_msgSend)(recognizer, sel("setTranslation:inView:"), CGPointMake(0, 0), superview);
}

static void handleMenuPan_imp(id self, SEL _cmd, id recognizer) {
    if (!g_panel || !recognizer) return;
    id superview = ((id (*)(id, SEL))objc_msgSend)(g_panel, sel("superview"));
    if (!superview) return;
    CGPoint trans = ((msgSend_pt_id)objc_msgSend)(recognizer, sel("translationInView:"), superview);
    CGPoint center = ((msgSend_pt)objc_msgSend)(g_panel, sel("center"));
    center.x += trans.x;
    center.y += trans.y;
    ((msgSend_void_pt)objc_msgSend)(g_panel, sel("setCenter:"), center);
    ((msgSend_void_pt_id)objc_msgSend)(recognizer, sel("setTranslation:inView:"), CGPointMake(0, 0), superview);
}

static void toggleMenu_imp(id self, SEL _cmd, id sender) {
    if (!g_panel) return;
    long isHidden = (long)((long (*)(id, SEL))objc_msgSend)(g_panel, sel("isHidden"));
    if (isHidden) {
        ((msgSend_void_long)objc_msgSend)(g_panel, sel("setHidden:"), 0);
        id pSuper = ((id (*)(id, SEL))objc_msgSend)(g_panel, sel("superview"));
        if (pSuper) {
            ((msgSend_void_id)objc_msgSend)(pSuper, sel("bringSubviewToFront:"), g_panel);
        }
    } else {
        ((msgSend_void_long)objc_msgSend)(g_panel, sel("setHidden:"), 1);
    }
}

static void closeMenu_imp(id self, SEL _cmd, id sender) {
    if (!g_panel) return;
    ((msgSend_void_long)objc_msgSend)(g_panel, sel("setHidden:"), 1);
}

static BOOL swIsOn_fallback(id self, SEL _cmd) {
    return YES;
}

static Class g_toggleSwitchCls = Nil;

static BOOL toggleSw_isOn(id self, SEL _cmd) {
    id val = objc_getAssociatedObject(self, "on");
    return (val != NULL);
}

static void toggleSw_setOn(id self, SEL _cmd, BOOL on) {
    objc_setAssociatedObject(self, "on", on ? (id)(uintptr_t)1 : NULL, OBJC_ASSOCIATION_ASSIGN);
}

static dispatch_queue_t getVIPQueue(void) {
    static dispatch_queue_t q = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        q = dispatch_queue_create("com.doggymod.vipqueue", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

static id getSwitchSender(BOOL state) {
    if (!g_toggleSwitchCls) {
        g_toggleSwitchCls = cls("ROSToggleSwitch");
    }
    if (g_toggleSwitchCls) {
        id inst = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)g_toggleSwitchCls, sel("alloc")), sel("init"));
        if (inst) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(inst, sel("setOn:"), state);
            return inst;
        }
    }
    Class sw = cls("UISwitch");
    if (sw) {
        id inst = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)sw, sel("alloc")), sel("init"));
        if (inst) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(inst, sel("setOn:"), state);
            return inst;
        }
    }
    return NULL;
}

static void ensureESPOverlayOnTop(void) {
    id curWin = getActiveWindow();
    if (curWin && g_espOverlay) {
        id espSuper = ((id (*)(id, SEL))objc_msgSend)(g_espOverlay, sel("superview"));
        if (espSuper != curWin) {
            ((msgSend_void_id)objc_msgSend)(curWin, sel("addSubview:"), g_espOverlay);
        }
        ((msgSend_void_id)objc_msgSend)(curWin, sel("bringSubviewToFront:"), g_espOverlay);
        if (g_flyHudView) {
            id hudSuper = ((id (*)(id, SEL))objc_msgSend)(g_flyHudView, sel("superview"));
            if (hudSuper) ((msgSend_void_id)objc_msgSend)(hudSuper, sel("bringSubviewToFront:"), g_flyHudView);
        }
        if (g_aimHudView) {
            id aimSuper = ((id (*)(id, SEL))objc_msgSend)(g_aimHudView, sel("superview"));
            if (aimSuper) ((msgSend_void_id)objc_msgSend)(aimSuper, sel("bringSubviewToFront:"), g_aimHudView);
        }
        if (g_panel) {
            id pSuper = ((id (*)(id, SEL))objc_msgSend)(g_panel, sel("superview"));
            if (pSuper) ((msgSend_void_id)objc_msgSend)(pSuper, sel("bringSubviewToFront:"), g_panel);
        }
        if (g_floatBtn) {
            id fSuper = ((id (*)(id, SEL))objc_msgSend)(g_floatBtn, sel("superview"));
            if (fSuper) ((msgSend_void_id)objc_msgSend)(fSuper, sel("bringSubviewToFront:"), g_floatBtn);
        }
    }
}

static void triggerTweakFeature(const char *selName, const char *swKey, BOOL state) {
    @autoreleasepool {
        Class defsCls = cls("NSUserDefaults");
        if (defsCls) {
            id defs = ((id (*)(id, SEL))objc_msgSend)((id)defsCls, sel("standardUserDefaults"));
            if (defs) {
                Class strCls = cls("NSString");
                id key = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)strCls, sel("alloc")), sel("initWithUTF8String:"), swKey);
                if (key) {
                    ((void (*)(id, SEL, BOOL, id))objc_msgSend)(defs, sel("setBool:forKey:"), state, key);
                    ((id (*)(id, SEL))objc_msgSend)(defs, sel("synchronize"));
                }
            }
        }

        Class nsObj = cls("NSObject");
        SEL fSel = sel(selName);
        if (nsObj) {
            Method m = class_getClassMethod(nsObj, fSel);
            if (!m) m = class_getInstanceMethod(nsObj, fSel);
            if (m) {
                IMP imp = method_getImplementation(m);
                id sender = getSwitchSender(state);
                if (imp && sender) {
                    printf("[FlyMenuUI] Executing %s (state=%d)\n", selName, (int)state);
                    ((void (*)(id, SEL, id))imp)((id)nsObj, fSel, sender);
                    printf("[FlyMenuUI] Completed %s (state=%d)\n", selName, (int)state);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        ensureESPOverlayOnTop();
                    });
                }
            }
        }
    }
}

// 1 Hit Kill VIP Toggle (Button 6)
static void toggleOneHit_imp(id self, SEL _cmd, id sender) {
    Class defsCls = cls("NSUserDefaults");
    if (!defsCls) return;
    id defs = ((id (*)(id, SEL))objc_msgSend)((id)defsCls, sel("standardUserDefaults"));
    if (!defs) return;

    Class strCls = cls("NSString");
    id key = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)strCls, sel("alloc")), sel("initWithUTF8String:"), "sw7");
    if (!key) return;

    BOOL cur = (BOOL)((long (*)(id, SEL, id))objc_msgSend)(defs, sel("boolForKey:"), key);
    BOOL newState = !cur;

    // Immediately save state synchronously so UI updates instantly with zero latency
    ((void (*)(id, SEL, BOOL, id))objc_msgSend)(defs, sel("setBool:forKey:"), newState, key);
    ((id (*)(id, SEL))objc_msgSend)(defs, sel("synchronize"));
    updateRowStates();

    dispatch_async(getVIPQueue(), ^{
        triggerTweakFeature("feature7:", "sw7", newState);
    });

    printf("[FlyMenuUI] 1 Hit Kill VIP toggled -> %s\n", newState ? "ENABLED" : "DISABLED");
}

// Speed Epic VIP Toggle (Button 7)
static void toggleSpeedEpic_imp(id self, SEL _cmd, id sender) {
    Class defsCls = cls("NSUserDefaults");
    if (!defsCls) return;
    id defs = ((id (*)(id, SEL))objc_msgSend)((id)defsCls, sel("standardUserDefaults"));
    if (!defs) return;

    Class strCls = cls("NSString");
    id key = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)strCls, sel("alloc")), sel("initWithUTF8String:"), "sw6");
    if (!key) return;

    BOOL cur = (BOOL)((long (*)(id, SEL, id))objc_msgSend)(defs, sel("boolForKey:"), key);
    BOOL newState = !cur;

    // Immediately save state synchronously so UI updates instantly with zero latency
    ((void (*)(id, SEL, BOOL, id))objc_msgSend)(defs, sel("setBool:forKey:"), newState, key);
    ((id (*)(id, SEL))objc_msgSend)(defs, sel("synchronize"));
    updateRowStates();

    dispatch_async(getVIPQueue(), ^{
        triggerTweakFeature("feature6:", "sw6", newState);
    });

    printf("[FlyMenuUI] Speed Epic VIP toggled -> %s\n", newState ? "ENABLED" : "DISABLED");
}

// No Recoil 100% VIP Toggle (Button 8)
static void toggleNoRecoil_imp(id self, SEL _cmd, id sender) {
    Class defsCls = cls("NSUserDefaults");
    if (!defsCls) return;
    id defs = ((id (*)(id, SEL))objc_msgSend)((id)defsCls, sel("standardUserDefaults"));
    if (!defs) return;

    Class strCls = cls("NSString");
    id key = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)strCls, sel("alloc")), sel("initWithUTF8String:"), "sw2");
    if (!key) return;

    BOOL cur = (BOOL)((long (*)(id, SEL, id))objc_msgSend)(defs, sel("boolForKey:"), key);
    BOOL newState = !cur;

    // Immediately save state synchronously so UI updates instantly with zero latency
    ((void (*)(id, SEL, BOOL, id))objc_msgSend)(defs, sel("setBool:forKey:"), newState, key);
    ((id (*)(id, SEL))objc_msgSend)(defs, sel("synchronize"));
    updateRowStates();

    dispatch_async(getVIPQueue(), ^{
        triggerTweakFeature("feature2:", "sw2", newState);
        triggerTweakFeature("feature4:", "sw4", newState);
    });

    printf("[FlyMenuUI] No Recoil 100%% VIP toggled -> %s\n", newState ? "ENABLED" : "DISABLED");
}

// Wallhack VIP Toggle (Button 9)
static void toggleWallhack_imp(id self, SEL _cmd, id sender) {
    Class defsCls = cls("NSUserDefaults");
    if (!defsCls) return;
    id defs = ((id (*)(id, SEL))objc_msgSend)((id)defsCls, sel("standardUserDefaults"));
    if (!defs) return;

    Class strCls = cls("NSString");
    id key = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)strCls, sel("alloc")), sel("initWithUTF8String:"), "sw1");
    if (!key) return;

    BOOL cur = (BOOL)((long (*)(id, SEL, id))objc_msgSend)(defs, sel("boolForKey:"), key);
    BOOL newState = !cur;

    // Immediately save state synchronously so UI updates instantly with zero latency
    ((void (*)(id, SEL, BOOL, id))objc_msgSend)(defs, sel("setBool:forKey:"), newState, key);
    ((id (*)(id, SEL))objc_msgSend)(defs, sel("synchronize"));
    updateRowStates();

    dispatch_async(getVIPQueue(), ^{
        triggerTweakFeature("feature1:", "sw1", newState);
    });

    printf("[FlyMenuUI] Wallhack VIP toggled -> %s\n", newState ? "ENABLED" : "DISABLED");
}

static void closeInfoModal_imp(id self, SEL _cmd, id sender) {
    if (g_infoModal) {
        id superview = ((id (*)(id, SEL))objc_msgSend)(g_infoModal, sel("superview"));
        if (superview) {
            ((void (*)(id, SEL))objc_msgSend)(g_infoModal, sel("removeFromSuperview"));
        }
        g_infoModal = NULL;
    }
}

static void openTelegramGroup_imp(id self, SEL _cmd, id sender) {
    Class uiApp = cls("UIApplication");
    Class nsUrl = cls("NSURL");
    Class nsStr = cls("NSString");
    if (uiApp && nsUrl && nsStr) {
        id app = ((id (*)(id, SEL))objc_msgSend)((id)uiApp, sel("sharedApplication"));
        id urlStr = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsStr, sel("alloc")), sel("initWithUTF8String:"), "https://t.me/+syJHus_hGxgxZTJl");
        id url = ((id (*)(id, SEL, id))objc_msgSend)((id)nsUrl, sel("URLWithString:"), urlStr);
        if (app && url) {
            ((void (*)(id, SEL, id))objc_msgSend)(app, sel("openURL:"), url);
        }
    }
}

static void openTelegramUser_imp(id self, SEL _cmd, id sender) {
    Class uiApp = cls("UIApplication");
    Class nsUrl = cls("NSURL");
    Class nsStr = cls("NSString");
    if (uiApp && nsUrl && nsStr) {
        id app = ((id (*)(id, SEL))objc_msgSend)((id)uiApp, sel("sharedApplication"));
        id urlStr = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsStr, sel("alloc")), sel("initWithUTF8String:"), "https://t.me/ikhozzzz");
        id url = ((id (*)(id, SEL, id))objc_msgSend)((id)nsUrl, sel("URLWithString:"), urlStr);
        if (app && url) {
            ((void (*)(id, SEL, id))objc_msgSend)(app, sel("openURL:"), url);
        }
    }
}

static void showCustomInfo_imp(id self, SEL _cmd, id sender) {
    Class nsThread = cls("NSThread");
    if (nsThread && !((BOOL (*)(id, SEL))objc_msgSend)((id)nsThread, sel("isMainThread"))) {
        dispatch_async(dispatch_get_main_queue(), ^{
            showCustomInfo_imp(self, _cmd, sender);
        });
        return;
    }

    id win = getActiveWindow();
    if (!win) return;

    if (g_infoModal) {
        id superview = ((id (*)(id, SEL))objc_msgSend)(g_infoModal, sel("superview"));
        if (superview) {
            ((void (*)(id, SEL))objc_msgSend)(g_infoModal, sel("removeFromSuperview"));
        }
        g_infoModal = NULL;
    }

    CGRect winBounds = ((CGRect (*)(id, SEL))objc_msgSend)(win, sel("bounds"));
    double modalW = 340.0;
    double modalH = 250.0;
    if (modalW > winBounds.size.width - 20.0) modalW = winBounds.size.width - 20.0;
    if (modalH > winBounds.size.height - 20.0) modalH = winBounds.size.height - 20.0;
    double modalX = (winBounds.size.width - modalW) * 0.5;
    double modalY = (winBounds.size.height - modalH) * 0.5;
    if (modalX < 10.0) modalX = 10.0;
    if (modalY < 10.0) modalY = 10.0;

    Class uiView = cls("UIView");
    Class uiColor = cls("UIColor");
    Class uiLabel = cls("UILabel");
    Class uiBtn = cls("UIButton");
    Class uiFont = cls("UIFont");
    Class nsStr = cls("NSString");
    Class imgViewCls = cls("UIImageView");
    Class imgCls = cls("UIImage");
    Class nsData = cls("NSData");

    id modal = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)uiView, sel("alloc")), sel("init"));
    if (!modal) return;
    ((msgSend_void_rect)objc_msgSend)(modal, sel("setFrame:"), CGRectMake(modalX, modalY, modalW, modalH));

    if (uiColor) {
        id bg = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.08, 0.08, 0.11, 0.98);
        if (bg) ((msgSend_void_id)objc_msgSend)(modal, sel("setBackgroundColor:"), bg);

        id mLayer = ((id (*)(id, SEL))objc_msgSend)(modal, sel("layer"));
        if (mLayer) {
            ((msgSend_void_double)objc_msgSend)(mLayer, sel("setCornerRadius:"), 14.0);
            ((msgSend_void_double)objc_msgSend)(mLayer, sel("setBorderWidth:"), 1.5);
            id borderC = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.0, 0.60, 1.0, 0.60);
            if (borderC) ((msgSend_void_id)objc_msgSend)(mLayer, sel("setBorderColor:"), ((id (*)(id, SEL))objc_msgSend)(borderC, sel("CGColor")));
            ((msgSend_void_long)objc_msgSend)(mLayer, sel("setMasksToBounds:"), 1);
        }
    }

    // Top Header: Title "ikhozzzz VIP Info"
    if (uiLabel && nsStr) {
        id titleLbl = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)uiLabel, sel("alloc")), sel("init"));
        if (titleLbl) {
            ((msgSend_void_rect)objc_msgSend)(titleLbl, sel("setFrame:"), CGRectMake(14, 10, modalW - 50, 22));
            id tStr = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsStr, sel("alloc")), sel("initWithUTF8String:"), "ikhozzzz VIP Info");
            if (tStr) ((msgSend_void_id)objc_msgSend)(titleLbl, sel("setText:"), tStr);
            if (uiColor) {
                id whiteC = ((id (*)(id, SEL))objc_msgSend)((id)uiColor, sel("whiteColor"));
                if (whiteC) ((msgSend_void_id)objc_msgSend)(titleLbl, sel("setTextColor:"), whiteC);
            }
            if (uiFont) {
                id boldF = ((msgSend_id_double)objc_msgSend)((id)uiFont, sel("boldSystemFontOfSize:"), 15.0);
                if (boldF) ((msgSend_void_id)objc_msgSend)(titleLbl, sel("setFont:"), boldF);
            }
            ((msgSend_void_id)objc_msgSend)(modal, sel("addSubview:"), titleLbl);
        }
    }

    // Close button [✕] top right
    if (uiBtn && nsStr) {
        id closeB = ((msgSend_id_long)objc_msgSend)((id)uiBtn, sel("buttonWithType:"), 0);
        if (closeB) {
            ((msgSend_void_rect)objc_msgSend)(closeB, sel("setFrame:"), CGRectMake(modalW - 34, 6, 28, 28));
            id xStr = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsStr, sel("alloc")), sel("initWithUTF8String:"), "✕");
            if (xStr) ((msgSend_void_id_long)objc_msgSend)(closeB, sel("setTitle:forState:"), xStr, 0);
            if (uiColor) {
                id greyC = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.8, 0.8, 0.85, 1.0);
                if (greyC) ((msgSend_void_id_long)objc_msgSend)(closeB, sel("setTitleColor:forState:"), greyC, 0);
            }
            if (uiFont) {
                id f = ((msgSend_id_double)objc_msgSend)((id)uiFont, sel("boldSystemFontOfSize:"), 16.0);
                id lbl = ((id (*)(id, SEL))objc_msgSend)(closeB, sel("titleLabel"));
                if (lbl && f) ((msgSend_void_id)objc_msgSend)(lbl, sel("setFont:"), f);
            }
            ((msgSend_void_id_sel_long)objc_msgSend)(closeB, sel("addTarget:action:forControlEvents:"), g_uiMgr, sel("closeInfoModal:"), 1 << 6);
            ((msgSend_void_id)objc_msgSend)(modal, sel("addSubview:"), closeB);
        }
    }

    // Left Column: Details & Action Buttons
    if (uiLabel && nsStr) {
        id authorLbl = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)uiLabel, sel("alloc")), sel("init"));
        if (authorLbl) {
            ((msgSend_void_rect)objc_msgSend)(authorLbl, sel("setFrame:"), CGRectMake(14, 38, 175, 18));
            id aStr = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsStr, sel("alloc")), sel("initWithUTF8String:"), "Author: ikhozzzz");
            if (aStr) ((msgSend_void_id)objc_msgSend)(authorLbl, sel("setText:"), aStr);
            if (uiColor) {
                id cyanC = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.0, 0.80, 1.0, 1.0);
                if (cyanC) ((msgSend_void_id)objc_msgSend)(authorLbl, sel("setTextColor:"), cyanC);
            }
            if (uiFont) {
                id f = ((msgSend_id_double)objc_msgSend)((id)uiFont, sel("boldSystemFontOfSize:"), 11.0);
                if (f) ((msgSend_void_id)objc_msgSend)(authorLbl, sel("setFont:"), f);
            }
            ((msgSend_void_id)objc_msgSend)(modal, sel("addSubview:"), authorLbl);
        }

        id tgLbl = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)uiLabel, sel("alloc")), sel("init"));
        if (tgLbl) {
            ((msgSend_void_rect)objc_msgSend)(tgLbl, sel("setFrame:"), CGRectMake(14, 58, 175, 18));
            id tgStr = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsStr, sel("alloc")), sel("initWithUTF8String:"), "Telegram: @ikhozzzz");
            if (tgStr) ((msgSend_void_id)objc_msgSend)(tgLbl, sel("setText:"), tgStr);
            if (uiColor) {
                id greyC = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.70, 0.75, 0.85, 1.0);
                if (greyC) ((msgSend_void_id)objc_msgSend)(tgLbl, sel("setTextColor:"), greyC);
            }
            if (uiFont) {
                id f = ((msgSend_id_double)objc_msgSend)((id)uiFont, sel("systemFontOfSize:"), 10.5);
                if (f) ((msgSend_void_id)objc_msgSend)(tgLbl, sel("setFont:"), f);
            }
            ((msgSend_void_id)objc_msgSend)(modal, sel("addSubview:"), tgLbl);
        }
    }

    // Button 1: "💬 Join Telegram Group"
    if (uiBtn && nsStr) {
        id grpBtn = ((msgSend_id_long)objc_msgSend)((id)uiBtn, sel("buttonWithType:"), 0);
        if (grpBtn) {
            ((msgSend_void_rect)objc_msgSend)(grpBtn, sel("setFrame:"), CGRectMake(14, 84, 160, 32));
            id gTitle = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsStr, sel("alloc")), sel("initWithUTF8String:"), "💬 Join TG Group");
            if (gTitle) ((msgSend_void_id_long)objc_msgSend)(grpBtn, sel("setTitle:forState:"), gTitle, 0);
            if (uiColor) {
                id blueBg = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.0, 0.53, 0.80, 1.0);
                if (blueBg) ((msgSend_void_id)objc_msgSend)(grpBtn, sel("setBackgroundColor:"), blueBg);
                id whiteC = ((id (*)(id, SEL))objc_msgSend)((id)uiColor, sel("whiteColor"));
                if (whiteC) ((msgSend_void_id_long)objc_msgSend)(grpBtn, sel("setTitleColor:forState:"), whiteC, 0);
            }
            id bLayer = ((id (*)(id, SEL))objc_msgSend)(grpBtn, sel("layer"));
            if (bLayer) {
                ((msgSend_void_double)objc_msgSend)(bLayer, sel("setCornerRadius:"), 6.0);
                ((msgSend_void_long)objc_msgSend)(bLayer, sel("setMasksToBounds:"), 1);
            }
            if (uiFont) {
                id f = ((msgSend_id_double)objc_msgSend)((id)uiFont, sel("boldSystemFontOfSize:"), 11.5);
                id lbl = ((id (*)(id, SEL))objc_msgSend)(grpBtn, sel("titleLabel"));
                if (lbl && f) ((msgSend_void_id)objc_msgSend)(lbl, sel("setFont:"), f);
            }
            ((msgSend_void_id_sel_long)objc_msgSend)(grpBtn, sel("addTarget:action:forControlEvents:"), g_uiMgr, sel("openTelegramGroup:"), 1 << 6);
            ((msgSend_void_id)objc_msgSend)(modal, sel("addSubview:"), grpBtn);
        }
    }

    // Button 2: "👤 Telegram @ikhozzzz"
    if (uiBtn && nsStr) {
        id tgBtn = ((msgSend_id_long)objc_msgSend)((id)uiBtn, sel("buttonWithType:"), 0);
        if (tgBtn) {
            ((msgSend_void_rect)objc_msgSend)(tgBtn, sel("setFrame:"), CGRectMake(14, 122, 160, 32));
            id tgTitle = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsStr, sel("alloc")), sel("initWithUTF8String:"), "👤 @ikhozzzz");
            if (tgTitle) ((msgSend_void_id_long)objc_msgSend)(tgBtn, sel("setTitle:forState:"), tgTitle, 0);
            if (uiColor) {
                id darkBlue = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.12, 0.22, 0.35, 1.0);
                if (darkBlue) ((msgSend_void_id)objc_msgSend)(tgBtn, sel("setBackgroundColor:"), darkBlue);
                id whiteC = ((id (*)(id, SEL))objc_msgSend)((id)uiColor, sel("whiteColor"));
                if (whiteC) ((msgSend_void_id_long)objc_msgSend)(tgBtn, sel("setTitleColor:forState:"), whiteC, 0);
            }
            id bLayer = ((id (*)(id, SEL))objc_msgSend)(tgBtn, sel("layer"));
            if (bLayer) {
                ((msgSend_void_double)objc_msgSend)(bLayer, sel("setCornerRadius:"), 6.0);
                ((msgSend_void_long)objc_msgSend)(bLayer, sel("setMasksToBounds:"), 1);
            }
            if (uiFont) {
                id f = ((msgSend_id_double)objc_msgSend)((id)uiFont, sel("boldSystemFontOfSize:"), 11.5);
                id lbl = ((id (*)(id, SEL))objc_msgSend)(tgBtn, sel("titleLabel"));
                if (lbl && f) ((msgSend_void_id)objc_msgSend)(lbl, sel("setFont:"), f);
            }
            ((msgSend_void_id_sel_long)objc_msgSend)(tgBtn, sel("addTarget:action:forControlEvents:"), g_uiMgr, sel("openTelegramUser:"), 1 << 6);
            ((msgSend_void_id)objc_msgSend)(modal, sel("addSubview:"), tgBtn);
        }
    }

    // Button 3: "Close"
    if (uiBtn && nsStr) {
        id okBtn = ((msgSend_id_long)objc_msgSend)((id)uiBtn, sel("buttonWithType:"), 0);
        if (okBtn) {
            ((msgSend_void_rect)objc_msgSend)(okBtn, sel("setFrame:"), CGRectMake(14, 160, 160, 32));
            id okTitle = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsStr, sel("alloc")), sel("initWithUTF8String:"), "Close");
            if (okTitle) ((msgSend_void_id_long)objc_msgSend)(okBtn, sel("setTitle:forState:"), okTitle, 0);
            if (uiColor) {
                id greyBg = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.18, 0.18, 0.22, 1.0);
                if (greyBg) ((msgSend_void_id)objc_msgSend)(okBtn, sel("setBackgroundColor:"), greyBg);
                id whiteC = ((id (*)(id, SEL))objc_msgSend)((id)uiColor, sel("whiteColor"));
                if (whiteC) ((msgSend_void_id_long)objc_msgSend)(okBtn, sel("setTitleColor:forState:"), whiteC, 0);
            }
            id bLayer = ((id (*)(id, SEL))objc_msgSend)(okBtn, sel("layer"));
            if (bLayer) {
                ((msgSend_void_double)objc_msgSend)(bLayer, sel("setCornerRadius:"), 6.0);
                ((msgSend_void_long)objc_msgSend)(bLayer, sel("setMasksToBounds:"), 1);
            }
            if (uiFont) {
                id f = ((msgSend_id_double)objc_msgSend)((id)uiFont, sel("boldSystemFontOfSize:"), 11.5);
                id lbl = ((id (*)(id, SEL))objc_msgSend)(okBtn, sel("titleLabel"));
                if (lbl && f) ((msgSend_void_id)objc_msgSend)(lbl, sel("setFont:"), f);
            }
            ((msgSend_void_id_sel_long)objc_msgSend)(okBtn, sel("addTarget:action:forControlEvents:"), g_uiMgr, sel("closeInfoModal:"), 1 << 6);
            ((msgSend_void_id)objc_msgSend)(modal, sel("addSubview:"), okBtn);
        }
    }

    // Right Column: Donate QR Code Image + Caption
    if (imgViewCls && imgCls) {
        id qrImg = NULL;
        if (nsData && EMBEDDED_DONATE_JPEG_LEN > 0) {
            id imgData = ((id (*)(id, SEL, const void *, unsigned long))objc_msgSend)((id)nsData, sel("dataWithBytes:length:"), EMBEDDED_DONATE_JPEG, (unsigned long)EMBEDDED_DONATE_JPEG_LEN);
            if (imgData) {
                qrImg = ((id (*)(id, SEL, id))objc_msgSend)((id)imgCls, sel("imageWithData:"), imgData);
            }
        }
        if (!qrImg && nsStr) {
            const char *paths[] = {
                "/var/jb/Library/MobileSubstrate/DynamicLibraries/D79oM.bundle/donate.jpeg",
                "/Library/MobileSubstrate/DynamicLibraries/D79oM.bundle/donate.jpeg",
                NULL
            };
            for (int p = 0; paths[p]; p++) {
                id pStr = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsStr, sel("alloc")), sel("initWithUTF8String:"), paths[p]);
                if (pStr) {
                    qrImg = ((id (*)(id, SEL, id))objc_msgSend)((id)imgCls, sel("imageWithContentsOfFile:"), pStr);
                    if (qrImg) break;
                }
            }
        }

        double qrSize = 130.0;
        double qrX = modalW - qrSize - 14.0;
        double qrY = 38.0;

        id qrView = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)imgViewCls, sel("alloc")), sel("init"));
        if (qrView) {
            ((msgSend_void_rect)objc_msgSend)(qrView, sel("setFrame:"), CGRectMake(qrX, qrY, qrSize, qrSize));
            if (qrImg) ((msgSend_void_id)objc_msgSend)(qrView, sel("setImage:"), qrImg);
            ((msgSend_void_long)objc_msgSend)(qrView, sel("setContentMode:"), 1); // AspectFit

            if (uiColor) {
                id whiteC = ((id (*)(id, SEL))objc_msgSend)((id)uiColor, sel("whiteColor"));
                if (whiteC) ((msgSend_void_id)objc_msgSend)(qrView, sel("setBackgroundColor:"), whiteC);
            }

            id qrLayer = ((id (*)(id, SEL))objc_msgSend)(qrView, sel("layer"));
            if (qrLayer) {
                ((msgSend_void_double)objc_msgSend)(qrLayer, sel("setCornerRadius:"), 8.0);
                ((msgSend_void_double)objc_msgSend)(qrLayer, sel("setBorderWidth:"), 1.5);
                if (uiColor) {
                    id bC = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.25, 0.25, 0.35, 1.0);
                    if (bC) ((msgSend_void_id)objc_msgSend)(qrLayer, sel("setBorderColor:"), ((id (*)(id, SEL))objc_msgSend)(bC, sel("CGColor")));
                }
                ((msgSend_void_long)objc_msgSend)(qrLayer, sel("setMasksToBounds:"), 1);
            }
            ((msgSend_void_id)objc_msgSend)(modal, sel("addSubview:"), qrView);
        }

        // QR Caption: "Scan QR to Donate"
        if (uiLabel && nsStr) {
            id capLbl = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)uiLabel, sel("alloc")), sel("init"));
            if (capLbl) {
                ((msgSend_void_rect)objc_msgSend)(capLbl, sel("setFrame:"), CGRectMake(qrX - 5, qrY + qrSize + 6, qrSize + 10, 18));
                id capStr = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsStr, sel("alloc")), sel("initWithUTF8String:"), "Scan QR for Donate");
                if (capStr) ((msgSend_void_id)objc_msgSend)(capLbl, sel("setText:"), capStr);
                ((msgSend_void_long)objc_msgSend)(capLbl, sel("setTextAlignment:"), 1); // Center
                if (uiColor) {
                    id goldC = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.95, 0.80, 0.25, 1.0);
                    if (goldC) ((msgSend_void_id)objc_msgSend)(capLbl, sel("setTextColor:"), goldC);
                }
                if (uiFont) {
                    id f = ((msgSend_id_double)objc_msgSend)((id)uiFont, sel("boldSystemFontOfSize:"), 10.5);
                    if (f) ((msgSend_void_id)objc_msgSend)(capLbl, sel("setFont:"), f);
                }
                ((msgSend_void_id)objc_msgSend)(modal, sel("addSubview:"), capLbl);
            }
        }
    }

    // Add modal to active window
    ((msgSend_void_id)objc_msgSend)(win, sel("addSubview:"), modal);
    ((msgSend_void_id)objc_msgSend)(win, sel("bringSubviewToFront:"), modal);
    g_infoModal = modal;
}

// Update layout of the buttons based on active tab filter
static void updateRowLayout(void) {
    double startY = 84.0;
    double rowH = 38.0;
    double gap = 4.0;
    int visibleIdx = 0;

    for (int i = 0; i < NUM_BUTTONS; i++) {
        id btn = g_coreBtns[i];
        if (!btn) continue;

        BOOL show = YES;
        if (g_selectedTab == 0) {
            // Aim/Combat tab: show Aim (3), Aim Smooth (10), 1 Hit (6), No Recoil (8)
            show = (i == 3 || i == 10 || i == 6 || i == 8);
        } else if (g_selectedTab == 1) {
            // ESP/Vision tab: show ESP (4), Wallhack (9)
            show = (i == 4 || i == 9);
        } else if (g_selectedTab == 2) {
            // Fly / Mobility tab: show Fly, Fly HUD Outside, Up, Down, Speed Epic (indices 0, 11, 1, 2, 7)
            show = (i == 0 || i == 11 || i == 1 || i == 2 || i == 7);
        } else if (g_selectedTab == 3) {
            // Info tab: show Info button (index 5)
            show = (i == 5);
        }

        ((msgSend_void_long)objc_msgSend)(btn, sel("setHidden:"), show ? 0 : 1);
        if (show) {
            CGRect f = CGRectMake(10, startY + visibleIdx * (rowH + gap), 260, rowH);
            ((msgSend_void_rect)objc_msgSend)(btn, sel("setFrame:"), f);
            visibleIdx++;
        }
    }

    if (g_panel) {
        CGRect pFrame = ((msgSend_rect)objc_msgSend)(g_panel, sel("frame"));
        double newH = startY + visibleIdx * (rowH + gap) + 12.0;
        if (newH < 220.0) newH = 220.0;
        pFrame.size.height = newH;
        ((msgSend_void_rect)objc_msgSend)(g_panel, sel("setFrame:"), pFrame);
    }
}

// Handle tab selection
static void selectTab_imp(id self, SEL _cmd, id sender) {
    long tag = (long)((long (*)(id, SEL))objc_msgSend)(sender, sel("tag"));
    if (g_selectedTab == (int)tag) {
        g_selectedTab = -1; // Toggle back to Show All
    } else {
        g_selectedTab = (int)tag;
    }

    if (tag == 3 && g_selectedTab == 3) {
        showCustomInfo_imp(self, _cmd, sender);
    }

    Class uiColor = cls("UIColor");
    id activeBg = uiColor ? ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.83, 0.11, 0.11, 1.0) : NULL;
    id inactiveBg = uiColor ? ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.11, 0.11, 0.15, 1.0) : NULL;
    id whiteColor = uiColor ? ((id (*)(id, SEL))objc_msgSend)((id)uiColor, sel("whiteColor")) : NULL;
    id greyColor = uiColor ? ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.65, 0.65, 0.70, 1.0) : NULL;
    id cgWhite = whiteColor ? ((id (*)(id, SEL))objc_msgSend)(whiteColor, sel("CGColor")) : NULL;
    id cgGrey = greyColor ? ((id (*)(id, SEL))objc_msgSend)(greyColor, sel("CGColor")) : NULL;

    for (int t = 0; t < 4; t++) {
        if (!g_tabBtns[t]) continue;
        BOOL isSel = (g_selectedTab == t);
        if (activeBg && inactiveBg) {
            ((msgSend_void_id)objc_msgSend)(g_tabBtns[t], sel("setBackgroundColor:"), isSel ? activeBg : inactiveBg);
        }
        if (g_tabLabels[t] && whiteColor && greyColor) {
            ((msgSend_void_id)objc_msgSend)(g_tabLabels[t], sel("setTextColor:"), isSel ? whiteColor : greyColor);
        }
        if (g_tabIcons[t] && cgWhite && cgGrey) {
            ((msgSend_void_id)objc_msgSend)(g_tabIcons[t], sel("setStrokeColor:"), isSel ? cgWhite : cgGrey);
        }
    }

    updateRowLayout();
}

// Switch state helper for realistic switch knob + colored pill
static void setSwitchState(int idx, BOOL on, id onPillBg, id offPillBg, id whiteColor, id knobOffColor, id activeBorder, id normalBorder) {
    if (g_rowPills[idx]) {
        ((msgSend_void_id)objc_msgSend)(g_rowPills[idx], sel("setBackgroundColor:"), on ? onPillBg : offPillBg);
    }
    if (g_rowKnobs[idx]) {
        ((msgSend_void_rect)objc_msgSend)(g_rowKnobs[idx], sel("setFrame:"), CGRectMake(on ? 16 : 2, 2, 18, 18));
        if (whiteColor && knobOffColor) {
            ((msgSend_void_id)objc_msgSend)(g_rowKnobs[idx], sel("setBackgroundColor:"), on ? whiteColor : knobOffColor);
        }
    }
    if (g_coreBtns[idx]) {
        id layer = ((id (*)(id, SEL))objc_msgSend)(g_coreBtns[idx], sel("layer"));
        if (layer && activeBorder && normalBorder) {
            id c = ((id (*)(id, SEL))objc_msgSend)(on ? activeBorder : normalBorder, sel("CGColor"));
            ((msgSend_void_id)objc_msgSend)(layer, sel("setBorderColor:"), c);
        }
    }
}

// Update pill colors, knob positions & button card borders based on real core engine state
static void updateRowStates(void) {
    @autoreleasepool {
        Class uiColor = cls("UIColor");
        if (!uiColor) return;

        id whiteColor = ((id (*)(id, SEL))objc_msgSend)((id)uiColor, sel("whiteColor"));
        id offPillBg = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.15, 0.15, 0.18, 1.0);
        id onPillBg = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.83, 0.11, 0.11, 1.0);
        id activeBorder = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.83, 0.11, 0.11, 1.0);
        id normalBorder = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.14, 0.14, 0.18, 1.0);
        id darkBg = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.08, 0.08, 0.11, 1.0);
        id knobOffColor = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.50, 0.50, 0.55, 1.0);

        // Keep native button title text hidden so only our clean UI shows
        for (int i = 0; i < NUM_BUTTONS; i++) {
            id btn = g_coreBtns[i];
            if (btn) {
                id tLbl = ((id (*)(id, SEL))objc_msgSend)(btn, sel("titleLabel"));
                if (tLbl) {
                    ((msgSend_void_double)objc_msgSend)(tLbl, sel("setAlpha:"), 0.0);
                }
                if (darkBg) {
                    ((msgSend_void_id)objc_msgSend)(btn, sel("setBackgroundColor:"), darkBg);
                }
            }
        }

        // Fly State (Button 0)
        BOOL flyOn = NO;
        if (g_coreBtns[0]) {
            id t = ((msgSend_id_long)objc_msgSend)(g_coreBtns[0], sel("titleForState:"), 0);
            const char *s = t ? (const char *)((id (*)(id, SEL))objc_msgSend)(t, sel("UTF8String")) : "";
            if (strstr(s, "ON") != NULL || strstr(s, "STOP") != NULL) {
                flyOn = YES;
            } else if (strstr(s, "OFF") != NULL) {
                flyOn = NO;
            }
        }
        setSwitchState(0, flyOn, onPillBg, offPillBg, whiteColor, knobOffColor, activeBorder, normalBorder);

        // Update on-screen floating Fly HUD button state
        if (g_flyHudToggleBtn) {
            Class nsString = cls("NSString");
            Class uiColor = cls("UIColor");
            if (nsString && uiColor) {
                id flyTitle = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel("alloc")), sel("initWithUTF8String:"), flyOn ? "FLY: ON" : "FLY: OFF");
                ((msgSend_id_id_long)objc_msgSend)(g_flyHudToggleBtn, sel("setTitle:forState:"), flyTitle, 0);
                id btnBg = flyOn ? onPillBg : ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.10, 0.12, 0.18, 0.92);
                if (btnBg) ((msgSend_void_id)objc_msgSend)(g_flyHudToggleBtn, sel("setBackgroundColor:"), btnBg);

                id tLayer = ((id (*)(id, SEL))objc_msgSend)(g_flyHudToggleBtn, sel("layer"));
                if (tLayer) {
                    id brdColor = flyOn ? activeBorder : ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.3, 0.8, 1.0, 0.35);
                    if (brdColor) {
                        id cgBrd = ((id (*)(id, SEL))objc_msgSend)(brdColor, sel("CGColor"));
                        ((msgSend_void_id)objc_msgSend)(tLayer, sel("setBorderColor:"), cgBrd);
                    }
                }
            }
        }

        // Aim State (Button 3)
        static id s_keySwAim = NULL;
        Class strCls = cls("NSString");
        Class defsCls = cls("NSUserDefaults");
        if (strCls && !s_keySwAim) {
            s_keySwAim = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)strCls, sel("alloc")), sel("initWithUTF8String:"), "sw_aimbot");
        }
        BOOL aimOn = NO;
        if (defsCls && s_keySwAim) {
            id defs = ((id (*)(id, SEL))objc_msgSend)((id)defsCls, sel("standardUserDefaults"));
            if (defs) {
                aimOn = (BOOL)((long (*)(id, SEL, id))objc_msgSend)(defs, sel("boolForKey:"), s_keySwAim);
            }
        }
        if (!aimOn && g_coreBtns[3]) {
            id t = ((msgSend_id_long)objc_msgSend)(g_coreBtns[3], sel("titleForState:"), 0);
            const char *s = t ? (const char *)((id (*)(id, SEL))objc_msgSend)(t, sel("UTF8String")) : "";
            if (strstr(s, ":ON") != NULL || strstr(s, ":LOCK") != NULL || strstr(s, ":WAIT") != NULL || strstr(s, ":PAUSED") != NULL || (strstr(s, "AIM") != NULL && strstr(s, "OFF") == NULL && strlen(s) > 3)) {
                aimOn = YES;
            }
        }
        setSwitchState(3, aimOn, onPillBg, offPillBg, whiteColor, knobOffColor, activeBorder, normalBorder);

        // ESP State (Button 4)
        static id s_keySwEsp = NULL;
        if (strCls && !s_keySwEsp) {
            s_keySwEsp = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)strCls, sel("alloc")), sel("initWithUTF8String:"), "sw_esp");
        }
        BOOL espOn = NO;
        if (defsCls && s_keySwEsp) {
            id defs = ((id (*)(id, SEL))objc_msgSend)((id)defsCls, sel("standardUserDefaults"));
            if (defs) {
                espOn = (BOOL)((long (*)(id, SEL, id))objc_msgSend)(defs, sel("boolForKey:"), s_keySwEsp);
            }
        }
        if (!espOn && g_coreBtns[4]) {
            id t = ((msgSend_id_long)objc_msgSend)(g_coreBtns[4], sel("titleForState:"), 0);
            const char *s = t ? (const char *)((id (*)(id, SEL))objc_msgSend)(t, sel("UTF8String")) : "";
            if (strstr(s, ":ON") != NULL || strstr(s, ":WAIT") != NULL || strstr(s, ":PAUSED") != NULL || (strstr(s, "ESP") != NULL && strstr(s, "OFF") == NULL && strlen(s) > 3)) {
                espOn = YES;
            }
        }
        setSwitchState(4, espOn, onPillBg, offPillBg, whiteColor, knobOffColor, activeBorder, normalBorder);

        // Info button (Button 5)
        if (g_rowPills[5]) {
            ((msgSend_void_id)objc_msgSend)(g_rowPills[5], sel("setBackgroundColor:"), offPillBg);
        }

        static id s_keySw7 = NULL;
        static id s_keySw6 = NULL;
        static id s_keySw2 = NULL;
        static id s_keySw1 = NULL;
        if (strCls) {
            if (!s_keySw7) s_keySw7 = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)strCls, sel("alloc")), sel("initWithUTF8String:"), "sw7");
            if (!s_keySw6) s_keySw6 = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)strCls, sel("alloc")), sel("initWithUTF8String:"), "sw6");
            if (!s_keySw2) s_keySw2 = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)strCls, sel("alloc")), sel("initWithUTF8String:"), "sw2");
            if (!s_keySw1) s_keySw1 = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)strCls, sel("alloc")), sel("initWithUTF8String:"), "sw1");
        }

        // 1 Hit Kill VIP (Button 6)
        BOOL oneHitOn = NO;
        if (defsCls && s_keySw7) {
            id defs = ((id (*)(id, SEL))objc_msgSend)((id)defsCls, sel("standardUserDefaults"));
            if (defs) {
                oneHitOn = (BOOL)((long (*)(id, SEL, id))objc_msgSend)(defs, sel("boolForKey:"), s_keySw7);
            }
        }
        setSwitchState(6, oneHitOn, onPillBg, offPillBg, whiteColor, knobOffColor, activeBorder, normalBorder);

        // Speed Epic VIP (Button 7)
        BOOL speedOn = NO;
        if (defsCls && s_keySw6) {
            id defs = ((id (*)(id, SEL))objc_msgSend)((id)defsCls, sel("standardUserDefaults"));
            if (defs) {
                speedOn = (BOOL)((long (*)(id, SEL, id))objc_msgSend)(defs, sel("boolForKey:"), s_keySw6);
            }
        }
        setSwitchState(7, speedOn, onPillBg, offPillBg, whiteColor, knobOffColor, activeBorder, normalBorder);

        // No Recoil 100% VIP (Button 8)
        BOOL recoilOn = NO;
        if (defsCls && s_keySw2) {
            id defs = ((id (*)(id, SEL))objc_msgSend)((id)defsCls, sel("standardUserDefaults"));
            if (defs) {
                recoilOn = (BOOL)((long (*)(id, SEL, id))objc_msgSend)(defs, sel("boolForKey:"), s_keySw2);
            }
        }
        setSwitchState(8, recoilOn, onPillBg, offPillBg, whiteColor, knobOffColor, activeBorder, normalBorder);

        // Wallhack VIP (Button 9)
        BOOL wallhackOn = NO;
        if (defsCls && s_keySw1) {
            id defs = ((id (*)(id, SEL))objc_msgSend)((id)defsCls, sel("standardUserDefaults"));
            if (defs) {
                wallhackOn = (BOOL)((long (*)(id, SEL, id))objc_msgSend)(defs, sel("boolForKey:"), s_keySw1);
            }
        }
        setSwitchState(9, wallhackOn, onPillBg, offPillBg, whiteColor, knobOffColor, activeBorder, normalBorder);

        // Aim Smooth 100% Auto (Button 10)
        static id s_keyAimSmooth = NULL;
        if (strCls && !s_keyAimSmooth) {
            s_keyAimSmooth = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)strCls, sel("alloc")), sel("initWithUTF8String:"), "sw_aimsmooth");
        }
        BOOL aimSmoothOn = NO;
        if (defsCls && s_keyAimSmooth) {
            id defs = ((id (*)(id, SEL))objc_msgSend)((id)defsCls, sel("standardUserDefaults"));
            if (defs) {
                aimSmoothOn = (BOOL)((long (*)(id, SEL, id))objc_msgSend)(defs, sel("boolForKey:"), s_keyAimSmooth);
            }
        }
        setSwitchState(10, aimSmoothOn, onPillBg, offPillBg, whiteColor, knobOffColor, activeBorder, normalBorder);

        // Update on-screen floating Aim Smooth HUD button state
        if (g_aimHudToggleBtn) {
            Class nsString = cls("NSString");
            Class uiColor = cls("UIColor");
            if (nsString && uiColor) {
                int gunHolding = checkPlayerHoldingGun();
                // When holding a gun, auto activate; when unarmed/hands, auto deactivate
                BOOL aimActive = aimSmoothOn && (gunHolding != 0);
                const char *aimText = "AIM: OFF";
                if (aimSmoothOn) {
                    if (gunHolding == 1) {
                        aimText = "AIM: ON";
                    } else if (gunHolding == 0) {
                        aimText = "AIM: OFF";
                    } else {
                        aimText = "AIM: ON";
                    }
                }
                id aimTitle = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel("alloc")), sel("initWithUTF8String:"), aimText);
                ((msgSend_id_id_long)objc_msgSend)(g_aimHudToggleBtn, sel("setTitle:forState:"), aimTitle, 0);

                id btnBg = aimActive ? onPillBg : ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.10, 0.12, 0.18, 0.92);
                if (btnBg) ((msgSend_void_id)objc_msgSend)(g_aimHudToggleBtn, sel("setBackgroundColor:"), btnBg);

                id tLayer = ((id (*)(id, SEL))objc_msgSend)(g_aimHudToggleBtn, sel("layer"));
                if (tLayer) {
                    id brdColor = aimActive ? activeBorder : ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.3, 0.8, 1.0, 0.35);
                    if (brdColor) {
                        id cgBrd = ((id (*)(id, SEL))objc_msgSend)(brdColor, sel("CGColor"));
                        ((msgSend_void_id)objc_msgSend)(tLayer, sel("setBorderColor:"), cgBrd);
                    }
                }
            }
        }

        // Fly HUD Outside Screen (Button 11)
        static id s_keyFlyHud = NULL;
        if (strCls && !s_keyFlyHud) {
            s_keyFlyHud = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)strCls, sel("alloc")), sel("initWithUTF8String:"), "sw_flyhud");
        }
        BOOL flyHudOn = YES;
        if (defsCls && s_keyFlyHud) {
            id defs = ((id (*)(id, SEL))objc_msgSend)((id)defsCls, sel("standardUserDefaults"));
            if (defs) {
                id val = ((id (*)(id, SEL, id))objc_msgSend)(defs, sel("objectForKey:"), s_keyFlyHud);
                if (val) {
                    flyHudOn = (BOOL)((long (*)(id, SEL, id))objc_msgSend)(defs, sel("boolForKey:"), s_keyFlyHud);
                }
            }
        }
        setSwitchState(11, flyHudOn, onPillBg, offPillBg, whiteColor, knobOffColor, activeBorder, normalBorder);

        if (g_flyHudView) {
            ((msgSend_void_long)objc_msgSend)(g_flyHudView, sel("setHidden:"), flyHudOn ? 0 : 1);
        }
    }
}

static void createFloatingLogoButton(id win) {
    if (g_floatBtn || !win) return;

    Class uiBtn = cls("UIButton");
    if (!uiBtn) return;
    id floatBtn = ((msgSend_id_long)objc_msgSend)((id)uiBtn, sel("buttonWithType:"), 0);
    if (!floatBtn) return;

    ((msgSend_void_rect)objc_msgSend)(floatBtn, sel("setFrame:"), CGRectMake(20, 100, 54, 54));

    Class uiColor = cls("UIColor");
    if (uiColor) {
        id bgColor = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.06, 0.06, 0.08, 0.96);
        if (bgColor) {
            ((msgSend_void_id)objc_msgSend)(floatBtn, sel("setBackgroundColor:"), bgColor);
        }
        id redColor = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.83, 0.11, 0.11, 1.0);
        id layer = ((id (*)(id, SEL))objc_msgSend)(floatBtn, sel("layer"));
        if (layer) {
            ((msgSend_void_double)objc_msgSend)(layer, sel("setCornerRadius:"), 27.0);
            ((msgSend_void_double)objc_msgSend)(layer, sel("setBorderWidth:"), 2.5);
            if (redColor) {
                id cgBorder = ((id (*)(id, SEL))objc_msgSend)(redColor, sel("CGColor"));
                ((msgSend_void_id)objc_msgSend)(layer, sel("setBorderColor:"), cgBorder);
            }
            ((msgSend_void_long)objc_msgSend)(layer, sel("setMasksToBounds:"), 1);
        }
    }

    // Try loading header.png (with 100% reliable embedded fallback)
    id logoImg = loadLogoImage();
    if (logoImg) {
        ((msgSend_id_id_long)objc_msgSend)(floatBtn, sel("setImage:forState:"), logoImg, 0);
        id imgView = ((id (*)(id, SEL))objc_msgSend)(floatBtn, sel("imageView"));
        if (imgView) {
            ((msgSend_void_long)objc_msgSend)(imgView, sel("setContentMode:"), 1); // AspectFit
            id imgLayer = ((id (*)(id, SEL))objc_msgSend)(imgView, sel("layer"));
            if (imgLayer) {
                ((msgSend_void_double)objc_msgSend)(imgLayer, sel("setCornerRadius:"), 27.0);
                ((msgSend_void_long)objc_msgSend)(imgLayer, sel("setMasksToBounds:"), 1);
            }
        }
    } else {
        Class nsString = cls("NSString");
        if (uiColor && nsString) {
            id redColor = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.83, 0.11, 0.11, 1.0);
            id txt = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "VIP\nMOD");
            ((msgSend_id_id_long)objc_msgSend)(floatBtn, sel("setTitle:forState:"), txt, 0);
            ((msgSend_id_id_long)objc_msgSend)(floatBtn, sel("setTitleColor:forState:"), redColor, 0);
            id lbl = ((id (*)(id, SEL))objc_msgSend)(floatBtn, sel("titleLabel"));
            if (lbl) {
                Class uiFont = cls("UIFont");
                if (uiFont) {
                    id font = ((msgSend_id_double)objc_msgSend)((id)uiFont, sel("boldSystemFontOfSize:"), 11.0);
                    if (font) ((msgSend_void_id)objc_msgSend)(lbl, sel("setFont:"), font);
                }
                ((msgSend_void_long)objc_msgSend)(lbl, sel("setTextAlignment:"), 1);
                ((msgSend_void_long)objc_msgSend)(lbl, sel("setNumberOfLines:"), 2);
            }
        }
    }

    // Tap action
    ((msgSend_void_id_sel_long)objc_msgSend)(floatBtn, sel("addTarget:action:forControlEvents:"), g_uiMgr, sel("toggleMenu:"), 1 << 6);

    // Pan drag gesture
    Class panCls = cls("UIPanGestureRecognizer");
    if (panCls) {
        id floatPan = ((id (*)(id, SEL, id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)panCls, sel("alloc")), sel("initWithTarget:action:"), g_uiMgr, sel("handleFloatPan:"));
        if (floatPan) {
            ((msgSend_void_id)objc_msgSend)(floatBtn, sel("addGestureRecognizer:"), floatPan);
        }
    }

    ((msgSend_void_id)objc_msgSend)(win, sel("addSubview:"), floatBtn);
    ((msgSend_void_id)objc_msgSend)(win, sel("bringSubviewToFront:"), floatBtn);

    g_floatBtn = floatBtn;
    printf("[FlyMenuUI] Floating Logo Button created on UIWindow\n");
}

static void ensureFloatingButtonOnWindow(id win) {
    if (!win) return;
    if (!g_floatBtn) {
        createFloatingLogoButton(win);
        return;
    }
    id curSuper = ((id (*)(id, SEL))objc_msgSend)(g_floatBtn, sel("superview"));
    if (!curSuper) {
        ((msgSend_void_id)objc_msgSend)(win, sel("addSubview:"), g_floatBtn);
        ((msgSend_void_id)objc_msgSend)(win, sel("bringSubviewToFront:"), g_floatBtn);
    }
}

static void createFloatingFlyHUD(id win) {
    if (g_flyHudView || !win) return;

    Class uiView = cls("UIView");
    Class uiBtn = cls("UIButton");
    Class uiColor = cls("UIColor");
    Class uiFont = cls("UIFont");
    Class nsString = cls("NSString");
    Class panCls = cls("UIPanGestureRecognizer");
    if (!uiView || !uiBtn || !uiColor || !nsString) return;

    // Outer container view: 172 x 38 pill
    id hudView = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)uiView, sel("alloc")), sel("init"));
    if (!hudView) return;

    ((msgSend_void_rect)objc_msgSend)(hudView, sel("setFrame:"), CGRectMake(20, 165, 172, 38));
    ((msgSend_void_long)objc_msgSend)(hudView, sel("setUserInteractionEnabled:"), 1);

    id hudBg = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.05, 0.07, 0.11, 0.88);
    if (hudBg) ((msgSend_void_id)objc_msgSend)(hudView, sel("setBackgroundColor:"), hudBg);

    id hudLayer = ((id (*)(id, SEL))objc_msgSend)(hudView, sel("layer"));
    if (hudLayer) {
        ((msgSend_void_double)objc_msgSend)(hudLayer, sel("setCornerRadius:"), 19.0);
        ((msgSend_void_double)objc_msgSend)(hudLayer, sel("setBorderWidth:"), 1.5);
        id bColor = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.20, 0.70, 0.90, 0.45);
        if (bColor) {
            id cgB = ((id (*)(id, SEL))objc_msgSend)(bColor, sel("CGColor"));
            ((msgSend_void_id)objc_msgSend)(hudLayer, sel("setBorderColor:"), cgB);
        }
        ((msgSend_void_long)objc_msgSend)(hudLayer, sel("setMasksToBounds:"), 1);
    }

    // 1. Fly Toggle Button (frame: 4, 4, 96, 30)
    id toggleBtn = ((msgSend_id_long)objc_msgSend)((id)uiBtn, sel("buttonWithType:"), 0);
    if (toggleBtn) {
        ((msgSend_void_rect)objc_msgSend)(toggleBtn, sel("setFrame:"), CGRectMake(4, 4, 96, 30));
        id defBg = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.10, 0.12, 0.18, 0.92);
        if (defBg) ((msgSend_void_id)objc_msgSend)(toggleBtn, sel("setBackgroundColor:"), defBg);

        id tLayer = ((id (*)(id, SEL))objc_msgSend)(toggleBtn, sel("layer"));
        if (tLayer) {
            ((msgSend_void_double)objc_msgSend)(tLayer, sel("setCornerRadius:"), 15.0);
            ((msgSend_void_double)objc_msgSend)(tLayer, sel("setBorderWidth:"), 1.0);
            id tBorder = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.3, 0.8, 1.0, 0.35);
            if (tBorder) {
                id cgTB = ((id (*)(id, SEL))objc_msgSend)(tBorder, sel("CGColor"));
                ((msgSend_void_id)objc_msgSend)(tLayer, sel("setBorderColor:"), cgTB);
            }
            ((msgSend_void_long)objc_msgSend)(tLayer, sel("setMasksToBounds:"), 1);
        }

        id tTitle = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "FLY: OFF");
        id whiteColor = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 1.0, 1.0, 1.0, 1.0);
        ((msgSend_id_id_long)objc_msgSend)(toggleBtn, sel("setTitle:forState:"), tTitle, 0);
        ((msgSend_id_id_long)objc_msgSend)(toggleBtn, sel("setTitleColor:forState:"), whiteColor, 0);

        id lbl = ((id (*)(id, SEL))objc_msgSend)(toggleBtn, sel("titleLabel"));
        if (lbl && uiFont) {
            id font = ((msgSend_id_double)objc_msgSend)((id)uiFont, sel("boldSystemFontOfSize:"), 11.5);
            if (font) ((msgSend_void_id)objc_msgSend)(lbl, sel("setFont:"), font);
        }

        ((msgSend_void_id_sel_long)objc_msgSend)(toggleBtn, sel("addTarget:action:forControlEvents:"), g_uiMgr, sel("onFlyHudToggle:"), 1 << 6);
        ((msgSend_void_id)objc_msgSend)(hudView, sel("addSubview:"), toggleBtn);
        g_flyHudToggleBtn = toggleBtn;
    }

    // 2. Up Button (frame: 104, 4, 30, 30)
    id upBtn = ((msgSend_id_long)objc_msgSend)((id)uiBtn, sel("buttonWithType:"), 0);
    if (upBtn) {
        ((msgSend_void_rect)objc_msgSend)(upBtn, sel("setFrame:"), CGRectMake(104, 4, 30, 30));
        id upBg = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.12, 0.16, 0.24, 0.92);
        if (upBg) ((msgSend_void_id)objc_msgSend)(upBtn, sel("setBackgroundColor:"), upBg);

        id uLayer = ((id (*)(id, SEL))objc_msgSend)(upBtn, sel("layer"));
        if (uLayer) {
            ((msgSend_void_double)objc_msgSend)(uLayer, sel("setCornerRadius:"), 15.0);
            ((msgSend_void_double)objc_msgSend)(uLayer, sel("setBorderWidth:"), 1.0);
            id uBorder = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.2, 0.7, 1.0, 0.4);
            if (uBorder) {
                id cgUB = ((id (*)(id, SEL))objc_msgSend)(uBorder, sel("CGColor"));
                ((msgSend_void_id)objc_msgSend)(uLayer, sel("setBorderColor:"), cgUB);
            }
            ((msgSend_void_long)objc_msgSend)(uLayer, sel("setMasksToBounds:"), 1);
        }

        id uTitle = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "▲");
        id cyanColor = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.25, 0.85, 1.0, 1.0);
        ((msgSend_id_id_long)objc_msgSend)(upBtn, sel("setTitle:forState:"), uTitle, 0);
        ((msgSend_id_id_long)objc_msgSend)(upBtn, sel("setTitleColor:forState:"), cyanColor, 0);

        id uLbl = ((id (*)(id, SEL))objc_msgSend)(upBtn, sel("titleLabel"));
        if (uLbl && uiFont) {
            id font = ((msgSend_id_double)objc_msgSend)((id)uiFont, sel("boldSystemFontOfSize:"), 13.0);
            if (font) ((msgSend_void_id)objc_msgSend)(uLbl, sel("setFont:"), font);
        }

        ((msgSend_void_id_sel_long)objc_msgSend)(upBtn, sel("addTarget:action:forControlEvents:"), g_uiMgr, sel("onFlyHudUpStart:"), 1 << 0 /* TouchDown */);
        ((msgSend_void_id_sel_long)objc_msgSend)(upBtn, sel("addTarget:action:forControlEvents:"), g_uiMgr, sel("onFlyHudLiftStop:"), (1 << 6) | (1 << 7) | (1 << 8) /* TouchUp/Cancel */);
        ((msgSend_void_id)objc_msgSend)(hudView, sel("addSubview:"), upBtn);
        g_flyHudUpBtn = upBtn;
    }

    // 3. Down Button (frame: 138, 4, 30, 30)
    id downBtn = ((msgSend_id_long)objc_msgSend)((id)uiBtn, sel("buttonWithType:"), 0);
    if (downBtn) {
        ((msgSend_void_rect)objc_msgSend)(downBtn, sel("setFrame:"), CGRectMake(138, 4, 30, 30));
        id downBg = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.12, 0.16, 0.24, 0.92);
        if (downBg) ((msgSend_void_id)objc_msgSend)(downBtn, sel("setBackgroundColor:"), downBg);

        id dLayer = ((id (*)(id, SEL))objc_msgSend)(downBtn, sel("layer"));
        if (dLayer) {
            ((msgSend_void_double)objc_msgSend)(dLayer, sel("setCornerRadius:"), 15.0);
            ((msgSend_void_double)objc_msgSend)(dLayer, sel("setBorderWidth:"), 1.0);
            id dBorder = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.2, 0.7, 1.0, 0.4);
            if (dBorder) {
                id cgDB = ((id (*)(id, SEL))objc_msgSend)(dBorder, sel("CGColor"));
                ((msgSend_void_id)objc_msgSend)(dLayer, sel("setBorderColor:"), cgDB);
            }
            ((msgSend_void_long)objc_msgSend)(dLayer, sel("setMasksToBounds:"), 1);
        }

        id dTitle = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "▼");
        id cyanColor = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.25, 0.85, 1.0, 1.0);
        ((msgSend_id_id_long)objc_msgSend)(downBtn, sel("setTitle:forState:"), dTitle, 0);
        ((msgSend_id_id_long)objc_msgSend)(downBtn, sel("setTitleColor:forState:"), cyanColor, 0);

        id dLbl = ((id (*)(id, SEL))objc_msgSend)(downBtn, sel("titleLabel"));
        if (dLbl && uiFont) {
            id font = ((msgSend_id_double)objc_msgSend)((id)uiFont, sel("boldSystemFontOfSize:"), 13.0);
            if (font) ((msgSend_void_id)objc_msgSend)(dLbl, sel("setFont:"), font);
        }

        ((msgSend_void_id_sel_long)objc_msgSend)(downBtn, sel("addTarget:action:forControlEvents:"), g_uiMgr, sel("onFlyHudDownStart:"), 1 << 0 /* TouchDown */);
        ((msgSend_void_id_sel_long)objc_msgSend)(downBtn, sel("addTarget:action:forControlEvents:"), g_uiMgr, sel("onFlyHudLiftStop:"), (1 << 6) | (1 << 7) | (1 << 8) /* TouchUp/Cancel */);
        ((msgSend_void_id)objc_msgSend)(hudView, sel("addSubview:"), downBtn);
        g_flyHudDownBtn = downBtn;
    }

    // Pan drag gesture to move the Fly HUD anywhere on screen
    if (panCls) {
        id hudPan = ((id (*)(id, SEL, id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)panCls, sel("alloc")), sel("initWithTarget:action:"), g_uiMgr, sel("handleFloatPan:"));
        if (hudPan) {
            ((msgSend_void_id)objc_msgSend)(hudView, sel("addGestureRecognizer:"), hudPan);
        }
    }

    ((msgSend_void_id)objc_msgSend)(win, sel("addSubview:"), hudView);
    ((msgSend_void_id)objc_msgSend)(win, sel("bringSubviewToFront:"), hudView);

    g_flyHudView = hudView;
    printf("[FlyMenuUI] On-screen Floating Fly HUD created on UIWindow\n");
}

static void ensureFloatingFlyHUD(id win) {
    if (!win) return;
    if (!g_flyHudView) {
        createFloatingFlyHUD(win);
    }
    if (g_flyHudView) {
        id curSuper = ((id (*)(id, SEL))objc_msgSend)(g_flyHudView, sel("superview"));
        if (!curSuper) {
            ((msgSend_void_id)objc_msgSend)(win, sel("addSubview:"), g_flyHudView);
            ((msgSend_void_id)objc_msgSend)(win, sel("bringSubviewToFront:"), g_flyHudView);
        }
        Class defsCls = cls("NSUserDefaults");
        if (defsCls) {
            id defs = ((id (*)(id, SEL))objc_msgSend)((id)defsCls, sel("standardUserDefaults"));
            if (defs) {
                Class strCls = cls("NSString");
                if (strCls) {
                    id key = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)strCls, sel("alloc")), sel("initWithUTF8String:"), "sw_flyhud");
                    if (key) {
                        id val = ((id (*)(id, SEL, id))objc_msgSend)(defs, sel("objectForKey:"), key);
                        if (val) {
                            BOOL enabled = (BOOL)((long (*)(id, SEL, id))objc_msgSend)(defs, sel("boolForKey:"), key);
                            ((msgSend_void_long)objc_msgSend)(g_flyHudView, sel("setHidden:"), enabled ? 0 : 1);
                        }
                    }
                }
            }
        }
    }
}

// Queries Python combat engine to check if avatar is currently holding a firearm (1) vs bare hands (0)
static int checkPlayerHoldingGun(void) {
    uint32_t count = _dyld_image_count();
    intptr_t coreSlide = 0;
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "FlyMenu_core")) {
            coreSlide = _dyld_get_image_vmaddr_slide(i);
            break;
        }
    }
    if (!coreSlide) return -1;
    uint8_t *pCombatReady = (uint8_t *)(coreSlide + 0xc160);
    if (!pCombatReady || *pCombatReady != 1) return -1;
    void **pCombatDict = (void **)(coreSlide + 0xc168);
    if (!pCombatDict || !(*pCombatDict)) return -1;
    void **pPyGILStateEnsure = (void **)(coreSlide + 0xc0f0);
    void **pPyGILStateRelease = (void **)(coreSlide + 0xc118);
    void **pPyRunString = (void **)(coreSlide + 0xc138);
    void **pPyStringAsString = (void **)(coreSlide + 0xc150);
    if (!pPyGILStateEnsure || !*pPyGILStateEnsure || !pPyGILStateRelease || !*pPyGILStateRelease || !pPyRunString || !*pPyRunString) return -1;

    int (*PyGILState_Ensure)(void) = (int (*)(void))*pPyGILStateEnsure;
    void (*PyGILState_Release)(int) = (void (*)(int))*pPyGILStateRelease;
    void *(*PyRun_String)(const char *, int, void *, void *) = (void *(*)(const char *, int, void *, void *))*pPyRunString;
    char *(*PyString_AsString)(void *) = pPyStringAsString ? (char *(*)(void *))*pPyStringAsString : NULL;

    int gstate = PyGILState_Ensure();
    int hasGun = 0;
    void *dict = *pCombatDict;
    if (dict) {
        void *res = PyRun_String("str(is_holding_gun())", 258 /* Py_eval_input */, dict, dict);
        if (res && PyString_AsString) {
            char *s = PyString_AsString(res);
            if (s && s[0] == '1') {
                hasGun = 1;
            }
        }
    }
    PyGILState_Release(gstate);
    return hasGun;
}

static void createFloatingAimHUD(id win) {
    if (g_aimHudView || !win) return;

    Class uiView = cls("UIView");
    Class uiBtn = cls("UIButton");
    Class uiColor = cls("UIColor");
    Class uiFont = cls("UIFont");
    Class nsString = cls("NSString");
    Class panCls = cls("UIPanGestureRecognizer");
    if (!uiView || !uiBtn || !uiColor || !nsString) return;

    // Outer container view: 110 x 38 pill positioned cleanly on screen
    id hudView = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)uiView, sel("alloc")), sel("init"));
    if (!hudView) return;

    ((msgSend_void_rect)objc_msgSend)(hudView, sel("setFrame:"), CGRectMake(20, 210, 110, 38));
    ((msgSend_void_long)objc_msgSend)(hudView, sel("setUserInteractionEnabled:"), 1);

    id hudBg = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.05, 0.07, 0.11, 0.88);
    if (hudBg) ((msgSend_void_id)objc_msgSend)(hudView, sel("setBackgroundColor:"), hudBg);

    id hudLayer = ((id (*)(id, SEL))objc_msgSend)(hudView, sel("layer"));
    if (hudLayer) {
        ((msgSend_void_double)objc_msgSend)(hudLayer, sel("setCornerRadius:"), 19.0);
        ((msgSend_void_double)objc_msgSend)(hudLayer, sel("setBorderWidth:"), 1.5);
        id bColor = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.20, 0.70, 0.90, 0.45);
        if (bColor) {
            id cgB = ((id (*)(id, SEL))objc_msgSend)(bColor, sel("CGColor"));
            ((msgSend_void_id)objc_msgSend)(hudLayer, sel("setBorderColor:"), cgB);
        }
        ((msgSend_void_long)objc_msgSend)(hudLayer, sel("setMasksToBounds:"), 1);
    }

    // Aim Smooth Toggle Button (frame: 4, 4, 102, 30)
    id toggleBtn = ((msgSend_id_long)objc_msgSend)((id)uiBtn, sel("buttonWithType:"), 0);
    if (toggleBtn) {
        ((msgSend_void_rect)objc_msgSend)(toggleBtn, sel("setFrame:"), CGRectMake(4, 4, 102, 30));
        id defBg = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.10, 0.12, 0.18, 0.92);
        if (defBg) ((msgSend_void_id)objc_msgSend)(toggleBtn, sel("setBackgroundColor:"), defBg);

        id tLayer = ((id (*)(id, SEL))objc_msgSend)(toggleBtn, sel("layer"));
        if (tLayer) {
            ((msgSend_void_double)objc_msgSend)(tLayer, sel("setCornerRadius:"), 15.0);
            ((msgSend_void_double)objc_msgSend)(tLayer, sel("setBorderWidth:"), 1.0);
            id tBorder = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.3, 0.8, 1.0, 0.35);
            if (tBorder) {
                id cgTB = ((id (*)(id, SEL))objc_msgSend)(tBorder, sel("CGColor"));
                ((msgSend_void_id)objc_msgSend)(tLayer, sel("setBorderColor:"), cgTB);
            }
            ((msgSend_void_long)objc_msgSend)(tLayer, sel("setMasksToBounds:"), 1);
        }

        id tTitle = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "AIM: OFF");
        id whiteColor = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 1.0, 1.0, 1.0, 1.0);
        ((msgSend_id_id_long)objc_msgSend)(toggleBtn, sel("setTitle:forState:"), tTitle, 0);
        ((msgSend_id_id_long)objc_msgSend)(toggleBtn, sel("setTitleColor:forState:"), whiteColor, 0);

        id lbl = ((id (*)(id, SEL))objc_msgSend)(toggleBtn, sel("titleLabel"));
        if (lbl && uiFont) {
            id font = ((msgSend_id_double)objc_msgSend)((id)uiFont, sel("boldSystemFontOfSize:"), 11.0);
            if (font) ((msgSend_void_id)objc_msgSend)(lbl, sel("setFont:"), font);
        }

        ((msgSend_void_id_sel_long)objc_msgSend)(toggleBtn, sel("addTarget:action:forControlEvents:"), g_uiMgr, sel("toggleAimSmooth:"), 1 << 6);
        ((msgSend_void_id)objc_msgSend)(hudView, sel("addSubview:"), toggleBtn);
        g_aimHudToggleBtn = toggleBtn;
    }

    // Pan drag gesture to move the Aim HUD anywhere on screen
    if (panCls) {
        id hudPan = ((id (*)(id, SEL, id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)panCls, sel("alloc")), sel("initWithTarget:action:"), g_uiMgr, sel("handleFloatPan:"));
        if (hudPan) {
            ((msgSend_void_id)objc_msgSend)(hudView, sel("addGestureRecognizer:"), hudPan);
        }
    }

    ((msgSend_void_id)objc_msgSend)(win, sel("addSubview:"), hudView);
    ((msgSend_void_id)objc_msgSend)(win, sel("bringSubviewToFront:"), hudView);

    g_aimHudView = hudView;
    printf("[FlyMenuUI] On-screen Floating Aim HUD created on UIWindow\n");
}

static void ensureFloatingAimHUD(id win) {
    if (!win) return;
    if (!g_aimHudView) {
        createFloatingAimHUD(win);
    }
    if (g_aimHudView) {
        id curSuper = ((id (*)(id, SEL))objc_msgSend)(g_aimHudView, sel("superview"));
        if (!curSuper) {
            ((msgSend_void_id)objc_msgSend)(win, sel("addSubview:"), g_aimHudView);
            ((msgSend_void_id)objc_msgSend)(win, sel("bringSubviewToFront:"), g_aimHudView);
        }
    }
}

static void setupMenuUI(id win, id panel) {
    if (!panel || !win) return;
    long tag = (long)((long (*)(id, SEL))objc_msgSend)(panel, sel("tag"));
    if (tag == 0x777) return;
    ((msgSend_void_long)objc_msgSend)(panel, sel("setTag:"), 0x777);

    // 1. Initially hide menu by default
    ((msgSend_void_long)objc_msgSend)(panel, sel("setHidden:"), 1);

    // Reset VIP switch preferences safely here on main thread
    Class defsCls = cls("NSUserDefaults");
    if (defsCls) {
        id defs = ((id (*)(id, SEL))objc_msgSend)((id)defsCls, sel("standardUserDefaults"));
        if (defs) {
            Class strCls = cls("NSString");
            if (strCls) {
                const char *resetKeys[] = {"sw1", "sw2", "sw4", "sw6", "sw7", "sw_esp", "sw_aimsmooth", NULL};
                for (int k = 0; resetKeys[k]; k++) {
                    id key = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)strCls, sel("alloc")), sel("initWithUTF8String:"), resetKeys[k]);
                    if (key) {
                        ((void (*)(id, SEL, BOOL, id))objc_msgSend)(defs, sel("setBool:forKey:"), NO, key);
                    }
                }
                ((id (*)(id, SEL))objc_msgSend)(defs, sel("synchronize"));
            }
        }
    }

    // 2. Identify the 6 native core buttons from FlyMenu_core.dylib
    id subviews = ((id (*)(id, SEL))objc_msgSend)(panel, sel("subviews"));
    if (subviews) {
        long count = (long)((long (*)(id, SEL))objc_msgSend)(subviews, sel("count"));
        Class btnCls = cls("UIButton");
        for (long i = 0; i < count; i++) {
            id sub = ((msgSend_id_long)objc_msgSend)(subviews, sel("objectAtIndex:"), i);
            if (!sub) continue;
            if (btnCls && (long)((long (*)(id, SEL, id))objc_msgSend)(sub, sel("isKindOfClass:"), (id)btnCls)) {
                id title = ((msgSend_id_long)objc_msgSend)(sub, sel("titleForState:"), 0);
                const char *utf = title ? (const char *)((id (*)(id, SEL))objc_msgSend)(title, sel("UTF8String")) : "";
                if (strstr(utf, "FLY") != NULL || (i == 0 && !g_coreBtns[0])) {
                    g_coreBtns[0] = sub; // Fly Hack
                } else if (strstr(utf, "UP") != NULL || (i == 1 && !g_coreBtns[1])) {
                    g_coreBtns[1] = sub; // Ascend (Up)
                } else if (strstr(utf, "DOWN") != NULL || (i == 2 && !g_coreBtns[2])) {
                    g_coreBtns[2] = sub; // Descend (Down)
                } else if (strstr(utf, "AIM") != NULL || (i == 4 && !g_coreBtns[3])) {
                    g_coreBtns[3] = sub; // Aimbot
                } else if (strstr(utf, "ESP") != NULL || (i == 3 && !g_coreBtns[4])) {
                    g_coreBtns[4] = sub; // ESP
                } else if (strstr(utf, "INFO") != NULL || (i == 5 && !g_coreBtns[5])) {
                    g_coreBtns[5] = sub; // Info
                }
            }
        }
    }

    // 2b. Dynamically create buttons for features from ros.dylib:
    // 6: 1 Hit Kill VIP
    // 7: Speed Epic VIP
    // 8: No Recoil 100% VIP
    // 9: Wallhack VIP
    Class uiBtn = cls("UIButton");
    if (uiBtn) {
        // 6: 1 Hit Kill VIP
        id btn1Hit = ((msgSend_id_long)objc_msgSend)((id)uiBtn, sel("buttonWithType:"), 0);
        if (btn1Hit) {
            ((msgSend_void_id_sel_long)objc_msgSend)(btn1Hit, sel("addTarget:action:forControlEvents:"), g_uiMgr, sel("toggleOneHit:"), 1 << 6);
            ((msgSend_void_id)objc_msgSend)(panel, sel("addSubview:"), btn1Hit);
            g_coreBtns[6] = btn1Hit;
        }
        // 7: Speed Epic VIP
        id btnSpeed = ((msgSend_id_long)objc_msgSend)((id)uiBtn, sel("buttonWithType:"), 0);
        if (btnSpeed) {
            ((msgSend_void_id_sel_long)objc_msgSend)(btnSpeed, sel("addTarget:action:forControlEvents:"), g_uiMgr, sel("toggleSpeedEpic:"), 1 << 6);
            ((msgSend_void_id)objc_msgSend)(panel, sel("addSubview:"), btnSpeed);
            g_coreBtns[7] = btnSpeed;
        }
        // 8: No Recoil 100% VIP
        id btnRecoil = ((msgSend_id_long)objc_msgSend)((id)uiBtn, sel("buttonWithType:"), 0);
        if (btnRecoil) {
            ((msgSend_void_id_sel_long)objc_msgSend)(btnRecoil, sel("addTarget:action:forControlEvents:"), g_uiMgr, sel("toggleNoRecoil:"), 1 << 6);
            ((msgSend_void_id)objc_msgSend)(panel, sel("addSubview:"), btnRecoil);
            g_coreBtns[8] = btnRecoil;
        }
        // 9: Wallhack VIP
        id btnWallhack = ((msgSend_id_long)objc_msgSend)((id)uiBtn, sel("buttonWithType:"), 0);
        if (btnWallhack) {
            ((msgSend_void_id_sel_long)objc_msgSend)(btnWallhack, sel("addTarget:action:forControlEvents:"), g_uiMgr, sel("toggleWallhack:"), 1 << 6);
            ((msgSend_void_id)objc_msgSend)(panel, sel("addSubview:"), btnWallhack);
            g_coreBtns[9] = btnWallhack;
        }
        // 10: Aim Smooth 100% (Auto Aim)
        id btnAimSmooth = ((msgSend_id_long)objc_msgSend)((id)uiBtn, sel("buttonWithType:"), 0);
        if (btnAimSmooth) {
            ((msgSend_void_id_sel_long)objc_msgSend)(btnAimSmooth, sel("addTarget:action:forControlEvents:"), g_uiMgr, sel("toggleAimSmooth:"), 1 << 6);
            ((msgSend_void_id)objc_msgSend)(panel, sel("addSubview:"), btnAimSmooth);
            g_coreBtns[10] = btnAimSmooth;
        }
        // 11: Fly HUD Outside Screen VIP
        id btnFlyHud = ((msgSend_id_long)objc_msgSend)((id)uiBtn, sel("buttonWithType:"), 0);
        if (btnFlyHud) {
            ((msgSend_void_id_sel_long)objc_msgSend)(btnFlyHud, sel("addTarget:action:forControlEvents:"), g_uiMgr, sel("toggleFlyHudOption:"), 1 << 6);
            ((msgSend_void_id)objc_msgSend)(panel, sel("addSubview:"), btnFlyHud);
            g_coreBtns[11] = btnFlyHud;
        }
    }

    // 3. Size and style the main panel (280 width x 558 height)
    double panelW = 280.0;
    double panelH = 558.0;
    CGRect pFrame = ((msgSend_rect)objc_msgSend)(panel, sel("frame"));
    pFrame.size.width = panelW;
    pFrame.size.height = panelH;
    ((msgSend_void_rect)objc_msgSend)(panel, sel("setFrame:"), pFrame);

    Class uiColor = cls("UIColor");
    Class uiView = cls("UIView");
    Class uiLabel = cls("UILabel");
    Class uiFont = cls("UIFont");
    Class nsString = cls("NSString");

    if (uiColor) {
        id panelBg = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.05, 0.05, 0.07, 0.98);
        if (panelBg) ((msgSend_void_id)objc_msgSend)(panel, sel("setBackgroundColor:"), panelBg);

        id pLayer = ((id (*)(id, SEL))objc_msgSend)(panel, sel("layer"));
        if (pLayer) {
            ((msgSend_void_double)objc_msgSend)(pLayer, sel("setCornerRadius:"), 16.0);
            ((msgSend_void_double)objc_msgSend)(pLayer, sel("setBorderWidth:"), 2.0);
            id redBorder = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.83, 0.11, 0.11, 1.0);
            if (redBorder) {
                id cg = ((id (*)(id, SEL))objc_msgSend)(redBorder, sel("CGColor"));
                ((msgSend_void_id)objc_msgSend)(pLayer, sel("setBorderColor:"), cg);
            }
            ((msgSend_void_long)objc_msgSend)(pLayer, sel("setMasksToBounds:"), 1);
        }
    }

    // 4. Create Header Bar (Height 42)
    double headerH = 42.0;
    id headerBar = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)uiView, sel("alloc")), sel("init"));
    if (headerBar) {
        ((msgSend_void_rect)objc_msgSend)(headerBar, sel("setFrame:"), CGRectMake(0, 0, panelW, headerH));
        if (uiColor) {
            id headerBg = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.83, 0.11, 0.11, 1.0);
            if (headerBg) ((msgSend_void_id)objc_msgSend)(headerBar, sel("setBackgroundColor:"), headerBg);
        }

        // Header Logo Icon
        id logoImg = loadLogoImage();
        if (logoImg) {
            Class uiImgView = cls("UIImageView");
            if (uiImgView) {
                id iconView = ((msgSend_id_id)objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)uiImgView, sel("alloc")), sel("initWithImage:"), logoImg);
                if (iconView) {
                    ((msgSend_void_rect)objc_msgSend)(iconView, sel("setFrame:"), CGRectMake(10, 7, 28, 28));
                    id iconLayer = ((id (*)(id, SEL))objc_msgSend)(iconView, sel("layer"));
                    if (iconLayer) {
                        ((msgSend_void_double)objc_msgSend)(iconLayer, sel("setCornerRadius:"), 6.0);
                        ((msgSend_void_long)objc_msgSend)(iconLayer, sel("setMasksToBounds:"), 1);
                    }
                    ((msgSend_void_id)objc_msgSend)(headerBar, sel("addSubview:"), iconView);
                }
            }
        }

        // Header Title Label: "ikhozzzz vip"
        if (uiLabel && nsString) {
            id titleLbl = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)uiLabel, sel("alloc")), sel("init"));
            if (titleLbl) {
                ((msgSend_void_rect)objc_msgSend)(titleLbl, sel("setFrame:"), CGRectMake(logoImg ? 46 : 14, 0, panelW - 85, headerH));
                id titleStr = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "ikhozzzz vip");
                if (titleStr) {
                    ((msgSend_void_id)objc_msgSend)(titleLbl, sel("setText:"), titleStr);
                }
                if (uiColor) {
                    id whiteColor = ((id (*)(id, SEL))objc_msgSend)((id)uiColor, sel("whiteColor"));
                    if (whiteColor) {
                        ((msgSend_void_id)objc_msgSend)(titleLbl, sel("setTextColor:"), whiteColor);
                    }
                }
                if (uiFont) {
                    id boldFont = ((msgSend_id_double)objc_msgSend)((id)uiFont, sel("boldSystemFontOfSize:"), 14.5);
                    if (boldFont) {
                        ((msgSend_void_id)objc_msgSend)(titleLbl, sel("setFont:"), boldFont);
                    }
                }
                ((msgSend_void_id)objc_msgSend)(headerBar, sel("addSubview:"), titleLbl);
            }
        }

        // Header Close [✕] Button
        if (uiBtn && nsString) {
            id closeBtn = ((msgSend_id_long)objc_msgSend)((id)uiBtn, sel("buttonWithType:"), 0);
            if (closeBtn) {
                ((msgSend_void_rect)objc_msgSend)(closeBtn, sel("setFrame:"), CGRectMake(panelW - 38, 5, 32, 32));
                id closeStr = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "✕");
                if (closeStr) {
                    ((msgSend_id_id_long)objc_msgSend)(closeBtn, sel("setTitle:forState:"), closeStr, 0);
                }
                if (uiColor) {
                    id whiteColor = ((id (*)(id, SEL))objc_msgSend)((id)uiColor, sel("whiteColor"));
                    if (whiteColor) {
                        ((msgSend_id_id_long)objc_msgSend)(closeBtn, sel("setTitleColor:forState:"), whiteColor, 0);
                    }
                }
                if (uiFont) {
                    id btnFont = ((msgSend_id_double)objc_msgSend)((id)uiFont, sel("boldSystemFontOfSize:"), 18.0);
                    if (btnFont) {
                        id btnLbl = ((id (*)(id, SEL))objc_msgSend)(closeBtn, sel("titleLabel"));
                        if (btnLbl) ((msgSend_void_id)objc_msgSend)(btnLbl, sel("setFont:"), btnFont);
                    }
                }
                ((msgSend_void_id_sel_long)objc_msgSend)(closeBtn, sel("addTarget:action:forControlEvents:"), g_uiMgr, sel("closeMenu:"), 1 << 6);
                ((msgSend_void_id)objc_msgSend)(headerBar, sel("addSubview:"), closeBtn);
            }
        }

        // Header Pan Gesture
        Class panCls = cls("UIPanGestureRecognizer");
        if (panCls) {
            id headerPan = ((id (*)(id, SEL, id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)panCls, sel("alloc")), sel("initWithTarget:action:"), g_uiMgr, sel("handleMenuPan:"));
            if (headerPan) {
                ((msgSend_void_id)objc_msgSend)(headerBar, sel("addGestureRecognizer:"), headerPan);
            }
        }
        ((msgSend_void_id)objc_msgSend)(panel, sel("addSubview:"), headerBar);
    }

    // 5. Create Navigation / Tabs Bar (Directly below header)
    id tabBar = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)uiView, sel("alloc")), sel("init"));
    if (tabBar) {
        ((msgSend_void_rect)objc_msgSend)(tabBar, sel("setFrame:"), CGRectMake(0, headerH, panelW, 36));
        if (uiColor) {
            id tabBg = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.08, 0.08, 0.10, 1.0);
            if (tabBg) ((msgSend_void_id)objc_msgSend)(tabBar, sel("setBackgroundColor:"), tabBg);
        }

        const char *tabTitles[] = { "AIM", "ESP", "FLY", "INFO" };
        double tabW = (panelW - 20) / 4.0;
        id greyColor = uiColor ? ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.65, 0.65, 0.70, 1.0) : NULL;
        id inactiveTabBg = uiColor ? ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.11, 0.11, 0.15, 1.0) : NULL;

        for (int t = 0; t < 4; t++) {
            id tBtn = ((msgSend_id_long)objc_msgSend)((id)uiBtn, sel("buttonWithType:"), 0);
            if (tBtn) {
                ((msgSend_void_rect)objc_msgSend)(tBtn, sel("setFrame:"), CGRectMake(4 + t * (tabW + 3), 5, tabW, 26));
                if (inactiveTabBg) ((msgSend_void_id)objc_msgSend)(tBtn, sel("setBackgroundColor:"), inactiveTabBg);

                id tLayer = ((id (*)(id, SEL))objc_msgSend)(tBtn, sel("layer"));
                if (tLayer) {
                    ((msgSend_void_double)objc_msgSend)(tLayer, sel("setCornerRadius:"), 5.0);
                    ((msgSend_void_long)objc_msgSend)(tLayer, sel("setMasksToBounds:"), 1);

                    // Add clean vector icon layer
                    id iconLayer = createTabIconLayer(t, greyColor);
                    if (iconLayer) {
                        ((msgSend_void_id)objc_msgSend)(tLayer, sel("addSublayer:"), iconLayer);
                        g_tabIcons[t] = iconLayer;
                    }
                }

                // Add clean text label to the right of the icon
                if (uiLabel && nsString) {
                    id tabLbl = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)uiLabel, sel("alloc")), sel("init"));
                    if (tabLbl) {
                        ((msgSend_void_rect)objc_msgSend)(tabLbl, sel("setFrame:"), CGRectMake(22, 0, tabW - 24, 26));
                        ((msgSend_void_long)objc_msgSend)(tabLbl, sel("setUserInteractionEnabled:"), 0);
                        id tStr = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel("alloc")), sel("initWithUTF8String:"), tabTitles[t]);
                        if (tStr) ((msgSend_void_id)objc_msgSend)(tabLbl, sel("setText:"), tStr);
                        if (greyColor) ((msgSend_void_id)objc_msgSend)(tabLbl, sel("setTextColor:"), greyColor);
                        if (uiFont) {
                            id font = ((msgSend_id_double)objc_msgSend)((id)uiFont, sel("boldSystemFontOfSize:"), 10.5);
                            if (font) ((msgSend_void_id)objc_msgSend)(tabLbl, sel("setFont:"), font);
                        }
                        ((msgSend_void_id)objc_msgSend)(tBtn, sel("addSubview:"), tabLbl);
                        g_tabLabels[t] = tabLbl;
                    }
                }

                ((msgSend_void_long)objc_msgSend)(tBtn, sel("setTag:"), t);
                ((msgSend_void_id_sel_long)objc_msgSend)(tBtn, sel("addTarget:action:forControlEvents:"), g_uiMgr, sel("selectTab:"), 1 << 6);
                ((msgSend_void_id)objc_msgSend)(tabBar, sel("addSubview:"), tBtn);
                g_tabBtns[t] = tBtn;
            }
        }

        // Red accent divider line
        id divider = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)uiView, sel("alloc")), sel("init"));
        if (divider) {
            ((msgSend_void_rect)objc_msgSend)(divider, sel("setFrame:"), CGRectMake(0, 35, panelW, 1.5));
            if (uiColor) {
                id redLine = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.83, 0.11, 0.11, 1.0);
                if (redLine) ((msgSend_void_id)objc_msgSend)(divider, sel("setBackgroundColor:"), redLine);
            }
            ((msgSend_void_id)objc_msgSend)(tabBar, sel("addSubview:"), divider);
        }

        ((msgSend_void_id)objc_msgSend)(panel, sel("addSubview:"), tabBar);
    }

    // 6. Style all buttons directly with clean modern card container and toggle knob
    const char *cleanTitles[] = {
        "Fly Hack (Zero Gravity)",
        "Flight Ascend (Up)",
        "Flight Descend (Down)",
        "Aimbot 360 Lock",
        "Esp Player Laser & Box",
        "Flight Diagnostics & Info",
        "1 Hit Kill VIP",
        "Speed Epic VIP",
        "No Recoil 100% VIP",
        "Wallhack VIP",
        "Aim Smooth (Auto Aim)",
        "Fly HUD (Outside Screen)"
    };

    double startY = 84.0;
    double rowH = 38.0;
    double gap = 4.0;

    for (int i = 0; i < NUM_BUTTONS; i++) {
        id btn = g_coreBtns[i];
        if (!btn) continue;

        // Position the button directly as the row card
        ((msgSend_void_rect)objc_msgSend)(btn, sel("setFrame:"), CGRectMake(10, startY + i * (rowH + gap), panelW - 20, rowH));
        ((msgSend_void_long)objc_msgSend)(btn, sel("setHidden:"), 0);
        ((msgSend_void_long)objc_msgSend)(btn, sel("setUserInteractionEnabled:"), 1);

        // Make default raw button text invisible so only our custom label renders
        id nativeLbl = ((id (*)(id, SEL))objc_msgSend)(btn, sel("titleLabel"));
        if (nativeLbl) {
            ((msgSend_void_double)objc_msgSend)(nativeLbl, sel("setAlpha:"), 0.0);
        }

        // Style the button card container
        if (uiColor) {
            id rowBg = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.08, 0.08, 0.11, 1.0);
            if (rowBg) ((msgSend_void_id)objc_msgSend)(btn, sel("setBackgroundColor:"), rowBg);

            id rLayer = ((id (*)(id, SEL))objc_msgSend)(btn, sel("layer"));
            if (rLayer) {
                ((msgSend_void_double)objc_msgSend)(rLayer, sel("setCornerRadius:"), 8.0);
                ((msgSend_void_double)objc_msgSend)(rLayer, sel("setBorderWidth:"), 1.0);
                id bColor = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.14, 0.14, 0.18, 1.0);
                if (bColor) {
                    id cg = ((id (*)(id, SEL))objc_msgSend)(bColor, sel("CGColor"));
                    ((msgSend_void_id)objc_msgSend)(rLayer, sel("setBorderColor:"), cg);
                }
                ((msgSend_void_long)objc_msgSend)(rLayer, sel("setMasksToBounds:"), 1);
            }
        }

        // Left Toggle Switch Pill
        id pill = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)uiView, sel("alloc")), sel("init"));
        if (pill) {
            ((msgSend_void_rect)objc_msgSend)(pill, sel("setFrame:"), CGRectMake(10, 8, 36, 22));
            ((msgSend_void_long)objc_msgSend)(pill, sel("setUserInteractionEnabled:"), 0); // Touches pass through to button
            if (uiColor) {
                id offBg = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.15, 0.15, 0.18, 1.0);
                if (offBg) ((msgSend_void_id)objc_msgSend)(pill, sel("setBackgroundColor:"), offBg);
                id pLayer = ((id (*)(id, SEL))objc_msgSend)(pill, sel("layer"));
                if (pLayer) {
                    ((msgSend_void_double)objc_msgSend)(pLayer, sel("setCornerRadius:"), 11.0);
                    ((msgSend_void_long)objc_msgSend)(pLayer, sel("setMasksToBounds:"), 1);
                }
            }

            if (i == 1 || i == 2 || i == 5) {
                if (uiLabel && nsString) {
                    id symLbl = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)uiLabel, sel("alloc")), sel("init"));
                    if (symLbl) {
                        ((msgSend_void_rect)objc_msgSend)(symLbl, sel("setFrame:"), CGRectMake(0, 0, 36, 22));
                        ((msgSend_void_long)objc_msgSend)(symLbl, sel("setUserInteractionEnabled:"), 0);
                        const char *sym = (i == 1) ? "▲" : ((i == 2) ? "▼" : "ℹ");
                        id symStr = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel("alloc")), sel("initWithUTF8String:"), sym);
                        if (symStr) ((msgSend_void_id)objc_msgSend)(symLbl, sel("setText:"), symStr);
                        id whiteColor = uiColor ? ((id (*)(id, SEL))objc_msgSend)((id)uiColor, sel("whiteColor")) : NULL;
                        if (whiteColor) ((msgSend_void_id)objc_msgSend)(symLbl, sel("setTextColor:"), whiteColor);
                        if (uiFont) {
                            id f = ((msgSend_id_double)objc_msgSend)((id)uiFont, sel("boldSystemFontOfSize:"), 10.0);
                            if (f) ((msgSend_void_id)objc_msgSend)(symLbl, sel("setFont:"), f);
                        }
                        ((msgSend_void_long)objc_msgSend)(symLbl, sel("setTextAlignment:"), 1); // Center
                        ((msgSend_void_id)objc_msgSend)(pill, sel("addSubview:"), symLbl);
                    }
                }
            } else {
                // Real modern sliding knob inside toggle pill
                if (uiView && uiColor) {
                    id knob = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)uiView, sel("alloc")), sel("init"));
                    if (knob) {
                        ((msgSend_void_rect)objc_msgSend)(knob, sel("setFrame:"), CGRectMake(2, 2, 18, 18));
                        ((msgSend_void_long)objc_msgSend)(knob, sel("setUserInteractionEnabled:"), 0);
                        id knobColor = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.50, 0.50, 0.55, 1.0);
                        if (knobColor) ((msgSend_void_id)objc_msgSend)(knob, sel("setBackgroundColor:"), knobColor);
                        id kLayer = ((id (*)(id, SEL))objc_msgSend)(knob, sel("layer"));
                        if (kLayer) {
                            ((msgSend_void_double)objc_msgSend)(kLayer, sel("setCornerRadius:"), 9.0);
                            ((msgSend_void_long)objc_msgSend)(kLayer, sel("setMasksToBounds:"), 1);
                        }
                        ((msgSend_void_id)objc_msgSend)(pill, sel("addSubview:"), knob);
                        g_rowKnobs[i] = knob;
                    }
                }
            }
            ((msgSend_void_id)objc_msgSend)(btn, sel("addSubview:"), pill);
            g_rowPills[i] = pill;
        }

        // Clean Feature Title Label
        if (uiLabel && nsString) {
            id lbl = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)uiLabel, sel("alloc")), sel("init"));
            if (lbl) {
                ((msgSend_void_rect)objc_msgSend)(lbl, sel("setFrame:"), CGRectMake(54, 0, panelW - 20 - 58, rowH));
                ((msgSend_void_long)objc_msgSend)(lbl, sel("setUserInteractionEnabled:"), 0); // Touches pass through to button
                id txt = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel("alloc")), sel("initWithUTF8String:"), cleanTitles[i]);
                if (txt) ((msgSend_void_id)objc_msgSend)(lbl, sel("setText:"), txt);
                if (uiColor) {
                    id whiteColor = ((id (*)(id, SEL))objc_msgSend)((id)uiColor, sel("whiteColor"));
                    if (whiteColor) ((msgSend_void_id)objc_msgSend)(lbl, sel("setTextColor:"), whiteColor);
                }
                if (uiFont) {
                    id font = ((msgSend_id_double)objc_msgSend)((id)uiFont, sel("boldSystemFontOfSize:"), 12.5);
                    if (font) ((msgSend_void_id)objc_msgSend)(lbl, sel("setFont:"), font);
                }
                ((msgSend_void_id)objc_msgSend)(btn, sel("addSubview:"), lbl);
                g_rowLabels[i] = lbl;
            }
        }

        // For button 3 (Aimbot 360 Lock), cleanly remove raw FlyMenu_core targets and wire to custom toggleAimbot:
        if (i == 3) {
            id allTargets = ((id (*)(id, SEL))objc_msgSend)(btn, sel("allTargets"));
            if (allTargets) {
                id enumerator = ((id (*)(id, SEL))objc_msgSend)(allTargets, sel("objectEnumerator"));
                if (enumerator) {
                    id t;
                    while ((t = ((id (*)(id, SEL))objc_msgSend)(enumerator, sel("nextObject")))) {
                        ((void (*)(id, SEL, id, SEL, unsigned long))objc_msgSend)(btn, sel("removeTarget:action:forControlEvents:"), t, NULL, 0x0FFFFFFF);
                    }
                }
            }
            ((void (*)(id, SEL, id, SEL, unsigned long))objc_msgSend)(btn, sel("removeTarget:action:forControlEvents:"), NULL, NULL, 0x0FFFFFFF);
            ((void (*)(id, SEL, id, SEL, unsigned long))objc_msgSend)(btn, sel("addTarget:action:forControlEvents:"), g_uiMgr, sel("toggleAimbot:"), 1 << 6);
        }

        // For button 4 (ESP), cleanly remove raw FlyMenu_core targets and wire to custom toggleEsp:
        if (i == 4) {
            id allTargets = ((id (*)(id, SEL))objc_msgSend)(btn, sel("allTargets"));
            if (allTargets) {
                id enumerator = ((id (*)(id, SEL))objc_msgSend)(allTargets, sel("objectEnumerator"));
                if (enumerator) {
                    id t;
                    while ((t = ((id (*)(id, SEL))objc_msgSend)(enumerator, sel("nextObject")))) {
                        ((void (*)(id, SEL, id, SEL, unsigned long))objc_msgSend)(btn, sel("removeTarget:action:forControlEvents:"), t, NULL, 0x0FFFFFFF);
                    }
                }
            }
            ((void (*)(id, SEL, id, SEL, unsigned long))objc_msgSend)(btn, sel("removeTarget:action:forControlEvents:"), NULL, NULL, 0x0FFFFFFF);
            ((void (*)(id, SEL, id, SEL, unsigned long))objc_msgSend)(btn, sel("addTarget:action:forControlEvents:"), g_uiMgr, sel("toggleEsp:"), 1 << 6);
        }

        // For button 5 (Flight Diagnostics & Info), cleanly remove all existing targets (e.g. ROSFlyTestTarget) and attach custom info modal
        if (i == 5) {
            id allTargets = ((id (*)(id, SEL))objc_msgSend)(btn, sel("allTargets"));
            if (allTargets) {
                id enumerator = ((id (*)(id, SEL))objc_msgSend)(allTargets, sel("objectEnumerator"));
                if (enumerator) {
                    id t;
                    while ((t = ((id (*)(id, SEL))objc_msgSend)(enumerator, sel("nextObject")))) {
                        ((void (*)(id, SEL, id, SEL, unsigned long))objc_msgSend)(btn, sel("removeTarget:action:forControlEvents:"), t, NULL, 0x0FFFFFFF);
                    }
                }
            }
            ((void (*)(id, SEL, id, SEL, unsigned long))objc_msgSend)(btn, sel("removeTarget:action:forControlEvents:"), NULL, NULL, 0x0FFFFFFF);
            ((void (*)(id, SEL, id, SEL, unsigned long))objc_msgSend)(btn, sel("addTarget:action:forControlEvents:"), g_uiMgr, sel("showCustomInfo:"), 1 << 6);
        }

        // Bring button to front so touches are natively received
        ((msgSend_void_id)objc_msgSend)(panel, sel("bringSubviewToFront:"), btn);
    }

    // 7. Ensure Floating Logo Button and on-screen Fly & Aim HUDs are on the active window
    ensureFloatingButtonOnWindow(win);
    ensureFloatingFlyHUD(win);
    ensureFloatingAimHUD(win);
}

static inline void safePyDecref(void *obj) {
    if (!obj) return;
    int64_t *ref = (int64_t *)obj;
    if (--(*ref) == 0) {
        void *tp = *((void **)obj + 1);
        if (tp) {
            void (*dealloc)(void *) = *(void **)((uintptr_t)tp + 0x30);
            if (dealloc) dealloc(obj);
        }
    }
}

static BOOL runCombatPython(const char *cmd) {
    if (!cmd) return NO;
    uint32_t count = _dyld_image_count();
    intptr_t coreSlide = 0;
    BOOL foundCore = NO;
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "FlyMenu_core")) {
            coreSlide = _dyld_get_image_vmaddr_slide(i);
            foundCore = YES;
            break;
        }
    }
    if (!foundCore) return NO;

    uint8_t *pCombatReady = (uint8_t *)(coreSlide + 0xc160);
    if (!pCombatReady || *pCombatReady != 1) return NO;

    void **pCombatDict = (void **)(coreSlide + 0xc168);
    if (!pCombatDict || !(*pCombatDict)) return NO;

    void **pPyGILStateEnsure = (void **)(coreSlide + 0xc0f0);
    void **pPyErrClear = (void **)(coreSlide + 0xc110);
    void **pPyGILStateRelease = (void **)(coreSlide + 0xc118);
    void **pPyRunString = (void **)(coreSlide + 0xc138);

    if (!pPyGILStateEnsure || !*pPyGILStateEnsure ||
        !pPyGILStateRelease || !*pPyGILStateRelease ||
        !pPyRunString || !*pPyRunString) {
        return NO;
    }

    int (*PyGILState_Ensure)(void) = (int (*)(void))*pPyGILStateEnsure;
    void (*PyGILState_Release)(int) = (void (*)(int))*pPyGILStateRelease;
    void *(*PyRun_String)(const char *, int, void *, void *) = (void *(*)(const char *, int, void *, void *))*pPyRunString;
    void (*PyErr_Clear)(void) = pPyErrClear ? (void (*)(void))*pPyErrClear : NULL;

    int gstate = PyGILState_Ensure();
    void *dict = *pCombatDict;
    BOOL ok = NO;
    if (dict) {
        void *res = PyRun_String(cmd, 257 /* Py_single_input */, dict, dict);
        if (res) {
            safePyDecref(res);
            ok = YES;
        }
        if (PyErr_Clear) PyErr_Clear();
    }
    PyGILState_Release(gstate);
    return ok;
}

// Aimbot 360 Lock (Button 3)
static void toggleAimbot_imp(id self, SEL _cmd, id sender) {
    Class defsCls = cls("NSUserDefaults");
    if (!defsCls) return;
    id defs = ((id (*)(id, SEL))objc_msgSend)((id)defsCls, sel("standardUserDefaults"));
    if (!defs) return;

    Class strCls = cls("NSString");
    id key = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)strCls, sel("alloc")), sel("initWithUTF8String:"), "sw_aimbot");
    if (!key) return;

    BOOL cur = (BOOL)((long (*)(id, SEL, id))objc_msgSend)(defs, sel("boolForKey:"), key);
    BOOL newState = !cur;

    ((void (*)(id, SEL, BOOL, id))objc_msgSend)(defs, sel("setBool:forKey:"), newState, key);
    ((id (*)(id, SEL))objc_msgSend)(defs, sel("synchronize"));
    updateRowStates();

    char pyCmd[128];
    snprintf(pyCmd, sizeof(pyCmd), "set_aim(%s)", newState ? "True" : "False");
    runCombatPython(pyCmd);

    printf("[FlyMenuUI] Aimbot 360 Lock toggled -> %s\n", newState ? "ENABLED" : "DISABLED");
}

// Aim Smooth 100% Auto (Button 10)
static void toggleAimSmooth_imp(id self, SEL _cmd, id sender) {
    Class defsCls = cls("NSUserDefaults");
    if (!defsCls) return;
    id defs = ((id (*)(id, SEL))objc_msgSend)((id)defsCls, sel("standardUserDefaults"));
    if (!defs) return;

    Class strCls = cls("NSString");
    id key = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)strCls, sel("alloc")), sel("initWithUTF8String:"), "sw_aimsmooth");
    if (!key) return;

    BOOL cur = (BOOL)((long (*)(id, SEL, id))objc_msgSend)(defs, sel("boolForKey:"), key);
    BOOL newState = !cur;

    ((void (*)(id, SEL, BOOL, id))objc_msgSend)(defs, sel("setBool:forKey:"), newState, key);
    ((id (*)(id, SEL))objc_msgSend)(defs, sel("synchronize"));
    updateRowStates();

    char pyCmd[128];
    snprintf(pyCmd, sizeof(pyCmd), "set_aim_smooth(%s)", newState ? "True" : "False");
    runCombatPython(pyCmd);

    printf("[FlyMenuUI] Aim Smooth 100%% Auto toggled -> %s\n", newState ? "ENABLED" : "DISABLED");
}

static BOOL runFlyPython(const char *cmd) {
    if (!cmd) return NO;
    uint32_t count = _dyld_image_count();
    intptr_t coreSlide = 0;
    BOOL foundCore = NO;
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "FlyMenu_core")) {
            coreSlide = _dyld_get_image_vmaddr_slide(i);
            foundCore = YES;
            break;
        }
    }
    if (!foundCore) return NO;

    void **pModuleDict = (void **)(coreSlide + 0xc0e8);
    if (!pModuleDict || !(*pModuleDict)) return NO;

    void **pPyGILStateEnsure = (void **)(coreSlide + 0xc0f0);
    void **pPyErrClear = (void **)(coreSlide + 0xc110);
    void **pPyGILStateRelease = (void **)(coreSlide + 0xc118);
    void **pPyRunString = (void **)(coreSlide + 0xc138);

    if (!pPyGILStateEnsure || !*pPyGILStateEnsure ||
        !pPyGILStateRelease || !*pPyGILStateRelease ||
        !pPyRunString || !*pPyRunString) {
        return NO;
    }

    int (*PyGILState_Ensure)(void) = (int (*)(void))*pPyGILStateEnsure;
    void (*PyGILState_Release)(int) = (void (*)(int))*pPyGILStateRelease;
    void *(*PyRun_String)(const char *, int, void *, void *) = (void *(*)(const char *, int, void *, void *))*pPyRunString;
    void (*PyErr_Clear)(void) = pPyErrClear ? (void (*)(void))*pPyErrClear : NULL;

    int gstate = PyGILState_Ensure();
    void *dict = *pModuleDict;
    BOOL ok = NO;
    if (dict) {
        void *res = PyRun_String(cmd, 257 /* Py_single_input */, dict, dict);
        if (res) {
            safePyDecref(res);
            ok = YES;
        }
        if (PyErr_Clear) PyErr_Clear();
    }
    PyGILState_Release(gstate);
    return ok;
}

// ESP Laser & Box (Button 4)
static void toggleEsp_imp(id self, SEL _cmd, id sender) {
    Class defsCls = cls("NSUserDefaults");
    if (!defsCls) return;
    id defs = ((id (*)(id, SEL))objc_msgSend)((id)defsCls, sel("standardUserDefaults"));
    if (!defs) return;

    Class strCls = cls("NSString");
    id key = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)strCls, sel("alloc")), sel("initWithUTF8String:"), "sw_esp");
    if (!key) return;

    BOOL cur = (BOOL)((long (*)(id, SEL, id))objc_msgSend)(defs, sel("boolForKey:"), key);
    BOOL newState = !cur;

    ((void (*)(id, SEL, BOOL, id))objc_msgSend)(defs, sel("setBool:forKey:"), newState, key);
    ((id (*)(id, SEL))objc_msgSend)(defs, sel("synchronize"));
    updateRowStates();

    char pyCmd[128];
    snprintf(pyCmd, sizeof(pyCmd), "set_esp(%s)", newState ? "True" : "False");
    runCombatPython(pyCmd);

    printf("[FlyMenuUI] ESP Laser & Box toggled -> %s\n", newState ? "ENABLED" : "DISABLED");
}

// Toggle Fly HUD outside on screen (Button 11)
static void toggleFlyHudOption_imp(id self, SEL _cmd, id sender) {
    Class defsCls = cls("NSUserDefaults");
    if (!defsCls) return;
    id defs = ((id (*)(id, SEL))objc_msgSend)((id)defsCls, sel("standardUserDefaults"));
    if (!defs) return;

    Class strCls = cls("NSString");
    id key = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)strCls, sel("alloc")), sel("initWithUTF8String:"), "sw_flyhud");
    if (!key) return;

    BOOL cur = YES;
    id val = ((id (*)(id, SEL, id))objc_msgSend)(defs, sel("objectForKey:"), key);
    if (val) {
        cur = (BOOL)((long (*)(id, SEL, id))objc_msgSend)(defs, sel("boolForKey:"), key);
    }
    BOOL newState = !cur;

    ((void (*)(id, SEL, BOOL, id))objc_msgSend)(defs, sel("setBool:forKey:"), newState, key);
    ((id (*)(id, SEL))objc_msgSend)(defs, sel("synchronize"));

    if (g_flyHudView) {
        ((msgSend_void_long)objc_msgSend)(g_flyHudView, sel("setHidden:"), newState ? 0 : 1);
    }
    updateRowStates();

    printf("[FlyMenuUI] Fly HUD Outside Screen toggled -> %s\n", newState ? "ENABLED" : "DISABLED");
}

// On-screen Fly HUD Actions
static void onFlyHudToggle_imp(id self, SEL _cmd, id sender) {
    // 1. Invoke ROSFlyTestTarget directly from FlyMenu_core
    uint32_t count = _dyld_image_count();
    intptr_t coreSlide = 0;
    BOOL foundCore = NO;
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "FlyMenu_core")) {
            coreSlide = _dyld_get_image_vmaddr_slide(i);
            foundCore = YES;
            break;
        }
    }
    if (foundCore) {
        id *pTarget = (id *)(coreSlide + 0xc060);
        if (pTarget && *pTarget) {
            ((void (*)(id, SEL, id))objc_msgSend)(*pTarget, sel("toggle:"), NULL);
        }
    }

    if (g_coreBtns[0]) {
        ((msgSend_void_long)objc_msgSend)(g_coreBtns[0], sel("sendActionsForControlEvents:"), 1 << 6);
    }
    runFlyPython("handle('toggle', 0)");
    updateRowStates();
}

static void onFlyHudUpStart_imp(id self, SEL _cmd, id sender) {
    uint32_t count = _dyld_image_count();
    intptr_t coreSlide = 0;
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "FlyMenu_core")) {
            coreSlide = _dyld_get_image_vmaddr_slide(i);
            id *pTarget = (id *)(coreSlide + 0xc060);
            if (pTarget && *pTarget) {
                ((void (*)(id, SEL, id))objc_msgSend)(*pTarget, sel("up:"), NULL);
            }
            break;
        }
    }
    if (g_coreBtns[1]) {
        ((msgSend_void_long)objc_msgSend)(g_coreBtns[1], sel("sendActionsForControlEvents:"), 1 << 0);
    }
    runFlyPython("handle('lift', 1)");
}

static void onFlyHudDownStart_imp(id self, SEL _cmd, id sender) {
    uint32_t count = _dyld_image_count();
    intptr_t coreSlide = 0;
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "FlyMenu_core")) {
            coreSlide = _dyld_get_image_vmaddr_slide(i);
            id *pTarget = (id *)(coreSlide + 0xc060);
            if (pTarget && *pTarget) {
                ((void (*)(id, SEL, id))objc_msgSend)(*pTarget, sel("down:"), NULL);
            }
            break;
        }
    }
    if (g_coreBtns[2]) {
        ((msgSend_void_long)objc_msgSend)(g_coreBtns[2], sel("sendActionsForControlEvents:"), 1 << 0);
    }
    runFlyPython("handle('lift', -1)");
}

static void onFlyHudLiftStop_imp(id self, SEL _cmd, id sender) {
    uint32_t count = _dyld_image_count();
    intptr_t coreSlide = 0;
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "FlyMenu_core")) {
            coreSlide = _dyld_get_image_vmaddr_slide(i);
            id *pTarget = (id *)(coreSlide + 0xc060);
            if (pTarget && *pTarget) {
                ((void (*)(id, SEL, id))objc_msgSend)(*pTarget, sel("release:"), NULL);
            }
            break;
        }
    }
    if (g_coreBtns[1]) {
        ((msgSend_void_long)objc_msgSend)(g_coreBtns[1], sel("sendActionsForControlEvents:"), 1 << 6);
    }
    if (g_coreBtns[2]) {
        ((msgSend_void_long)objc_msgSend)(g_coreBtns[2], sel("sendActionsForControlEvents:"), 1 << 6);
    }
    runFlyPython("handle('lift', 0)");
}

// Extract rich ESP snapshot string safely from FlyMenu_core's validated Python session
static char *getESPSnapshot(void) {
    uint32_t count = _dyld_image_count();
    intptr_t coreSlide = 0;
    BOOL foundCore = NO;
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "FlyMenu_core")) {
            coreSlide = _dyld_get_image_vmaddr_slide(i);
            foundCore = YES;
            break;
        }
    }
    if (!foundCore) return NULL;

    // Check if FlyMenu_core's combat engine has successfully initialized and is ready
    uint8_t *pCombatReady = (uint8_t *)(coreSlide + 0xc160);
    if (!pCombatReady || *pCombatReady != 1) {
        return NULL; // Zero-risk: return NULL immediately while game is booting or ESP is off
    }

    void **pCombatDict = (void **)(coreSlide + 0xc168);
    if (!pCombatDict || !(*pCombatDict)) return NULL;

    // Validated BSS pointers from FlyMenu_core.dylib:
    // 0xc0f0: _gil (PyGILState_Ensure)
    // 0xc110: _clearError (PyErr_Clear)
    // 0xc118: _releaseGil (PyGILState_Release)
    // 0xc138: _runString (PyRun_String)
    // 0xc150: _stringData (PyString_AsString)
    void **pPyGILStateEnsure = (void **)(coreSlide + 0xc0f0);
    void **pPyErrClear = (void **)(coreSlide + 0xc110);
    void **pPyGILStateRelease = (void **)(coreSlide + 0xc118);
    void **pPyRunString = (void **)(coreSlide + 0xc138);
    void **pPyStringAsString = (void **)(coreSlide + 0xc150);

    if (!pPyGILStateEnsure || !*pPyGILStateEnsure ||
        !pPyGILStateRelease || !*pPyGILStateRelease ||
        !pPyRunString || !*pPyRunString ||
        !pPyStringAsString || !*pPyStringAsString) {
        return NULL;
    }

    int (*PyGILState_Ensure)(void) = (int (*)(void))*pPyGILStateEnsure;
    void (*PyGILState_Release)(int) = (void (*)(int))*pPyGILStateRelease;
    void *(*PyRun_String)(const char *, int, void *, void *) = (void *(*)(const char *, int, void *, void *))*pPyRunString;
    char *(*PyString_AsString)(void *) = (char *(*)(void *))*pPyStringAsString;
    void (*PyErr_Clear)(void) = pPyErrClear ? (void (*)(void))*pPyErrClear : NULL;

    int gstate = PyGILState_Ensure();
    char *resultCopy = NULL;
    void *dict = *pCombatDict;

    if (dict) {
        // 1. First try rich esp_snapshot() (Py_eval_input = 258)
        void *res = PyRun_String("esp_snapshot()", 258 /* Py_eval_input */, dict, dict);
        if (res) {
            char *s = PyString_AsString(res);
            if (s && *s && strcmp(s, "NONE") != 0) {
                resultCopy = strdup(s);
            }
            safePyDecref(res);
        }
        if (PyErr_Clear) {
            PyErr_Clear();
        }

        // 2. Fallback to standard snapshot() if esp_snapshot was empty or "NONE"
        if (!resultCopy) {
            void *res2 = PyRun_String("snapshot()", 258 /* Py_eval_input */, dict, dict);
            if (res2) {
                char *s2 = PyString_AsString(res2);
                if (s2 && *s2 && strcmp(s2, "NONE") != 0) {
                    resultCopy = strdup(s2);
                }
                safePyDecref(res2);
            }
            if (PyErr_Clear) {
                PyErr_Clear();
            }
        }
    }

    PyGILState_Release(gstate);
    return resultCopy;
}

static void ensureESPOverlay(id win) {
    if (!win) return;
    if (g_espOverlay) {
        id sView = ((id (*)(id, SEL))objc_msgSend)(g_espOverlay, sel("superview"));
        if (sView != win) {
            ((msgSend_void_id)objc_msgSend)(win, sel("addSubview:"), g_espOverlay);
            if (g_panel) {
                id pSuper = ((id (*)(id, SEL))objc_msgSend)(g_panel, sel("superview"));
                if (pSuper) ((msgSend_void_id)objc_msgSend)(pSuper, sel("bringSubviewToFront:"), g_panel);
            }
            if (g_floatBtn) {
                id fSuper = ((id (*)(id, SEL))objc_msgSend)(g_floatBtn, sel("superview"));
                if (fSuper) ((msgSend_void_id)objc_msgSend)(fSuper, sel("bringSubviewToFront:"), g_floatBtn);
            }
        }
        return;
    }

    Class uiView = cls("UIView");
    if (!uiView) return;
    id overlay = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)uiView, sel("alloc")), sel("init"));
    if (!overlay) return;

    CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(win, sel("bounds"));
    ((msgSend_void_rect)objc_msgSend)(overlay, sel("setFrame:"), bounds);
    ((msgSend_void_long)objc_msgSend)(overlay, sel("setUserInteractionEnabled:"), 0);
    ((msgSend_void_long)objc_msgSend)(overlay, sel("setOpaque:"), 0);

    Class uiColor = cls("UIColor");
    if (uiColor) {
        id clear = ((id (*)(id, SEL))objc_msgSend)((id)uiColor, sel("clearColor"));
        if (clear) ((msgSend_void_id)objc_msgSend)(overlay, sel("setBackgroundColor:"), clear);
    }

    id overlayLayer = ((id (*)(id, SEL))objc_msgSend)(overlay, sel("layer"));
    Class shapeCls = cls("CAShapeLayer");
    Class textCls = cls("CATextLayer");

    if (shapeCls && uiColor && overlayLayer) {
        id redC = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 1.0, 0.20, 0.20, 0.90);
        id greenC = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.0, 1.0, 0.40, 0.98);

        // Red Line Layer (blocked enemies)
        id rLine = ((id (*)(id, SEL))objc_msgSend)((id)shapeCls, sel("layer"));
        ((msgSend_void_rect)objc_msgSend)(rLine, sel("setFrame:"), bounds);
        if (redC) ((msgSend_void_id)objc_msgSend)(rLine, sel("setStrokeColor:"), ((id (*)(id, SEL))objc_msgSend)(redC, sel("CGColor")));
        ((msgSend_void_double)objc_msgSend)(rLine, sel("setLineWidth:"), 1.4);
        ((msgSend_void_id)objc_msgSend)(rLine, sel("setFillColor:"), NULL);
        ((msgSend_void_id)objc_msgSend)(overlayLayer, sel("addSublayer:"), rLine);
        g_espRedLineLayer = rLine;

        // Green Line Layer (shootable / can shoot!)
        id gLine = ((id (*)(id, SEL))objc_msgSend)((id)shapeCls, sel("layer"));
        ((msgSend_void_rect)objc_msgSend)(gLine, sel("setFrame:"), bounds);
        if (greenC) ((msgSend_void_id)objc_msgSend)(gLine, sel("setStrokeColor:"), ((id (*)(id, SEL))objc_msgSend)(greenC, sel("CGColor")));
        ((msgSend_void_double)objc_msgSend)(gLine, sel("setLineWidth:"), 1.8);
        ((msgSend_void_id)objc_msgSend)(gLine, sel("setFillColor:"), NULL);
        ((msgSend_void_id)objc_msgSend)(overlayLayer, sel("addSublayer:"), gLine);
        g_espGreenLineLayer = gLine;

        // Red Box Layer (blocked enemies)
        id rBox = ((id (*)(id, SEL))objc_msgSend)((id)shapeCls, sel("layer"));
        ((msgSend_void_rect)objc_msgSend)(rBox, sel("setFrame:"), bounds);
        if (redC) ((msgSend_void_id)objc_msgSend)(rBox, sel("setStrokeColor:"), ((id (*)(id, SEL))objc_msgSend)(redC, sel("CGColor")));
        ((msgSend_void_double)objc_msgSend)(rBox, sel("setLineWidth:"), 1.2);
        ((msgSend_void_id)objc_msgSend)(rBox, sel("setFillColor:"), NULL);
        ((msgSend_void_id)objc_msgSend)(overlayLayer, sel("addSublayer:"), rBox);
        g_espRedBoxLayer = rBox;

        // Green Box Layer (shootable!)
        id gBox = ((id (*)(id, SEL))objc_msgSend)((id)shapeCls, sel("layer"));
        ((msgSend_void_rect)objc_msgSend)(gBox, sel("setFrame:"), bounds);
        if (greenC) ((msgSend_void_id)objc_msgSend)(gBox, sel("setStrokeColor:"), ((id (*)(id, SEL))objc_msgSend)(greenC, sel("CGColor")));
        ((msgSend_void_double)objc_msgSend)(gBox, sel("setLineWidth:"), 1.6);
        id subtleGreenFill = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.0, 1.0, 0.40, 0.08);
        if (subtleGreenFill) ((msgSend_void_id)objc_msgSend)(gBox, sel("setFillColor:"), ((id (*)(id, SEL))objc_msgSend)(subtleGreenFill, sel("CGColor")));
        ((msgSend_void_id)objc_msgSend)(overlayLayer, sel("addSublayer:"), gBox);
        g_espGreenBoxLayer = gBox;
    }

    if (textCls && overlayLayer && uiColor) {
        id tagBg = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.05, 0.05, 0.08, 0.82);
        id whiteC = ((id (*)(id, SEL))objc_msgSend)((id)uiColor, sel("whiteColor"));
        Class nsString = cls("NSString");
        id alignCenter = nsString ? ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "center") : NULL;

        Class uiScreen = cls("UIScreen");
        double screenScale = 2.0;
        if (uiScreen) {
            id ms = ((id (*)(id, SEL))objc_msgSend)((id)uiScreen, sel("mainScreen"));
            if (ms) screenScale = ((double (*)(id, SEL))objc_msgSend)(ms, sel("scale"));
        }

        Class uiFont = cls("UIFont");
        id fontName = NULL;
        if (uiFont) {
            id f = ((msgSend_id_double)objc_msgSend)((id)uiFont, sel("boldSystemFontOfSize:"), 10.0);
            if (f) fontName = ((id (*)(id, SEL))objc_msgSend)(f, sel("fontName"));
        }

        for (int i = 0; i < MAX_ESP_LABELS; i++) {
            id tLayer = ((id (*)(id, SEL))objc_msgSend)((id)textCls, sel("layer"));
            ((msgSend_void_long)objc_msgSend)(tLayer, sel("setHidden:"), 1);
            ((msgSend_void_double)objc_msgSend)(tLayer, sel("setFontSize:"), 10.0);
            ((msgSend_void_double)objc_msgSend)(tLayer, sel("setCornerRadius:"), 3.0);
            ((msgSend_void_long)objc_msgSend)(tLayer, sel("setMasksToBounds:"), 1);
            ((msgSend_void_double)objc_msgSend)(tLayer, sel("setContentsScale:"), screenScale);
            if (alignCenter) ((msgSend_void_id)objc_msgSend)(tLayer, sel("setAlignmentMode:"), alignCenter);
            if (fontName) ((msgSend_void_id)objc_msgSend)(tLayer, sel("setFont:"), fontName);
            if (tagBg) ((msgSend_void_id)objc_msgSend)(tLayer, sel("setBackgroundColor:"), ((id (*)(id, SEL))objc_msgSend)(tagBg, sel("CGColor")));
            if (whiteC) ((msgSend_void_id)objc_msgSend)(tLayer, sel("setForegroundColor:"), ((id (*)(id, SEL))objc_msgSend)(whiteC, sel("CGColor")));

            ((msgSend_void_id)objc_msgSend)(overlayLayer, sel("addSublayer:"), tLayer);
            g_espTextLayers[i] = tLayer;
        }
    }

    ((msgSend_void_id)objc_msgSend)(win, sel("addSubview:"), overlay);
    if (g_panel) {
        id pSuper = ((id (*)(id, SEL))objc_msgSend)(g_panel, sel("superview"));
        if (pSuper) ((msgSend_void_id)objc_msgSend)(pSuper, sel("bringSubviewToFront:"), g_panel);
    }
    if (g_floatBtn) {
        id fSuper = ((id (*)(id, SEL))objc_msgSend)(g_floatBtn, sel("superview"));
        if (fSuper) ((msgSend_void_id)objc_msgSend)(fSuper, sel("bringSubviewToFront:"), g_floatBtn);
    }
    g_espOverlay = overlay;
}

static void updateESPOverlay(id win) {
    if (!win) return;
    ensureESPOverlay(win);
    if (!g_espOverlay) return;

    // Check if ESP is ON in core button or persisted preferences
    BOOL espActive = NO;
    Class defsCls = cls("NSUserDefaults");
    if (defsCls) {
        id defs = ((id (*)(id, SEL))objc_msgSend)((id)defsCls, sel("standardUserDefaults"));
        if (defs) {
            Class strCls = cls("NSString");
            if (strCls) {
                id key = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)strCls, sel("alloc")), sel("initWithUTF8String:"), "sw_esp");
                if (key) {
                    espActive = (BOOL)((long (*)(id, SEL, id))objc_msgSend)(defs, sel("boolForKey:"), key);
                }
            }
        }
    }
    if (!espActive && g_coreBtns[4]) {
        id t = ((msgSend_id_long)objc_msgSend)(g_coreBtns[4], sel("titleForState:"), 0);
        const char *s = t ? (const char *)((id (*)(id, SEL))objc_msgSend)(t, sel("UTF8String")) : "";
        espActive = (strstr(s, ":ON") != NULL || strstr(s, ":WAIT") != NULL || strstr(s, ":PAUSED") != NULL || (strstr(s, "ESP") != NULL && strstr(s, "OFF") == NULL && strlen(s) > 3));
    }

    char *snapStr = getESPSnapshot();
    // If ESP is not active in the button AND Python has no live snapshot data, clear and return
    if (!espActive && (!snapStr || strlen(snapStr) == 0 || strcmp(snapStr, "NONE") == 0)) {
        if (g_espRedLineLayer) ((msgSend_void_id)objc_msgSend)(g_espRedLineLayer, sel("setPath:"), NULL);
        if (g_espGreenLineLayer) ((msgSend_void_id)objc_msgSend)(g_espGreenLineLayer, sel("setPath:"), NULL);
        if (g_espRedBoxLayer) ((msgSend_void_id)objc_msgSend)(g_espRedBoxLayer, sel("setPath:"), NULL);
        if (g_espGreenBoxLayer) ((msgSend_void_id)objc_msgSend)(g_espGreenBoxLayer, sel("setPath:"), NULL);
        for (int i = 0; i < MAX_ESP_LABELS; i++) {
            if (g_espTextLayers[i]) ((msgSend_void_long)objc_msgSend)(g_espTextLayers[i], sel("setHidden:"), 1);
        }
        if (snapStr) free(snapStr);
        return;
    }

    static int s_emptyFrames = 0;
    if (!snapStr || strlen(snapStr) == 0 || strcmp(snapStr, "NONE") == 0) {
        s_emptyFrames++;
        if (s_emptyFrames > 45) {
            if (g_espRedLineLayer) ((msgSend_void_id)objc_msgSend)(g_espRedLineLayer, sel("setPath:"), NULL);
            if (g_espGreenLineLayer) ((msgSend_void_id)objc_msgSend)(g_espGreenLineLayer, sel("setPath:"), NULL);
            if (g_espRedBoxLayer) ((msgSend_void_id)objc_msgSend)(g_espRedBoxLayer, sel("setPath:"), NULL);
            if (g_espGreenBoxLayer) ((msgSend_void_id)objc_msgSend)(g_espGreenBoxLayer, sel("setPath:"), NULL);
            for (int i = 0; i < MAX_ESP_LABELS; i++) {
                if (g_espTextLayers[i]) ((msgSend_void_long)objc_msgSend)(g_espTextLayers[i], sel("setHidden:"), 1);
            }
        }
        if (snapStr) free(snapStr);
        return;
    }
    s_emptyFrames = 0;

    Class caTrans = cls("CATransaction");
    if (caTrans) {
        ((id (*)(id, SEL))objc_msgSend)((id)caTrans, sel("begin"));
        ((msgSend_void_long)objc_msgSend)((id)caTrans, sel("setDisableActions:"), 1);
    }

    Class pathCls = cls("UIBezierPath");
    id redLineP = ((id (*)(id, SEL))objc_msgSend)((id)pathCls, sel("bezierPath"));
    id greenLineP = ((id (*)(id, SEL))objc_msgSend)((id)pathCls, sel("bezierPath"));
    id redBoxP = ((id (*)(id, SEL))objc_msgSend)((id)pathCls, sel("bezierPath"));
    id greenBoxP = ((id (*)(id, SEL))objc_msgSend)((id)pathCls, sel("bezierPath"));

    CGRect winBounds = ((CGRect (*)(id, SEL))objc_msgSend)(win, sel("bounds"));
    double winW = winBounds.size.width;
    double winH = winBounds.size.height;
    double startX = winW * 0.5;
    double startY = winH * 0.02; // Snapline originates from the TOP ("Up") of the screen

    Class nsString = cls("NSString");
    int labelIdx = 0;

    if (strchr(snapStr, ',') != NULL && strncmp(snapStr, "10,", 3) != 0) {
        // Rich ESP format: canShoot,lx,ly,bx,by,bw,bh,dist,name;...
        char *savePtr = NULL;
        char *token = strtok_r(snapStr, ";", &savePtr);
        while (token && labelIdx < MAX_ESP_LABELS) {
            int canShoot = 0, lx = 0, ly = 0, bx = 0, by = 0, bw = 0, bh = 0, dist = 0;
            char nameBuf[64] = { 0 };

            if (sscanf(token, "%d,%d,%d,%d,%d,%d,%d,%d,%63s",
                       &canShoot, &lx, &ly, &bx, &by, &bw, &bh, &dist, nameBuf) >= 9) {
                double s_bx = (double)bx / 10000.0 * winW;
                double s_by = (double)by / 10000.0 * winH;
                double s_bw = (double)bw / 10000.0 * winW;
                double s_bh = (double)bh / 10000.0 * winH;

                // Snapline from top-center to top of enemy bounding box
                id lineTarget = canShoot ? greenLineP : redLineP;
                ((msgSend_void_pt)objc_msgSend)(lineTarget, sel("moveToPoint:"), CGPointMake(startX, startY));
                ((msgSend_void_pt)objc_msgSend)(lineTarget, sel("addLineToPoint:"), CGPointMake(s_bx + s_bw * 0.5, s_by));

                // Bounding box
                id boxTarget = canShoot ? greenBoxP : redBoxP;
                id rectP = ((msgSend_id_rect)objc_msgSend)((id)pathCls, sel("bezierPathWithRect:"), CGRectMake(s_bx, s_by, s_bw, s_bh));
                if (rectP) {
                    ((msgSend_void_id)objc_msgSend)(boxTarget, sel("appendPath:"), rectP);
                }

                // Real Name & distance badge
                if (labelIdx < MAX_ESP_LABELS && g_espTextLayers[labelIdx]) {
                    id tLayer = g_espTextLayers[labelIdx];
                    char tagStr[96];
                    snprintf(tagStr, sizeof(tagStr), "%s [%dm]", nameBuf, dist);
                    id nsTxt = nsString ? ((id (*)(id, SEL, const char *))objc_msgSend)((id)nsString, sel("stringWithUTF8String:"), tagStr) : NULL;

                    double tagW = strlen(tagStr) * 6.5 + 14.0;
                    if (tagW < 60.0) tagW = 60.0;
                    double tagH = 14.0;
                    double tagX = s_bx + (s_bw - tagW) * 0.5;
                    double tagY = s_by - tagH - 2.0;
                    if (tagY < 20.0) tagY = s_by + s_bh + 2.0;

                    ((msgSend_void_rect)objc_msgSend)(tLayer, sel("setFrame:"), CGRectMake(tagX, tagY, tagW, tagH));
                    if (nsTxt) ((msgSend_void_id)objc_msgSend)(tLayer, sel("setString:"), nsTxt);
                    ((msgSend_void_long)objc_msgSend)(tLayer, sel("setHidden:"), 0);
                    labelIdx++;
                }
            }
            token = strtok_r(NULL, ";", &savePtr);
        }
    } else if (strncmp(snapStr, "10,", 3) == 0) {
        // Standard snapshot format fallback: 10,esp_state,aim_state,count,x1,y1,locked1,...
        char *savePtr = NULL;
        char *token = strtok_r(snapStr, ",", &savePtr); // "10"
        if (token) token = strtok_r(NULL, ",", &savePtr); // esp_state
        if (token) token = strtok_r(NULL, ",", &savePtr); // aim_state
        if (token) token = strtok_r(NULL, ",", &savePtr); // count
        int countVal = token ? atoi(token) : 0;
        for (int k = 0; k < countVal && labelIdx < MAX_ESP_LABELS; k++) {
            char *xTok = strtok_r(NULL, ",", &savePtr);
            char *yTok = strtok_r(NULL, ",", &savePtr);
            char *lockTok = strtok_r(NULL, ",", &savePtr);
            if (!xTok || !yTok || !lockTok) break;
            int x_i = atoi(xTok);
            int y_i = atoi(yTok);
            int locked = atoi(lockTok);

            double s_x = (double)x_i / 10000.0 * winW;
            double s_y = (double)y_i / 10000.0 * winH;
            double boxH = 44.0;
            double boxW = 22.0;

            id lineTarget = locked ? greenLineP : redLineP;
            ((msgSend_void_pt)objc_msgSend)(lineTarget, sel("moveToPoint:"), CGPointMake(startX, startY));
            ((msgSend_void_pt)objc_msgSend)(lineTarget, sel("addLineToPoint:"), CGPointMake(s_x, s_y));

            id boxTarget = locked ? greenBoxP : redBoxP;
            id rectP = ((msgSend_id_rect)objc_msgSend)((id)pathCls, sel("bezierPathWithRect:"), CGRectMake(s_x - boxW * 0.5, s_y - boxH * 0.5, boxW, boxH));
            if (rectP) {
                ((msgSend_void_id)objc_msgSend)(boxTarget, sel("appendPath:"), rectP);
            }

            if (labelIdx < MAX_ESP_LABELS && g_espTextLayers[labelIdx]) {
                id tLayer = g_espTextLayers[labelIdx];
                const char *tagStr = locked ? "Enemy [Locked]" : "Enemy";
                id nsTxt = nsString ? ((id (*)(id, SEL, const char *))objc_msgSend)((id)nsString, sel("stringWithUTF8String:"), tagStr) : NULL;
                ((msgSend_void_rect)objc_msgSend)(tLayer, sel("setFrame:"), CGRectMake(s_x - 30.0, s_y - boxH * 0.5 - 16.0, 60.0, 14.0));
                if (nsTxt) ((msgSend_void_id)objc_msgSend)(tLayer, sel("setString:"), nsTxt);
                ((msgSend_void_long)objc_msgSend)(tLayer, sel("setHidden:"), 0);
                labelIdx++;
            }
        }
    }

    for (int k = labelIdx; k < MAX_ESP_LABELS; k++) {
        if (g_espTextLayers[k]) {
            ((msgSend_void_long)objc_msgSend)(g_espTextLayers[k], sel("setHidden:"), 1);
        }
    }

    if (g_espRedLineLayer && redLineP) {
        id cgP = ((id (*)(id, SEL))objc_msgSend)(redLineP, sel("CGPath"));
        ((msgSend_void_id)objc_msgSend)(g_espRedLineLayer, sel("setPath:"), cgP);
    }
    if (g_espGreenLineLayer && greenLineP) {
        id cgP = ((id (*)(id, SEL))objc_msgSend)(greenLineP, sel("CGPath"));
        ((msgSend_void_id)objc_msgSend)(g_espGreenLineLayer, sel("setPath:"), cgP);
    }
    if (g_espRedBoxLayer && redBoxP) {
        id cgP = ((id (*)(id, SEL))objc_msgSend)(redBoxP, sel("CGPath"));
        ((msgSend_void_id)objc_msgSend)(g_espRedBoxLayer, sel("setPath:"), cgP);
    }
    if (g_espGreenBoxLayer && greenBoxP) {
        id cgP = ((id (*)(id, SEL))objc_msgSend)(greenBoxP, sel("CGPath"));
        ((msgSend_void_id)objc_msgSend)(g_espGreenBoxLayer, sel("setPath:"), cgP);
    }

    if (caTrans) {
        ((id (*)(id, SEL))objc_msgSend)((id)caTrans, sel("commit"));
    }

    free(snapStr);
}

static BOOL s_hasDisplayLink = NO;

static void timerTick_imp(id self, SEL _cmd, id timer) {
    static int tickCount = 0;
    tickCount++;

    static BOOL s_swizzledCoreInfo = NO;
    if (!s_swizzledCoreInfo) {
        Class targetCls = cls("ROSFlyTestTarget");
        if (targetCls) {
            Method m = class_getInstanceMethod(targetCls, sel("info:"));
            if (m) {
                method_setImplementation(m, (IMP)showCustomInfo_imp);
                s_swizzledCoreInfo = YES;
                printf("[FlyMenuUI] Swizzled ROSFlyTestTarget info: -> showCustomInfo_imp in timerTick\n");
            }
        }
    }

    // Proactively hide FlyMenu_core raw panel directly from memory
    id corePanel = getCoreFlyPanelFromMemory();
    if (corePanel && !g_panel) {
        ((msgSend_void_long)objc_msgSend)(corePanel, sel("setHidden:"), 1);
    }

    id win = getActiveWindow();
    if (!win) return;

    // 1. Ensure floating logo button and on-screen Fly & Aim HUDs are present on window
    ensureFloatingButtonOnWindow(win);
    ensureFloatingFlyHUD(win);
    ensureFloatingAimHUD(win);

    // 2. Discover and hook FlyMenu_core panel across windows safely
    if (!g_panel) {
        id p = findFlyPanel();
        if (p) {
            g_panel = p;
            setupMenuUI(win, g_panel);
        }
    } else {
        // Ensure g_panel is attached if window was reconstructed
        id pSuper = ((id (*)(id, SEL))objc_msgSend)(g_panel, sel("superview"));
        if (!pSuper) {
            ((msgSend_void_id)objc_msgSend)(win, sel("addSubview:"), g_panel);
        }

        // Update UI switches smoothly
        if (tickCount % 4 == 0) {
            updateRowStates();
        }

        // Periodically ensure Python combat module is synced with Aim Smooth & Aimbot settings
        if (tickCount % 20 == 0) {
            Class defsCls = cls("NSUserDefaults");
            if (defsCls) {
                id defs = ((id (*)(id, SEL))objc_msgSend)((id)defsCls, sel("standardUserDefaults"));
                Class strCls = cls("NSString");
                if (defs && strCls) {
                    id k = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)strCls, sel("alloc")), sel("initWithUTF8String:"), "sw_aimsmooth");
                    if (k) {
                        BOOL cur = (BOOL)((long (*)(id, SEL, id))objc_msgSend)(defs, sel("boolForKey:"), k);
                        char pyCmd[128];
                        snprintf(pyCmd, sizeof(pyCmd), "set_aim_smooth(%s)", cur ? "True" : "False");
                        runCombatPython(pyCmd);
                    }
                    id kAim = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)strCls, sel("alloc")), sel("initWithUTF8String:"), "sw_aimbot");
                    if (kAim) {
                        BOOL curAim = (BOOL)((long (*)(id, SEL, id))objc_msgSend)(defs, sel("boolForKey:"), kAim);
                        char pyCmd[128];
                        snprintf(pyCmd, sizeof(pyCmd), "set_aim(%s)", curAim ? "True" : "False");
                        runCombatPython(pyCmd);
                    }
                }
            }
        }

        // Keep floating logo, open menu, and ESP overlay properly ordered on top
        if (tickCount % 20 == 0) {
            if (g_espOverlay) {
                id espSuper = ((id (*)(id, SEL))objc_msgSend)(g_espOverlay, sel("superview"));
                if (espSuper != win) {
                    ((msgSend_void_id)objc_msgSend)(win, sel("addSubview:"), g_espOverlay);
                }
                ((msgSend_void_id)objc_msgSend)(win, sel("bringSubviewToFront:"), g_espOverlay);
            }
            if (g_floatBtn) {
                id fSuper = ((id (*)(id, SEL))objc_msgSend)(g_floatBtn, sel("superview"));
                if (fSuper) {
                    ((msgSend_void_id)objc_msgSend)(fSuper, sel("bringSubviewToFront:"), g_floatBtn);
                }
            }
            if (g_aimHudView) {
                id aSuper = ((id (*)(id, SEL))objc_msgSend)(g_aimHudView, sel("superview"));
                if (aSuper) {
                    ((msgSend_void_id)objc_msgSend)(aSuper, sel("bringSubviewToFront:"), g_aimHudView);
                }
            }
            long isHidden = (long)((long (*)(id, SEL))objc_msgSend)(g_panel, sel("isHidden"));
            if (!isHidden) {
                id curSuper = ((id (*)(id, SEL))objc_msgSend)(g_panel, sel("superview"));
                if (curSuper) {
                    ((msgSend_void_id)objc_msgSend)(curSuper, sel("bringSubviewToFront:"), g_panel);
                }
            }
        }
    }

    // 3. Render rich ESP overlay smoothly (fallback if CADisplayLink is not present)
    if (!s_hasDisplayLink) {
        updateESPOverlay(win);
    }
}

static void displayLinkTick_imp(id self, SEL _cmd, id sender) {
    @autoreleasepool {
        id win = getActiveWindow();
        if (win) {
            updateESPOverlay(win);
        }
    }
}

__attribute__((constructor))
static void initFlyMenuUI(void) {
    printf("[FlyMenuUI] Constructor called -> Initializing...\n");

    // 1. Swizzle -[NSBundle pathForResource:ofType:] safely
    Class nsBundle = cls("NSBundle");
    if (nsBundle) {
        Method m = class_getInstanceMethod(nsBundle, sel("pathForResource:ofType:"));
        if (m) {
            orig_pathForResource = (id (*)(id, SEL, id, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)custom_pathForResource);
            printf("[FlyMenuUI] Hooked -[NSBundle pathForResource:ofType:]\n");
        }
    }

    // 2. Load FlyMenu_core.dylib
    const char *coreCandidates[] = {
        "/Library/MobileSubstrate/DynamicLibraries/FlyMenu_core.dylib",
        "/var/jb/Library/MobileSubstrate/DynamicLibraries/FlyMenu_core.dylib",
        "/var/jb/usr/lib/TweakInject/FlyMenu_core.dylib",
        "/usr/lib/TweakInject/FlyMenu_core.dylib",
        "@executable_path/FlyMenu_core.dylib",
        "FlyMenu_core.dylib",
        NULL
    };
    void *h = NULL;
    for (int i = 0; coreCandidates[i]; i++) {
        h = dlopen(coreCandidates[i], RTLD_NOW | RTLD_GLOBAL);
        if (h) {
            printf("[FlyMenuUI] Loaded core from: %s\n", coreCandidates[i]);
            break;
        }
    }
    if (!h) {
        printf("[FlyMenuUI] Warning: core not loaded: %s\n", dlerror());
    }

    // 2b. Load ros.dylib (for 1 Hit Kill & Multi-Cheat features)
    const char *rosCandidates[] = {
        "/Library/MobileSubstrate/DynamicLibraries/ros.dylib",
        "/var/jb/Library/MobileSubstrate/DynamicLibraries/ros.dylib",
        "/var/jb/usr/lib/TweakInject/ros.dylib",
        "/usr/lib/TweakInject/ros.dylib",
        "@executable_path/ros.dylib",
        "ros.dylib",
        NULL
    };
    void *hRos = NULL;
    for (int i = 0; rosCandidates[i]; i++) {
        hRos = dlopen(rosCandidates[i], RTLD_NOW | RTLD_GLOBAL);
        if (hRos) {
            printf("[FlyMenuUI] Loaded ros.dylib from: %s\n", rosCandidates[i]);
            break;
        }
    }
    if (!hRos) {
        printf("[FlyMenuUI] Note: ros.dylib dlopen fallback check: %s\n", dlerror());
    }

    // Suppress ROS.deb on-screen UI (caidan menuView1, SCLAlertView, FPSDisplay)
    suppressROSDebUI();

    // 3. Register ROSToggleSwitch and ROSUIManager classes dynamically
    Class superCls = cls("NSObject");
    if (!superCls) return;

    Class swCls = objc_allocateClassPair(superCls, "ROSToggleSwitch", 0);
    if (swCls) {
        class_addMethod(swCls, sel("isOn"), (IMP)toggleSw_isOn, "B@:");
        class_addMethod(swCls, sel("on"), (IMP)toggleSw_isOn, "B@:");
        class_addMethod(swCls, sel("setOn:"), (IMP)toggleSw_setOn, "v@:B");
        objc_registerClassPair(swCls);
        g_toggleSwitchCls = swCls;
    } else {
        g_toggleSwitchCls = cls("ROSToggleSwitch");
    }

    Class uiMgrCls = objc_allocateClassPair(superCls, "ROSUIManager", 0);
    if (uiMgrCls) {
        class_addMethod(uiMgrCls, sel("handleFloatPan:"), (IMP)handleFloatPan_imp, "v@:@");
        class_addMethod(uiMgrCls, sel("handleMenuPan:"), (IMP)handleMenuPan_imp, "v@:@");
        class_addMethod(uiMgrCls, sel("toggleMenu:"), (IMP)toggleMenu_imp, "v@:@");
        class_addMethod(uiMgrCls, sel("closeMenu:"), (IMP)closeMenu_imp, "v@:@");
        class_addMethod(uiMgrCls, sel("timerTick:"), (IMP)timerTick_imp, "v@:@");
        class_addMethod(uiMgrCls, sel("displayLinkTick:"), (IMP)displayLinkTick_imp, "v@:@");
        class_addMethod(uiMgrCls, sel("selectTab:"), (IMP)selectTab_imp, "v@:@");
        class_addMethod(uiMgrCls, sel("toggleOneHit:"), (IMP)toggleOneHit_imp, "v@:@");
        class_addMethod(uiMgrCls, sel("toggleSpeedEpic:"), (IMP)toggleSpeedEpic_imp, "v@:@");
        class_addMethod(uiMgrCls, sel("toggleNoRecoil:"), (IMP)toggleNoRecoil_imp, "v@:@");
        class_addMethod(uiMgrCls, sel("toggleWallhack:"), (IMP)toggleWallhack_imp, "v@:@");
        class_addMethod(uiMgrCls, sel("toggleAimbot:"), (IMP)toggleAimbot_imp, "v@:@");
        class_addMethod(uiMgrCls, sel("toggleAimSmooth:"), (IMP)toggleAimSmooth_imp, "v@:@");
        class_addMethod(uiMgrCls, sel("toggleEsp:"), (IMP)toggleEsp_imp, "v@:@");
        class_addMethod(uiMgrCls, sel("onFlyHudToggle:"), (IMP)onFlyHudToggle_imp, "v@:@");
        class_addMethod(uiMgrCls, sel("onFlyHudUpStart:"), (IMP)onFlyHudUpStart_imp, "v@:@");
        class_addMethod(uiMgrCls, sel("onFlyHudDownStart:"), (IMP)onFlyHudDownStart_imp, "v@:@");
        class_addMethod(uiMgrCls, sel("onFlyHudLiftStop:"), (IMP)onFlyHudLiftStop_imp, "v@:@");
        class_addMethod(uiMgrCls, sel("toggleFlyHudOption:"), (IMP)toggleFlyHudOption_imp, "v@:@");
        class_addMethod(uiMgrCls, sel("showCustomInfo:"), (IMP)showCustomInfo_imp, "v@:@");
        class_addMethod(uiMgrCls, sel("closeInfoModal:"), (IMP)closeInfoModal_imp, "v@:@");
        class_addMethod(uiMgrCls, sel("openTelegramGroup:"), (IMP)openTelegramGroup_imp, "v@:@");
        class_addMethod(uiMgrCls, sel("openTelegramUser:"), (IMP)openTelegramUser_imp, "v@:@");
        class_addMethod(uiMgrCls, sel("isOn"), (IMP)swIsOn_fallback, "B@:");
        objc_registerClassPair(uiMgrCls);
    } else {
        uiMgrCls = cls("ROSUIManager");
        if (uiMgrCls) {
            class_addMethod(uiMgrCls, sel("toggleAimbot:"), (IMP)toggleAimbot_imp, "v@:@");
            class_addMethod(uiMgrCls, sel("toggleAimSmooth:"), (IMP)toggleAimSmooth_imp, "v@:@");
            class_addMethod(uiMgrCls, sel("toggleEsp:"), (IMP)toggleEsp_imp, "v@:@");
            class_addMethod(uiMgrCls, sel("onFlyHudToggle:"), (IMP)onFlyHudToggle_imp, "v@:@");
            class_addMethod(uiMgrCls, sel("onFlyHudUpStart:"), (IMP)onFlyHudUpStart_imp, "v@:@");
            class_addMethod(uiMgrCls, sel("onFlyHudDownStart:"), (IMP)onFlyHudDownStart_imp, "v@:@");
            class_addMethod(uiMgrCls, sel("onFlyHudLiftStop:"), (IMP)onFlyHudLiftStop_imp, "v@:@");
            class_addMethod(uiMgrCls, sel("toggleFlyHudOption:"), (IMP)toggleFlyHudOption_imp, "v@:@");
            class_addMethod(uiMgrCls, sel("showCustomInfo:"), (IMP)showCustomInfo_imp, "v@:@");
            class_addMethod(uiMgrCls, sel("closeInfoModal:"), (IMP)closeInfoModal_imp, "v@:@");
            class_addMethod(uiMgrCls, sel("openTelegramGroup:"), (IMP)openTelegramGroup_imp, "v@:@");
            class_addMethod(uiMgrCls, sel("openTelegramUser:"), (IMP)openTelegramUser_imp, "v@:@");
        }
    }
    if (uiMgrCls && !g_uiMgr) {
        g_uiMgr = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)uiMgrCls, sel("alloc")), sel("init"));
    }

    Class targetCls = cls("ROSFlyTestTarget");
    if (targetCls) {
        Method m = class_getInstanceMethod(targetCls, sel("info:"));
        if (m) {
            method_setImplementation(m, (IMP)showCustomInfo_imp);
            printf("[FlyMenuUI] Hooked -[ROSFlyTestTarget info:] -> showCustomInfo_imp\n");
        }
        class_addMethod(targetCls, sel("showCustomInfo:"), (IMP)showCustomInfo_imp, "v@:@");
        class_addMethod(targetCls, sel("closeInfoModal:"), (IMP)closeInfoModal_imp, "v@:@");
        class_addMethod(targetCls, sel("openTelegramGroup:"), (IMP)openTelegramGroup_imp, "v@:@");
        class_addMethod(targetCls, sel("openTelegramUser:"), (IMP)openTelegramUser_imp, "v@:@");
    }

    // 4. Safe & fast UI initialization on the main queue
    void (^armTimerBlock)(void) = ^{
        static BOOL s_armed = NO;
        if (s_armed || !g_uiMgr) return;

        // Proactively hide FlyMenu_core panel the moment it is loaded into memory
        id corePanel = getCoreFlyPanelFromMemory();
        if (corePanel) {
            ((msgSend_void_long)objc_msgSend)(corePanel, sel("setHidden:"), 1);
        }

        id win = getActiveWindow();
        if (!win) {
            // Window does not have rootViewController yet; wait for next tick
            return;
        }

        suppressROSDebUI();
        purgeROSDebViews();

        ensureAndGetScriptPath("ros_fly.py", EMBEDDED_ROS_FLY_PY, EMBEDDED_ROS_FLY_PY_LEN);
        ensureAndGetScriptPath("ros_combat.py", EMBEDDED_ROS_COMBAT_PY, EMBEDDED_ROS_COMBAT_PY_LEN);

        Class nsTimer = cls("NSTimer");
        Class nsRunLoop = cls("NSRunLoop");
        Class nsString = cls("NSString");
        if (!nsTimer || !nsRunLoop || !nsString) return;

        id timer = ((msgSend_id_id_sel_id_bool)objc_msgSend)((id)nsTimer, sel("timerWithTimeInterval:target:selector:userInfo:repeats:"),
                                                            (double)0.10, g_uiMgr, sel("timerTick:"), NULL, YES);
        if (!timer) return;
        id mainLoop = ((id (*)(id, SEL))objc_msgSend)((id)nsRunLoop, sel("mainRunLoop"));
        if (!mainLoop) return;
        id commonMode = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "kCFRunLoopCommonModes");
        if (commonMode) {
            ((id (*)(id, SEL, id, id))objc_msgSend)(mainLoop, sel("addTimer:forMode:"), timer, commonMode);
            s_armed = YES;
            printf("[FlyMenuUI] UI timer successfully armed\n");
            timerTick_imp(g_uiMgr, sel("timerTick:"), timer);

            // Arm CADisplayLink for 60/120 FPS ultra-smooth V-SYNC ESP line tracking
            Class caDisplayLinkCls = cls("CADisplayLink");
            if (caDisplayLinkCls) {
                id dLink = ((id (*)(id, SEL, id, SEL))objc_msgSend)((id)caDisplayLinkCls, sel("displayLinkWithTarget:selector:"), g_uiMgr, sel("displayLinkTick:"));
                if (dLink) {
                    ((void (*)(id, SEL, id, id))objc_msgSend)(dLink, sel("addToRunLoop:forMode:"), mainLoop, commonMode);
                    s_hasDisplayLink = YES;
                    printf("[FlyMenuUI] CADisplayLink successfully armed for 60/120 FPS smooth ESP tracking\n");
                }
            }
        }
    };

    // Staggered launch delays so we safely wait for the game window to have a rootViewController
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), armTimerBlock);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), armTimerBlock);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), armTimerBlock);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), armTimerBlock);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), armTimerBlock);
}
