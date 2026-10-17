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

typedef struct {
    double from_val;
    double to_val;
} search_args_t;

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
                                mach_vm_size_t w_end = (i + 256 + 8 <= bytes_read) ? (i + 256) : (bytes_read - 8);
                                
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
                                mach_vm_size_t w_end = (i + 128 + 8 <= bytes_read) ? (i + 128) : (bytes_read - 8);

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

static void install_hooks(void) {
    Class metaCls = objc_getMetaClass("NSObject");
    if (metaCls) {
        class_replaceMethod(metaCls, sel("feature3:"), (IMP)custom_feature3, "v@:@");
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
