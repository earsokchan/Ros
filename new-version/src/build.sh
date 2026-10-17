#!/usr/bin/env bash
set -e

# Disable AppleDouble (._*) files in tar archives
export COPYFILE_DISABLE=1

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$(dirname "$DIR")"
IPA_DIR="$ROOT_DIR/IPA_Direct_Injection"

echo "==============================================="
echo "   Building ROS ikhozzzz Mod Menu & Yes360     "
echo "==============================================="

# 1. Compile aimbot_auto.dylib
echo "[1/4] Compiling aimbot_auto.dylib..."
clang -target arm64-apple-ios9.0 -isysroot /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
    -dynamiclib -lobjc -O2 \
    "$DIR/aimbot_auto.m" -o "$DIR/aimbot_auto.dylib"

install_name_tool -id @rpath/aimbot_auto.dylib "$DIR/aimbot_auto.dylib"
codesign -f -s - "$DIR/aimbot_auto.dylib"

# 2. Update IPA Direct Injection files
echo "[2/4] Updating IPA Direct Injection bundle..."
cp "$DIR/aimbot_auto.dylib" "$IPA_DIR/aimbot_auto.dylib"
install_name_tool -id "@executable_path/Frameworks/aimbot_auto.dylib" "$IPA_DIR/aimbot_auto.dylib"
codesign -f -s - "$IPA_DIR/aimbot_auto.dylib"

cp "$DIR/aimbot_auto.plist" "$IPA_DIR/aimbot_auto.plist"
cp "$DIR/ros.plist" "$IPA_DIR/ros.plist"

# Ensure ros.dylib in IPA_DIR is signed
codesign -f -s - "$IPA_DIR/ros.dylib"

# 3. Build Rootless Debian Package
echo "[3/4] Building Rootless .deb package..."
TMP_RL="/tmp/deb_build_rootless"
rm -rf "$TMP_RL"
mkdir -p "$TMP_RL/control"
mkdir -p "$TMP_RL/data/var/jb/Library/MobileSubstrate/DynamicLibraries"

echo "2.0" > "$TMP_RL/debian-binary"
cp "$DIR/control" "$TMP_RL/control/control"

# Copy dylibs and update install names for rootless
cp "$IPA_DIR/ros.dylib" "$TMP_RL/data/var/jb/Library/MobileSubstrate/DynamicLibraries/ros.dylib"
install_name_tool -id "/var/jb/Library/MobileSubstrate/DynamicLibraries/ros.dylib" "$TMP_RL/data/var/jb/Library/MobileSubstrate/DynamicLibraries/ros.dylib"
codesign -f -s - "$TMP_RL/data/var/jb/Library/MobileSubstrate/DynamicLibraries/ros.dylib"

cp "$DIR/aimbot_auto.dylib" "$TMP_RL/data/var/jb/Library/MobileSubstrate/DynamicLibraries/aimbot_auto.dylib"
install_name_tool -id "/var/jb/Library/MobileSubstrate/DynamicLibraries/aimbot_auto.dylib" "$TMP_RL/data/var/jb/Library/MobileSubstrate/DynamicLibraries/aimbot_auto.dylib"
codesign -f -s - "$TMP_RL/data/var/jb/Library/MobileSubstrate/DynamicLibraries/aimbot_auto.dylib"

cp "$DIR/ros.plist" "$TMP_RL/data/var/jb/Library/MobileSubstrate/DynamicLibraries/"
cp "$DIR/aimbot_auto.plist" "$TMP_RL/data/var/jb/Library/MobileSubstrate/DynamicLibraries/"
cp -R "$IPA_DIR/D79oM.bundle" "$TMP_RL/data/var/jb/Library/MobileSubstrate/DynamicLibraries/"

# Clean any remaining ._* files
find "$TMP_RL" -name "._*" -delete || true

(cd "$TMP_RL/control" && tar -cJf "$TMP_RL/control.tar.xz" *)
(cd "$TMP_RL/data" && tar -cJf "$TMP_RL/data.tar.xz" *)
ar -cr "$ROOT_DIR/ROS_ikhozzzz_rootless_v2.6.0_Yes360.deb" "$TMP_RL/debian-binary" "$TMP_RL/control.tar.xz" "$TMP_RL/data.tar.xz"

# Also update the rootless deb at project root for direct access
cp "$ROOT_DIR/ROS_ikhozzzz_rootless_v2.6.0_Yes360.deb" "$ROOT_DIR/../ROS_ikhozzzz_rootless_v2.6.0_Yes360.deb"
rm -rf "$TMP_RL"

# 4. Build Rootful Debian Package
echo "[4/5] Building Rootful .deb package..."
TMP_RF="/tmp/deb_build_rootful"
rm -rf "$TMP_RF"
mkdir -p "$TMP_RF/control"
mkdir -p "$TMP_RF/data/Library/MobileSubstrate/DynamicLibraries"

echo "2.0" > "$TMP_RF/debian-binary"
cp "$DIR/control" "$TMP_RF/control/control"

cp "$IPA_DIR/ros.dylib" "$TMP_RF/data/Library/MobileSubstrate/DynamicLibraries/ros.dylib"
install_name_tool -id "/Library/MobileSubstrate/DynamicLibraries/ros.dylib" "$TMP_RF/data/Library/MobileSubstrate/DynamicLibraries/ros.dylib"
codesign -f -s - "$TMP_RF/data/Library/MobileSubstrate/DynamicLibraries/ros.dylib"

cp "$DIR/aimbot_auto.dylib" "$TMP_RF/data/Library/MobileSubstrate/DynamicLibraries/aimbot_auto.dylib"
install_name_tool -id "/Library/MobileSubstrate/DynamicLibraries/aimbot_auto.dylib" "$TMP_RF/data/Library/MobileSubstrate/DynamicLibraries/aimbot_auto.dylib"
codesign -f -s - "$TMP_RF/data/Library/MobileSubstrate/DynamicLibraries/aimbot_auto.dylib"

cp "$DIR/ros.plist" "$TMP_RF/data/Library/MobileSubstrate/DynamicLibraries/"
cp "$DIR/aimbot_auto.plist" "$TMP_RF/data/Library/MobileSubstrate/DynamicLibraries/"
cp -R "$IPA_DIR/D79oM.bundle" "$TMP_RF/data/Library/MobileSubstrate/DynamicLibraries/"

find "$TMP_RF" -name "._*" -delete || true

(cd "$TMP_RF/control" && tar -cJf "$TMP_RF/control.tar.xz" *)
(cd "$TMP_RF/data" && tar -cJf "$TMP_RF/data.tar.xz" *)
ar -cr "$ROOT_DIR/ROS_ikhozzzz_rootful_v2.6.0_Yes360.deb" "$TMP_RF/debian-binary" "$TMP_RF/control.tar.xz" "$TMP_RF/data.tar.xz"
rm -rf "$TMP_RF"

# 5. Update IPAs with clean client & aimbot_auto.dylib and valid bundle CodeSignature
echo "[5/5] Updating IPAs with clean client, aimbot_auto.dylib & verified CodeSignature..."
TMP_IPA_UPDATE="/tmp/ipa_patch_stage"
rm -rf "$TMP_IPA_UPDATE"
mkdir -p "$TMP_IPA_UPDATE"

python3 -c "
import zipfile, os, shutil, subprocess

base_ipa = '$ROOT_DIR/../Ros ikhozzzz v2.4.0.ipa'
stage = '$TMP_IPA_UPDATE'
app_dir = os.path.join(stage, 'Payload/client.app')
fw_dir = os.path.join(app_dir, 'Frameworks')

print('Extracting base IPA for complete bundle signing...')
with zipfile.ZipFile(base_ipa, 'r') as z:
    z.extractall(stage)

# Copy new aimbot_auto.dylib
src_aimbot = '$DIR/aimbot_auto.dylib'
dst_aimbot = os.path.join(fw_dir, 'aimbot_auto.dylib')
os.makedirs(fw_dir, exist_ok=True)
shutil.copy(src_aimbot, dst_aimbot)

# Remove any old rosauthhook.dylib
old_auth = os.path.join(app_dir, 'rosauthhook.dylib')
if os.path.exists(old_auth):
    os.remove(old_auth)

# 1. Update Info.plist FIRST before signing binary or bundle
plist_path = os.path.join(app_dir, 'Info.plist')
subprocess.run(['plutil', '-replace', 'MinimumOSVersion', '-string', '11.0', plist_path], check=True)

# 2. Patch & reorganize client binary load commands:
# Clean dummy placeholder commands and move LC_CODE_SIGNATURE to be the FINAL load command
client_path = os.path.join(app_dir, 'client')
import struct

with open(client_path, 'rb') as f:
    client_raw = bytearray(f.read())

magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from('<IIIIIIII', client_raw, 0)
offset = 32
cmds = []
for i in range(ncmds):
    cmd, cmdsize = struct.unpack_from('<II', client_raw, offset)
    raw = client_raw[offset:offset+cmdsize]
    str_val = ''
    if cmd in (0xc, 0x18, 0x1c):
        s_off, = struct.unpack_from('<I', raw, 8)
        str_val = raw[s_off:].split(b'\0')[0].decode('latin1', 'ignore')
    cmds.append({'idx': i, 'cmd': cmd, 'cmdsize': cmdsize, 'raw': raw, 'str': str_val})
    offset += cmdsize

# Filter out ros.dylib, rosauthhook, and duplicate libSystem commands
non_codesig = []
codesig_cmd = None
for c in cmds:
    if c['cmd'] == 0x1d: # LC_CODE_SIGNATURE
        codesig_cmd = c
    elif c['str'].endswith('ros.dylib') or c['str'].endswith('rosauthhook.dylib'):
        continue
    elif c['str'] == '/usr/lib/libSystem.B.dylib' and c['idx'] >= 65:
        continue
    else:
        non_codesig.append(c)

new_cmds = non_codesig + [codesig_cmd]
new_ncmds = len(new_cmds)
new_sizeofcmds = sum(len(c['raw']) for c in new_cmds)
padding = b'\0' * (sizeofcmds - new_sizeofcmds)

new_hdr = struct.pack('<IIIIIIII', magic, cputype, cpusubtype, filetype, new_ncmds, new_sizeofcmds, flags, reserved)
new_client = new_hdr + b''.join(c['raw'] for c in new_cmds) + padding + client_raw[32 + sizeofcmds:]

with open(client_path, 'wb') as f:
    f.write(new_client)

print(f'Mach-O load commands reorganized: {new_ncmds} commands, LC_CODE_SIGNATURE is at index {new_ncmds - 1}')

# 3. Configure dylib install names & sign frameworks
subprocess.run(['install_name_tool', '-id', '@executable_path/Frameworks/aimbot_auto.dylib', dst_aimbot], check=True)
subprocess.run(['codesign', '-f', '-s', '-', dst_aimbot], check=True)

# Remove crashing ros.dylib from Frameworks
ros_dylib = os.path.join(fw_dir, 'ros.dylib')
if os.path.exists(ros_dylib):
    os.remove(ros_dylib)

# 4. Sign the entire app bundle (creates valid CodeResources and seals Info.plist hash into client)
print('Codesigning full Payload/client.app bundle...')
subprocess.run(['codesign', '-f', '-s', '-', app_dir], check=True)

# 5. Verify bundle integrity
res = subprocess.run(['codesign', '-v', '-vvv', app_dir], capture_output=True, text=True)
print('Codesign bundle verification:')
print(res.stderr if res.stderr else 'OK')
if res.returncode != 0:
    raise RuntimeError('Bundle codesign verification failed!')
"

# Remove any old rosauthhook.dylib and ros.dylib from IPAs
zip -d "$ROOT_DIR/../Ros ikhozzzz v2.4.0.ipa" "Payload/client.app/rosauthhook.dylib" "Payload/client.app/Frameworks/ros.dylib" 2>/dev/null || true
zip -d "$ROOT_DIR/../Ros ikhozzzz v2.6.0_Fixed.ipa" "Payload/client.app/rosauthhook.dylib" "Payload/client.app/Frameworks/ros.dylib" 2>/dev/null || true

# Update IPAs with clean client, Info.plist, aimbot_auto.dylib (local bridge), and _CodeSignature
echo "Updating IPAs with verified local bridge bundle..."
(cd "$TMP_IPA_UPDATE" && zip -u "$ROOT_DIR/../Ros ikhozzzz v2.4.0.ipa" \
    Payload/client.app/client \
    Payload/client.app/Info.plist \
    Payload/client.app/Frameworks/aimbot_auto.dylib \
    Payload/client.app/_CodeSignature/CodeResources)

(cd "$TMP_IPA_UPDATE" && zip -u "$ROOT_DIR/../Ros ikhozzzz v2.6.0_Fixed.ipa" \
    Payload/client.app/client \
    Payload/client.app/Info.plist \
    Payload/client.app/Frameworks/aimbot_auto.dylib \
    Payload/client.app/_CodeSignature/CodeResources)

cp "$ROOT_DIR/../Ros ikhozzzz v2.4.0.ipa" "$ROOT_DIR/../Ros_Local_Play.ipa"
rm -rf "$TMP_IPA_UPDATE"

echo "==============================================="
echo "   Build Complete! Local Bridge IPAs Ready     "
echo "==============================================="

