# ROS ikhozzzz Mod Menu & Yes360 / IGG Auto-Search Engine (v2.6.0)

## 📌 Overview
This release provides the completely updated, crash-free version of **ROS ikhozzzz Mod Menu**, the **Yes360 Auto-Search Engine**, and the automated **iGameGod (IGG) Aimlock & AimSmooth Nearby Search & Edit Engine**.

---

## ⚡ New Features & Capabilities

### 1. Automated IGG Aimlock (Feature 3)
Replaces manual iGameGod nearby searching with a 1-click automated memory scanner:
- **Nearby Search (Double):** Searches for the player/aim structure containing:
  - `999999999.0` (or `9999999.0`)
  - `800.0`
  - `30.0`
  - `10.0`
  - `0.1`
  - `1.0`
  - `2.0`
- **Automated Memory Modification:**
  - `800.0`, `10.0`, `1.0`, `2.0` ➔ `99999.0`
  - `30.0`, `0.1` ➔ `-1.0`
- **Automatic Revert:** When toggled OFF, restores original values (`800.0`, `10.0`, `1.0`, `2.0`, `30.0`, `0.1`).

### 2. Automated IGG AimSmooth (Integrated with Feature 3)
- **Nearby & Exact Filter (Double):**
  - Searches for nearby cluster with `0.1`, `0.5`, `0.05`
- **Automated Memory Modification:**
  - Edits all matching AimSmooth parameters ➔ `99999.0`
- **Automatic Revert:** Restores original values on toggle OFF.

### 3. Yes360 & AIMBOT 180 Engine (Features 11 & 12)
- Automatically patches game constant `slide + 0x102a371f0` (`3.14` ➔ `360.0` / `180.0`).
- Safely writes to active instance field `106D67F0` (`*(slide + 0x103a88060) + 0x10`).
- Activates code hook at `slide + 0x10272ca44`.
- Scans heap memory safely using buffered kernel `mach_vm_read_overwrite`.

### 4. Cyberpunk On-Screen Terminal Flow HUD
- Real-time visual terminal display on-screen showing live memory search progression, addresses matched, and modification status.
- Interactive `[✕]` button to instantly dismiss the HUD.
- Auto-closes cleanly after execution.

---

## 📁 Directory Structure

```
new-version/
├── ROS_ikhozzzz_rootless_v2.6.0_Yes360.deb   # Rootless package (Dopamine, Palera1n)
├── ROS_ikhozzzz_rootful_v2.6.0_Yes360.deb    # Rootful package (unc0ver, checkra1n)
├── iGameGod_0.8.9.4.deb                      # Standalone iGameGod package
├── README.md                                 # Full documentation
├── IPA_Direct_Injection/                     # Ready for direct .ipa sideloading / injection
│   ├── ros.dylib                             # Main mod menu dylib
│   ├── ros.plist                             # Bundle filter
│   ├── aimbot_auto.dylib                     # Yes360 & IGG Auto-Search engine
│   ├── aimbot_auto.plist                     # Bundle filter
│   └── D79oM.bundle/                         # Menu graphics & logos
└── src/                                      # Source code and build scripts
    ├── aimbot_auto.m                         # Objective-C source with IGG automation
    ├── aimbot_auto.plist                     # Bundle filter
    ├── ros.plist                             # Bundle filter
    ├── control                               # Debian package metadata
    └── build.sh                              # Automatic build & pack script
```

---

## 🚀 How to Install & Use

### Option A: Jailbroken Device (.deb)
- **Rootless:** Install `ROS_ikhozzzz_rootless_v2.6.0_Yes360.deb` via Sileo, Zebra, or Filza.
- **Rootful:** Install `ROS_ikhozzzz_rootful_v2.6.0_Yes360.deb` via Cydia, Zebra, or Filza.

### Option B: Non-Jailbroken IPA Injection (Sideloadly, ESign, TrollStore, Scarlet)
1. Inject both `ros.dylib` and `aimbot_auto.dylib` from `IPA_Direct_Injection/` into the ROS `.ipa`.
2. Include the `D79oM.bundle` folder in the root of the app bundle.
3. Sign and install.

---

## 🎮 In-Game Controls
1. **AIMLOCK 100% (Switch 3):** Toggles automated IGG Aimlock (`800,10,1,2 -> 99999`, `30,0.1 -> -1`) and AimSmooth (`0.1, 0.5, 0.05 -> 99999`) with live terminal HUD.
2. **AIMBOT 360 / Yes360 (Switch 11):** Toggles automated 360-degree rotation view (`3.14 -> 360.0`).
3. **AIMBOT 180 (Switch 12):** Toggles 180-degree view (`3.14 -> 180.0`).
