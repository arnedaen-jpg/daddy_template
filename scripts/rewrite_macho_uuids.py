#!/usr/bin/env python3
"""确定性重写 Mach-O LC_UUID（含 fat slice）。

用途：同一源码打出的 IPA 里 framework UUID 往往雷同，被机审/指纹碰撞。
就地改 16 字节 UUID，不移动任何段偏移；改完须重签名。

用法:
    rewrite_macho_uuids.py [--seed S] <binary> [<binary> ...]
"""
from __future__ import annotations

import hashlib
import struct
import sys

LC_UUID = 0x1B
MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
FAT_MAGIC = 0xCAFEBABE


def _uuid_for(seed: str, path: str, slice_idx: int) -> bytes:
    h = hashlib.sha1(f"{seed}|uuid|{path}|{slice_idx}".encode("utf-8")).digest()
    u = bytearray(h[:16])
    # RFC 4122 variant/version 位，避免全零
    u[6] = (u[6] & 0x0F) | 0x40  # version 4
    u[8] = (u[8] & 0x3F) | 0x80  # variant
    if u == b"\x00" * 16:
        u[0] = 1
    return bytes(u)


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
            mag = struct.unpack_from(">I", data, off)[0]
        if mag != MH_MAGIC_64 and struct.unpack_from(">I", data, off)[0] != MH_MAGIC_64:
            # also accept little-endian feedfacf already handled
            if struct.unpack_from("<I", data, off)[0] != MH_MAGIC_64:
                continue
        end = ">" if be else "<"
        ncmds = struct.unpack_from(end + "I", data, off + 16)[0]
        lc = off + (32 if (struct.unpack_from(end + "I", data, off)[0] == MH_MAGIC_64 or not be) else 32)
        # header size 32 for 64-bit
        lc = off + 32
        for _ in range(ncmds):
            if lc + 8 > off + size:
                break
            cmd = struct.unpack_from(end + "I", data, lc)[0]
            cmdsize = struct.unpack_from(end + "I", data, lc + 4)[0]
            if cmdsize == 0:
                break
            if cmd == LC_UUID and cmdsize >= 24:
                new_u = _uuid_for(seed, path, slice_idx)
                old = bytes(data[lc + 8 : lc + 24])
                if old != new_u:
                    data[lc + 8 : lc + 24] = new_u
                    n += 1
            lc += cmdsize
    if n:
        with open(path, "wb") as f:
            f.write(data)
    return n


def main(argv: list[str]) -> int:
    seed = "uuid"
    args = argv[1:]
    if args and args[0] == "--seed":
        seed = args[1]
        args = args[2:]
    if not args:
        print("usage: rewrite_macho_uuids.py [--seed S] <binary>...", file=sys.stderr)
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
    print(f"TOTAL LC_UUID rewritten: {total}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
