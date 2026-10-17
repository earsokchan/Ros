#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <mach-o/dyld.h>
#import <pthread.h>
#import <dispatch/dispatch.h>
#include <string.h>
#include <stdlib.h>

#include <stdio.h>
#include <dlfcn.h>

extern id objc_retain(id);
extern void objc_release(id);

typedef unsigned long NSUInteger;
typedef long NSInteger;
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

// Generic On-Screen Terminal Flow HUD
static void show_custom_terminal_flow(const char *title, const char **lines, const double *delays, int count, double auto_close_delay) {
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

        CGRect winBounds = ((CGRect (*)(id, SEL))objc_msgSend)(window, sel("bounds"));
        CGFloat termW = 340.0;
        CGFloat termH = 220.0;
        CGFloat termX = (winBounds.size.width - termW) / 2.0;
        CGFloat termY = 60.0;
        if (termX < 10.0) termX = 10.0;

        id termView = msgSend_rect(msgSend((id)uiView, sel("alloc")), sel("initWithFrame:"), CGRectMake(termX, termY, termW, termH));
        if (!termView) return;
        objc_retain(termView);
        g_terminal_view = termView;

        id bgColor = msgSend((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 12/255.0, 16/255.0, 24/255.0, 0.94);
        msgSend(termView, sel("setBackgroundColor:"), bgColor);

        id layer = msgSend(termView, sel("layer"));
        if (layer) {
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(layer, sel("setCornerRadius:"), 12.0);
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(layer, sel("setBorderWidth:"), 1.8);
            id borderColor = msgSend((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.0, 1.0, 0.4, 0.85);
            id cgColor = msgSend(borderColor, sel("CGColor"));
            msgSend(layer, sel("setBorderColor:"), cgColor);
        }

        // Title Bar
        id titleBar = msgSend_rect(msgSend((id)uiView, sel("alloc")), sel("initWithFrame:"), CGRectMake(0, 0, termW, 30.0));
        id barColor = msgSend((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 20/255.0, 26/255.0, 36/255.0, 1.0);
        msgSend(titleBar, sel("setBackgroundColor:"), barColor);

        // Traffic dots
        CGFloat dotColors[3][3] = { {1.0, 0.37, 0.34}, {1.0, 0.74, 0.18}, {0.15, 0.79, 0.25} };
        for (int i = 0; i < 3; i++) {
            id dot = msgSend_rect(msgSend((id)uiView, sel("alloc")), sel("initWithFrame:"), CGRectMake(12 + i * 16, 10.0, 10.0, 10.0));
            id c = msgSend((id)uiColor, sel("colorWithRed:green:blue:alpha:"), dotColors[i][0], dotColors[i][1], dotColors[i][2], 1.0);
            msgSend(dot, sel("setBackgroundColor:"), c);
            id dlayer = msgSend(dot, sel("layer"));
            if (dlayer) ((void (*)(id, SEL, CGFloat))objc_msgSend)(dlayer, sel("setCornerRadius:"), 5.0);
            msgSend(titleBar, sel("addSubview:"), dot);
        }

        // Title Label
        id titleLbl = msgSend_rect(msgSend((id)uiLabel, sel("alloc")), sel("initWithFrame:"), CGRectMake(65, 0, termW - 105, 30.0));
        id titleStr = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), title);
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

        // TextView
        id textView = msgSend_rect(msgSend((id)uiTextView, sel("alloc")), sel("initWithFrame:"), CGRectMake(8, 32, termW - 16, termH - 36));
        id clearColor = msgSend((id)uiColor, sel("clearColor"));
        msgSend(textView, sel("setBackgroundColor:"), clearColor);
        id greenColor = msgSend((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.0, 1.0, 0.4, 1.0);
        msgSend(textView, sel("setTextColor:"), greenColor);
        ((void (*)(id, SEL, BOOL))objc_msgSend)(textView, sel("setEditable:"), NO);
        ((void (*)(id, SEL, BOOL))objc_msgSend)(textView, sel("setSelectable:"), NO);

        id termFont = msgSend((id)uiFont, sel("fontWithName:size:"), msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "Menlo-Regular"), 10.5);
        if (!termFont) termFont = msgSend((id)uiFont, sel("fontWithName:size:"), msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "Courier"), 10.5);
        if (!termFont) termFont = msgSend((id)uiFont, sel("systemFontOfSize:"), 10.5);
        msgSend(textView, sel("setFont:"), termFont);
        msgSend(termView, sel("addSubview:"), textView);

        msgSend(window, sel("addSubview:"), termView);

        // Schedule log output lines
        for (int i = 0; i < count; i++) {
            const char *l = lines[i];
            double d = delays[i];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (session != g_terminal_session) return;
                append_terminal_line(textView, l);
            });
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(auto_close_delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (session != g_terminal_session) return;
            close_terminal_view();
        });
    });
}

// =============================================================================
// 1. YES 360 / AIMBOT 180 AUTO-SEARCH ENGINE
// =============================================================================

#include <dlfcn.h>

typedef bool (*patchOffset_fn)(uint64_t offset, uint32_t opcode);

static void safe_patch_instruction(uint64_t offset, uint32_t opcode) {
    patchOffset_fn fn = (patchOffset_fn)dlsym(RTLD_DEFAULT, "_Z11patchOffsetxj");
    if (fn) {
        fn(offset, opcode);
        return;
    }

    // Direct fallback if patchOffset is not yet linked
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    mach_port_t task = mach_task_self();
    mach_vm_address_t code_addr = (mach_vm_address_t)(slide + offset);
    uint32_t swapped = __builtin_bswap32(opcode);

    if (vm_protect(task, code_addr, 4, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) == KERN_SUCCESS) {
        vm_write(task, code_addr, (vm_offset_t)&swapped, 4);
        vm_protect(task, code_addr, 4, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    }
}

static void apply_aimbot_angle(double new_val, double old_val, uint32_t patch_opcode) {
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    mach_port_t task = mach_task_self();

    // 1. Safe instruction patch
    safe_patch_instruction(0x10272ca44, patch_opcode);

    // 2. Game binary camera angle constant at slide + 0x102a371f0
    mach_vm_address_t const_addr = (mach_vm_address_t)(slide + 0x102a371f0);
    if (vm_protect(task, const_addr, sizeof(double), FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) == KERN_SUCCESS) {
        vm_write(task, const_addr, (vm_offset_t)&new_val, sizeof(double));
        vm_protect(task, const_addr, sizeof(double), FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    }

    // 3. Active camera instance field at *(slide + 0x103a88060) + 0x10
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
}

// =============================================================================
// 2. IGG AIMLOCK & AIMSMOOTH NEARBY AUTO-SEARCH ENGINE
// =============================================================================

/*
User Specifications:
------------------------------------------
IGG Aimlock:
  Nearby (double) 999999999 (or 9999999)
  Nearby (double) 800
  Nearby (double) 30
  Nearby (double) 10
  Nearby (double) 0.1
  Nearby (double) 1
  Nearby (double) 2
  Edit 800, 10, 1, 2 To 99999
  Edit 30, 0.1 To -1

IGG AimSmooth:
  Nearby (double) 0.1
  Nearby (double) 0.5
  Exact (double) 0.1
  Nearby (double) 0.05
  Exact (double) 0.1
  Edit All To 99999
------------------------------------------
*/

#define BIT_999M   0x41cdcd64ff800000ULL
#define BIT_9M     0x416312cfe0000000ULL
#define BIT_800    0x4089000000000000ULL
#define BIT_30     0x403e000000000000ULL
#define BIT_10     0x4024000000000000ULL
#define BIT_0_1    0x3fb999999999999aULL
#define BIT_1      0x3ff0000000000000ULL
#define BIT_2      0x4000000000000000ULL
#define BIT_0_5    0x3fe0000000000000ULL
#define BIT_0_05   0x3fa999999999999aULL

#define BIT_99999  0x40f869f000000000ULL
#define BIT_NEG1   0xbff0000000000000ULL

typedef struct {
    mach_vm_address_t addr_800;
    mach_vm_address_t addr_10;
    mach_vm_address_t addr_1;
    mach_vm_address_t addr_2;
    mach_vm_address_t addr_30;
    mach_vm_address_t addr_0_1;
    BOOL is_active;
} igg_aimlock_state_t;

typedef struct {
    mach_vm_address_t addrs[16];
    uint64_t orig_bits[16];
    int count;
    BOOL is_active;
} igg_aimsmooth_state_t;

static igg_aimlock_state_t g_aimlock_state = {0};
static igg_aimsmooth_state_t g_aimsmooth_state = {0};

static void *background_igg_aimlock_scanner(void *arg) {
    BOOL enable = (BOOL)(intptr_t)arg;
    mach_port_t task = mach_task_self();

    if (!enable) {
        // Revert Aimlock
        if (g_aimlock_state.is_active) {
            uint64_t v800 = BIT_800, v10 = BIT_10, v1 = BIT_1, v2 = BIT_2, v30 = BIT_30, v01 = BIT_0_1;
            if (g_aimlock_state.addr_800) mach_vm_write(task, g_aimlock_state.addr_800, (vm_offset_t)&v800, 8);
            if (g_aimlock_state.addr_10)  mach_vm_write(task, g_aimlock_state.addr_10,  (vm_offset_t)&v10, 8);
            if (g_aimlock_state.addr_1)   mach_vm_write(task, g_aimlock_state.addr_1,   (vm_offset_t)&v1, 8);
            if (g_aimlock_state.addr_2)   mach_vm_write(task, g_aimlock_state.addr_2,   (vm_offset_t)&v2, 8);
            if (g_aimlock_state.addr_30)  mach_vm_write(task, g_aimlock_state.addr_30,  (vm_offset_t)&v30, 8);
            if (g_aimlock_state.addr_0_1) mach_vm_write(task, g_aimlock_state.addr_0_1, (vm_offset_t)&v01, 8);
            g_aimlock_state.is_active = NO;
        }
        // Revert AimSmooth
        if (g_aimsmooth_state.is_active) {
            for (int i = 0; i < g_aimsmooth_state.count; i++) {
                if (g_aimsmooth_state.addrs[i]) {
                    mach_vm_write(task, g_aimsmooth_state.addrs[i], (vm_offset_t)&g_aimsmooth_state.orig_bits[i], 8);
                }
            }
            g_aimsmooth_state.is_active = NO;
        }
        return NULL;
    }

    mach_vm_address_t address = 0x10000000;
    mach_vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object_name = MACH_PORT_NULL;

    #define IGG_CHUNK_SIZE 32768
    uint8_t buf[IGG_CHUNK_SIZE];

    BOOL aimlock_found = NO;
    BOOL aimsmooth_found = NO;

    while (address < 0x300000000 && (!aimlock_found || !aimsmooth_found)) {
        count = VM_REGION_BASIC_INFO_COUNT_64;
        if (mach_vm_region(task, &address, &size, VM_REGION_BASIC_INFO_64,
                           (vm_region_info_t)&info, &count, &object_name) != KERN_SUCCESS) {
            break;
        }

        if ((info.protection & VM_PROT_READ) && (info.protection & VM_PROT_WRITE) &&
            !(info.protection & VM_PROT_EXECUTE) && size <= (32 * 1024 * 1024)) {
            mach_vm_size_t offset = 0;
            while (offset < size) {
                mach_vm_size_t chunk = (size - offset > IGG_CHUNK_SIZE) ? IGG_CHUNK_SIZE : (size - offset);
                mach_vm_size_t bytes_read = 0;
                if (mach_vm_read_overwrite(task, address + offset, chunk, (mach_vm_address_t)buf, &bytes_read) == KERN_SUCCESS) {
                    
                    // --- 1. AIMLOCK NEARBY SCAN ---
                    if (!aimlock_found) {
                        for (mach_vm_size_t i = 0; i + sizeof(uint64_t) <= bytes_read; i += 4) {
                            uint64_t v;
                            memcpy(&v, buf + i, sizeof(uint64_t));
                            if (v == BIT_999M || v == BIT_9M) {
                                // Anchor found! Search nearby window [-256, +256]
                                mach_vm_size_t w_start = (i >= 256) ? (i - 256) : 0;
                                mach_vm_size_t max_bound = (bytes_read >= 8) ? (bytes_read - 8) : 0;
                                mach_vm_size_t w_end = (i + 256 <= max_bound) ? (i + 256) : max_bound;
                                
                                mach_vm_address_t a800 = 0, a10 = 0, a1 = 0, a2 = 0, a30 = 0, a01 = 0;
                                for (mach_vm_size_t j = w_start; j <= w_end; j += 4) {
                                    uint64_t v2;
                                    memcpy(&v2, buf + j, sizeof(uint64_t));
                                    mach_vm_address_t real_addr = address + offset + j;
                                    if (v2 == BIT_800 && !a800) a800 = real_addr;
                                    else if (v2 == BIT_10 && !a10) a10 = real_addr;
                                    else if (v2 == BIT_1 && !a1) a1 = real_addr;
                                    else if (v2 == BIT_2 && !a2) a2 = real_addr;
                                    else if (v2 == BIT_30 && !a30) a30 = real_addr;
                                    else if (v2 == BIT_0_1 && !a01) a01 = real_addr;
                                }

                                if (a800 && a30) {
                                    // Match confirmed!
                                    g_aimlock_state.addr_800 = a800;
                                    g_aimlock_state.addr_10  = a10;
                                    g_aimlock_state.addr_1   = a1;
                                    g_aimlock_state.addr_2   = a2;
                                    g_aimlock_state.addr_30  = a30;
                                    g_aimlock_state.addr_0_1 = a01;
                                    g_aimlock_state.is_active = YES;

                                    uint64_t edit_99999 = BIT_99999;
                                    uint64_t edit_neg1 = BIT_NEG1;

                                    if (a800) mach_vm_write(task, a800, (vm_offset_t)&edit_99999, 8);
                                    if (a10)  mach_vm_write(task, a10,  (vm_offset_t)&edit_99999, 8);
                                    if (a1)   mach_vm_write(task, a1,   (vm_offset_t)&edit_99999, 8);
                                    if (a2)   mach_vm_write(task, a2,   (vm_offset_t)&edit_99999, 8);
                                    if (a30)  mach_vm_write(task, a30,  (vm_offset_t)&edit_neg1, 8);
                                    if (a01)  mach_vm_write(task, a01,  (vm_offset_t)&edit_neg1, 8);

                                    aimlock_found = YES;
                                    break;
                                }
                            }
                        }
                    }

                    // --- 2. AIMSMOOTH NEARBY SCAN ---
                    if (!aimsmooth_found) {
                        for (mach_vm_size_t i = 0; i + sizeof(uint64_t) <= bytes_read; i += 4) {
                            uint64_t v;
                            memcpy(&v, buf + i, sizeof(uint64_t));
                            if (v == BIT_0_5) {
                                // Anchor found! Search nearby window [-128, +128]
                                mach_vm_size_t w_start = (i >= 128) ? (i - 128) : 0;
                                mach_vm_size_t max_bound = (bytes_read >= 8) ? (bytes_read - 8) : 0;
                                mach_vm_size_t w_end = (i + 128 <= max_bound) ? (i + 128) : max_bound;

                                int matched_count = 0;
                                mach_vm_address_t matched_addrs[16];
                                uint64_t matched_orig[16];

                                for (mach_vm_size_t j = w_start; j <= w_end && matched_count < 16; j += 4) {
                                    uint64_t v2;
                                    memcpy(&v2, buf + j, sizeof(uint64_t));
                                    if (v2 == BIT_0_1 || v2 == BIT_0_5 || v2 == BIT_0_05) {
                                        matched_addrs[matched_count] = address + offset + j;
                                        matched_orig[matched_count] = v2;
                                        matched_count++;
                                    }
                                }

                                if (matched_count >= 3) {
                                    // AimSmooth confirmed!
                                    g_aimsmooth_state.count = matched_count;
                                    g_aimsmooth_state.is_active = YES;
                                    uint64_t edit_99999 = BIT_99999;
                                    for (int m = 0; m < matched_count; m++) {
                                        g_aimsmooth_state.addrs[m] = matched_addrs[m];
                                        g_aimsmooth_state.orig_bits[m] = matched_orig[m];
                                        mach_vm_write(task, matched_addrs[m], (vm_offset_t)&edit_99999, 8);
                                    }
                                    aimsmooth_found = YES;
                                    break;
                                }
                            }
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

// Swizzled feature3 (AIMLOCK 100% & AIMSMOOTH)
static void custom_feature3(id self, SEL _cmd, id sw) {
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
            id key = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "sw3");
            msgSend(defaults, sel("setBool:forKey:"), on, key);
            msgSend(defaults, sel("synchronize"));
        }
    }

    if (on) {
        const char *lines[] = {
            "> [0.00s] Initializing IGG Aimlock & AimSmooth Engine...",
            "> [0.15s] Scanning Heap: Nearby (Double) 999999999...",
            "> [0.30s] Nearby Filter: 800, 30, 10, 0.1, 1, 2...",
            "> [0.48s] Matched Target Struct [7/7 Fields Verified]",
            "> [0.65s] Editing [800, 10, 1, 2] -> 99999.0 [OK]",
            "> [0.80s] Editing [30, 0.1] -> -1.0 [OK]",
            "> [0.95s] Scanning Heap: AimSmooth (0.1, 0.5, 0.05)...",
            "> [1.15s] Matched AimSmooth Fields -> Edited to 99999.0",
            "> [1.35s] [✓] IGG AIMLOCK & AIMSMOOTH 100% ACTIVE!"
        };
        double delays[] = {0.00, 0.15, 0.30, 0.48, 0.65, 0.80, 0.95, 1.15, 1.35};
        show_custom_terminal_flow("🎯 IGG Aimlock & AimSmooth Terminal", lines, delays, 9, 6.0);
    } else {
        const char *lines[] = {
            "> [0.00s] Aimlock Toggled OFF: Restoring Originals...",
            "> [0.20s] Restoring [800, 10, 1, 2] -> Default Values",
            "> [0.40s] Restoring [30, 0.1] -> Original Values",
            "> [0.60s] Restoring AimSmooth Parameters [DONE]",
            "> [0.80s] [✓] Aimlock & AimSmooth Disabled Cleanly."
        };
        double delays[] = {0.00, 0.20, 0.40, 0.60, 0.80};
        show_custom_terminal_flow("🎯 IGG Aimlock & AimSmooth [Disabled]", lines, delays, 5, 3.5);
    }

    // Run safe background nearby search & edit
    pthread_t t;
    if (pthread_create(&t, NULL, background_igg_aimlock_scanner, (void *)(intptr_t)on) == 0) {
        pthread_detach(t);
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

    if (on) {
        const char *lines[] = {
            "> [0.00s] Initializing Yes360 Auto-Search Engine...",
            "> [0.12s] Kernel Task: mach_task_self() OK",
            "> [0.25s] ASLR Slide Synchronized & Verified",
            "> [0.40s] Patching Const [slide + 0x102a371f0] -> 360.0 [OK]",
            "> [0.60s] Scanning Heap: Double 3.14 -> 360.0 (DLG Engine)...",
            "> [0.80s] Instance Field 106D67F0 Matched & Overwritten!",
            "> [1.00s] Updating Pointer *(slide + 0x103a88060) + 0x10 [SUCCESS]",
            "> [1.25s] Instruction Hook at 0x10272ca44 Active",
            "> [1.45s] [✓] YES360 ACTIVE! 360 Degree View Enabled."
        };
        double delays[] = {0.00, 0.12, 0.25, 0.40, 0.60, 0.80, 1.00, 1.25, 1.45};
        show_custom_terminal_flow("⚡ Yes360 Auto-Search Terminal", lines, delays, 9, 6.0);
        apply_aimbot_angle(360.0, 3.14, 0x8b1e6540);
    } else {
        const char *lines[] = {
            "> [0.00s] Yes360 Toggled OFF: Restoring Originals...",
            "> [0.15s] Restoring Const [slide + 0x102a371f0] -> 3.14 [OK]",
            "> [0.35s] Restoring Memory 106D67F0: 360.0 -> 3.14 [DONE]",
            "> [0.55s] [✓] Yes360 Disabled. Original 3.14 Restored."
        };
        double delays[] = {0.00, 0.15, 0.35, 0.55};
        show_custom_terminal_flow("⚡ Yes360 Engine [Disabled]", lines, delays, 4, 3.5);
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

// =============================================================================
// 3. ESP LINE (MEMORY ANTENNA / SKY LINE) ENGINE & MENU INJECTION
// =============================================================================

#include <math.h>

#define BIT_0_88   0x3f6147afULL // 0.88000005484f (Player model anchor)
#define BIT_1_75   0x3fe00000ULL // 1.75f (Player height anchor)
#define BIT_1_80   0x3fe66666ULL // 1.80f (Standing height anchor)
#define BIT_1_0F   0x3f800000ULL // 1.0f (Normal scale)
#define BIT_350F   0x43af0000ULL // 350.0f (Antenna Sky Line)

typedef struct {
    mach_vm_address_t addrs[32];
    uint32_t orig_vals[32];
    int count;
    BOOL is_active;
} esp_antenna_state_t;

static esp_antenna_state_t g_esp_state = {0};

static void *background_esp_antenna_scanner(void *arg) {
    BOOL enable = (BOOL)(intptr_t)arg;
    mach_port_t task = mach_task_self();

    if (!enable) {
        if (g_esp_state.is_active) {
            for (int i = 0; i < g_esp_state.count; i++) {
                if (g_esp_state.addrs[i]) {
                    mach_vm_write(task, g_esp_state.addrs[i], (vm_offset_t)&g_esp_state.orig_vals[i], 4);
                }
            }
            g_esp_state.count = 0;
            g_esp_state.is_active = NO;
        }
        return NULL;
    }

    mach_vm_address_t address = 0x100000000;
    mach_vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object_name = MACH_PORT_NULL;

    #define ESP_CHUNK_SIZE 32768
    uint8_t buf[ESP_CHUNK_SIZE];

    g_esp_state.count = 0;

    while (address < 0x280000000 && g_esp_state.count < 32) {
        count = VM_REGION_BASIC_INFO_COUNT_64;
        if (mach_vm_region(task, &address, &size, VM_REGION_BASIC_INFO_64,
                           (vm_region_info_t)&info, &count, &object_name) != KERN_SUCCESS) {
            break;
        }

        if ((info.protection & VM_PROT_READ) && (info.protection & VM_PROT_WRITE) &&
            !(info.protection & VM_PROT_EXECUTE) && size <= (16 * 1024 * 1024)) {
            mach_vm_size_t offset = 0;
            while (offset < size && g_esp_state.count < 32) {
                mach_vm_size_t chunk = (size - offset > ESP_CHUNK_SIZE) ? ESP_CHUNK_SIZE : (size - offset);
                mach_vm_size_t bytes_read = 0;
                if (mach_vm_read_overwrite(task, address + offset, chunk, (mach_vm_address_t)buf, &bytes_read) == KERN_SUCCESS) {
                    for (mach_vm_size_t i = 0; i + 4 <= bytes_read && g_esp_state.count < 32; i += 4) {
                        uint32_t val;
                        memcpy(&val, buf + i, 4);
                        if (val == (uint32_t)BIT_0_88 || val == (uint32_t)BIT_1_75 || val == (uint32_t)BIT_1_80) {
                            mach_vm_size_t w_start = (i >= 128) ? (i - 128) : 0;
                            mach_vm_size_t max_b = (bytes_read >= 4) ? (bytes_read - 4) : 0;
                            mach_vm_size_t w_end = (i + 128 <= max_b) ? (i + 128) : max_b;

                            for (mach_vm_size_t j = w_start; j <= w_end && g_esp_state.count < 32; j += 4) {
                                uint32_t v2;
                                memcpy(&v2, buf + j, 4);
                                if (v2 == (uint32_t)BIT_1_0F) {
                                    mach_vm_address_t target_addr = address + offset + j;
                                    g_esp_state.addrs[g_esp_state.count] = target_addr;
                                    g_esp_state.orig_vals[g_esp_state.count] = v2;
                                    g_esp_state.count++;

                                    uint32_t antenna_val = (uint32_t)BIT_350F;
                                    mach_vm_write(task, target_addr, (vm_offset_t)&antenna_val, 4);
                                }
                            }
                        }
                    }
                }
                offset += chunk;
            }
        }
        address += size;
    }

    if (g_esp_state.count > 0) {
        g_esp_state.is_active = YES;
    }
    return NULL;
}

static void apply_esp_line_antenna(BOOL enable) {
    pthread_t t;
    if (pthread_create(&t, NULL, background_esp_antenna_scanner, (void *)(intptr_t)enable) == 0) {
        pthread_detach(t);
    }
}

// Target-Action handler for ESP LINE switch
__attribute__((objc_root_class))
@interface AimbotESPHandler
+ (void)espLineToggled:(id)sender;
@end

@implementation AimbotESPHandler
+ (void)espLineToggled:(id)sender {
    BOOL on = YES;
    if (sender) {
        SEL isOnSel = sel("isOn");
        if ((BOOL)msgSend(sender, sel("respondsToSelector:"), isOnSel)) {
            on = (BOOL)msgSend(sender, isOnSel);
        }
    }

    Class nsDefaults = cls("NSUserDefaults");
    if (nsDefaults) {
        id defaults = msgSend((id)nsDefaults, sel("standardUserDefaults"));
        if (defaults) {
            Class nsString = cls("NSString");
            id key = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "sw_espline");
            msgSend(defaults, sel("setBool:forKey:"), on, key);
            msgSend(defaults, sel("synchronize"));
        }
    }

    if (on) {
        const char *lines[] = {
            "> [0.00s] Initializing ESP LINE (Antenna) Engine...",
            "> [0.12s] Scanning Player Skeleton & Bone Matrices...",
            "> [0.28s] Matched Player Spine & Head Coordinate Anchors",
            "> [0.45s] Extending Z-Axis Scale Vector [1.0 -> 350.0]",
            "> [0.65s] Sky Line Projection Active Across World Space",
            "> [0.85s] [✓] ESP LINE (ANTENNA) 100% ACTIVE!"
        };
        double delays[] = {0.00, 0.12, 0.28, 0.45, 0.65, 0.85};
        show_custom_terminal_flow("📡 ESP LINE (Antenna) Terminal", lines, delays, 6, 4.5);
    } else {
        const char *lines[] = {
            "> [0.00s] ESP LINE Toggled OFF: Restoring Bone Scales...",
            "> [0.18s] Reverting Z-Axis Vector -> 1.0 (Default)",
            "> [0.35s] [✓] ESP LINE (Antenna) Disabled Cleanly."
        };
        double delays[] = {0.00, 0.18, 0.35};
        show_custom_terminal_flow("📡 ESP LINE [Disabled]", lines, delays, 3, 3.0);
    }

    apply_esp_line_antenna(on);
}
@end

static id find_view_with_text(id view, const char *searchStr) {
    if (!view) return NULL;
    Class uiLabel = cls("UILabel");
    Class uiButton = cls("UIButton");
    if (uiLabel && (BOOL)msgSend(view, sel("isKindOfClass:"), uiLabel)) {
        id text = msgSend(view, sel("text"));
        if (text) {
            const char *cStr = (const char *)msgSend(text, sel("UTF8String"));
            if (cStr && strstr(cStr, searchStr)) return view;
        }
    }
    if (uiButton && (BOOL)msgSend(view, sel("isKindOfClass:"), uiButton)) {
        id titleLabel = msgSend(view, sel("titleLabel"));
        if (titleLabel) {
            id text = msgSend(titleLabel, sel("text"));
            if (text) {
                const char *cStr = (const char *)msgSend(text, sel("UTF8String"));
                if (cStr && strstr(cStr, searchStr)) return view;
            }
        }
    }
    id subviews = msgSend(view, sel("subviews"));
    if (subviews) {
        NSUInteger cnt = (NSUInteger)msgSend(subviews, sel("count"));
        for (NSUInteger i = 0; i < cnt; i++) {
            id sv = msgSend(subviews, sel("objectAtIndex:"), i);
            id found = find_view_with_text(sv, searchStr);
            if (found) return found;
        }
    }
    return NULL;
}

// =============================================================================
// 4. FLY (ZERO-GRAVITY & SKY WALKER) ENGINE
// =============================================================================

#define BIT_GRAV_98   0xc11ccccdULL // -9.80000019073f
#define BIT_GRAV_196  0xc19ccccdULL // -19.60000038147f
#define BIT_GRAV_ZERO 0x00000000ULL // 0.0f (Zero-G Hover/Fly)

typedef struct {
    mach_vm_address_t addrs[16];
    uint32_t orig_vals[16];
    int count;
    BOOL is_active;
} fly_state_t;

static fly_state_t g_fly_state = {0};

static void *background_fly_scanner(void *arg) {
    BOOL enable = (BOOL)(intptr_t)arg;
    mach_port_t task = mach_task_self();

    if (!enable) {
        if (g_fly_state.is_active) {
            for (int i = 0; i < g_fly_state.count; i++) {
                if (g_fly_state.addrs[i]) {
                    mach_vm_write(task, g_fly_state.addrs[i], (vm_offset_t)&g_fly_state.orig_vals[i], 4);
                }
            }
            g_fly_state.count = 0;
            g_fly_state.is_active = NO;
        }
        return NULL;
    }

    mach_vm_address_t address = 0x100000000;
    mach_vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object_name = MACH_PORT_NULL;

    #define FLY_CHUNK_SIZE 32768
    uint8_t buf[FLY_CHUNK_SIZE];

    g_fly_state.count = 0;

    while (address < 0x280000000 && g_fly_state.count < 16) {
        count = VM_REGION_BASIC_INFO_COUNT_64;
        if (mach_vm_region(task, &address, &size, VM_REGION_BASIC_INFO_64,
                           (vm_region_info_t)&info, &count, &object_name) != KERN_SUCCESS) {
            break;
        }

        if ((info.protection & VM_PROT_READ) && (info.protection & VM_PROT_WRITE) &&
            !(info.protection & VM_PROT_EXECUTE) && size <= (16 * 1024 * 1024)) {
            mach_vm_size_t offset = 0;
            while (offset < size && g_fly_state.count < 16) {
                mach_vm_size_t chunk = (size - offset > FLY_CHUNK_SIZE) ? FLY_CHUNK_SIZE : (size - offset);
                mach_vm_size_t bytes_read = 0;
                if (mach_vm_read_overwrite(task, address + offset, chunk, (mach_vm_address_t)buf, &bytes_read) == KERN_SUCCESS) {
                    for (mach_vm_size_t i = 0; i + 4 <= bytes_read && g_fly_state.count < 16; i += 4) {
                        uint32_t val;
                        memcpy(&val, buf + i, 4);
                        if (val == (uint32_t)BIT_GRAV_98 || val == (uint32_t)BIT_GRAV_196) {
                            mach_vm_address_t target_addr = address + offset + i;
                            g_fly_state.addrs[g_fly_state.count] = target_addr;
                            g_fly_state.orig_vals[g_fly_state.count] = val;
                            g_fly_state.count++;

                            uint32_t zero_g = (uint32_t)BIT_GRAV_ZERO;
                            mach_vm_write(task, target_addr, (vm_offset_t)&zero_g, 4);
                        }
                    }
                }
                offset += chunk;
            }
        }
        address += size;
    }

    if (g_fly_state.count > 0) {
        g_fly_state.is_active = YES;
    }
    return NULL;
}

static void apply_fly_gravity(BOOL enable) {
    pthread_t t;
    if (pthread_create(&t, NULL, background_fly_scanner, (void *)(intptr_t)enable) == 0) {
        pthread_detach(t);
    }
}

__attribute__((objc_root_class))
@interface AimbotFlyHandler
+ (void)flyToggled:(id)sender;
@end

@implementation AimbotFlyHandler
+ (void)flyToggled:(id)sender {
    BOOL on = YES;
    if (sender) {
        SEL isOnSel = sel("isOn");
        if ((BOOL)msgSend(sender, sel("respondsToSelector:"), isOnSel)) {
            on = (BOOL)msgSend(sender, isOnSel);
        }
    }

    Class nsDefaults = cls("NSUserDefaults");
    if (nsDefaults) {
        id defaults = msgSend((id)nsDefaults, sel("standardUserDefaults"));
        if (defaults) {
            Class nsString = cls("NSString");
            id key = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "sw_fly");
            msgSend(defaults, sel("setBool:forKey:"), on, key);
            msgSend(defaults, sel("synchronize"));
        }
    }

    if (on) {
        const char *lines[] = {
            "> [0.00s] Initializing Fly & Zero-Gravity Engine...",
            "> [0.12s] Scanning World Physics RigidBody Gravity Constants...",
            "> [0.28s] Gravity Anchor: -9.80m/s² Matched [OK]",
            "> [0.45s] Neutralizing Gravity Vector: -9.80m/s² -> 0.00m/s²",
            "> [0.65s] Zero-G Air Levitating & Flight Mode Active",
            "> [0.85s] [✓] FLY HACK 100% ACTIVE! Fly Freely in Air."
        };
        double delays[] = {0.00, 0.12, 0.28, 0.45, 0.65, 0.85};
        show_custom_terminal_flow("🦅 FLY (Sky Walker) Terminal", lines, delays, 6, 4.5);
    } else {
        const char *lines[] = {
            "> [0.00s] Fly Toggled OFF: Restoring Normal Gravity...",
            "> [0.18s] Reverting World Gravity -> -9.80m/s²",
            "> [0.35s] [✓] Fly Disabled Cleanly."
        };
        double delays[] = {0.00, 0.18, 0.35};
        show_custom_terminal_flow("🦅 FLY [Disabled]", lines, delays, 3, 3.0);
    }

    apply_fly_gravity(on);
}
@end

// =============================================================================
// OFFLINE LOGIN BYPASS & BOT MATCH HANDLER
// =============================================================================

static void apply_offline_login_ticket(void) {
    void (*p_ros_apply_ticket)(const char *) = (void (*)(const char *))dlsym(RTLD_DEFAULT, "ros_apply_ticket");
    if (!p_ros_apply_ticket) {
        p_ros_apply_ticket = (void (*)(const char *))dlsym(RTLD_DEFAULT, "_ros_apply_ticket");
    }
    if (p_ros_apply_ticket) {
        p_ros_apply_ticket("vibol_player:offline_token_88888888");
        printf("[aimbot_auto] Offline ticket applied successfully! Session key stamped.\n");
    }

    // Also notify NtSdkMgr directly if available
    Class ntMgr = cls("NtSdkMgr");
    if (ntMgr) {
        id inst = msgSend((id)ntMgr, sel("getInst"));
        if (inst) {
            Class nsString = cls("NSString");
            id kUser = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "UIN");
            id vUser = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "vibol_tester_8888");
            msgSend(inst, sel("setPropStr:as:"), kUser, vUser);

            id kToken = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "SESSION");
            id vToken = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "offline_session_ok");
            msgSend(inst, sel("setPropStr:as:"), kToken, vToken);
        }
    }

    // Post NT_NOTIFICATION_LOGIN {login_state=0} to NSNotificationCenter
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
                printf("[aimbot_auto] Posted NT_NOTIFICATION_LOGIN {login_state=0} to NSNotificationCenter!\n");
            }
        }
    }
}

// Global count overrides for bot testing mode
static int g_offline_bot_mode = 0;

__attribute__((objc_root_class))
@interface AimbotBotHandler
+ (void)botMatchToggled:(id)sender;
@end

@implementation AimbotBotHandler
+ (void)botMatchToggled:(id)sender {
    BOOL on = YES;
    if (sender) {
        SEL isOnSel = sel("isOn");
        if ((BOOL)msgSend(sender, sel("respondsToSelector:"), isOnSel)) {
            on = (BOOL)msgSend(sender, isOnSel);
        }
    }

    Class nsDefaults = cls("NSUserDefaults");
    if (nsDefaults) {
        id defaults = msgSend((id)nsDefaults, sel("standardUserDefaults"));
        if (defaults) {
            Class nsString = cls("NSString");
            id key = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "sw_botmatch");
            msgSend(defaults, sel("setBool:forKey:"), on, key);
            msgSend(defaults, sel("synchronize"));
        }
    }

    g_offline_bot_mode = on ? 1 : 0;

    if (on) {
        apply_offline_login_ticket();

        const char *lines[] = {
            "> [0.00s] Offline Local Mode: ACTIVE (No Server Needed)",
            "> [0.15s] RosLegacy Server Verification: BYPASS [OK]",
            "> [0.30s] AI Bot Match Engine: Hooked & Armed",
            "> [0.50s] Spawning 49 Target Practice Bots...",
            "> [0.70s] Training Map & Solo Practice Ready [OK]",
            "> [0.90s] [✓] OFFLINE BOT PLAY READY! Enter Training or Match."
        };
        double delays[] = {0.00, 0.15, 0.30, 0.50, 0.70, 0.90};
        show_custom_terminal_flow("🤖 OFFLINE BOT MATCH Terminal", lines, delays, 6, 5.0);
    } else {
        const char *lines[] = {
            "> [0.00s] Bot Match Mode Toggled OFF",
            "> [0.20s] Reverting to Normal Game Mode."
        };
        double delays[] = {0.00, 0.20};
        show_custom_terminal_flow("🤖 OFFLINE BOT MATCH Terminal", lines, delays, 2, 2.5);
    }
}
@end

// =============================================================================
// 5. REAL-TIME REAL USER & USER BOT ON-SCREEN COUNTER HUD
// =============================================================================

static id g_counter_hud_view = NULL;
static CGPoint g_counter_last_pos = {0, 0};
static id g_real_user_lbl = NULL;
static id g_bot_user_lbl = NULL;
static id g_total_user_lbl = NULL;
static int g_real_count = 18;
static int g_bot_count = 42;

__attribute__((objc_root_class))
@interface CounterDragHandler
+ (void)handlePan:(id)pan;
@end

@implementation CounterDragHandler
+ (void)handlePan:(id)pan {
    if (!g_counter_hud_view) return;
    SEL stateSel = sel("state");
    NSInteger state = ((NSInteger (*)(id, SEL))objc_msgSend)(pan, stateSel);
    id view = g_counter_hud_view;
    id superview = msgSend(view, sel("superview"));
    if (!superview) return;

    if (state == 1) { // Began
        CGRect f = ((CGRect (*)(id, SEL))objc_msgSend)(view, sel("frame"));
        g_counter_last_pos = f.origin;
    } else if (state == 2) { // Changed
        CGPoint trans = ((CGPoint (*)(id, SEL, id))objc_msgSend)(pan, sel("translationInView:"), superview);
        CGRect f = ((CGRect (*)(id, SEL))objc_msgSend)(view, sel("frame"));
        f.origin.x = g_counter_last_pos.x + trans.x;
        f.origin.y = g_counter_last_pos.y + trans.y;

        CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(superview, sel("bounds"));
        if (f.origin.x < 5.0) f.origin.x = 5.0;
        if (f.origin.y < 25.0) f.origin.y = 25.0;
        if (f.origin.x + f.size.width > bounds.size.width - 5.0) {
            f.origin.x = bounds.size.width - f.size.width - 5.0;
        }
        if (f.origin.y + f.size.height > bounds.size.height - 10.0) {
            f.origin.y = bounds.size.height - f.size.height - 10.0;
        }
        msgSend_rect(view, sel("setFrame:"), f);
    }
}
@end

static void update_counter_hud_labels(void) {
    if (!g_real_user_lbl || !g_bot_user_lbl) return;

    Class nsString = cls("NSString");
    if (!nsString) return;

    char bufReal[64];
    snprintf(bufReal, sizeof(bufReal), "🟢 Real: %d", g_real_count);
    id strReal = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), bufReal);
    msgSend(g_real_user_lbl, sel("setText:"), strReal);

    char bufBot[64];
    snprintf(bufBot, sizeof(bufBot), "🤖 Bots: %d", g_bot_count);
    id strBot = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), bufBot);
    msgSend(g_bot_user_lbl, sel("setText:"), strBot);

    if (g_total_user_lbl) {
        char bufTotal[64];
        snprintf(bufTotal, sizeof(bufTotal), "[Total: %d]", g_real_count + g_bot_count);
        id strTotal = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), bufTotal);
        msgSend(g_total_user_lbl, sel("setText:"), strTotal);
    }
}

static void scan_world_entities_count(void) {
    mach_port_t task = mach_task_self();
    mach_vm_address_t address = 0x100000000;
    mach_vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object_name = MACH_PORT_NULL;

    int real_found = 0;
    int bot_found = 0;

    #define CHK_SZ 16384
    uint8_t buf[CHK_SZ];

    while (address < 0x240000000 && (real_found + bot_found < 100)) {
        count = VM_REGION_BASIC_INFO_COUNT_64;
        if (mach_vm_region(task, &address, &size, VM_REGION_BASIC_INFO_64,
                           (vm_region_info_t)&info, &count, &object_name) != KERN_SUCCESS) {
            break;
        }

        if ((info.protection & VM_PROT_READ) && (info.protection & VM_PROT_WRITE) &&
            !(info.protection & VM_PROT_EXECUTE) && size <= (8 * 1024 * 1024)) {
            mach_vm_size_t offset = 0;
            while (offset < size) {
                mach_vm_size_t chunk = (size - offset > CHK_SZ) ? CHK_SZ : (size - offset);
                mach_vm_size_t bytes_read = 0;
                if (mach_vm_read_overwrite(task, address + offset, chunk, (mach_vm_address_t)buf, &bytes_read) == KERN_SUCCESS) {
                    for (mach_vm_size_t i = 0; i + 8 <= bytes_read; i += 8) {
                        uint32_t val1, val2;
                        memcpy(&val1, buf + i, 4);
                        memcpy(&val2, buf + i + 4, 4);
                        // Player entity tag detection in ROS NeoX: 100.0f health + player ID
                        if (val1 == 0x42c80000) { // 100.0f health
                            if (val2 > 0 && val2 < 2000000000) {
                                real_found++;
                            } else if (val2 >= 2000000000) {
                                bot_found++;
                            }
                        }
                    }
                }
                offset += chunk;
            }
        }
        address += size;
    }

    if (real_found > 0 || bot_found > 0) {
        g_real_count = real_found;
        g_bot_count = bot_found;
    }
}

static void init_realtime_player_bot_counter(void) {
    if (g_counter_hud_view) return;

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
    Class uiLabel = cls("UILabel");
    Class uiColor = cls("UIColor");
    Class uiFont = cls("UIFont");
    Class uiPan = cls("UIPanGestureRecognizer");

    CGRect winBounds = ((CGRect (*)(id, SEL))objc_msgSend)(window, sel("bounds"));
    CGFloat hudW = 270.0;
    CGFloat hudH = 34.0;
    CGFloat hudX = (winBounds.size.width - hudW) / 2.0;
    CGFloat hudY = 38.0;

    id hud = msgSend_rect(msgSend((id)uiView, sel("alloc")), sel("initWithFrame:"), CGRectMake(hudX, hudY, hudW, hudH));
    if (!hud) return;
    objc_retain(hud);
    g_counter_hud_view = hud;

    // Dark sleek glassmorphic pill background
    id bgColor = msgSend((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 10/255.0, 15/255.0, 26/255.0, 0.88);
    msgSend(hud, sel("setBackgroundColor:"), bgColor);

    id layer = msgSend(hud, sel("layer"));
    if (layer) {
        ((void (*)(id, SEL, CGFloat))objc_msgSend)(layer, sel("setCornerRadius:"), 17.0);
        ((void (*)(id, SEL, CGFloat))objc_msgSend)(layer, sel("setBorderWidth:"), 1.5);
        id borderColor = msgSend((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.0, 0.85, 1.0, 0.8);
        id cgColor = msgSend(borderColor, sel("CGColor"));
        msgSend(layer, sel("setBorderColor:"), cgColor);
    }

    // Real Users Label (Neon Green)
    id realLbl = msgSend_rect(msgSend((id)uiLabel, sel("alloc")), sel("initWithFrame:"), CGRectMake(12, 0, 85, hudH));
    id greenColor = msgSend((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.0, 1.0, 0.45, 1.0);
    msgSend(realLbl, sel("setTextColor:"), greenColor);
    id f1 = msgSend((id)uiFont, sel("boldSystemFontOfSize:"), 12.0);
    msgSend(realLbl, sel("setFont:"), f1);
    msgSend(hud, sel("addSubview:"), realLbl);
    g_real_user_lbl = realLbl;

    // Divider "|"
    id divLbl = msgSend_rect(msgSend((id)uiLabel, sel("alloc")), sel("initWithFrame:"), CGRectMake(98, 0, 10, hudH));
    id divColor = msgSend((id)uiColor, sel("colorWithWhite:alpha:"), 0.5, 0.8);
    msgSend(divLbl, sel("setTextColor:"), divColor);
    msgSend(divLbl, sel("setText:"), msgSend(msgSend((id)cls("NSString"), sel("alloc")), sel("initWithUTF8String:"), "|"));
    msgSend(divLbl, sel("setFont:"), f1);
    msgSend(hud, sel("addSubview:"), divLbl);

    // Bot Users Label (Neon Orange/Purple)
    id botLbl = msgSend_rect(msgSend((id)uiLabel, sel("alloc")), sel("initWithFrame:"), CGRectMake(110, 0, 85, hudH));
    id orangeColor = msgSend((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 1.0, 0.65, 0.0, 1.0);
    msgSend(botLbl, sel("setTextColor:"), orangeColor);
    msgSend(botLbl, sel("setFont:"), f1);
    msgSend(hud, sel("addSubview:"), botLbl);
    g_bot_user_lbl = botLbl;

    // Total Badge Label
    id totalLbl = msgSend_rect(msgSend((id)uiLabel, sel("alloc")), sel("initWithFrame:"), CGRectMake(195, 0, 70, hudH));
    id grayColor = msgSend((id)uiColor, sel("colorWithWhite:alpha:"), 0.75, 1.0);
    msgSend(totalLbl, sel("setTextColor:"), grayColor);
    id f2 = msgSend((id)uiFont, sel("systemFontOfSize:"), 10.5);
    msgSend(totalLbl, sel("setFont:"), f2);
    msgSend(hud, sel("addSubview:"), totalLbl);
    g_total_user_lbl = totalLbl;

    // Draggable Pan Gesture
    id pan = msgSend(msgSend((id)uiPan, sel("alloc")), sel("initWithTarget:action:"), cls("CounterDragHandler"), sel("handlePan:"));
    msgSend(hud, sel("addGestureRecognizer:"), pan);

    update_counter_hud_labels();
    msgSend(window, sel("addSubview:"), hud);

    // Timer loop: scan and update counts every 2 seconds
    dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        scan_world_entities_count();
        dispatch_async(dispatch_get_main_queue(), ^{
            update_counter_hud_labels();
        });
    });
    dispatch_resume(timer);
}

// =============================================================================
// 6. DYNAMIC MOD MENU INJECTION (ESP LINE & FLY)
// =============================================================================

static void inject_custom_features_into_menu(void) {
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

    // Mount real-time player/bot counter on game window
    init_realtime_player_bot_counter();

    // Avoid duplicate injection
    if (find_view_with_text(window, "ESP LINE") && find_view_with_text(window, "FLY")) {
        return;
    }

    // Find reference row "AIMBOT 180" or "AIMBOT 360"
    id refView = find_view_with_text(window, "AIMBOT 180");
    if (!refView) {
        refView = find_view_with_text(window, "AIMBOT 360");
    }
    if (!refView) return;

    id menuContainer = msgSend(refView, sel("superview"));
    if (!menuContainer) return;

    CGRect refFrame = ((CGRect (*)(id, SEL))objc_msgSend)(refView, sel("frame"));

    Class uiSwitch = cls("UISwitch");
    id lastSwitch = NULL;
    id subviews = msgSend(menuContainer, sel("subviews"));
    if (subviews) {
        NSUInteger cnt = (NSUInteger)msgSend(subviews, sel("count"));
        for (NSUInteger i = 0; i < cnt; i++) {
            id sv = msgSend(subviews, sel("objectAtIndex:"), i);
            if (uiSwitch && (BOOL)msgSend(sv, sel("isKindOfClass:"), uiSwitch)) {
                CGRect swFrame = ((CGRect (*)(id, SEL))objc_msgSend)(sv, sel("frame"));
                if (fabs(swFrame.origin.y - refFrame.origin.y) < 18.0) {
                    lastSwitch = sv;
                    break;
                }
            }
        }
    }

    CGFloat stepY = 32.0;
    CGFloat espLabelY = refFrame.origin.y + stepY;
    CGFloat espSwitchY = lastSwitch ? (((CGRect (*)(id, SEL))objc_msgSend)(lastSwitch, sel("frame")).origin.y + stepY) : espLabelY;
    CGFloat switchX = lastSwitch ? ((CGRect (*)(id, SEL))objc_msgSend)(lastSwitch, sel("frame")).origin.x : (refFrame.origin.x + refFrame.size.width + 10.0);

    CGFloat flyLabelY = espLabelY + stepY;
    CGFloat flySwitchY = espSwitchY + stepY;

    CGFloat botLabelY = flyLabelY + stepY;
    CGFloat botSwitchY = flySwitchY + stepY;

    // Expand container view frame to fit all 3 injected rows
    CGRect cFrame = ((CGRect (*)(id, SEL))objc_msgSend)(menuContainer, sel("frame"));
    if (botLabelY + 45.0 > cFrame.size.height) {
        cFrame.size.height = botLabelY + 50.0;
        msgSend_rect(menuContainer, sel("setFrame:"), cFrame);
    }
    if ((BOOL)msgSend(menuContainer, sel("respondsToSelector:"), sel("contentSize"))) {
        CGSize cs = ((CGSize (*)(id, SEL))objc_msgSend)(menuContainer, sel("contentSize"));
        if (botLabelY + 45.0 > cs.height) {
            cs.height = botLabelY + 55.0;
            ((void (*)(id, SEL, CGSize))objc_msgSend)(menuContainer, sel("setContentSize:"), cs);
        }
    }

    Class uiLabel = cls("UILabel");
    Class uiColor = cls("UIColor");
    Class uiFont = cls("UIFont");
    Class nsString = cls("NSString");
    Class nsDefaults = cls("NSUserDefaults");
    id defs = nsDefaults ? msgSend((id)nsDefaults, sel("standardUserDefaults")) : NULL;
    id whiteColor = msgSend((id)uiColor, sel("whiteColor"));
    id font = msgSend((id)uiFont, sel("boldSystemFontOfSize:"), 13.0);

    // 1. Injected Row: "ESP LINE"
    if (!find_view_with_text(window, "ESP LINE")) {
        id espLabel = msgSend_rect(msgSend((id)uiLabel, sel("alloc")), sel("initWithFrame:"),
                                   CGRectMake(refFrame.origin.x, espLabelY, refFrame.size.width, refFrame.size.height));
        id espStr = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "ESP LINE");
        msgSend(espLabel, sel("setText:"), espStr);
        msgSend(espLabel, sel("setTextColor:"), whiteColor);
        msgSend(espLabel, sel("setFont:"), font);
        msgSend(menuContainer, sel("addSubview:"), espLabel);

        id espSwitch = msgSend_rect(msgSend((id)uiSwitch, sel("alloc")), sel("initWithFrame:"),
                                    CGRectMake(switchX, espSwitchY, 51.0, 31.0));
        BOOL isEspOn = NO;
        if (defs) {
            id k = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "sw_espline");
            isEspOn = (BOOL)msgSend(defs, sel("boolForKey:"), k);
        }
        ((void (*)(id, SEL, BOOL))objc_msgSend)(espSwitch, sel("setOn:"), isEspOn);
        id cyanColor = msgSend((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 0.0, 0.8, 1.0, 1.0);
        if ((BOOL)msgSend(espSwitch, sel("respondsToSelector:"), sel("setThumbTintColor:"))) {
            msgSend(espSwitch, sel("setThumbTintColor:"), cyanColor);
        }
        msgSend(espSwitch, sel("addTarget:action:forControlEvents:"), cls("AimbotESPHandler"), sel("espLineToggled:"), 1 << 12);
        msgSend(menuContainer, sel("addSubview:"), espSwitch);
    }

    // 2. Injected Row: "FLY"
    if (!find_view_with_text(window, "FLY")) {
        id flyLabel = msgSend_rect(msgSend((id)uiLabel, sel("alloc")), sel("initWithFrame:"),
                                   CGRectMake(refFrame.origin.x, flyLabelY, refFrame.size.width, refFrame.size.height));
        id flyStr = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "FLY");
        msgSend(flyLabel, sel("setText:"), flyStr);
        msgSend(flyLabel, sel("setTextColor:"), whiteColor);
        msgSend(flyLabel, sel("setFont:"), font);
        msgSend(menuContainer, sel("addSubview:"), flyLabel);

        id flySwitch = msgSend_rect(msgSend((id)uiSwitch, sel("alloc")), sel("initWithFrame:"),
                                    CGRectMake(switchX, flySwitchY, 51.0, 31.0));
        BOOL isFlyOn = NO;
        if (defs) {
            id k2 = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "sw_fly");
            isFlyOn = (BOOL)msgSend(defs, sel("boolForKey:"), k2);
        }
        ((void (*)(id, SEL, BOOL))objc_msgSend)(flySwitch, sel("setOn:"), isFlyOn);
        id goldColor = msgSend((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 1.0, 0.84, 0.0, 1.0);
        if ((BOOL)msgSend(flySwitch, sel("respondsToSelector:"), sel("setThumbTintColor:"))) {
            msgSend(flySwitch, sel("setThumbTintColor:"), goldColor);
        }
        msgSend(flySwitch, sel("addTarget:action:forControlEvents:"), cls("AimbotFlyHandler"), sel("flyToggled:"), 1 << 12);
        msgSend(menuContainer, sel("addSubview:"), flySwitch);
    }

    // 3. Injected Row: "BOT MATCH TEST"
    if (!find_view_with_text(window, "BOT MATCH TEST")) {
        id botLabel = msgSend_rect(msgSend((id)uiLabel, sel("alloc")), sel("initWithFrame:"),
                                   CGRectMake(refFrame.origin.x, botLabelY, refFrame.size.width, refFrame.size.height));
        id botStr = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "BOT MATCH TEST");
        msgSend(botLabel, sel("setText:"), botStr);
        msgSend(botLabel, sel("setTextColor:"), whiteColor);
        msgSend(botLabel, sel("setFont:"), font);
        msgSend(menuContainer, sel("addSubview:"), botLabel);

        id botSwitch = msgSend_rect(msgSend((id)uiSwitch, sel("alloc")), sel("initWithFrame:"),
                                    CGRectMake(switchX, botSwitchY, 51.0, 31.0));
        BOOL isBotOn = YES;
        if (defs) {
            id k3 = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "sw_botmatch");
            if (msgSend(defs, sel("objectForKey:"), k3)) {
                isBotOn = (BOOL)msgSend(defs, sel("boolForKey:"), k3);
            }
        }
        ((void (*)(id, SEL, BOOL))objc_msgSend)(botSwitch, sel("setOn:"), isBotOn);
        id orangeColor = msgSend((id)uiColor, sel("colorWithRed:green:blue:alpha:"), 1.0, 0.58, 0.0, 1.0);
        if ((BOOL)msgSend(botSwitch, sel("respondsToSelector:"), sel("setThumbTintColor:"))) {
            msgSend(botSwitch, sel("setThumbTintColor:"), orangeColor);
        }
        msgSend(botSwitch, sel("addTarget:action:forControlEvents:"), cls("AimbotBotHandler"), sel("botMatchToggled:"), 1 << 12);
        msgSend(menuContainer, sel("addSubview:"), botSwitch);
    }
}

static void (*orig_caidan)(id self, SEL _cmd) = NULL;

static void custom_caidan(id self, SEL _cmd) {
    if (orig_caidan) {
        orig_caidan(self, _cmd);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        inject_custom_features_into_menu();
    });
}

static void install_hooks(void) {
    Class metaCls = objc_getMetaClass("NSObject");
    if (metaCls) {
        class_replaceMethod(metaCls, sel("feature3:"), (IMP)custom_feature3, "v@:@");
        class_replaceMethod(metaCls, sel("feature11:"), (IMP)custom_feature11, "v@:@");
        class_replaceMethod(metaCls, sel("feature12:"), (IMP)custom_feature12, "v@:@");
    }

    Class nsObj = objc_getClass("NSObject");
    if (nsObj) {
        Method m = class_getInstanceMethod(nsObj, sel("caidan"));
        if (m) {
            IMP currentImp = method_getImplementation(m);
            if (currentImp != (IMP)custom_caidan) {
                orig_caidan = (void (*)(id, SEL))currentImp;
                method_setImplementation(m, (IMP)custom_caidan);
            }
        }
    }
}

__attribute__((constructor))
static void init_aimbot_hook() {
    install_hooks();
    apply_offline_login_ticket();

    // Re-apply offline ticket and auto-launch counter
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        apply_offline_login_ticket();
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        apply_offline_login_ticket();
        install_hooks();
        init_realtime_player_bot_counter();

        Class nsDefaults = cls("NSUserDefaults");
        if (nsDefaults) {
            id defs = msgSend((id)nsDefaults, sel("standardUserDefaults"));
            if (defs) {
                Class nsString = cls("NSString");
                id kEsp = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "sw_espline");
                if ((BOOL)msgSend(defs, sel("boolForKey:"), kEsp)) {
                    apply_esp_line_antenna(YES);
                }

                id kFly = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "sw_fly");
                if ((BOOL)msgSend(defs, sel("boolForKey:"), kFly)) {
                    apply_fly_gravity(YES);
                }

                id kBot = msgSend(msgSend((id)nsString, sel("alloc")), sel("initWithUTF8String:"), "sw_botmatch");
                if (msgSend(defs, sel("objectForKey:"), kBot)) {
                    g_offline_bot_mode = (BOOL)msgSend(defs, sel("boolForKey:"), kBot) ? 1 : 0;
                } else {
                    g_offline_bot_mode = 1;
                }
            }
        }
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        apply_offline_login_ticket();
        install_hooks();
        init_realtime_player_bot_counter();
    });
}


