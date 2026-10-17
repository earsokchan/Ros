#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#include <stdio.h>
#include <string.h>

#define msgSend ((id (*)(id, SEL, ...))objc_msgSend)
#define sel(s) sel_registerName(s)
#define cls(c) objc_getClass(c)

static const char *LOCAL_SERVER_BASE = "http://172.20.10.2:8080";

// 1. Hook -[NtSdkBase getNotice:] to suppress "Game has stopped" popup
static id custom_getNotice(id self, SEL _cmd, id arg) {
    printf("[LocalBridge] Suppressed NetEase shutdown notice!\n");
    return NULL;
}

// 2. Hook -[NtSdkBase isJailBroken] to always return clean status
static BOOL custom_isJailBroken(id self, SEL _cmd) {
    return NO;
}

// 3. Hook -[NtSdkBase ntLogin] to auto-log in as local user immediately
static void custom_ntLogin(id self, SEL _cmd) {
    printf("[LocalBridge] ntLogin intercepted -> Auto-logging in as local user...\n");

    Class ntMgr = cls("NtSdkMgr");
    if (ntMgr) {
        id inst = msgSend((id)ntMgr, sel("getInst"));
        if (inst) {
            Class nsString = cls("NSString");
            id kUser = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "UIN");
            id vUser = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "vibol_local_player");
            msgSend(inst, sel("setPropStr:as:"), kUser, vUser);

            id kToken = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "SESSION");
            id vToken = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "vibol_local_session");
            msgSend(inst, sel("setPropStr:as:"), kToken, vToken);
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        Class nsNotifCenter = cls("NSNotificationCenter");
        if (nsNotifCenter) {
            id center = msgSend((id)nsNotifCenter, sel("defaultCenter"));
            if (center) {
                Class nsString = cls("NSString");
                id notifName = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "NT_NOTIFICATION_LOGIN");
                Class nsDict = cls("NSDictionary");
                id kState = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "login_state");
                Class nsNumber = cls("NSNumber");
                id vState = msgSend((id)nsNumber, sel("numberWithInt:"), 0);
                if (notifName && kState && vState && nsDict) {
                    id userInfo = msgSend((id)nsDict, sel("dictionaryWithObject:forKey:"), vState, kState);
                    msgSend(center, sel("postNotificationName:object:userInfo:"), notifName, NULL, userInfo);
                    printf("[LocalBridge] Posted NT_NOTIFICATION_LOGIN {login_state=0} successfully!\n");
                }
            }
        }
    });
}

// 4. Hook +[NSURL URLWithString:] to redirect NetEase / 163 / RosLegacy traffic to Mac server
static id (*orig_URLWithString)(id self, SEL _cmd, id str) = NULL;

static id custom_URLWithString(id self, SEL _cmd, id str) {
    if (str) {
        SEL utf8Sel = sel("UTF8String");
        if ((BOOL)msgSend(str, sel("respondsToSelector:"), utf8Sel)) {
            const char *cstr = ((const char *(*)(id, SEL))objc_msgSend)(str, utf8Sel);
            if (cstr) {
                if (strstr(cstr, "netease.com") || strstr(cstr, "163.com") || 
                    strstr(cstr, "easebar.com") || strstr(cstr, "roslegacy.net")) {
                    
                    char newUrl[512];
                    const char *path = strstr(cstr, ".com");
                    if (!path) path = strstr(cstr, ".net");
                    if (path) {
                        path = strchr(path, '/');
                    }
                    if (!path) path = "/";
                    
                    snprintf(newUrl, sizeof(newUrl), "%s%s", LOCAL_SERVER_BASE, path);
                    printf("[LocalBridge] Redirected: %s -> %s\n", cstr, newUrl);
                    Class nsString = cls("NSString");
                    id redirectedStr = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), newUrl);
                    if (redirectedStr && orig_URLWithString) {
                        return orig_URLWithString(self, _cmd, redirectedStr);
                    }
                }
            }
        }
    }
    if (orig_URLWithString) {
        return orig_URLWithString(self, _cmd, str);
    }
    return NULL;
}

static void install_hooks(void) {
    Class ntSdkBase = cls("NtSdkBase");
    if (ntSdkBase) {
        Method m1 = class_getInstanceMethod(ntSdkBase, sel("ntLogin"));
        if (m1) {
            method_setImplementation(m1, (IMP)custom_ntLogin);
        }
        Method m2 = class_getInstanceMethod(ntSdkBase, sel("getNotice:"));
        if (m2) {
            method_setImplementation(m2, (IMP)custom_getNotice);
        }
        Method m3 = class_getInstanceMethod(ntSdkBase, sel("isJailBroken"));
        if (m3) {
            method_setImplementation(m3, (IMP)custom_isJailBroken);
        }
    }

    Class nsUrl = cls("NSURL");
    if (nsUrl) {
        Method mUrl = class_getClassMethod(nsUrl, sel("URLWithString:"));
        if (mUrl) {
            IMP cur = method_getImplementation(mUrl);
            if (cur != (IMP)custom_URLWithString) {
                orig_URLWithString = (id (*)(id, SEL, id))cur;
                method_setImplementation(mUrl, (IMP)custom_URLWithString);
            }
        }
    }
}

__attribute__((constructor))
static void init_local_bridge(void) {
    printf("[LocalBridge] Initialized! Server target: %s\n", LOCAL_SERVER_BASE);
    install_hooks();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        install_hooks();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        install_hooks();
    });
}
