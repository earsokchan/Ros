#!/usr/bin/env python3
"""Regenerate embedded_scripts.h from the Python runtime scripts.

The FlyMenu dylib ships ros_fly.py / ros_combat.py as byte arrays so it can
materialise them on disk at runtime. Keep this generator in sync with the
header format: 16 bytes per line, 4 space indent, trailing comma.

Usage: python3 gen_embedded.py [out.h]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = [
    ('EMBEDDED_ROS_FLY_PY', 'ros_fly.py'),
    ('EMBEDDED_ROS_COMBAT_PY', 'ros_combat.py'),
]


def emit(symbol, path):
    with open(path, 'rb') as fh:
        data = fh.read()
    lines = []
    for off in range(0, len(data), 16):
        chunk = data[off:off + 16]
        lines.append('    ' + ', '.join('0x%02x' % b for b in chunk) + ',')
    body = '\n'.join(lines)
    return (body, len(data))


def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, 'embedded_scripts.h')
    parts = ['// Auto-generated embedded scripts',
             '#ifndef EMBEDDED_SCRIPTS_H',
             '#define EMBEDDED_SCRIPTS_H',
             '']
    for symbol, filename in SCRIPTS:
        body, length = emit(symbol, os.path.join(HERE, filename))
        parts.append('static const unsigned char %s[] = {' % symbol)
        parts.append(body)
        parts.append('};')
        parts.append('static const unsigned int %s_LEN = %d;' % (symbol, length))
        parts.append('')
    parts.append('#endif')
    parts.append('')
    with open(out_path, 'w') as fh:
        fh.write('\n'.join(parts))
    print('wrote %s' % out_path)


if __name__ == '__main__':
    main()
