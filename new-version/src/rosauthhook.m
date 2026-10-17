#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#include <stdio.h>

// Export the symbols client or other dylibs might look for
__attribute__((visibility("default")))
void ros_apply_ticket(const char *ticket) {
    printf("[rosauthhook] ros_apply_ticket called with ticket: %s\n", ticket ? ticket : "(null)");
}

__attribute__((visibility("default")))
void ros_set_ticket(const char *ticket) {
    printf("[rosauthhook] ros_set_ticket called: %s\n", ticket ? ticket : "(null)");
}

__attribute__((visibility("default")))
void _ros_apply_ticket(const char *ticket) {
    ros_apply_ticket(ticket);
}

__attribute__((visibility("default")))
void _ros_set_ticket(const char *ticket) {
    ros_set_ticket(ticket);
}

// Intercept NtSdkBase ntLogin to complete login offline without any server or popup
static void custom_ntLogin(id self, SEL _cmd) {
    printf("[OfflineLogin] ntLogin called -> Stamping offline credentials...\n");

    Class ntMgr = objc_getClass("NtSdkMgr");
    if (ntMgr) {
        id inst = ((id (*)(id, SEL))objc_msgSend)((id)ntMgr, sel_registerName("getInst"));
        if (inst) {
            Class nsString = objc_getClass("NSString");
            id kUser = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel_registerName("alloc")), sel_registerName("initWithUTF8String:"), "UIN");
            id vUser = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel_registerName("alloc")), sel_registerName("initWithUTF8String:"), "vibol_offline_tester");
            ((void (*)(id, SEL, id, id))objc_msgSend)(inst, sel_registerName("setPropStr:as:"), kUser, vUser);

            id kToken = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel_registerName("alloc")), sel_registerName("initWithUTF8String:"), "SESSION");
            id vToken = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel_registerName("alloc")), sel_registerName("initWithUTF8String:"), "offline_token_ok");
            ((void (*)(id, SEL, id, id))objc_msgSend)(inst, sel_registerName("setPropStr:as:"), kToken, vToken);
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        Class nsNotifCenter = objc_getClass("NSNotificationCenter");
        if (nsNotifCenter) {
            id center = ((id (*)(id, SEL))objc_msgSend)((id)nsNotifCenter, sel_registerName("defaultCenter"));
            if (center) {
                Class nsString = objc_getClass("NSString");
                id notifName = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel_registerName("alloc")), sel_registerName("initWithUTF8String:"), "NT_NOTIFICATION_LOGIN");
                Class nsDict = objc_getClass("NSDictionary");
                id kState = ((id (*)(id, SEL, const char *))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)nsString, sel_registerName("alloc")), sel_registerName("initWithUTF8String:"), "login_state");
                Class nsNumber = objc_getClass("NSNumber");
                id vState = ((id (*)(id, SEL, int))objc_msgSend)((id)nsNumber, sel_registerName("numberWithInt:"), 0);
                if (notifName && kState && vState && nsDict) {
                    id userInfo = ((id (*)(id, SEL, id, id))objc_msgSend)((id)nsDict, sel_registerName("dictionaryWithObject:forKey:"), vState, kState);
                    ((void (*)(id, SEL, id, id, id))objc_msgSend)(center, sel_registerName("postNotificationName:object:userInfo:"), notifName, NULL, userInfo);
                    printf("[OfflineLogin] Successfully posted NT_NOTIFICATION_LOGIN {login_state=0}!\n");
                }
            }
        }
    });
}

static void install_offline_hooks(void) {
    Class ntSdkBase = objc_getClass("NtSdkBase");
    if (ntSdkBase) {
        Method m = class_getInstanceMethod(ntSdkBase, sel_registerName("ntLogin"));
        if (m) {
            method_setImplementation(m, (IMP)custom_ntLogin);
            printf("[rosauthhook] Successfully hooked NtSdkBase ntLogin -> Offline mode active!\n");
        }
    }
}

__attribute__((constructor))
static void init_clean_rosauthhook(void) {
    printf("[rosauthhook] Clean Offline Auth Hook Loaded (No RosLegacy Server Required)!\n");
    install_offline_hooks();

    // Re-verify hook after app finishes launching
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        install_offline_hooks();
    });
}
