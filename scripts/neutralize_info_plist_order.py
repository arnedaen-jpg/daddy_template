#!/usr/bin/env python3
"""扰动 Info.plist 字节指纹（取值语义不变）。

策略：
  1) 按 seed 确定性选择 binary / XML 写出格式
  2) 若不存在 CFBundleGetInfoString，则写入等长 seed 戳（仅展示元数据）

iOS / codesign 两种 plist 格式均接受。改完须重签名。

用法:
    neutralize_info_plist_order.py [--seed S] <app_dir>
"""
from __future__ import annotations

import hashlib
import os
import plistlib
import sys


def _stamp(seed: str, path: str) -> str:
    h = hashlib.sha1(f"{seed}|infostamp|{path}".encode("utf-8")).hexdigest()
    return h[:16]


def _permute_str_list(items: list, seed: str, path: str, tag: str) -> list:
    """确定性重排字符串数组（顺序无语义）。"""
    if not isinstance(items, list) or len(items) < 2:
        return items
    if not all(isinstance(x, str) for x in items):
        return items
    return sorted(
        items,
        key=lambda s: hashlib.sha1(
            f"{seed}|{tag}|{path}|{s}".encode("utf-8")).hexdigest(),
    )


def neutralize(app_dir: str, seed: str) -> int:
    n = 0
    for root, _dirs, files in os.walk(app_dir):
        for fn in files:
            if fn != "Info.plist":
                continue
            path = os.path.join(root, fn)
            try:
                with open(path, "rb") as f:
                    raw = f.read()
                    data = plistlib.loads(raw)
            except Exception:
                continue
            if not isinstance(data, dict):
                continue
            changed = False
            if "CFBundleGetInfoString" not in data:
                data["CFBundleGetInfoString"] = _stamp(seed, path)
                changed = True
            else:
                # 已有则等长替换，避免拉长/缩短其它逻辑假设
                old = str(data["CFBundleGetInfoString"])
                new = _stamp(seed, path)
                if len(new) == len(old) and new != old:
                    data["CFBundleGetInfoString"] = new
                    changed = True
                elif len(old) != 16:
                    # 非 16 位则改写为 16 位 seed 戳
                    data["CFBundleGetInfoString"] = new
                    changed = True
            # L279：CFBundleSignature 常为 ????，改为 seed 四字创造者码
            sig = str(data.get("CFBundleSignature", ""))
            if sig in ("", "????"):
                h = hashlib.sha1(f"{seed}|sig|{path}".encode("utf-8")).digest()
                alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                data["CFBundleSignature"] = "".join(alphabet[h[i] % 26] for i in range(4))
                changed = True
            # L281：重排无顺序语义的字符串数组
            for key, tag in (
                ("LSApplicationQueriesSchemes", "queries"),
                ("UIBackgroundModes", "bgmodes"),
                ("CFBundleSupportedPlatforms", "platforms"),
            ):
                if key in data and isinstance(data[key], list):
                    new_list = _permute_str_list(data[key], seed, path, tag)
                    if new_list != data[key]:
                        data[key] = new_list
                        changed = True
            h = hashlib.sha1(f"{seed}|plistfmt|{path}".encode("utf-8")).digest()
            fmt = plistlib.FMT_BINARY if (h[0] & 1) else plistlib.FMT_XML
            out = plistlib.dumps(data, fmt=fmt)
            if out != raw or changed:
                with open(path, "wb") as f:
                    f.write(out)
                n += 1
    return n


def main(argv: list[str]) -> int:
    seed = "plist-order"
    args = argv[1:]
    if args and args[0] == "--seed":
        seed = args[1]
        args = args[2:]
    if len(args) != 1:
        print("usage: neutralize_info_plist_order.py [--seed S] <app_dir>",
              file=sys.stderr)
        return 2
    c = neutralize(args[0], seed)
    print(f"TOTAL Info.plist fingerprint-neutralized: {c}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
