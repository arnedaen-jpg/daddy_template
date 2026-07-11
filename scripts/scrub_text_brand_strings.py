#!/usr/bin/env python3
"""等长擦除文本资源中的 SDK 品牌字样（HTML/TXT/JSON 等）。

不碰 Mach-O。用于隐私政策等资源里的 RongCloud / rongcloud.cn / 融云。
"""
from __future__ import annotations

import hashlib
import os
import sys

EXTS = {".html", ".htm", ".txt", ".md", ".json", ".xml", ".css", ".js"}
# 长串优先；等长替换。不碰 Mach-O / Flutter channel。
BRANDS = [
    "www.rongcloud.cn",
    "rongcloud.cn",
    "rongcloud.com",
    "RongCloud IM/RTC SDK",
    "RongCloud",
    "融云",
]


def _ren_bytes(s: str, seed: str) -> bytes:
    raw = s.encode("utf-8")
    h = hashlib.sha1((seed + "|" + s).encode("utf-8")).digest()
    charset = b"abcdefghijklmnopqrstuvwxyz"
    return bytes(charset[h[i % len(h)] % len(charset)] for i in range(len(raw)))


def scrub(app: str, seed: str) -> int:
    reps = [(b.encode("utf-8"), _ren_bytes(b, seed)) for b in BRANDS]
    reps.sort(key=lambda x: len(x[0]), reverse=True)
    file_count = 0
    hit_count = 0
    for root, _dirs, files in os.walk(app):
        for fn in files:
            ext = os.path.splitext(fn)[1].lower()
            if ext not in EXTS:
                continue
            path = os.path.join(root, fn)
            try:
                with open(path, "rb") as f:
                    data = f.read()
            except OSError:
                continue
            if not any(old in data for old, _ in reps):
                continue
            orig = data
            for old, new in reps:
                if len(old) != len(new):
                    continue
                n = data.count(old)
                if n:
                    data = data.replace(old, new)
                    hit_count += n
            if data != orig:
                with open(path, "wb") as f:
                    f.write(data)
                file_count += 1
    print("TOTAL text-brand scrubbed: files=%d hits=%d" % (file_count, hit_count))
    return hit_count


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print("usage: scrub_text_brand_strings.py <app_dir> <seed>", file=sys.stderr)
        return 2
    scrub(argv[1], argv[2])
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
