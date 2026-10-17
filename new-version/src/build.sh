#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$(dirname "$DIR")"
IPA_DIR="$ROOT_DIR/IPA_Direct_Injection"

echo "==============================================="
echo "   Building ROS ikhozzzz Mod Menu & Yes360     "
echo "==============================================="

# 1. Compile aimbot_auto.dylib
echo "[1/4] Compiling aimbot_auto.dylib..."
clang -target arm64-apple-ios14.0 -dynamiclib -lobjc -O2 \
    "$DIR/aimbot_auto.m" -o "$DIR/aimbot_auto.dylib"

install_name_tool -id @rpath/aimbot_auto.dylib "$DIR/aimbot_auto.dylib"
codesign -f -s - "$DIR/aimbot_auto.dylib"

# 2. Update IPA Direct Injection files
echo "[2/4] Updating IPA Direct Injection bundle..."
cp "$DIR/aimbot_auto.dylib" "$IPA_DIR/aimbot_auto.dylib"
cp "$DIR/aimbot_auto.plist" "$IPA_DIR/aimbot_auto.plist"
cp "$DIR/ros.plist" "$IPA_DIR/ros.plist"

# 3. Build Rootless Debian Package
echo "[3/4] Building Rootless .deb package..."
TMP_RL="/tmp/deb_build_rootless"
rm -rf "$TMP_RL"
mkdir -p "$TMP_RL/control"
mkdir -p "$TMP_RL/data/var/jb/Library/MobileSubstrate/DynamicLibraries"

echo "2.0" > "$TMP_RL/debian-binary"
cp "$DIR/control" "$TMP_RL/control/control"

cp "$IPA_DIR/ros.dylib" "$TMP_RL/data/var/jb/Library/MobileSubstrate/DynamicLibraries/"
cp "$IPA_DIR/ros.plist" "$TMP_RL/data/var/jb/Library/MobileSubstrate/DynamicLibraries/"
cp "$IPA_DIR/aimbot_auto.dylib" "$TMP_RL/data/var/jb/Library/MobileSubstrate/DynamicLibraries/"
cp "$IPA_DIR/aimbot_auto.plist" "$TMP_RL/data/var/jb/Library/MobileSubstrate/DynamicLibraries/"
cp -R "$IPA_DIR/D79oM.bundle" "$TMP_RL/data/var/jb/Library/MobileSubstrate/DynamicLibraries/"

tar -cJf "$TMP_RL/control.tar.xz" -C "$TMP_RL/control" .
tar -cJf "$TMP_RL/data.tar.xz" -C "$TMP_RL/data" .
ar -cr "$ROOT_DIR/ROS_ikhozzzz_rootless_v2.6.0_Yes360.deb" "$TMP_RL/debian-binary" "$TMP_RL/control.tar.xz" "$TMP_RL/data.tar.xz"
rm -rf "$TMP_RL"

# 4. Build Rootful Debian Package
echo "[4/4] Building Rootful .deb package..."
TMP_RF="/tmp/deb_build_rootful"
rm -rf "$TMP_RF"
mkdir -p "$TMP_RF/control"
mkdir -p "$TMP_RF/data/Library/MobileSubstrate/DynamicLibraries"

echo "2.0" > "$TMP_RF/debian-binary"
cp "$DIR/control" "$TMP_RF/control/control"

cp "$IPA_DIR/ros.dylib" "$TMP_RF/data/Library/MobileSubstrate/DynamicLibraries/"
cp "$IPA_DIR/ros.plist" "$TMP_RF/data/Library/MobileSubstrate/DynamicLibraries/"
cp "$IPA_DIR/aimbot_auto.dylib" "$TMP_RF/data/Library/MobileSubstrate/DynamicLibraries/"
cp "$IPA_DIR/aimbot_auto.plist" "$TMP_RF/data/Library/MobileSubstrate/DynamicLibraries/"
cp -R "$IPA_DIR/D79oM.bundle" "$TMP_RF/data/Library/MobileSubstrate/DynamicLibraries/"

tar -cJf "$TMP_RF/control.tar.xz" -C "$TMP_RF/control" .
tar -cJf "$TMP_RF/data.tar.xz" -C "$TMP_RF/data" .
ar -cr "$ROOT_DIR/ROS_ikhozzzz_rootful_v2.6.0_Yes360.deb" "$TMP_RF/debian-binary" "$TMP_RF/control.tar.xz" "$TMP_RF/data.tar.xz"
rm -rf "$TMP_RF"

echo "==============================================="
echo "   Build Complete! All packages updated.       "
echo "==============================================="
