import os, shutil, subprocess

extracted_dir = '/Users/macbook/Documents/vibol/Ros/ros/doggymod_extracted'
ros_dir = '/Users/macbook/Documents/vibol/Ros/ros'
workspace_dir = '/Users/macbook/Documents/vibol/Ros'

def build_deb(is_rootless, out_name):
    mode_str = 'rootless' if is_rootless else 'rootful'
    tmp_build = f'/tmp/build_deb_{mode_str}'
    shutil.rmtree(tmp_build, ignore_errors=True)
    os.makedirs(f'{tmp_build}/control', exist_ok=True)
    
    prefix = '/var/jb' if is_rootless else ''
    tweak_dir = f'{tmp_build}/data{prefix}/Library/MobileSubstrate/DynamicLibraries'
    support_dir = f'{tmp_build}/data{prefix}/Library/Application Support/ROS_Doggymod'
    os.makedirs(tweak_dir, exist_ok=True)
    os.makedirs(support_dir, exist_ok=True)

    with open(f'{tmp_build}/debian-binary', 'w') as f:
        f.write('2.0\n')

    ctrl_content = f'''Package: com.ikhozzzz.ros
Name: Ros_ikhozzzz VIP ({'v2 - Rootless' if is_rootless else 'v1 - Rootful'})
Depends: mobilesubstrate
Architecture: iphoneos-arm64
Replaces: com.doggymod.ros
Conflicts: com.doggymod.ros
Provides: com.doggymod.ros
Description: Rules of Survival VIP Mod Menu (Ros_ikhozzzz {'v2' if is_rootless else 'v1'}) with Floating Logo, Close [X] Button, Aimbot 360, ESP Laser & Box, Fly Hack, 1 Hit Kill, Speed Epic, No Recoil 100% & Wallhack ({'Rootless' if is_rootless else 'Rootful'}).
Maintainer: ikhozzzz
Author: ikhozzzz & DoggyMod
Section: Tweaks
Version: {'2.0.0' if is_rootless else '1.0.0'}
Installed-Size: 2400
'''
    with open(f'{tmp_build}/control/control', 'w') as f:
        f.write(ctrl_content)

    postinst_content = f'''#!/bin/sh
for app in /var/containers/Bundle/Application/*/client.app /Applications/client.app; do
    if [ -d "$app" ]; then
        cp -f "{prefix}/Library/Application Support/ROS_Doggymod/"* "$app/" 2>/dev/null || true
        cp -R "{prefix}/Library/MobileSubstrate/DynamicLibraries/D79oM.bundle" "$app/" 2>/dev/null || true
    fi
done
exit 0
'''
    postinst_path = f'{tmp_build}/control/postinst'
    with open(postinst_path, 'w') as f:
        f.write(postinst_content)
    os.chmod(postinst_path, 0o755)

    # 1. MobileSubstrate tweaks
    shutil.copy(os.path.join(extracted_dir, 'FlyMenu.dylib'), os.path.join(tweak_dir, 'FlyMenu.dylib'))
    shutil.copy(os.path.join(extracted_dir, 'FlyMenu_core.dylib'), os.path.join(tweak_dir, 'FlyMenu_core.dylib'))
    shutil.copy(os.path.join(extracted_dir, 'FlyMenu.plist'), os.path.join(tweak_dir, 'FlyMenu.plist'))
    shutil.copy(os.path.join(extracted_dir, 'ros.dylib'), os.path.join(tweak_dir, 'ros.dylib'))
    shutil.copy(os.path.join(extracted_dir, 'ros.plist'), os.path.join(tweak_dir, 'ros.plist'))

    if os.path.exists(os.path.join(extracted_dir, 'rosauthhook.dylib')):
        shutil.copy(os.path.join(extracted_dir, 'rosauthhook.dylib'), os.path.join(tweak_dir, 'rosauthhook.dylib'))
    if os.path.exists(os.path.join(extracted_dir, 'rosauthhook.plist')):
        shutil.copy(os.path.join(extracted_dir, 'rosauthhook.plist'), os.path.join(tweak_dir, 'rosauthhook.plist'))

    bundle_dst = os.path.join(tweak_dir, 'D79oM.bundle')
    if os.path.exists(bundle_dst):
        shutil.rmtree(bundle_dst)
    shutil.copytree(os.path.join(extracted_dir, 'D79oM.bundle'), bundle_dst)

    # 2. Application Support
    shutil.copy(os.path.join(extracted_dir, 'ros_fly.py'), os.path.join(support_dir, 'ros_fly.py'))
    shutil.copy(os.path.join(extracted_dir, 'ros_combat.py'), os.path.join(support_dir, 'ros_combat.py'))
    shutil.copy(os.path.join(extracted_dir, 'ros_content.json'), os.path.join(support_dir, 'ros_content.json'))
    shutil.copy(os.path.join(extracted_dir, 'D79oM.bundle', 'header.png'), os.path.join(support_dir, 'header.png'))
    shutil.copy(os.path.join(extracted_dir, 'D79oM.bundle', 'back.png'), os.path.join(support_dir, 'back.png'))

    # 3. install_name_tool and codesign
    for dylib_name in ['FlyMenu.dylib', 'FlyMenu_core.dylib', 'ros.dylib', 'rosauthhook.dylib']:
        d_path = os.path.join(tweak_dir, dylib_name)
        if os.path.exists(d_path):
            subprocess.run(['install_name_tool', '-id', f'{prefix}/Library/MobileSubstrate/DynamicLibraries/{dylib_name}', d_path], check=True)
            subprocess.run(['codesign', '-f', '-s', '-', d_path], check=True)

    # 4. Clean AppleDouble
    env = os.environ.copy()
    env['COPYFILE_DISABLE'] = '1'
    subprocess.run(['find', tmp_build, '-name', '._*', '-delete'], env=env)

    # 5. Build archives
    subprocess.run(['tar', '-cJf', f'{tmp_build}/control.tar.xz', '-C', f'{tmp_build}/control', '.'], env=env, check=True)
    subprocess.run(['tar', '-cJf', f'{tmp_build}/data.tar.xz', '-C', f'{tmp_build}/data', '.'], env=env, check=True)

    out_deb_ros = os.path.join(ros_dir, out_name)
    subprocess.run(['ar', '-cr', out_deb_ros, f'{tmp_build}/debian-binary', f'{tmp_build}/control.tar.xz', f'{tmp_build}/data.tar.xz'], check=True)
    
    # Copy to workspace root as well
    shutil.copy(out_deb_ros, os.path.join(workspace_dir, out_name))
    print(f'Successfully Built: {out_deb_ros} ({os.path.getsize(out_deb_ros)} bytes)')
    shutil.rmtree(tmp_build)

# Update 1: Rootful -> Ros_ikhozzzz_v1.deb (and aliases)
build_deb(is_rootless=False, out_name='Ros_ikhozzzz_v1.deb')
for extra in ['Ros_ikhozzzz_rootful_v1.deb', 'Ros_ikhozzzz.deb', 'ROS_Doggymod_rootful.deb']:
    shutil.copy(os.path.join(ros_dir, 'Ros_ikhozzzz_v1.deb'), os.path.join(ros_dir, extra))
    shutil.copy(os.path.join(ros_dir, 'Ros_ikhozzzz_v1.deb'), os.path.join(workspace_dir, extra))

# Update 2: Rootless -> Ros_ikhozzzz_v2.deb (and aliases)
build_deb(is_rootless=True, out_name='Ros_ikhozzzz_v2.deb')
for extra in ['Ros_ikhozzzz_rootless_v2.deb', 'ROS_Doggymod_rootless.deb']:
    shutil.copy(os.path.join(ros_dir, 'Ros_ikhozzzz_v2.deb'), os.path.join(ros_dir, extra))
    shutil.copy(os.path.join(ros_dir, 'Ros_ikhozzzz_v2.deb'), os.path.join(workspace_dir, extra))