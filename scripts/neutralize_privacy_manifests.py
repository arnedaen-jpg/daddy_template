#!/usr/bin/env python3
"""确定性重排 PrivacyInfo.xcprivacy 字典键序（内容不变，文件哈希变）。

不增删隐私声明项，仅按 seed 置换键顺序后写回 XML plist。
改完须重签名。

用法:
    neutralize_privacy_manifests.py [--seed S] <app_dir>
"""
from __future__ import annotations

import hashlib
import os
import plistlib
import sys


def _permute(obj, seed: str, path: str):
    if isinstance(obj, dict):
        keys = list(obj.keys())
        # 稳定置换：按 seed|path|key 排序
        keys.sort(key=lambda k: hashlib.sha1(
            f"{seed}|priv|{path}|{k}".encode("utf-8")).hexdigest())
        return {k: _permute(obj[k], seed, path) for k in keys}
    if isinstance(obj, list):
        return [_permute(x, seed, path) for x in obj]
    return obj


def neutralize(app_dir: str, seed: str) -> int:
    n = 0
    for root, _dirs, files in os.walk(app_dir):
        for fn in files:
            if fn != "PrivacyInfo.xcprivacy" and not fn.endswith(".xcprivacy"):
                continue
            path = os.path.join(root, fn)
            try:
                with open(path, "rb") as f:
                    raw = f.read()
                    data = plistlib.loads(raw)
            except Exception:
                continue
            new = _permute(data, seed, path)
            out = plistlib.dumps(new, fmt=plistlib.FMT_XML)
            if out != raw:
                with open(path, "wb") as f:
                    f.write(out)
                n += 1
    return n


def main(argv: list[str]) -> int:
    seed = "privacy"
    args = argv[1:]
    if args and args[0] == "--seed":
        seed = args[1]
        args = args[2:]
    if len(args) != 1:
        print("usage: neutralize_privacy_manifests.py [--seed S] <app_dir>",
              file=sys.stderr)
        return 2
    c = neutralize(args[0], seed)
    print(f"TOTAL privacy manifests reordered: {c}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
