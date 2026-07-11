#!/usr/bin/env python3
"""等长重命名 app 内 RCConfig.plist，并同步 Mach-O __cstring 中的同名引用。

融云 SDK 通过 bundle 路径加载该配置；文件名与二进制字面量必须一起改且等长。

用法:
    rename_rcconfig_plist.py --seed S <app_dir>
"""
from __future__ import annotations

import hashlib
import os
import struct
import sys

OLD_NAME = "RCConfig.plist"
LC_SEGMENT_64 = 0x19
CSTRING_SECTS = {b"__cstring", b"__oslogstring"}


def _rename_same_length(name: str, seed: str) -> str:
    h = hashlib.sha1(f"{seed}|{name}".encode()).digest()
    charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    out = []
    hi = 0
    for ch in name:
        if ch.isalnum() or ch == "_":
            out.append(charset[h[hi % len(h)] % len(charset)])
            hi += 1
        else:
            out.append(ch)  # 保留 '.' 等
    return "".join(out)


def _slices(data: bytes):
    magic = struct.unpack_from(">I", data, 0)[0]
    if magic == 0xCAFEBABE:
        narch = struct.unpack_from(">I", data, 4)[0]
        out = []
        for i in range(narch):
            _c, _s, off, size, _a = struct.unpack_from(">IIIII", data, 8 + i * 20)
            out.append((off, size))
        return out
    return [(0, len(data))]


def _cstring_ranges(slice_data: bytes):
    if isinstance(slice_data, bytearray):
        slice_data = bytes(slice_data)
    if len(slice_data) < 32 or struct.unpack_from("<I", slice_data, 0)[0] != 0xFEEDFACF:
        return []
    ncmds = struct.unpack_from("<I", slice_data, 16)[0]
    off = 32
    ranges = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", slice_data, off)
        if cmdsize == 0:
            break
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from("<I", slice_data, off + 64)[0]
            so = off + 72
            for _s in range(nsects):
                sn = bytes(slice_data[so : so + 16].split(b"\0", 1)[0])
                if sn in CSTRING_SECTS:
                    ssize = struct.unpack_from("<Q", slice_data, so + 40)[0]
                    soff = struct.unpack_from("<I", slice_data, so + 48)[0]
                    if ssize:
                        ranges.append((soff, ssize))
                so += 80
        off += cmdsize
    return ranges


def _patch_macho(path: str, old: bytes, new: bytes) -> int:
    if len(old) != len(new):
        return 0
    with open(path, "rb") as f:
        data = bytearray(f.read())
    n = 0
    for slice_off, slice_size in _slices(data):
        slice_bytes = data[slice_off : slice_off + slice_size]
        for soff, ssize in _cstring_ranges(slice_bytes):
            abs_off = slice_off + soff
            blob = data[abs_off : abs_off + ssize]
            # 完整 NUL 结尾字面量
            start = 0
            while True:
                i = blob.find(old, start)
                if i < 0:
                    break
                end = i + len(old)
                prev = blob[i - 1] if i > 0 else 0
                nxt = blob[end] if end < len(blob) else 0
                if (i == 0 or prev == 0) and (end >= len(blob) or nxt == 0):
                    data[abs_off + i : abs_off + end] = new
                    n += 1
                start = end
    if n:
        with open(path, "wb") as f:
            f.write(data)
    return n


def process(app_dir: str, seed: str) -> tuple[int, int]:
    new_name = _rename_same_length(OLD_NAME, seed)
    if new_name == OLD_NAME:
        new_name = "X" + _rename_same_length(OLD_NAME[1:], seed)
        if len(new_name) != len(OLD_NAME):
            new_name = _rename_same_length(OLD_NAME, seed + "|x")

    # 可能存在多份（app 根 + framework 内嵌）
    targets = []
    for root, _dirs, files in os.walk(app_dir):
        if OLD_NAME in files:
            targets.append(os.path.join(root, OLD_NAME))
    if not targets:
        return 0, 0

    file_renamed = 0
    for old_path in targets:
        new_path = os.path.join(os.path.dirname(old_path), new_name)
        if os.path.abspath(old_path) != os.path.abspath(new_path):
            os.rename(old_path, new_path)
            file_renamed += 1

    old_b = OLD_NAME.encode()
    new_b = new_name.encode()
    assert len(old_b) == len(new_b)
    patched = 0
    for root, _dirs, files in os.walk(app_dir):
        for fn in files:
            path = os.path.join(root, fn)
            try:
                with open(path, "rb") as f:
                    head = f.read(4)
            except OSError:
                continue
            if head not in (
                b"\xca\xfe\xba\xbe",
                b"\xcf\xfa\xed\xfe",
                b"\xce\xfa\xed\xfe",
                b"\xfe\xed\xfa\xce",
                b"\xfe\xed\xfa\xcf",
            ):
                continue
            patched += _patch_macho(path, old_b, new_b)
    return file_renamed, patched


def main(argv: list[str]) -> int:
    seed = "rcconfig"
    args = argv[1:]
    if args and args[0] == "--seed":
        seed = args[1]
        args = args[2:]
    if not args:
        print("usage: rename_rcconfig_plist.py --seed S <app_dir>", file=sys.stderr)
        return 2
    fr, pr = process(args[0], seed)
    print(f"TOTAL RCConfig rename: files={fr} cstring_patches={pr} -> {_rename_same_length(OLD_NAME, seed)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
