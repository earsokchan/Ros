#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#include <stdio.h>
#include <string.h>

#define msgSend ((id (*)(id, SEL, ...))objc_msgSend)
#define sel(s) sel_registerName(s)
#define cls(c) objc_getClass(c)

// 1. Hook -[NtSdkBase getNotice:] to suppress "Game has stopped" popup
static id custom_getNotice(id self, SEL _cmd, id arg) {
    printf("[ros_local_bridge] Suppressed NetEase shutdown notice!\n");
    return NULL;
}

// 2. Hook -[NtSdkBase ntLogin] to stamp offline session immediately
static void custom_ntLogin(id self, SEL _cmd) {
    printf("[ros_local_bridge] ntLogin intercepted -> Auto-logging in as local user...\n");

    Class ntMgr = cls("NtSdkMgr");
    if (ntMgr) {
        id inst = msgSend((id)ntMgr, sel("getInst"));
        if (inst) {
            Class nsString = cls("NSString");
            id kUser = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "UIN");
            id vUser = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "vibol_local_player");
            msgSend(inst, sel("setPropStr:as:"), kUser, vUser);

            id kToken = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "SESSION");
            id vToken = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "local_token_ok");
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
                    printf("[ros_local_bridge] Posted NT_NOTIFICATION_LOGIN {login_state=0}!\n");
                }
            }
        }
    });
}

// 3. Hook +[NSURL URLWithString:] to redirect NetEase / RosLegacy domains to local Mac server (172.20.10.2:8080)
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
                    
                    snprintf(newUrl, sizeof(newUrl), "http://172.20.10.2:8080%s", path);
                    printf("[ros_local_bridge] Redirected: %s -> %s\n", cstr, newUrl);
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

static void install_bridge_hooks(void) {
    Class ntSdkBase = cls("NtSdkBase");
    if (ntSdkBase) {
        Method m1 = class_getInstanceMethod(ntSdkBase, sel("ntLogin"));
        if (m1) {
            method_setImplementation(m1, (IMP)custom_ntLogin);
            printf("[ros_local_bridge] Hooked NtSdkBase ntLogin\n");
        }
        Method m2 = class_getInstanceMethod(ntSdkBase, sel("getNotice:"));
        if (m2) {
            method_setImplementation(m2, (IMP)custom_getNotice);
            printf("[ros_local_bridge] Hooked NtSdkBase getNotice:\n");
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
                printf("[ros_local_bridge] Hooked NSURL URLWithString: -> 172.20.10.2:8080\n");
            }
        }
    }
}

__attribute__((constructor))
static void init_bridge(void) {
    printf("[ros_local_bridge] Local Offline Bridge Initialized!\n");
    install_bridge_hooks();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        install_bridge_hooks();
    });
}
