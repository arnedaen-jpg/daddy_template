#!/usr/bin/env python3
"""确定性改写包内 gzip 头（mtime / OS），不改压缩载荷。

典型目标：flutter_assets/NOTICES.Z（1f 8b 08 …）。
解压结果不变，仅文件哈希/指纹变化；改完须重签名。

用法:
    perturb_gzip_headers.py [--seed S] <app_dir>
"""
from __future__ import annotations

import hashlib
import os
import struct
import sys


def _patch_gz(data: bytearray, seed: str, path: str) -> bool:
    if len(data) < 10 or data[0:3] != b"\x1f\x8b\x08":
        return False
    h = hashlib.sha1(f"{seed}|gzip|{path}".encode("utf-8")).digest()
    mtime = struct.unpack_from("<I", h, 0)[0]
    if mtime == 0:
        mtime = 1
    os_id = h[4]  # 0..255；常见 0xff/0x03 等
    old = bytes(data[4:10])
    struct.pack_into("<I", data, 4, mtime)
    data[8] = data[8]  # xfl 不动
    data[9] = os_id
    return bytes(data[4:10]) != old


def perturb(app_dir: str, seed: str) -> int:
    n = 0
    for root, _dirs, files in os.walk(app_dir):
        for fn in files:
            path = os.path.join(root, fn)
            # 常见 gzip 资源；也扫 .gz
            if not (fn.endswith(".Z") or fn.endswith(".gz") or fn == "NOTICES.Z"):
                continue
            try:
                with open(path, "rb") as f:
                    raw = bytearray(f.read())
            except OSError:
                continue
            if _patch_gz(raw, seed, path):
                with open(path, "wb") as f:
                    f.write(raw)
                n += 1
                print(f"{path}: gzip header patched")
    return n


def main(argv: list[str]) -> int:
    seed = "gzip"
    args = argv[1:]
    if args and args[0] == "--seed":
        seed = args[1]
        args = args[2:]
    if len(args) != 1:
        print("usage: perturb_gzip_headers.py [--seed S] <app_dir>", file=sys.stderr)
        return 2
    c = perturb(args[0], seed)
    print(f"TOTAL gzip headers perturbed: {c}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
