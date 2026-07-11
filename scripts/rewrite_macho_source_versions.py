#!/usr/bin/env python3
"""确定性重写 Mach-O LC_SOURCE_VERSION（含 fat slice）。

用途：多数闭源 SDK 的 SOURCE_VERSION 为 0，机审侧可作为同构指纹。
就地改 8 字节版本号，不移动段偏移；改完须重签名。

编码：A.B.C.D.E → a24.b10.c10.d10.e10（Apple LC_SOURCE_VERSION）。
保留合理范围，避免全零。

用法:
    rewrite_macho_source_versions.py [--seed S] <binary> [<binary> ...]
"""
from __future__ import annotations

import hashlib
import struct
import sys

LC_SOURCE_VERSION = 0x2A
MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
FAT_MAGIC = 0xCAFEBABE


def _version_for(seed: str, path: str, slice_idx: int) -> int:
    h = hashlib.sha1(f"{seed}|srcver|{path}|{slice_idx}".encode("utf-8")).digest()
    # A: 1..2047, B..E: 0..1023
    a = 1 + (h[0] | (h[1] << 8)) % 2047
    b = h[2] | ((h[3] & 0x03) << 8)
    c = h[4] | ((h[5] & 0x03) << 8)
    d = h[6] | ((h[7] & 0x03) << 8)
    e = h[8] | ((h[9] & 0x03) << 8)
    return (a << 40) | (b << 30) | (c << 20) | (d << 10) | e


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
            if cmd == LC_SOURCE_VERSION and cmdsize >= 16:
                new_v = _version_for(seed, path, slice_idx)
                old = struct.unpack_from(end + "Q", data, lc + 8)[0]
                if old != new_v:
                    struct.pack_into(end + "Q", data, lc + 8, new_v)
                    n += 1
            lc += cmdsize
    if n:
        with open(path, "wb") as f:
            f.write(data)
    return n


def main(argv: list[str]) -> int:
    seed = "srcver"
    args = argv[1:]
    if args and args[0] == "--seed":
        seed = args[1]
        args = args[2:]
    if not args:
        print("usage: rewrite_macho_source_versions.py [--seed S] <binary>...",
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
    print(f"TOTAL LC_SOURCE_VERSION rewritten: {total}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
