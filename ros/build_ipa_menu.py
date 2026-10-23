#!/usr/bin/env python3
"""Inject FlyMenu + Auto Scope into the direct-install IPA.

The IPA already loads ros.dylib twice. We repurpose the duplicate load command
to load FlyMenu.dylib from the app root, then patch ros.dylib's raw caidan
menu to a no-op so it can never cover the game/DLG. FlyMenu then provides the
clean menu (including Auto Scope) and also suppresses caidan at runtime.
"""
import os
import shutil
import struct
import subprocess
import sys

ROS_DIR = os.path.dirname(os.path.abspath(__file__))
EXTRACTED = os.path.join(ROS_DIR, 'doggymod_extracted')
BASE_IPA = os.path.join(ROS_DIR, 'Ros ikhozzzz v2.4.0.ipa')
OUT_IPA = os.path.join(ROS_DIR, 'Ros ikhozzzz v2.4.0_MenuFixed.ipa')
STAGE = '/tmp/ipa_menu_stage'

CLIENT_REL = 'Payload/client.app/client'
ROS_REL = 'Payload/client.app/Frameworks/ros.dylib'
FLYMENU_REL = 'Payload/client.app/FlyMenu.dylib'
COREMENU_REL = 'Payload/client.app/FlyMenu_core.dylib'
NEW_LOAD_PATH = '@executable_path/FlyMenu.dylib'
CAIDAN_VMADDR = 0x54c20

LC_LOAD_DYLIB = 0xc


def run(cmd, **kw):
    print('+', ' '.join(cmd))
    subprocess.run(cmd, check=True, **kw)


def extract_entry(ipa, rel, stage):
    dst = os.path.join(stage, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    run(['unzip', '-q', '-o', ipa, rel, '-d', stage])


def patch_client_load_command(path):
    with open(path, 'rb') as f:
        raw = bytearray(f.read())

    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = \
        struct.unpack_from('<IIIIIIII', raw, 0)
    if magic != 0xfeedfacf:
        raise RuntimeError('unexpected client magic: %#x' % magic)

    off = 32
    candidates = []
    for i in range(ncmds):
        cmd, cmdsize = struct.unpack_from('<II', raw, off)
        if cmd == LC_LOAD_DYLIB:
            str_off, = struct.unpack_from('<I', raw, off + 8)
            start = off + str_off
            end = raw.index(b'\0', start, off + cmdsize)
            name = raw[start:end].decode('latin1')
            if name.endswith('/ros.dylib') or name == 'ros.dylib':
                candidates.append((i, off, cmdsize, str_off, name))
        off += cmdsize

    if len(candidates) < 2:
        raise RuntimeError('expected duplicate ros.dylib load commands, got %d' % len(candidates))

    idx, cmd_off, cmdsize, str_off, old = candidates[-1]
    space = cmdsize - str_off
    new_bytes = NEW_LOAD_PATH.encode() + b'\0'
    if len(new_bytes) > space:
        raise RuntimeError('no room for %s in command %d' % (NEW_LOAD_PATH, idx))

    raw[cmd_off + str_off:cmd_off + str_off + space] = new_bytes.ljust(space, b'\0')
    with open(path, 'wb') as f:
        f.write(raw)
    print('Patched client load command %d: %s -> %s' % (idx, old, NEW_LOAD_PATH))


def patch_caidan_noop(path):
    with open(path, 'rb') as f:
        data = bytearray(f.read())

    magic, = struct.unpack_from('>I', data, 0)
    slice_off = 0
    if magic == 0xcafebabe:
        nfat, = struct.unpack_from('>I', data, 4)
        slice_off = None
        for i in range(nfat):
            cputype, cpusubtype, offset, size, align = struct.unpack_from('>IIIII', data, 8 + i * 20)
            if cputype == 0x100000c:
                slice_off = offset
                break
        if slice_off is None:
            raise RuntimeError('no arm64 slice in ros.dylib')
        print('ros.dylib arm64 slice at %#x' % slice_off)

    target = slice_off + CAIDAN_VMADDR
    old = bytes(data[target:target + 4])
    if old == b'\xc0\x03\x5f\xd6':
        print('caidan already patched')
        return
    data[target:target + 4] = b'\xc0\x03\x5f\xd6'
    with open(path, 'wb') as f:
        f.write(data)
    print('Patched caidan at file offset %#x (%s -> ret)' % (target, old.hex()))


def sign(path):
    run(['codesign', '-f', '-s', '-', path])


def main():
    if not os.path.exists(BASE_IPA):
        raise SystemExit('missing base IPA: ' + BASE_IPA)
    if os.path.exists(OUT_IPA):
        os.remove(OUT_IPA)
    shutil.rmtree(STAGE, ignore_errors=True)
    os.makedirs(STAGE, exist_ok=True)

    extract_entry(BASE_IPA, CLIENT_REL, STAGE)
    extract_entry(BASE_IPA, ROS_REL, STAGE)

    client = os.path.join(STAGE, CLIENT_REL)
    ros = os.path.join(STAGE, ROS_REL)
    flymenu = os.path.join(STAGE, FLYMENU_REL)
    coremenu = os.path.join(STAGE, COREMENU_REL)

    patch_client_load_command(client)
    patch_caidan_noop(ros)

    shutil.copy2(os.path.join(EXTRACTED, 'FlyMenu.dylib'), flymenu)
    shutil.copy2(os.path.join(EXTRACTED, 'FlyMenu_core.dylib'), coremenu)

    for p in (flymenu, coremenu, ros, client):
        sign(p)

    print('Copying base IPA -> output')
    shutil.copy2(BASE_IPA, OUT_IPA)

    run(['zip', '-q', '-u', OUT_IPA, CLIENT_REL, ROS_REL, FLYMENU_REL, COREMENU_REL], cwd=STAGE)

    print('Output: %s (%d bytes)' % (OUT_IPA, os.path.getsize(OUT_IPA)))


if __name__ == '__main__':
    main()
