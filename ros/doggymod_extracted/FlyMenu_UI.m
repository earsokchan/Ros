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

static id g_uiMgr = NULL;
static id g_panel = NULL;
static id g_floatBtn = NULL;
static id (*orig_pathForResource)(id self, SEL _cmd, id name, id ext) = NULL;

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

static void createFloatingLogoButton(id win) {
    if (g_floatBtn || !win) return;

    Class uiBtn = cls("UIButton");
    if (!uiBtn) return;
    id floatBtn = ((msgSend_id_long)objc_msgSend)((id)uiBtn, sel("buttonWithType:"), 0);
    if (!floatBtn) return;

    ((msgSend_void_rect)objc_msgSend)(floatBtn, sel("setFrame:"), CGRectMake(20, 80, 50, 50));

    Class uiColor = cls("UIColor");
    if (uiColor) {
        id bgColor = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.08, 0.10, 0.15, 0.95);
        if (bgColor) {
            ((msgSend_void_id)objc_msgSend)(floatBtn, sel("setBackgroundColor:"), bgColor);
        }
        id borderColor = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.0, 0.85, 1.0, 1.0);
        id layer = ((id (*)(id, SEL))objc_msgSend)(floatBtn, sel("layer"));
        if (layer) {
            ((msgSend_void_double)objc_msgSend)(layer, sel("setCornerRadius:"), 25.0);
            ((msgSend_void_double)objc_msgSend)(layer, sel("setBorderWidth:"), 2.0);
            if (borderColor) {
                id cgBorder = ((id (*)(id, SEL))objc_msgSend)(borderColor, sel("CGColor"));
                ((msgSend_void_id)objc_msgSend)(layer, sel("setBorderColor:"), cgBorder);
            }
            ((msgSend_void_long)objc_msgSend)(layer, sel("setMasksToBounds:"), 1);
        }
    }

    // Try loading D79oM.bundle/back.png
    Class uiImg = cls("UIImage");
    Class nsString = cls("NSString");
    id backImg = NULL;

    const char *candPaths[] = {
        "/Library/MobileSubstrate/DynamicLibraries/D79oM.bundle/back.png",
        "/var/jb/Library/MobileSubstrate/DynamicLibraries/D79oM.bundle/back.png",
        "/var/jb/usr/lib/TweakInject/D79oM.bundle/back.png",
        "/usr/lib/TweakInject/D79oM.bundle/back.png",
        "/Library/Application Support/ROS_Doggymod/back.png",
        "/var/jb/Library/Application Support/ROS_Doggymod/back.png",
        NULL
    };
    for (int k = 0; candPaths[k]; k++) {
        if (access(candPaths[k], R_OK) == 0 && uiImg && nsString) {
            id p = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel("alloc")), sel("initWithUTF8String:"), candPaths[k]);
            if (p) {
                backImg = ((msgSend_id_id)objc_msgSend)((id)uiImg, sel("imageWithContentsOfFile:"), p);
                if (backImg) break;
            }
        }
    }

    if (backImg) {
        ((msgSend_id_id_long)objc_msgSend)(floatBtn, sel("setImage:forState:"), backImg, 0);
        id imgView = ((id (*)(id, SEL))objc_msgSend)(floatBtn, sel("imageView"));
        if (imgView) {
            ((msgSend_void_long)objc_msgSend)(imgView, sel("setContentMode:"), 1); // UIViewContentModeScaleAspectFit
        }
    } else if (uiColor && nsString) {
        id goldColor = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 1.0, 0.84, 0.0, 1.0);
        id txt = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "👑\nRoS");
        ((msgSend_id_id_long)objc_msgSend)(floatBtn, sel("setTitle:forState:"), txt, 0);
        ((msgSend_id_id_long)objc_msgSend)(floatBtn, sel("setTitleColor:forState:"), goldColor, 0);
        id lbl = ((id (*)(id, SEL))objc_msgSend)(floatBtn, sel("titleLabel"));
        if (lbl) {
            Class uiFont = cls("UIFont");
            if (uiFont) {
                id font = ((msgSend_id_double)objc_msgSend)((id)uiFont, sel("boldSystemFontOfSize:"), 11.0);
                if (font) {
                    ((msgSend_void_id)objc_msgSend)(lbl, sel("setFont:"), font);
                }
            }
            ((msgSend_void_long)objc_msgSend)(lbl, sel("setTextAlignment:"), 1); // Center
            ((msgSend_void_long)objc_msgSend)(lbl, sel("setNumberOfLines:"), 2);
        }
    }

    // Tap action
    ((msgSend_void_id_sel_long)objc_msgSend)(floatBtn, sel("addTarget:action:forControlEvents:"), g_uiMgr, sel("toggleMenu:"), 1 << 6); // TouchUpInside

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

static void setupMenuUI(id win, id panel) {
    if (!panel || !win) return;
    long tag = (long)((long (*)(id, SEL))objc_msgSend)(panel, sel("tag"));
    if (tag == 0x777) return;
    ((msgSend_void_long)objc_msgSend)(panel, sel("setTag:"), 0x777);

    // 1. Initially hide menu by default
    ((msgSend_void_long)objc_msgSend)(panel, sel("setHidden:"), 1);

    // 2. Style panel container
    Class uiColor = cls("UIColor");
    if (uiColor) {
        id bgColor = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.08, 0.09, 0.13, 0.96);
        if (bgColor) {
            ((msgSend_void_id)objc_msgSend)(panel, sel("setBackgroundColor:"), bgColor);
        }
        id pLayer = ((id (*)(id, SEL))objc_msgSend)(panel, sel("layer"));
        if (pLayer) {
            ((msgSend_void_double)objc_msgSend)(pLayer, sel("setCornerRadius:"), 14.0);
            ((msgSend_void_double)objc_msgSend)(pLayer, sel("setBorderWidth:"), 1.5);
            id borderColor = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.22, 0.25, 0.32, 1.0);
            if (borderColor) {
                id cgBorder = ((id (*)(id, SEL))objc_msgSend)(borderColor, sel("CGColor"));
                ((msgSend_void_id)objc_msgSend)(pLayer, sel("setBorderColor:"), cgBorder);
            }
            ((msgSend_void_long)objc_msgSend)(pLayer, sel("setMasksToBounds:"), 1);
        }
    }

    CGRect pFrame = ((msgSend_rect)objc_msgSend)(panel, sel("frame"));
    double panelW = pFrame.size.width;
    double headerH = 34.0;

    // 3. Shift existing buttons down by headerH
    id subviews = ((id (*)(id, SEL))objc_msgSend)(panel, sel("subviews"));
    if (subviews) {
        long count = (long)((long (*)(id, SEL))objc_msgSend)(subviews, sel("count"));
        Class btnCls = cls("UIButton");
        for (long i = 0; i < count; i++) {
            id sub = ((msgSend_id_long)objc_msgSend)(subviews, sel("objectAtIndex:"), i);
            if (!sub) continue;
            if (btnCls && (long)((long (*)(id, SEL, id))objc_msgSend)(sub, sel("isKindOfClass:"), (id)btnCls)) {
                CGRect f = ((msgSend_rect)objc_msgSend)(sub, sel("frame"));
                f.origin.y += headerH;
                ((msgSend_void_rect)objc_msgSend)(sub, sel("setFrame:"), f);
                id sLayer = ((id (*)(id, SEL))objc_msgSend)(sub, sel("layer"));
                if (sLayer) {
                    ((msgSend_void_double)objc_msgSend)(sLayer, sel("setCornerRadius:"), 8.0);
                    ((msgSend_void_long)objc_msgSend)(sLayer, sel("setMasksToBounds:"), 1);
                }
            }
        }
    }
    pFrame.size.height += headerH;
    ((msgSend_void_rect)objc_msgSend)(panel, sel("setFrame:"), pFrame);

    // 4. Create Header Bar
    Class uiView = cls("UIView");
    if (!uiView) return;
    id headerBar = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)uiView, sel("alloc")), sel("init"));
    if (!headerBar) return;

    ((msgSend_void_rect)objc_msgSend)(headerBar, sel("setFrame:"), CGRectMake(0, 0, panelW, headerH));
    if (uiColor) {
        id headerBg = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.12, 0.14, 0.20, 1.0);
        if (headerBg) {
            ((msgSend_void_id)objc_msgSend)(headerBar, sel("setBackgroundColor:"), headerBg);
        }
    }
    ((msgSend_void_long)objc_msgSend)(headerBar, sel("setUserInteractionEnabled:"), 1);

    // Header Title Label
    Class uiLabel = cls("UILabel");
    Class nsString = cls("NSString");
    if (uiLabel && nsString) {
        id titleLbl = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)uiLabel, sel("alloc")), sel("init"));
        if (titleLbl) {
            ((msgSend_void_rect)objc_msgSend)(titleLbl, sel("setFrame:"), CGRectMake(8, 0, panelW - 40, headerH));
            id titleStr = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "⚡ RoS VIP");
            if (titleStr) {
                ((msgSend_void_id)objc_msgSend)(titleLbl, sel("setText:"), titleStr);
            }
            if (uiColor) {
                id whiteColor = ((id (*)(id, SEL))objc_msgSend)((id)uiColor, sel("whiteColor"));
                if (whiteColor) {
                    ((msgSend_void_id)objc_msgSend)(titleLbl, sel("setTextColor:"), whiteColor);
                }
            }
            Class uiFont = cls("UIFont");
            if (uiFont) {
                id boldFont = ((msgSend_id_double)objc_msgSend)((id)uiFont, sel("boldSystemFontOfSize:"), 11.0);
                if (boldFont) {
                    ((msgSend_void_id)objc_msgSend)(titleLbl, sel("setFont:"), boldFont);
                }
            }
            ((msgSend_void_id)objc_msgSend)(headerBar, sel("addSubview:"), titleLbl);
        }
    }

    // Header Close [✕] Button
    Class uiBtn = cls("UIButton");
    if (uiBtn && nsString) {
        id closeBtn = ((msgSend_id_long)objc_msgSend)((id)uiBtn, sel("buttonWithType:"), 0);
        if (closeBtn) {
            ((msgSend_void_rect)objc_msgSend)(closeBtn, sel("setFrame:"), CGRectMake(panelW - 28, 5, 22, 22));
            id closeStr = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "✕");
            if (closeStr) {
                ((msgSend_id_id_long)objc_msgSend)(closeBtn, sel("setTitle:forState:"), closeStr, 0);
            }
            if (uiColor) {
                id whiteColor = ((id (*)(id, SEL))objc_msgSend)((id)uiColor, sel("whiteColor"));
                if (whiteColor) {
                    ((msgSend_id_id_long)objc_msgSend)(closeBtn, sel("setTitleColor:forState:"), whiteColor, 0);
                }
                id redColor = ((msgSend_id_double4)objc_msgSend)((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.94, 0.27, 0.27, 1.0);
                if (redColor) {
                    ((msgSend_void_id)objc_msgSend)(closeBtn, sel("setBackgroundColor:"), redColor);
                }
            }
            id cLayer = ((id (*)(id, SEL))objc_msgSend)(closeBtn, sel("layer"));
            if (cLayer) {
                ((msgSend_void_double)objc_msgSend)(cLayer, sel("setCornerRadius:"), 11.0);
                ((msgSend_void_long)objc_msgSend)(cLayer, sel("setMasksToBounds:"), 1);
            }

            // Close button action
            ((msgSend_void_id_sel_long)objc_msgSend)(closeBtn, sel("addTarget:action:forControlEvents:"), g_uiMgr, sel("closeMenu:"), 1 << 6);
            ((msgSend_void_id)objc_msgSend)(headerBar, sel("addSubview:"), closeBtn);
        }
    }

    // Pan gesture on Header Bar
    Class panCls = cls("UIPanGestureRecognizer");
    if (panCls) {
        id headerPan = ((id (*)(id, SEL, id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)panCls, sel("alloc")), sel("initWithTarget:action:"), g_uiMgr, sel("handleMenuPan:"));
        if (headerPan) {
            ((msgSend_void_id)objc_msgSend)(headerBar, sel("addGestureRecognizer:"), headerPan);
        }
    }

    ((msgSend_void_id)objc_msgSend)(panel, sel("addSubview:"), headerBar);

    // 5. Create Floating Logo Button
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
        objc_registerClassPair(uiMgrCls);
        g_uiMgr = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)uiMgrCls, sel("alloc")), sel("init"));
    }

    // 4. Safe post-launch configuration (1.5s delay to ensure UIKit is completely ready)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Try writing scripts directly into mainBundle path if writable
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

        // Also ensure scripts exist in Documents/
        ensureAndGetScriptPath("ros_fly.py", EMBEDDED_ROS_FLY_PY, EMBEDDED_ROS_FLY_PY_LEN);
        ensureAndGetScriptPath("ros_combat.py", EMBEDDED_ROS_COMBAT_PY, EMBEDDED_ROS_COMBAT_PY_LEN);

        // Schedule UI inspection timer
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
