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
SPEED_ENABLE_VMADDR = 0x60d10
SPEED_DISABLE_VMADDRS = (0x5c9cc, 0x5c9f8)
SPEED_VALUE = 15.0
SPEED_DEFAULT = 1.1

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


def arm64_slice_offset(data):
    magic, = struct.unpack_from('>I', data, 0)
    if magic != 0xcafebabe:
        return 0
    nfat, = struct.unpack_from('>I', data, 4)
    for i in range(nfat):
        cputype, cpusubtype, offset, size, align = struct.unpack_from('>IIIII', data, 8 + i * 20)
        if cputype == 0x100000c:
            print('ros.dylib arm64 slice at %#x' % offset)
            return offset
    raise RuntimeError('no arm64 slice in ros.dylib')


def patch_speed_15x(data, slice_off):
    target = slice_off + SPEED_ENABLE_VMADDR
    old = struct.unpack_from('<d', data, target)[0]
    if abs(old - SPEED_VALUE) < 1e-9:
        print('Speed Epic already 15x')
    else:
        if abs(old - 8.0) > 1e-6 and abs(old - 1.6) > 1e-6:
            raise RuntimeError('unexpected Speed Epic value: %r' % old)
        struct.pack_into('<d', data, target, SPEED_VALUE)
        print('Patched Speed Epic value %.1f -> %.1f' % (old, SPEED_VALUE))

    movz_15 = struct.pack('<I', 0xd2e805c8)
    nop = struct.pack('<I', 0xd503201f)
    triple_16 = bytes.fromhex('e8e701b2483393f228ffe7f2')
    for vmaddr in SPEED_DISABLE_VMADDRS:
        off = slice_off + vmaddr
        cur = bytes(data[off:off + 12])
        if cur[:4] == struct.pack('<I', 0xd2e80408):
            data[off:off + 4] = movz_15
            print('Patched Speed Epic disable search at %#x (8.0 -> 15.0)' % vmaddr)
        elif cur == triple_16:
            data[off:off + 12] = movz_15 + nop + nop
            print('Patched Speed Epic disable search at %#x (1.6 -> 15.0)' % vmaddr)
        elif cur[:12] == movz_15 + nop + nop:
            print('Speed Epic disable search at %#x already 15.0' % vmaddr)
        else:
            raise RuntimeError('unexpected disable-search bytes at %#x: %s' % (vmaddr, cur.hex()))


def patch_ros_dylib(path):
    with open(path, 'rb') as f:
        data = bytearray(f.read())

    slice_off = arm64_slice_offset(data)

    target = slice_off + CAIDAN_VMADDR
    old = bytes(data[target:target + 4])
    if old == b'\xc0\x03\x5f\xd6':
        print('caidan already patched')
    else:
        data[target:target + 4] = b'\xc0\x03\x5f\xd6'
        print('Patched caidan at file offset %#x (%s -> ret)' % (target, old.hex()))

    patch_speed_15x(data, slice_off)

    with open(path, 'wb') as f:
        f.write(data)


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
    patch_ros_dylib(ros)

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
