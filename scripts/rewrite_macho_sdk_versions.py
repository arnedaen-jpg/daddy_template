#!/usr/bin/env python3
"""确定性扰动 Mach-O 的 SDK 版本字段（保留最低系统版本）。

处理：
  - LC_VERSION_MIN_IPHONEOS / MACOSX / TVOS / WATCHOS：只改 sdk，保留 version
  - LC_BUILD_VERSION：只改 sdk，保留 platform + minos

用途：闭源 SDK 常带相同 sdk 指纹；就地改 4 字节，不移段；须重签名。

用法:
    rewrite_macho_sdk_versions.py [--seed S] <binary> [<binary> ...]
"""
from __future__ import annotations

import hashlib
import struct
import sys

LC_VERSION_MIN_MACOSX = 0x24
LC_VERSION_MIN_IPHONEOS = 0x25
LC_VERSION_MIN_TVOS = 0x2F
LC_VERSION_MIN_WATCHOS = 0x30
LC_BUILD_VERSION = 0x32
MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
FAT_MAGIC = 0xCAFEBABE

_MIN_CMDS = {
    LC_VERSION_MIN_MACOSX,
    LC_VERSION_MIN_IPHONEOS,
    LC_VERSION_MIN_TVOS,
    LC_VERSION_MIN_WATCHOS,
}


def _pack_ver(major: int, minor: int, patch: int) -> int:
    return ((major & 0xFFFF) << 16) | ((minor & 0xFF) << 8) | (patch & 0xFF)


def _sdk_for(seed: str, path: str, slice_idx: int, old_sdk: int) -> int:
    """在保留 major 的前提下扰动 minor/patch；major 过小则落到 15。"""
    h = hashlib.sha1(f"{seed}|sdk|{path}|{slice_idx}|{old_sdk}".encode("utf-8")).digest()
    major = (old_sdk >> 16) & 0xFFFF
    if major < 12:
        major = 15
    minor = h[0] % 16
    patch = h[1] % 16
    new = _pack_ver(major, minor, patch)
    if new == old_sdk:
        patch = (patch + 1) % 16
        new = _pack_ver(major, minor, patch)
    return new


def _slices(data: bytes):
    magic = struct.unpack_from(">I", data, 0)[0]
    if magic == FAT_MAGIC:
        narch = struct.unpack_from(">I", data, 4)[0]
        out = []
        for i in range(narch):
            _c, _s, off, size, _a = struct.unpack_from(">IIIII", data, 8 + i * 20)
            out.append((i, off, size))
        return out
    return [(0, 0, len(data))]


def rewrite(path: str, seed: str) -> int:
    with open(path, "rb") as f:
        data = bytearray(f.read())
    n = 0
    for slice_idx, off, size in _slices(data):
        if size < 32:
            continue
        mag = struct.unpack_from("<I", data, off)[0]
        be = False
        if mag == MH_CIGAM_64:
            be = True
        elif mag != MH_MAGIC_64:
            if struct.unpack_from(">I", data, off)[0] == MH_MAGIC_64:
                be = True
            else:
                continue
        end = ">" if be else "<"
        ncmds = struct.unpack_from(end + "I", data, off + 16)[0]
        lc = off + 32
        for _ in range(ncmds):
            if lc + 8 > off + size:
                break
            cmd = struct.unpack_from(end + "I", data, lc)[0]
            cmdsize = struct.unpack_from(end + "I", data, lc + 4)[0]
            if cmdsize == 0:
                break
            if cmd in _MIN_CMDS and cmdsize >= 16:
                old = struct.unpack_from(end + "I", data, lc + 12)[0]
                new = _sdk_for(seed, path, slice_idx, old)
                if new != old:
                    struct.pack_into(end + "I", data, lc + 12, new)
                    n += 1
            elif cmd == LC_BUILD_VERSION and cmdsize >= 24:
                # platform@8, minos@12, sdk@16
                old = struct.unpack_from(end + "I", data, lc + 16)[0]
                new = _sdk_for(seed, path, slice_idx, old)
                if new != old:
                    struct.pack_into(end + "I", data, lc + 16, new)
                    n += 1
            lc += cmdsize
    if n:
        with open(path, "wb") as f:
            f.write(data)
    return n


def main(argv: list[str]) -> int:
    seed = "sdkver"
    args = argv[1:]
    if args and args[0] == "--seed":
        seed = args[1]
        args = args[2:]
    if not args:
        print("usage: rewrite_macho_sdk_versions.py [--seed S] <binary>...",
              file=sys.stderr)
        return 2
    total = 0
    for p in args:
        try:
            c = rewrite(p, seed)
        except Exception as e:
            print(f"{p}: 跳过 ({e})")
            continue
        total += c
        if c:
            print(f"{p}: {c}")
    print(f"TOTAL LC sdk-version fields rewritten: {total}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
