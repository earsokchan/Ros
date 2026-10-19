#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <unistd.h>

#include "embedded_scripts.h"

#define sel(s) sel_registerName(s)
#define cls(c) objc_getClass(c)

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
typedef CGRect (*msgSend_rect)(id, SEL);
typedef CGPoint (*msgSend_pt_id)(id, SEL, id);
typedef void (*msgSend_void_pt_id)(id, SEL, CGPoint, id);
typedef CGPoint (*msgSend_pt)(id, SEL);
typedef void (*msgSend_void_pt)(id, SEL, CGPoint);
typedef void (*msgSend_void_long)(id, SEL, long);
typedef void (*msgSend_void_id)(id, SEL, id);
typedef void (*msgSend_void_id_sel_long)(id, SEL, id, SEL, long);
typedef void (*msgSend_void_ulong)(id, SEL, unsigned long);
typedef void (*msgSend_void_bool)(id, SEL, BOOL);

static id g_uiMgr = NULL;
static id g_panel = NULL;
static id g_floatBtn = NULL;
static id (*orig_pathForResource)(id self, SEL _cmd, id name, id ext) = NULL;

// References to the 6 native core buttons created by FlyMenu_core.dylib
#define NUM_BUTTONS 6
static id g_coreBtns[NUM_BUTTONS] = { NULL };    // 0:Fly, 1:Up, 2:Down, 3:Aim, 4:Esp, 5:Info
static id g_rowPills[NUM_BUTTONS] = { NULL };    // Toggle switch indicators
static id g_rowLabels[NUM_BUTTONS] = { NULL };   // Clean titles
static id g_tabBtns[4] = { NULL };              // 0:Aim, 1:Esp, 2:Fly, 3:Info
static int g_selectedTab = -1;                  // -1 = Show All

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

static id findFlyPanel(id win) {
    if (!win) return NULL;
    id subviews = ((id (*)(id, SEL))objc_msgSend)(win, sel("subviews"));
    if (!subviews) return NULL;
    long count = (long)((long (*)(id, SEL))objc_msgSend)(subviews, sel("count"));
    Class btnCls = cls("UIButton");
    if (!btnCls) return NULL;

    for (long i = 0; i < count; i++) {
        id v = ((msgSend_id_long)objc_msgSend)(subviews, sel("objectAtIndex:"), i);
        if (!v) continue;
        id innerSubs = ((id (*)(id, SEL))objc_msgSend)(v, sel("subviews"));
        if (!innerSubs) continue;
        long innerCount = (long)((long (*)(id, SEL))objc_msgSend)(innerSubs, sel("count"));
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
    return NULL;
}

// Load header.png or back.png
static id loadLogoImage(void) {
    Class uiImg = cls("UIImage");
    Class nsString = cls("NSString");
    if (!uiImg || !nsString) return NULL;

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
        if (access(candPaths[k], R_OK) == 0) {
            id p = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel("alloc")), sel("initWithUTF8String:"), candPaths[k]);
            if (p) {
                id img = ((msgSend_id_id)objc_msgSend)((id)uiImg, sel("imageWithContentsOfFile:"), p);
                if (img) return img;
            }
        }
    }

    id mb = ((id (*)(id, SEL))objc_msgSend)((id)cls("NSBundle"), sel("mainBundle"));
    if (mb) {
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
    return NULL;
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
        id win = ((id (*)(id, SEL))objc_msgSend)(g_panel, sel("window"));
        if (!win) win = ((id (*)(id, SEL))objc_msgSend)(g_panel, sel("superview"));
        if (win) {
            ((msgSend_void_id)objc_msgSend)(win, sel("bringSubviewToFront:"), g_panel);
        }
    } else {
        ((msgSend_void_long)objc_msgSend)(g_panel, sel("setHidden:"), 1);
    }
}

static void closeMenu_imp(id self, SEL _cmd, id sender) {
    if (!g_panel) return;
    ((msgSend_void_long)objc_msgSend)(g_panel, sel("setHidden:"), 1);
}

// Update layout of the 6 core buttons based on active tab filter
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
            // Aim tab: show Aim button (index 3)
            show = (i == 3);
        } else if (g_selectedTab == 1) {
            // ESP tab: show ESP button (index 4)
            show = (i == 4);
        } else if (g_selectedTab == 2) {
            // Fly tab: show Fly, Up, Down buttons (indices 0, 1, 2)
            show = (i == 0 || i == 1 || i == 2);
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

    for (int t = 0; t < 4; t++) {
        if (!g_tabBtns[t]) continue;
        BOOL isSel = (g_selectedTab == t);
        if (activeBg && inactiveBg) {
            ((msgSend_void_id)objc_msgSend)(g_tabBtns[t], sel("setBackgroundColor:"), isSel ? activeBg : inactiveBg);
        }
        if (whiteColor && greyColor) {
            ((msgSend_id_id_long)objc_msgSend)(g_tabBtns[t], sel("setTitleColor:forState:"), isSel ? whiteColor : greyColor, 0);
        }
    }

    updateRowLayout();
}

// Update pill colors & button card borders based on real core engine state
static void updateRowStates(void) {
    Class uiColor = cls("UIColor");
    if (!uiColor) return;

    id whiteColor = ((id (*)(id, SEL))objc_msgSend)((id)uiColor, sel("whiteColor"));
    id offPillBg = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.15, 0.15, 0.18, 1.0);
    id activeBorder = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.83, 0.11, 0.11, 1.0);
    id normalBorder = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.14, 0.14, 0.18, 1.0);
    id darkBg = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.08, 0.08, 0.11, 1.0);

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
    if (g_coreBtns[0] && g_rowPills[0]) {
        id t = ((msgSend_id_long)objc_msgSend)(g_coreBtns[0], sel("titleForState:"), 0);
        const char *s = t ? (const char *)((id (*)(id, SEL))objc_msgSend)(t, sel("UTF8String")) : "";
        flyOn = (strstr(s, "ON") != NULL);
        ((msgSend_void_id)objc_msgSend)(g_rowPills[0], sel("setBackgroundColor:"), flyOn ? whiteColor : offPillBg);
        id layer = ((id (*)(id, SEL))objc_msgSend)(g_coreBtns[0], sel("layer"));
        if (layer && activeBorder && normalBorder) {
            id c = ((id (*)(id, SEL))objc_msgSend)(flyOn ? activeBorder : normalBorder, sel("CGColor"));
            ((msgSend_void_id)objc_msgSend)(layer, sel("setBorderColor:"), c);
        }
    }

    // Up & Down Buttons visual state & hold feedback (Buttons 1 & 2)
    for (int k = 1; k <= 2; k++) {
        if (g_coreBtns[k] && g_rowPills[k]) {
            BOOL isPressed = (BOOL)((long (*)(id, SEL))objc_msgSend)(g_coreBtns[k], sel("isHighlighted"));
            ((msgSend_void_id)objc_msgSend)(g_rowPills[k], sel("setBackgroundColor:"), isPressed ? activeBorder : offPillBg);
            id layer = ((id (*)(id, SEL))objc_msgSend)(g_coreBtns[k], sel("layer"));
            if (layer && activeBorder && normalBorder) {
                id c = ((id (*)(id, SEL))objc_msgSend)(isPressed ? activeBorder : normalBorder, sel("CGColor"));
                ((msgSend_void_id)objc_msgSend)(layer, sel("setBorderColor:"), c);
            }
            if (g_rowLabels[k]) {
                ((msgSend_void_double)objc_msgSend)(g_rowLabels[k], sel("setAlpha:"), flyOn ? 1.0 : 0.45);
            }
            ((msgSend_void_double)objc_msgSend)(g_rowPills[k], sel("setAlpha:"), flyOn ? 1.0 : 0.45);
        }
    }

    // Aim State (Button 3)
    if (g_coreBtns[3] && g_rowPills[3]) {
        id t = ((msgSend_id_long)objc_msgSend)(g_coreBtns[3], sel("titleForState:"), 0);
        const char *s = t ? (const char *)((id (*)(id, SEL))objc_msgSend)(t, sel("UTF8String")) : "";
        BOOL on = (strstr(s, "ON") != NULL || strstr(s, "LOCK") != NULL);
        ((msgSend_void_id)objc_msgSend)(g_rowPills[3], sel("setBackgroundColor:"), on ? whiteColor : offPillBg);
        id layer = ((id (*)(id, SEL))objc_msgSend)(g_coreBtns[3], sel("layer"));
        if (layer && activeBorder && normalBorder) {
            id c = ((id (*)(id, SEL))objc_msgSend)(on ? activeBorder : normalBorder, sel("CGColor"));
            ((msgSend_void_id)objc_msgSend)(layer, sel("setBorderColor:"), c);
        }
    }

    // ESP State (Button 4)
    if (g_coreBtns[4] && g_rowPills[4]) {
        id t = ((msgSend_id_long)objc_msgSend)(g_coreBtns[4], sel("titleForState:"), 0);
        const char *s = t ? (const char *)((id (*)(id, SEL))objc_msgSend)(t, sel("UTF8String")) : "";
        BOOL on = (strstr(s, "ON") != NULL);
        ((msgSend_void_id)objc_msgSend)(g_rowPills[4], sel("setBackgroundColor:"), on ? whiteColor : offPillBg);
        id layer = ((id (*)(id, SEL))objc_msgSend)(g_coreBtns[4], sel("layer"));
        if (layer && activeBorder && normalBorder) {
            id c = ((id (*)(id, SEL))objc_msgSend)(on ? activeBorder : normalBorder, sel("CGColor"));
            ((msgSend_void_id)objc_msgSend)(layer, sel("setBorderColor:"), c);
        }
    }

    // Info button (Button 5)
    if (g_rowPills[5]) {
        ((msgSend_void_id)objc_msgSend)(g_rowPills[5], sel("setBackgroundColor:"), offPillBg);
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

    // Try loading header.png
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
            id txt = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "👑\nVIP");
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
    printf("[FlyMenuUI] Floating Logo Button (header.png) created on UIWindow\n");
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
                } else if (strcmp(utf, "UP") == 0 || (i == 1 && !g_coreBtns[1])) {
                    g_coreBtns[1] = sub; // Ascend (Up)
                } else if (strcmp(utf, "DOWN") == 0 || (i == 2 && !g_coreBtns[2])) {
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

    // 3. Panel Container styling (Width = 280, Height = 345)
    double panelW = 280.0;
    double panelH = 345.0;
    CGRect pFrame = ((msgSend_rect)objc_msgSend)(panel, sel("frame"));
    pFrame.size.width = panelW;
    pFrame.size.height = panelH;
    ((msgSend_void_rect)objc_msgSend)(panel, sel("setFrame:"), pFrame);

    Class uiColor = cls("UIColor");
    Class uiView = cls("UIView");
    Class uiBtn = cls("UIButton");
    Class uiLabel = cls("UILabel");
    Class uiFont = cls("UIFont");
    Class nsString = cls("NSString");

    if (uiColor) {
        id bgColor = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.05, 0.05, 0.07, 0.98);
        if (bgColor) {
            ((msgSend_void_id)objc_msgSend)(panel, sel("setBackgroundColor:"), bgColor);
        }
        id pLayer = ((id (*)(id, SEL))objc_msgSend)(panel, sel("layer"));
        if (pLayer) {
            ((msgSend_void_double)objc_msgSend)(pLayer, sel("setCornerRadius:"), 16.0);
            ((msgSend_void_double)objc_msgSend)(pLayer, sel("setBorderWidth:"), 2.0);
            id redBorder = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.83, 0.11, 0.11, 1.0);
            if (redBorder) {
                id cgBorder = ((id (*)(id, SEL))objc_msgSend)(redBorder, sel("CGColor"));
                ((msgSend_void_id)objc_msgSend)(pLayer, sel("setBorderColor:"), cgBorder);
            }
            ((msgSend_void_long)objc_msgSend)(pLayer, sel("setMasksToBounds:"), 1);
        }
    }

    ((msgSend_void_long)objc_msgSend)(panel, sel("setUserInteractionEnabled:"), 1);

    // Disable cancelsTouchesInView on panel gestures so hold/touch events on buttons are never canceled
    id panelGestures = ((id (*)(id, SEL))objc_msgSend)(panel, sel("gestureRecognizers"));
    if (panelGestures) {
        long gCount = (long)((long (*)(id, SEL))objc_msgSend)(panelGestures, sel("count"));
        for (long g = 0; g < gCount; g++) {
            id gr = ((msgSend_id_long)objc_msgSend)(panelGestures, sel("objectAtIndex:"), g);
            if (gr) {
                ((msgSend_void_bool)objc_msgSend)(gr, sel("setCancelsTouchesInView:"), NO);
                ((msgSend_void_bool)objc_msgSend)(gr, sel("setDelaysTouchesBegan:"), NO);
                ((msgSend_void_bool)objc_msgSend)(gr, sel("setDelaysTouchesEnded:"), NO);
            }
        }
    }

    // 4. Create Red Header Bar (Matching user's reference image)
    double headerH = 42.0;
    if (!uiView) return;
    id headerBar = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)uiView, sel("alloc")), sel("init"));
    if (!headerBar) return;

    ((msgSend_void_rect)objc_msgSend)(headerBar, sel("setFrame:"), CGRectMake(0, 0, panelW, headerH));
    if (uiColor) {
        id headerRed = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.83, 0.11, 0.11, 1.0);
        if (headerRed) {
            ((msgSend_void_id)objc_msgSend)(headerBar, sel("setBackgroundColor:"), headerRed);
        }
    }
    ((msgSend_void_long)objc_msgSend)(headerBar, sel("setUserInteractionEnabled:"), 1);

    // Header Logo Icon (header.png)
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

    // 5. Create Navigation / Tabs Bar (Directly below header)
    id tabBar = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)uiView, sel("alloc")), sel("init"));
    if (tabBar) {
        ((msgSend_void_rect)objc_msgSend)(tabBar, sel("setFrame:"), CGRectMake(0, headerH, panelW, 36));
        if (uiColor) {
            id tabBg = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.08, 0.08, 0.10, 1.0);
            if (tabBg) ((msgSend_void_id)objc_msgSend)(tabBar, sel("setBackgroundColor:"), tabBg);
        }

        const char *tabTitles[] = { "🎯 Aim", "👁 Esp", "⚡ Fly", "📇 Info" };
        double tabW = (panelW - 20) / 4.0;
        id greyColor = uiColor ? ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.65, 0.65, 0.70, 1.0) : NULL;
        id inactiveTabBg = uiColor ? ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.11, 0.11, 0.15, 1.0) : NULL;

        for (int t = 0; t < 4; t++) {
            id tBtn = ((msgSend_id_long)objc_msgSend)((id)uiBtn, sel("buttonWithType:"), 0);
            if (tBtn) {
                ((msgSend_void_rect)objc_msgSend)(tBtn, sel("setFrame:"), CGRectMake(4 + t * (tabW + 3), 5, tabW, 26));
                id tStr = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel("alloc")), sel("initWithUTF8String:"), tabTitles[t]);
                if (tStr) ((msgSend_id_id_long)objc_msgSend)(tBtn, sel("setTitle:forState:"), tStr, 0);
                if (greyColor) ((msgSend_id_id_long)objc_msgSend)(tBtn, sel("setTitleColor:forState:"), greyColor, 0);
                if (inactiveTabBg) ((msgSend_void_id)objc_msgSend)(tBtn, sel("setBackgroundColor:"), inactiveTabBg);

                if (uiFont) {
                    id font = ((msgSend_id_double)objc_msgSend)((id)uiFont, sel("boldSystemFontOfSize:"), 11.0);
                    if (font) {
                        id lbl = ((id (*)(id, SEL))objc_msgSend)(tBtn, sel("titleLabel"));
                        if (lbl) ((msgSend_void_id)objc_msgSend)(lbl, sel("setFont:"), font);
                    }
                }
                id tLayer = ((id (*)(id, SEL))objc_msgSend)(tBtn, sel("layer"));
                if (tLayer) {
                    ((msgSend_void_double)objc_msgSend)(tLayer, sel("setCornerRadius:"), 5.0);
                    ((msgSend_void_long)objc_msgSend)(tLayer, sel("setMasksToBounds:"), 1);
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

    // 6. Style the 6 native core buttons DIRECTLY with clean modern row styling
    // Ordering:
    // 0: Fly Hack (Zero Gravity)
    // 1: Flight Ascend (Up)
    // 2: Flight Descend (Down)
    // 3: Aimbot 360 Lock
    // 4: Esp Player Laser & Box
    // 5: Flight Diagnostics & Info
    const char *cleanTitles[] = {
        "Fly Hack (Zero Gravity)",
        "Flight Ascend (Up)",
        "Flight Descend (Down)",
        "Aimbot 360 Lock",
        "Esp Player Laser & Box",
        "Flight Diagnostics & Info"
    };

    double startY = 84.0;
    double rowH = 38.0;
    double gap = 4.0;

    for (int i = 0; i < NUM_BUTTONS; i++) {
        id btn = g_coreBtns[i];
        if (!btn) continue;

        // Position the real core button directly as the row
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

        // Left Toggle Switch Pill (Matches reference image)
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

    // 7. Create Floating Logo Button
    createFloatingLogoButton(win);
}

static void timerTick_imp(id self, SEL _cmd, id timer) {
    id win = getActiveWindow();
    if (!win) return;

    if (!g_panel) {
        id p = findFlyPanel(win);
        if (p) {
            g_panel = p;
            setupMenuUI(win, g_panel);
        }
    } else {
        updateRowStates();
        if (g_floatBtn) {
            ((msgSend_void_id)objc_msgSend)(win, sel("bringSubviewToFront:"), g_floatBtn);
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
                                                            (double)0.25, g_uiMgr, sel("timerTick:"), NULL, YES);
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
