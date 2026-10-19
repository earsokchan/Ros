#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <unistd.h>
#include <mach-o/dyld.h>

#include "embedded_scripts.h"
#import "embedded_header_png.h"

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
#define NUM_BUTTONS 10
static id g_coreBtns[NUM_BUTTONS] = { NULL };    // 0:Fly, 1:Up, 2:Down, 3:Aim, 4:Esp, 5:Info, 6:1Hit, 7:Speed, 8:Recoil, 9:Wallhack
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
    id keyWin = ((id (*)(id, SEL))objc_msgSend)(app, sel("keyWindow"));
    if (keyWin) return keyWin;
    id windows = ((id (*)(id, SEL))objc_msgSend)(app, sel("windows"));
    if (windows) {
        long count = (long)((long (*)(id, SEL))objc_msgSend)(windows, sel("count"));
        if (count > 0) {
            return ((msgSend_id_long)objc_msgSend)(windows, sel("objectAtIndex:"), 0);
        }
    }
    return NULL;
}

// Comprehensive search for FlyMenu_core's panel across ALL UIWindows
// Note: DLGMem views are preserved untouched so DLG operates smoothly alongside FlyMenu.
static id findFlyPanel(void) {
    Class uiApp = cls("UIApplication");
    if (!uiApp) return NULL;
    id app = ((id (*)(id, SEL))objc_msgSend)((id)uiApp, sel("sharedApplication"));
    if (!app) return NULL;
    id windows = ((id (*)(id, SEL))objc_msgSend)(app, sel("windows"));
    if (!windows) return NULL;
    long winCount = (long)((long (*)(id, SEL))objc_msgSend)(windows, sel("count"));
    Class btnCls = cls("UIButton");
    if (!btnCls) return NULL;

    for (long w = 0; w < winCount; w++) {
        id win = ((msgSend_id_long)objc_msgSend)(windows, sel("objectAtIndex:"), w);
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
            if (innerCount < 6) continue;

            for (long j = 0; j < innerCount; j++) {
                id sub = ((msgSend_id_long)objc_msgSend)(innerSubs, sel("objectAtIndex:"), j);
                if (!sub) continue;
                if ((long)((long (*)(id, SEL, id))objc_msgSend)(sub, sel("isKindOfClass:"), (id)btnCls)) {
                    id title = ((msgSend_id_long)objc_msgSend)(sub, sel("titleForState:"), 0);
                    if (title) {
                        const char *utf = (const char *)((id (*)(id, SEL))objc_msgSend)(title, sel("UTF8String"));
                        if (utf && (strstr(utf, "FLY") != NULL || strstr(utf, "ESP") != NULL || strstr(utf, "AIM") != NULL)) {
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

    // 1. Save state
    ((void (*)(id, SEL, BOOL, id))objc_msgSend)(defs, sel("setBool:forKey:"), newState, key);
    ((id (*)(id, SEL))objc_msgSend)(defs, sel("synchronize"));

    // 2. Trigger ros.dylib's memory patch engine via +[NSObject feature7:]
    Class nsObj = cls("NSObject");
    SEL f7Sel = sel("feature7:");
    if (nsObj && ((BOOL (*)(id, SEL, SEL))objc_msgSend)((id)nsObj, sel("respondsToSelector:"), f7Sel)) {
        Class uiSw = cls("UISwitch");
        if (uiSw) {
            id fakeSw = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)uiSw, sel("alloc")), sel("init"));
            if (fakeSw) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(fakeSw, sel("setOn:"), newState);
                ((void (*)(id, SEL, id))objc_msgSend)((id)nsObj, f7Sel, fakeSw);
            }
        }
    }

    printf("[FlyMenuUI] 1 Hit Kill VIP toggled -> %s\n", newState ? "ENABLED" : "DISABLED");
    updateRowStates();
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

    // 1. Save state
    ((void (*)(id, SEL, BOOL, id))objc_msgSend)(defs, sel("setBool:forKey:"), newState, key);
    ((id (*)(id, SEL))objc_msgSend)(defs, sel("synchronize"));

    // 2. Trigger ros.dylib's memory patch engine via +[NSObject feature6:]
    Class nsObj = cls("NSObject");
    SEL f6Sel = sel("feature6:");
    if (nsObj && ((BOOL (*)(id, SEL, SEL))objc_msgSend)((id)nsObj, sel("respondsToSelector:"), f6Sel)) {
        Class uiSw = cls("UISwitch");
        if (uiSw) {
            id fakeSw = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)uiSw, sel("alloc")), sel("init"));
            if (fakeSw) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(fakeSw, sel("setOn:"), newState);
                ((void (*)(id, SEL, id))objc_msgSend)((id)nsObj, f6Sel, fakeSw);
            }
        }
    }

    printf("[FlyMenuUI] Speed Epic VIP toggled -> %s\n", newState ? "ENABLED" : "DISABLED");
    updateRowStates();
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

    // 1. Save state
    ((void (*)(id, SEL, BOOL, id))objc_msgSend)(defs, sel("setBool:forKey:"), newState, key);
    ((id (*)(id, SEL))objc_msgSend)(defs, sel("synchronize"));

    // 2. Trigger ros.dylib's memory patch engine via +[NSObject feature2:]
    Class nsObj = cls("NSObject");
    SEL f2Sel = sel("feature2:");
    if (nsObj && ((BOOL (*)(id, SEL, SEL))objc_msgSend)((id)nsObj, sel("respondsToSelector:"), f2Sel)) {
        Class uiSw = cls("UISwitch");
        if (uiSw) {
            id fakeSw = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)uiSw, sel("alloc")), sel("init"));
            if (fakeSw) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(fakeSw, sel("setOn:"), newState);
                ((void (*)(id, SEL, id))objc_msgSend)((id)nsObj, f2Sel, fakeSw);
            }
        }
    }

    printf("[FlyMenuUI] No Recoil 100%% VIP toggled -> %s\n", newState ? "ENABLED" : "DISABLED");
    updateRowStates();
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

    // 1. Save state
    ((void (*)(id, SEL, BOOL, id))objc_msgSend)(defs, sel("setBool:forKey:"), newState, key);
    ((id (*)(id, SEL))objc_msgSend)(defs, sel("synchronize"));

    // 2. Trigger ros.dylib's memory patch engine via +[NSObject feature1:]
    Class nsObj = cls("NSObject");
    SEL f1Sel = sel("feature1:");
    if (nsObj && ((BOOL (*)(id, SEL, SEL))objc_msgSend)((id)nsObj, sel("respondsToSelector:"), f1Sel)) {
        Class uiSw = cls("UISwitch");
        if (uiSw) {
            id fakeSw = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)uiSw, sel("alloc")), sel("init"));
            if (fakeSw) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(fakeSw, sel("setOn:"), newState);
                ((void (*)(id, SEL, id))objc_msgSend)((id)nsObj, f1Sel, fakeSw);
            }
        }
    }

    printf("[FlyMenuUI] Wallhack VIP toggled -> %s\n", newState ? "ENABLED" : "DISABLED");
    updateRowStates();
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
            // Aim/Combat tab: show Aim (3), 1 Hit (6), No Recoil (8)
            show = (i == 3 || i == 6 || i == 8);
        } else if (g_selectedTab == 1) {
            // ESP/Vision tab: show ESP (4), Wallhack (9)
            show = (i == 4 || i == 9);
        } else if (g_selectedTab == 2) {
            // Fly / Mobility tab: show Fly, Up, Down, Speed Epic (indices 0, 1, 2, 7)
            show = (i == 0 || i == 1 || i == 2 || i == 7);
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
        flyOn = (strstr(s, "ON") != NULL || strstr(s, "STOP") != NULL);
    }
    setSwitchState(0, flyOn, onPillBg, offPillBg, whiteColor, knobOffColor, activeBorder, normalBorder);

    // Aim State (Button 3)
    BOOL aimOn = NO;
    if (g_coreBtns[3]) {
        id t = ((msgSend_id_long)objc_msgSend)(g_coreBtns[3], sel("titleForState:"), 0);
        const char *s = t ? (const char *)((id (*)(id, SEL))objc_msgSend)(t, sel("UTF8String")) : "";
        aimOn = (strstr(s, "ON") != NULL || strstr(s, "LOCK") != NULL);
    }
    setSwitchState(3, aimOn, onPillBg, offPillBg, whiteColor, knobOffColor, activeBorder, normalBorder);

    // ESP State (Button 4)
    BOOL espOn = NO;
    if (g_coreBtns[4]) {
        id t = ((msgSend_id_long)objc_msgSend)(g_coreBtns[4], sel("titleForState:"), 0);
        const char *s = t ? (const char *)((id (*)(id, SEL))objc_msgSend)(t, sel("UTF8String")) : "";
        espOn = (strstr(s, "ON") != NULL);
    }
    setSwitchState(4, espOn, onPillBg, offPillBg, whiteColor, knobOffColor, activeBorder, normalBorder);

    // Info button (Button 5)
    if (g_rowPills[5]) {
        ((msgSend_void_id)objc_msgSend)(g_rowPills[5], sel("setBackgroundColor:"), offPillBg);
    }

    // 1 Hit Kill VIP (Button 6)
    BOOL oneHitOn = NO;
    Class defsCls = cls("NSUserDefaults");
    if (defsCls) {
        id defs = ((id (*)(id, SEL))objc_msgSend)((id)defsCls, sel("standardUserDefaults"));
        if (defs) {
            Class strCls = cls("NSString");
            id key = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)strCls, sel("alloc")), sel("initWithUTF8String:"), "sw7");
            if (key) {
                oneHitOn = (BOOL)((long (*)(id, SEL, id))objc_msgSend)(defs, sel("boolForKey:"), key);
            }
        }
    }
    setSwitchState(6, oneHitOn, onPillBg, offPillBg, whiteColor, knobOffColor, activeBorder, normalBorder);

    // Speed Epic VIP (Button 7)
    BOOL speedOn = NO;
    if (defsCls) {
        id defs = ((id (*)(id, SEL))objc_msgSend)((id)defsCls, sel("standardUserDefaults"));
        if (defs) {
            Class strCls = cls("NSString");
            id key = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)strCls, sel("alloc")), sel("initWithUTF8String:"), "sw6");
            if (key) {
                speedOn = (BOOL)((long (*)(id, SEL, id))objc_msgSend)(defs, sel("boolForKey:"), key);
            }
        }
    }
    setSwitchState(7, speedOn, onPillBg, offPillBg, whiteColor, knobOffColor, activeBorder, normalBorder);

    // No Recoil 100% VIP (Button 8)
    BOOL recoilOn = NO;
    if (defsCls) {
        id defs = ((id (*)(id, SEL))objc_msgSend)((id)defsCls, sel("standardUserDefaults"));
        if (defs) {
            Class strCls = cls("NSString");
            id key = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)strCls, sel("alloc")), sel("initWithUTF8String:"), "sw2");
            if (key) {
                recoilOn = (BOOL)((long (*)(id, SEL, id))objc_msgSend)(defs, sel("boolForKey:"), key);
            }
        }
    }
    setSwitchState(8, recoilOn, onPillBg, offPillBg, whiteColor, knobOffColor, activeBorder, normalBorder);

    // Wallhack VIP (Button 9)
    BOOL wallhackOn = NO;
    if (defsCls) {
        id defs = ((id (*)(id, SEL))objc_msgSend)((id)defsCls, sel("standardUserDefaults"));
        if (defs) {
            Class strCls = cls("NSString");
            id key = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)strCls, sel("alloc")), sel("initWithUTF8String:"), "sw1");
            if (key) {
                wallhackOn = (BOOL)((long (*)(id, SEL, id))objc_msgSend)(defs, sel("boolForKey:"), key);
            }
        }
    }
    setSwitchState(9, wallhackOn, onPillBg, offPillBg, whiteColor, knobOffColor, activeBorder, normalBorder);
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

static void setupMenuUI(id win, id panel) {
    if (!panel || !win) return;
    long tag = (long)((long (*)(id, SEL))objc_msgSend)(panel, sel("tag"));
    if (tag == 0x777) return;
    ((msgSend_void_long)objc_msgSend)(panel, sel("setTag:"), 0x777);

    // 1. Initially hide menu by default
    ((msgSend_void_long)objc_msgSend)(panel, sel("setHidden:"), 1);

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
    }

    // 3. Size and style the main panel (280 width x 516 height)
    double panelW = 280.0;
    double panelH = 516.0;
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
        "Wallhack VIP"
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

        // Bring button to front so touches are natively received
        ((msgSend_void_id)objc_msgSend)(panel, sel("bringSubviewToFront:"), btn);
    }

    // 7. Ensure Floating Logo Button is on the active window
    ensureFloatingButtonOnWindow(win);
}

// Safely read rich ESP snapshot string generated by ros_combat in RAM-cached temp file
static char *getESPSnapshot(void) {
    const char *candidates[3] = { NULL, NULL, NULL };
    int count = 0;
    const char *tmp = getenv("TMPDIR");
    char tmpBuf[1024];
    if (tmp && *tmp) {
        snprintf(tmpBuf, sizeof(tmpBuf), "%s/ros_esp.dat", tmp);
        candidates[count++] = tmpBuf;
    }
    candidates[count++] = "/tmp/ros_esp.dat";

    FILE *f = NULL;
    for (int i = 0; i < count; i++) {
        f = fopen(candidates[i], "r");
        if (f) break;
    }
    if (!f) return NULL;

    char buf[8192];
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    if (n == 0) return NULL;
    buf[n] = '\0';
    return strdup(buf);
}

static void ensureESPOverlay(id win) {
    if (g_espOverlay || !win) return;

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

    // Add overlay to window, but keep panel and float button in front
    ((msgSend_void_id)objc_msgSend)(win, sel("addSubview:"), overlay);
    id pSuper = g_panel ? ((id (*)(id, SEL))objc_msgSend)(g_panel, sel("superview")) : NULL;
    if (pSuper == win) ((msgSend_void_id)objc_msgSend)(win, sel("bringSubviewToFront:"), g_panel);
    id fSuper = g_floatBtn ? ((id (*)(id, SEL))objc_msgSend)(g_floatBtn, sel("superview")) : NULL;
    if (fSuper == win) ((msgSend_void_id)objc_msgSend)(win, sel("bringSubviewToFront:"), g_floatBtn);
    g_espOverlay = overlay;
    printf("[FlyMenuUI] ESP Overlay created successfully\n");
}

static void updateESPOverlay(id win) {
    if (!win) return;
    ensureESPOverlay(win);
    if (!g_espOverlay) return;

    void *pool = objc_autoreleasePoolPush();

    // Check if ESP is ON in core button
    BOOL espActive = NO;
    if (g_coreBtns[4]) {
        id t = ((msgSend_id_long)objc_msgSend)(g_coreBtns[4], sel("titleForState:"), 0);
        const char *s = t ? (const char *)((id (*)(id, SEL))objc_msgSend)(t, sel("UTF8String")) : "";
        espActive = (strstr(s, "ON") != NULL);
    }

    static BOOL wasEspActive = NO;
    if (!espActive) {
        if (wasEspActive) {
            if (g_espRedLineLayer) ((msgSend_void_id)objc_msgSend)(g_espRedLineLayer, sel("setPath:"), NULL);
            if (g_espGreenLineLayer) ((msgSend_void_id)objc_msgSend)(g_espGreenLineLayer, sel("setPath:"), NULL);
            if (g_espRedBoxLayer) ((msgSend_void_id)objc_msgSend)(g_espRedBoxLayer, sel("setPath:"), NULL);
            if (g_espGreenBoxLayer) ((msgSend_void_id)objc_msgSend)(g_espGreenBoxLayer, sel("setPath:"), NULL);
            for (int i = 0; i < MAX_ESP_LABELS; i++) {
                if (g_espTextLayers[i]) ((msgSend_void_long)objc_msgSend)(g_espTextLayers[i], sel("setHidden:"), 1);
            }
            wasEspActive = NO;
        }
        objc_autoreleasePoolPop(pool);
        return;
    }
    wasEspActive = YES;

    char *snapStr = getESPSnapshot();
    if (!snapStr || strlen(snapStr) == 0) {
        if (g_espRedLineLayer) ((msgSend_void_id)objc_msgSend)(g_espRedLineLayer, sel("setPath:"), NULL);
        if (g_espGreenLineLayer) ((msgSend_void_id)objc_msgSend)(g_espGreenLineLayer, sel("setPath:"), NULL);
        if (g_espRedBoxLayer) ((msgSend_void_id)objc_msgSend)(g_espRedBoxLayer, sel("setPath:"), NULL);
        if (g_espGreenBoxLayer) ((msgSend_void_id)objc_msgSend)(g_espGreenBoxLayer, sel("setPath:"), NULL);
        for (int i = 0; i < MAX_ESP_LABELS; i++) {
            if (g_espTextLayers[i]) ((msgSend_void_long)objc_msgSend)(g_espTextLayers[i], sel("setHidden:"), 1);
        }
        if (snapStr) free(snapStr);
        objc_autoreleasePoolPop(pool);
        return;
    }

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
    double startY = winH * 0.94;

    Class nsString = cls("NSString");
    int labelIdx = 0;

    char *savePtr = NULL;
    char *token = strtok_r(snapStr, ";", &savePtr);
    while (token && labelIdx < MAX_ESP_LABELS) {
        int canShoot = 0, lx = 0, ly = 0, bx = 0, by = 0, bw = 0, bh = 0, dist = 0;
        char nameBuf[64] = { 0 };

        if (sscanf(token, "%d,%d,%d,%d,%d,%d,%d,%d,%63s",
                   &canShoot, &lx, &ly, &bx, &by, &bw, &bh, &dist, nameBuf) >= 9) {
            // Restore spaces in player name if encoded
            for (char *p = nameBuf; *p; p++) {
                if (*p == '_') *p = ' ';
            }

            double s_bx = (double)bx / 10000.0 * winW;
            double s_by = (double)by / 10000.0 * winH;
            double s_bw = (double)bw / 10000.0 * winW;
            double s_bh = (double)bh / 10000.0 * winH;

            // Snapline from bottom-center to bottom of enemy box
            id lineTarget = canShoot ? greenLineP : redLineP;
            ((msgSend_void_pt)objc_msgSend)(lineTarget, sel("moveToPoint:"), CGPointMake(startX, startY));
            ((msgSend_void_pt)objc_msgSend)(lineTarget, sel("addLineToPoint:"), CGPointMake(s_bx + s_bw * 0.5, s_by + s_bh));

            // Bounding box
            id boxTarget = canShoot ? greenBoxP : redBoxP;
            id rectP = ((msgSend_id_rect)objc_msgSend)((id)pathCls, sel("bezierPathWithRect:"), CGRectMake(s_bx, s_by, s_bw, s_bh));
            if (rectP) {
                ((msgSend_void_id)objc_msgSend)(boxTarget, sel("appendPath:"), rectP);
            }

            // Name & distance badge
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
    objc_autoreleasePoolPop(pool);
}

static void timerTick_imp(id self, SEL _cmd, id timer) {
    id win = getActiveWindow();
    if (!win) return;

    // 1. Ensure floating logo button is created and present on window
    ensureFloatingButtonOnWindow(win);

    // 2. Discover and hook FlyMenu_core panel across windows safely
    if (!g_panel) {
        id p = findFlyPanel();
        if (p) {
            g_panel = p;
            setupMenuUI(win, g_panel);
        }
    } else {
        static int tickCount = 0;
        tickCount++;
        if (tickCount % 8 == 0) {
            updateRowStates();
        }
        if (tickCount % 30 == 0) {
            if (g_floatBtn) {
                id fSuper = ((id (*)(id, SEL))objc_msgSend)(g_floatBtn, sel("superview"));
                if (fSuper) {
                    ((msgSend_void_id)objc_msgSend)(fSuper, sel("bringSubviewToFront:"), g_floatBtn);
                }
            }
        }
        updateESPOverlay(win);
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

    // 3. Register ROSUIManager class dynamically
    Class superCls = cls("NSObject");
    if (!superCls) return;
    Class uiMgrCls = objc_allocateClassPair(superCls, "ROSUIManager", 0);
    if (uiMgrCls) {
        class_addMethod(uiMgrCls, sel("handleFloatPan:"), (IMP)handleFloatPan_imp, "v@:@");
        class_addMethod(uiMgrCls, sel("handleMenuPan:"), (IMP)handleMenuPan_imp, "v@:@");
        class_addMethod(uiMgrCls, sel("toggleMenu:"), (IMP)toggleMenu_imp, "v@:@");
        class_addMethod(uiMgrCls, sel("closeMenu:"), (IMP)closeMenu_imp, "v@:@");
        class_addMethod(uiMgrCls, sel("timerTick:"), (IMP)timerTick_imp, "v@:@");
        class_addMethod(uiMgrCls, sel("selectTab:"), (IMP)selectTab_imp, "v@:@");
        class_addMethod(uiMgrCls, sel("toggleOneHit:"), (IMP)toggleOneHit_imp, "v@:@");
        class_addMethod(uiMgrCls, sel("toggleSpeedEpic:"), (IMP)toggleSpeedEpic_imp, "v@:@");
        class_addMethod(uiMgrCls, sel("toggleNoRecoil:"), (IMP)toggleNoRecoil_imp, "v@:@");
        class_addMethod(uiMgrCls, sel("toggleWallhack:"), (IMP)toggleWallhack_imp, "v@:@");
        objc_registerClassPair(uiMgrCls);
        g_uiMgr = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)uiMgrCls, sel("alloc")), sel("init"));
    }

    // 4. Safe post-launch configuration (1.5s delay to ensure UIKit is completely ready)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{

        id mainBundle = ((id (*)(id, SEL))objc_msgSend)((id)cls("NSBundle"), sel("mainBundle"));
        if (mainBundle) {
            id bundlePath = ((id (*)(id, SEL))objc_msgSend)(mainBundle, sel("bundlePath"));
            if (bundlePath) {
                const char *bStr = (const char *)((id (*)(id, SEL))objc_msgSend)(bundlePath, sel("UTF8String"));
                if (bStr) {
                    char flyPath[1024];
                    snprintf(flyPath, sizeof(flyPath), "%s/ros_fly.py", bStr);
                    if (access(flyPath, R_OK) != 0) {
                        FILE *f = fopen(flyPath, "wb");
                        if (f) {
                            fwrite(EMBEDDED_ROS_FLY_PY, 1, EMBEDDED_ROS_FLY_PY_LEN, f);
                            fclose(f);
                        }
                    }
                    char combatPath[1024];
                    snprintf(combatPath, sizeof(combatPath), "%s/ros_combat.py", bStr);
                    if (access(combatPath, R_OK) != 0) {
                        FILE *f = fopen(combatPath, "wb");
                        if (f) {
                            fwrite(EMBEDDED_ROS_COMBAT_PY, 1, EMBEDDED_ROS_COMBAT_PY_LEN, f);
                            fclose(f);
                        }
                    }
                }
            }
        }

        ensureAndGetScriptPath("ros_fly.py", EMBEDDED_ROS_FLY_PY, EMBEDDED_ROS_FLY_PY_LEN);
        ensureAndGetScriptPath("ros_combat.py", EMBEDDED_ROS_COMBAT_PY, EMBEDDED_ROS_COMBAT_PY_LEN);

        Class nsTimer = cls("NSTimer");
        if (!nsTimer || !g_uiMgr) return;
        id timer = ((msgSend_id_id_sel_id_bool)objc_msgSend)((id)nsTimer, sel("timerWithTimeInterval:target:selector:userInfo:repeats:"),
                                                            (double)0.033, g_uiMgr, sel("timerTick:"), NULL, YES);
        if (!timer) return;
        Class nsRunLoop = cls("NSRunLoop");
        if (!nsRunLoop) return;
        id mainLoop = ((id (*)(id, SEL))objc_msgSend)((id)nsRunLoop, sel("mainRunLoop"));
        if (!mainLoop) return;
        Class nsString = cls("NSString");
        id commonMode = nsString ? ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "kCFRunLoopCommonModes") : NULL;
        if (commonMode) {
            ((id (*)(id, SEL, id, id))objc_msgSend)(mainLoop, sel("addTimer:forMode:"), timer, commonMode);
            printf("[FlyMenuUI] UI timer successfully armed\n");
        }
    });
}
