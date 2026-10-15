#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at
# https://mozilla.org/MPL/2.0/.

"""Retags arm64 Mach-O code built for iOS as tvOS, in place: thin static libraries (every
object in the archive), dylibs and frameworks. Apple TV runs the same arm64 code as an
iPhone; the linker only refuses to mix platforms. Rewrites LC_BUILD_VERSION's platform
(iOS 2 -> tvOS 3, iOS simulator 7 -> tvOS simulator 8) and minimum OS, and turns the older
LC_VERSION_MIN_IPHONEOS into LC_VERSION_MIN_TVOS. Sizes never change.

usage: retarget-macho.py device|simulator FILE...
"""
import struct, sys

LC_BUILD_VERSION, LC_VERSION_MIN_IPHONEOS, LC_VERSION_MIN_TVOS = 0x32, 0x25, 0x2F
PLATFORMS = {"device": {2: 3}, "simulator": {7: 8, 2: 8}}
MINOS = 18 << 16  # tvOS 18.0


def patch(buf, base, mapping):
    magic, _, _, _, ncmds, _, _, _ = struct.unpack_from("<IiiIIIII", buf, base)
    if magic != 0xFEEDFACF:
        return 0
    off, changed = base + 32, 0
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", buf, off)
        if cmd == LC_BUILD_VERSION:
            platform = struct.unpack_from("<I", buf, off + 8)[0]
            if platform in mapping:
                struct.pack_into("<II", buf, off + 8, mapping[platform], MINOS)
                changed += 1
        elif cmd == LC_VERSION_MIN_IPHONEOS:
            struct.pack_into("<II", buf, off, LC_VERSION_MIN_TVOS, size)
            struct.pack_into("<I", buf, off + 8, MINOS)
            changed += 1
        off += size
    return changed


def retarget(path, mapping):
    buf = bytearray(open(path, "rb").read())
    count = 0
    if buf[:8] == b"!<arch>\n":
        off = 8
        while off + 60 <= len(buf):
            name = buf[off:off + 16].decode().strip()
            size = int(buf[off + 48:off + 58].decode().strip())
            data = off + 60
            if name.startswith("#1/"):  # BSD long name, stored before the data
                data += int(name[3:])
            count += patch(buf, data, mapping)
            off += 60 + size + (size & 1)
    else:
        count = patch(buf, 0, mapping)
    open(path, "wb").write(buf)
    return count


if __name__ == "__main__":
    mapping = PLATFORMS[sys.argv[1]]
    for path in sys.argv[2:]:
        print(f"{path}: {retarget(path, mapping)} retagged")
