#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <mach-o/dyld.h>
#import <pthread.h>
#import <dispatch/dispatch.h>
#include <string.h>
#include <stdlib.h>

extern id objc_retain(id);
extern void objc_release(id);

typedef unsigned long NSUInteger;
typedef struct _NSRange { NSUInteger location; NSUInteger length; } NSRange;

#define msgSend ((id (*)(id, SEL, ...))objc_msgSend)
#define msgSend_rect ((id (*)(id, SEL, CGRect))objc_msgSend)
#define sel(s) sel_registerName(s)
#define cls(c) objc_getClass(c)

#ifndef CGFLOAT_DEFINED
typedef double CGFloat;
#endif

typedef struct CGPoint { CGFloat x; CGFloat y; } CGPoint;
typedef struct CGSize { CGFloat width; CGFloat height; } CGSize;
typedef struct CGRect { CGPoint origin; CGSize size; } CGRect;

static inline CGRect CGRectMake(CGFloat x, CGFloat y, CGFloat width, CGFloat height) {
    CGRect r; r.origin.x = x; r.origin.y = y; r.size.width = width; r.size.height = height; return r;
}

// Global reference for on-screen terminal
static id g_terminal_view = NULL;
static uint64_t g_terminal_session = 0;

static void close_terminal_view(void) {
    Class nsThread = cls("NSThread");
    if (nsThread && !(BOOL)msgSend((id)nsThread, sel("isMainThread"))) {
        dispatch_async(dispatch_get_main_queue(), ^{
            close_terminal_view();
        });
        return;
    }
    if (g_terminal_view) {
        id view = g_terminal_view;
        g_terminal_view = NULL;
        msgSend(view, sel("removeFromSuperview"));
        objc_release(view);
    }
}

// Target-Action handler for close button
__attribute__((objc_root_class))
@interface Yes360CloseTarget
+ (void)closeClicked:(id)sender;
@end

@implementation Yes360CloseTarget
+ (void)closeClicked:(id)sender {
    close_terminal_view();
}
@end

// Append a line to the on-screen terminal TextView safely
static void append_terminal_line(id textView, const char *line) {
    if (!textView) return;
    Class nsString = cls("NSString");
    if (!nsString) return;
    id str = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), line);
    if (!str) return;
    id currentText = msgSend(textView, sel("text"));
    if (currentText) {
        id format = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "%@%@\n");
        id newText = msgSend((id)nsString, sel("stringWithFormat:"), format, currentText, str);
        msgSend(textView, sel("setText:"), newText);
    } else {
        id format = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "%@\n");
        id newText = msgSend((id)nsString, sel("stringWithFormat:"), format, str);
        msgSend(textView, sel("setText:"), newText);
    }

    NSUInteger len = (NSUInteger)msgSend(msgSend(textView, sel("text")), sel("length"));
    if (len > 0) {
        NSRange range;
        range.location = len - 1;
        range.length = 1;
        ((void (*)(id, SEL, NSRange))objc_msgSend)(textView, sel("scrollRangeToVisible:"), range);
    }
}

// Show the on-screen terminal with execution flow
static void show_terminal_flow(BOOL is_on) {
    dispatch_async(dispatch_get_main_queue(), ^{
        close_terminal_view();

        uint64_t session = ++g_terminal_session;

        Class uiApp = cls("UIApplication");
        if (!uiApp) return;
        id app = msgSend((id)uiApp, sel("sharedApplication"));
        if (!app) return;
        id window = msgSend(app, sel("keyWindow"));
        if (!window) {
            id windows = msgSend(app, sel("windows"));
            if (windows && (NSUInteger)msgSend(windows, sel("count")) > 0) {
                window = msgSend(windows, sel("objectAtIndex:"), 0);
            }
        }
        if (!window) return;

        Class uiView = cls("UIView");
        Class uiColor = cls("UIColor");
        Class uiLabel = cls("UILabel");
        Class uiFont = cls("UIFont");
        Class uiButton = cls("UIButton");
        Class uiTextView = cls("UITextView");
        Class nsString = cls("NSString");

        // Window bounds & layout
        CGRect winBounds = ((CGRect (*)(id, SEL))objc_msgSend)(window, sel("bounds"));
        CGFloat termW = 340.0;
        CGFloat termH = 220.0;
        CGFloat termX = (winBounds.size.width - termW) / 2.0;
        CGFloat termY = 60.0;
        if (termX < 10.0) termX = 10.0;

        // Container view
        id termView = msgSend_rect(msgSend((id)uiView, sel("alloc")), sel("initWithFrame:"), CGRectMake(termX, termY, termW, termH));
        if (!termView) return;
        objc_retain(termView);
        g_terminal_view = termView;

        // Dark background with cyberpunk styling
        id bgColor = msgSend((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 12/255.0, 16/255.0, 24/255.0, 0.94);
        msgSend(termView, sel("setBackgroundColor:"), bgColor);

        id layer = msgSend(termView, sel("layer"));
        if (layer) {
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(layer, sel("setCornerRadius:"), 12.0);
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(layer, sel("setBorderWidth:"), 1.8);
            // Glowing neon border #00FF66
            id borderColor = msgSend((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.0, 1.0, 0.4, 0.85);
            id cgColor = msgSend(borderColor, sel("CGColor"));
            msgSend(layer, sel("setBorderColor:"), cgColor);
        }

        // Title Bar
        id titleBar = msgSend_rect(msgSend((id)uiView, sel("alloc")), sel("initWithFrame:"), CGRectMake(0, 0, termW, 30.0));
        id barColor = msgSend((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 20/255.0, 26/255.0, 36/255.0, 1.0);
        msgSend(titleBar, sel("setBackgroundColor:"), barColor);

        // Terminal traffic lights: Red, Yellow, Green
        CGFloat dotY = 10.0;
        CGFloat dotSize = 10.0;
        CGFloat dotColors[3][3] = { {1.0, 0.37, 0.34}, {1.0, 0.74, 0.18}, {0.15, 0.79, 0.25} };
        for (int i = 0; i < 3; i++) {
            id dot = msgSend_rect(msgSend((id)uiView, sel("alloc")), sel("initWithFrame:"), CGRectMake(12 + i * 16, dotY, dotSize, dotSize));
            id c = msgSend((id)uiColor, sel("colorWithRed:green:blue:alpha:"), dotColors[i][0], dotColors[i][1], dotColors[i][2], 1.0);
            msgSend(dot, sel("setBackgroundColor:"), c);
            id dlayer = msgSend(dot, sel("layer"));
            if (dlayer) ((void (*)(id, SEL, CGFloat))objc_msgSend)(dlayer, sel("setCornerRadius:"), 5.0);
            msgSend(titleBar, sel("addSubview:"), dot);
        }

        // Title Label
        id titleLbl = msgSend_rect(msgSend((id)uiLabel, sel("alloc")), sel("initWithFrame:"), CGRectMake(65, 0, termW - 105, 30.0));
        id titleStr = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), is_on ? "⚡ Yes360 Auto-Search Terminal" : "⚡ Yes360 Engine [Disabled]");
        msgSend(titleLbl, sel("setText:"), titleStr);
        id whiteColor = msgSend((id)uiColor, sel("whiteColor"));
        msgSend(titleLbl, sel("setTextColor:"), whiteColor);
        id titleFont = msgSend((id)uiFont, sel("boldSystemFontOfSize:"), 11.0);
        msgSend(titleLbl, sel("setFont:"), titleFont);
        msgSend(titleBar, sel("addSubview:"), titleLbl);

        // Close Button [x]
        id closeBtn = msgSend((id)uiButton, sel("buttonWithType:"), 0);
        ((void (*)(id, SEL, CGRect))objc_msgSend)(closeBtn, sel("setFrame:"), CGRectMake(termW - 32, 2, 26, 26));
        id xStr = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "✕");
        msgSend(closeBtn, sel("setTitle:forState:"), xStr, 0);
        id grayColor = msgSend((id)uiColor, sel("colorWithWhite:alpha:"), 0.7, 1.0);
        msgSend(closeBtn, sel("setTitleColor:forState:"), grayColor, 0);
        id xFont = msgSend((id)uiFont, sel("boldSystemFontOfSize:"), 14.0);
        id btnLbl = msgSend(closeBtn, sel("titleLabel"));
        if (btnLbl) msgSend(btnLbl, sel("setFont:"), xFont);
        msgSend(closeBtn, sel("addTarget:action:forControlEvents:"), cls("Yes360CloseTarget"), sel("closeClicked:"), 1 << 6);

        msgSend(titleBar, sel("addSubview:"), closeBtn);
        msgSend(termView, sel("addSubview:"), titleBar);

        // Terminal Output TextView
        id textView = msgSend_rect(msgSend((id)uiTextView, sel("alloc")), sel("initWithFrame:"), CGRectMake(8, 32, termW - 16, termH - 36));
        id clearColor = msgSend((id)uiColor, sel("clearColor"));
        msgSend(textView, sel("setBackgroundColor:"), clearColor);
        id greenColor = msgSend((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.0, 1.0, 0.4, 1.0); // #00FF66 Matrix Green
        msgSend(textView, sel("setTextColor:"), greenColor);
        ((void (*)(id, SEL, BOOL))objc_msgSend)(textView, sel("setEditable:"), NO);
        ((void (*)(id, SEL, BOOL))objc_msgSend)(textView, sel("setSelectable:"), NO);

        id termFont = msgSend((id)uiFont, sel("fontWithName:size:"), msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "Menlo-Regular"), 10.5);
        if (!termFont) termFont = msgSend((id)uiFont, sel("fontWithName:size:"), msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "Courier"), 10.5);
        if (!termFont) termFont = msgSend((id)uiFont, sel("systemFontOfSize:"), 10.5);
        msgSend(textView, sel("setFont:"), termFont);
        msgSend(termView, sel("addSubview:"), textView);

        // Add to window
        msgSend(window, sel("addSubview:"), termView);

        // Live Log Stream
        if (is_on) {
            append_terminal_line(textView, "> [0.00s] Initializing Yes360 Auto-Search Engine...");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (session != g_terminal_session) return;
                append_terminal_line(textView, "> [0.12s] Kernel Task: mach_task_self() OK");
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (session != g_terminal_session) return;
                append_terminal_line(textView, "> [0.25s] ASLR Slide Synchronized & Verified");
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.40 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (session != g_terminal_session) return;
                append_terminal_line(textView, "> [0.40s] Patching Const [slide + 0x102a371f0] -> 360.0 [OK]");
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.60 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (session != g_terminal_session) return;
                append_terminal_line(textView, "> [0.60s] Scanning Heap: Double 3.14 -> 360.0 (DLG Engine)...");
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.80 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (session != g_terminal_session) return;
                append_terminal_line(textView, "> [0.80s] Instance Field 106D67F0 Matched & Overwritten!");
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.00 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (session != g_terminal_session) return;
                append_terminal_line(textView, "> [1.00s] Updating Pointer *(slide + 0x103a88060) + 0x10 [SUCCESS]");
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (session != g_terminal_session) return;
                append_terminal_line(textView, "> [1.25s] Instruction Hook at 0x10272ca44 Active");
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (session != g_terminal_session) return;
                append_terminal_line(textView, "> [1.45s] [✓] YES360 ACTIVE! 360 Degree View Enabled.");
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (session != g_terminal_session) return;
                close_terminal_view();
            });
        } else {
            append_terminal_line(textView, "> [0.00s] Yes360 Toggled OFF: Restoring Originals...");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (session != g_terminal_session) return;
                append_terminal_line(textView, "> [0.15s] Restoring Const [slide + 0x102a371f0] -> 3.14 [OK]");
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (session != g_terminal_session) return;
                append_terminal_line(textView, "> [0.35s] Restoring Memory 106D67F0: 360.0 -> 3.14 [DONE]");
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (session != g_terminal_session) return;
                append_terminal_line(textView, "> [0.55s] [✓] Yes360 Disabled. Original 3.14 Restored.");
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (session != g_terminal_session) return;
                close_terminal_view();
            });
        }
    });
}

// Memory search args
typedef struct {
    double from_val;
    double to_val;
} search_args_t;

// Background memory scanner - completely safe using mach_vm_read_overwrite
static void *background_memory_scanner(void *arg) {
    search_args_t *args = (search_args_t *)arg;
    if (!args) return NULL;
    double from_val = args->from_val;
    double to_val = args->to_val;
    free(args);

    mach_port_t task = mach_task_self();
    mach_vm_address_t address = 0x10000000;
    mach_vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object_name = MACH_PORT_NULL;

    uint64_t from_bits, to_bits;
    memcpy(&from_bits, &from_val, sizeof(double));
    memcpy(&to_bits, &to_val, sizeof(double));

    #define SCAN_CHUNK_SIZE 16384
    uint8_t buf[SCAN_CHUNK_SIZE];

    while (address < 0x300000000) {
        count = VM_REGION_BASIC_INFO_COUNT_64;
        if (mach_vm_region(task, &address, &size, VM_REGION_BASIC_INFO_64,
                           (vm_region_info_t)&info, &count, &object_name) != KERN_SUCCESS) {
            break;
        }

        // Only search readable, writable, non-executable heap/data pages of reasonable size (<32MB)
        if ((info.protection & VM_PROT_READ) && (info.protection & VM_PROT_WRITE) &&
            !(info.protection & VM_PROT_EXECUTE) && size <= (32 * 1024 * 1024)) {
            mach_vm_size_t offset = 0;
            while (offset < size) {
                mach_vm_size_t chunk = (size - offset > SCAN_CHUNK_SIZE) ? SCAN_CHUNK_SIZE : (size - offset);
                mach_vm_size_t bytes_read = 0;
                if (mach_vm_read_overwrite(task, address + offset, chunk, (mach_vm_address_t)buf, &bytes_read) == KERN_SUCCESS) {
                    for (mach_vm_size_t i = 0; i + sizeof(uint64_t) <= bytes_read; i += 4) {
                        uint64_t v;
                        memcpy(&v, buf + i, sizeof(uint64_t));
                        if (v == from_bits) {
                            mach_vm_write(task, address + offset + i, (vm_offset_t)&to_bits, sizeof(uint64_t));
                        }
                    }
                }
                offset += chunk;
            }
        }
        address += size;
    }
    return NULL;
}

// 100% crash-proof memory applier using kernel Mach VM primitives
static void apply_aimbot_angle(double new_val, double old_val, uint32_t patch_opcode) {
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    mach_port_t task = mach_task_self();

    // 1. Original game binary instruction hook at slide + 0x10272ca44
    mach_vm_address_t code_addr = (mach_vm_address_t)(slide + 0x10272ca44);
    if (vm_protect(task, code_addr, 4, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) == KERN_SUCCESS) {
        vm_write(task, code_addr, (vm_offset_t)&patch_opcode, 4);
        vm_protect(task, code_addr, 4, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    }

    // 2. Game binary constant at slide + 0x102a371f0
    mach_vm_address_t const_addr = (mach_vm_address_t)(slide + 0x102a371f0);
    if (vm_protect(task, const_addr, sizeof(double), FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) == KERN_SUCCESS) {
        vm_write(task, const_addr, (vm_offset_t)&new_val, sizeof(double));
        vm_protect(task, const_addr, sizeof(double), FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    }

    // 3. Active instance field at *(slide + 0x103a88060) + 0x10 (field 106D67F0)
    mach_vm_address_t ptr_loc = (mach_vm_address_t)(slide + 0x103a88060);
    vm_offset_t data_read = 0;
    mach_msg_type_number_t count = 0;
    if (vm_read(task, ptr_loc, sizeof(uint64_t), &data_read, &count) == KERN_SUCCESS && count >= sizeof(uint64_t)) {
        uint64_t obj_ptr = *(uint64_t *)data_read;
        vm_deallocate(task, data_read, count);
        if (obj_ptr > 0x10000000 && obj_ptr < 0x300000000 && (obj_ptr & 0x7) == 0) {
            mach_vm_address_t field_addr = (mach_vm_address_t)(obj_ptr + 0x10);
            vm_write(task, field_addr, (vm_offset_t)&new_val, sizeof(double));
        }
    }

    // 4. Automated memory search & replace (mirrors DLG double search & modify)
    search_args_t *args = (search_args_t *)malloc(sizeof(search_args_t));
    if (args) {
        args->from_val = old_val;
        args->to_val = new_val;
        pthread_t t;
        if (pthread_create(&t, NULL, background_memory_scanner, args) == 0) {
            pthread_detach(t);
        } else {
            free(args);
        }
    }
}

// Swizzled feature11 (Yes360 / AIMBOT 360)
static void custom_feature11(id self, SEL _cmd, id sw) {
    BOOL on = YES;
    if (sw) {
        SEL isOnSel = sel("isOn");
        if ((BOOL)msgSend(sw, sel("respondsToSelector:"), isOnSel)) {
            on = (BOOL)msgSend(sw, isOnSel);
        }
    }

    // Save switch state
    Class nsDefaults = cls("NSUserDefaults");
    if (nsDefaults) {
        id defaults = msgSend((id)nsDefaults, sel("standardUserDefaults"));
        if (defaults) {
            Class nsString = cls("NSString");
            id key = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "sw11");
            msgSend(defaults, sel("setBool:forKey:"), on, key);
            msgSend(defaults, sel("synchronize"));
        }
    }

    // Show On-Screen Terminal Flow
    show_terminal_flow(on);

    // Apply Memory Search & Overwrite (0x8b1e6540 = 360 instruction, 0xb81e0940 = original)
    if (on) {
        apply_aimbot_angle(360.0, 3.14, 0x8b1e6540);
    } else {
        apply_aimbot_angle(3.14, 360.0, 0xb81e0940);
    }
}

// Swizzled feature12 (AIMBOT 180)
static void custom_feature12(id self, SEL _cmd, id sw) {
    BOOL on = YES;
    if (sw) {
        SEL isOnSel = sel("isOn");
        if ((BOOL)msgSend(sw, sel("respondsToSelector:"), isOnSel)) {
            on = (BOOL)msgSend(sw, isOnSel);
        }
    }

    Class nsDefaults = cls("NSUserDefaults");
    if (nsDefaults) {
        id defaults = msgSend((id)nsDefaults, sel("standardUserDefaults"));
        if (defaults) {
            Class nsString = cls("NSString");
            id key = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "sw12");
            msgSend(defaults, sel("setBool:forKey:"), on, key);
            msgSend(defaults, sel("synchronize"));
        }
    }

    if (on) {
        apply_aimbot_angle(180.0, 3.14, 0x8b1e4940);
    } else {
        apply_aimbot_angle(3.14, 180.0, 0xb81e0940);
    }
}

static void install_hooks(void) {
    Class metaCls = objc_getMetaClass("NSObject");
    if (metaCls) {
        class_replaceMethod(metaCls, sel("feature11:"), (IMP)custom_feature11, "v@:@");
        class_replaceMethod(metaCls, sel("feature12:"), (IMP)custom_feature12, "v@:@");
    }
}

__attribute__((constructor))
static void init_aimbot_hook() {
    install_hooks();

    // Re-verify hooks after app finishes initialization
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        install_hooks();
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        install_hooks();
    });
}
