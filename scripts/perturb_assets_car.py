#!/usr/bin/env python3
"""用 seed 填充 Assets.car 文件末尾的零填充区（长度不变）。

BOM/CAR 解析按内部偏移读有效载荷，尾部对齐零区通常不被读取。
就地改字节、不改文件大小；改完须重签名。

用法:
    perturb_assets_car.py [--seed S] <app_dir>
"""
from __future__ import annotations

import hashlib
import os
import sys


def _fill(data: bytearray, seed: str, path: str) -> int:
    if len(data) < 64 or not data.startswith(b"BOMStore"):
        return 0
    end = len(data)
    i = end
    while i > 0 and data[i - 1] == 0:
        i -= 1
    # 至少保留 16 字节尾零，避免贴到有效区
    pad_start = i
    pad_len = end - pad_start
    if pad_len < 64:
        return 0
    usable = pad_len - 16
    h = hashlib.sha1(f"{seed}|assets.car|{path}|{usable}".encode("utf-8")).digest()
    out = bytearray()
    while len(out) < usable:
        h = hashlib.sha1(h + bytes([len(out) & 0xFF])).digest()
        out.extend(h)
    data[pad_start : pad_start + usable] = out[:usable]
    # 末 16 字节保持 0
    return usable


def perturb(app_dir: str, seed: str) -> int:
    n = 0
    for root, _dirs, files in os.walk(app_dir):
        for fn in files:
            if fn != "Assets.car":
                continue
            path = os.path.join(root, fn)
            with open(path, "rb") as f:
                raw = bytearray(f.read())
            c = _fill(raw, seed, path)
            if c:
                with open(path, "wb") as f:
                    f.write(raw)
                n += 1
                print(f"{path}: filled {c} trailing pad bytes")
    return n


def main(argv: list[str]) -> int:
    seed = "assets-car"
    args = argv[1:]
    if args and args[0] == "--seed":
        seed = args[1]
        args = args[2:]
    if len(args) != 1:
        print("usage: perturb_assets_car.py [--seed S] <app_dir>", file=sys.stderr)
        return 2
    c = perturb(args[0], seed)
    print(f"TOTAL Assets.car perturbed: {c}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
