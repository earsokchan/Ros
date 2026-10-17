# ROS ikhozzzz Mod Menu & Yes360 Auto-Search Engine (v2.6.0)

## 📌 Overview
This release provides the completely updated, crash-free version of **ROS ikhozzzz Mod Menu** and the **Yes360 Auto-Search Engine**.

---

## 🛠️ Summary of Fixes (Root Causes Resolved)

### 1. Fixed "Yes 360" & "AIMBOT 180" Crash
- **Previous Issue:** An experimental patch inside `ros.dylib` replaced `patchOffset` with a 12GB synchronous heap-scanning loop that performed direct pointer dereferences (`ldr x10, [x8]`) across unmapped/guard memory pages. This caused an immediate `EXC_BAD_ACCESS` / `SIGSEGV` crash whenever "Yes 360" or other menu switches were toggled.
- **The Fix:**
  - Restored `ros.dylib` to the clean, non-crashing binary where `patchOffset` uses kernel-safe `vm_protect` + `vm_write`.
  - Re-implemented the automated double `3.14` ➔ `360.0` (and `180.0`) engine in `aimbot_auto.m` using **100% safe Mach VM kernel primitives** (`vm_read`, `vm_write`, `vm_protect`).
  - Safely updates:
    1. Game binary constant at `slide + 0x102a371f0` (`3.14` ➔ `360.0` / `180.0`).
    2. Active instance field at `*(slide + 0x103a88060) + 0x10` (`106D67F0`).
    3. Game binary instruction hook at `slide + 0x10272ca44`.
    4. Safe background heap scanning using `mach_vm_read_overwrite` into buffered chunks (no raw memory reads).

### 2. Fixed Crash When Enabling Menu / Other Features
- Fixed previous crashes on **Speed**, **Speed Epic (Feature 6)**, **High Scope (Feature 8)**, **Fast Shoot (Feature 9)**, and **Auto Scope (Feature 10)**.
- All 12 menu options now operate cleanly and reliably.

### 3. Fixed iOS dyld Framework Linker Crash
- `aimbot_auto.dylib` now links exclusively against `/usr/lib/libobjc.A.dylib` and `/usr/lib/libSystem.B.dylib` with target `arm64-apple-ios14.0`.
- No dependencies on macOS-only framework paths (`Versions/C/Foundation`).

### 4. Terminal Flow & HUD Thread Safety
- Cyberpunk on-screen terminal flow now checks main thread execution, tracks unique sessions to prevent race conditions, and includes a working `[✕]` close button.

---

## 📁 Directory Structure

```
new-version/
├── ROS_ikhozzzz_rootless_v2.6.0_Yes360.deb   # Rootless jailbreak package (Dopamine, Palera1n)
├── ROS_ikhozzzz_rootful_v2.6.0_Yes360.deb    # Rootful jailbreak package (unc0ver, checkra1n)
├── IPA_Direct_Injection/                     # Files for direct .ipa sideloading / injection
│   ├── ros.dylib                             # Main mod menu dylib
│   ├── ros.plist                             # Filter plist (com.netease.chiji & com.netease.g93na)
│   ├── aimbot_auto.dylib                     # Yes360 Auto-Search & Terminal engine
│   ├── aimbot_auto.plist                     # Filter plist
│   └── D79oM.bundle/                         # Menu graphics & logos (header.png, back.png)
└── src/                                      # Source code and build scripts
    ├── aimbot_auto.m                         # Clean Objective-C source
    ├── aimbot_auto.plist                     # Bundle filter
    ├── ros.plist                             # Bundle filter
    ├── control                               # Debian package metadata
    └── build.sh                              # Automatic build & pack script
```

---

## 🚀 How to Install

### Option A: Jailbreak (.deb installation)
- **Rootless (Dopamine / Palera1n):** Install `ROS_ikhozzzz_rootless_v2.6.0_Yes360.deb` via Sileo, Zebra, or Filza.
- **Rootful (Checkra1n / Unc0ver):** Install `ROS_ikhozzzz_rootful_v2.6.0_Yes360.deb` via Cydia, Zebra, or Filza.

### Option B: Sideloading / IPA Injection (Non-Jailbroken)
Using **Sideloadly**, **ESign**, **TrollStore**, **Scarlet**, or **LiveContainer**:
1. Inject both `ros.dylib` and `aimbot_auto.dylib` from `IPA_Direct_Injection/` into your Rules of Survival `.ipa`.
2. Include the `D79oM.bundle` folder into the IPA app bundle root so the menu icons load.
3. Sign and install the IPA to your iOS device.

---

## 🔨 How to Rebuild
To make modifications and rebuild from source:
```bash
cd new-version/src
./build.sh
```
This will automatically recompile `aimbot_auto.dylib`, sign all binaries, and generate the rootless and rootful `.deb` packages.
