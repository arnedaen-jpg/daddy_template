#!/usr/bin/env python3
"""中和 .framework Info.plist 中的版本/构建号指纹。

对 Payload 内各 *.framework/Info.plist：
  - CFBundleShortVersionString / CFBundleVersion → seed 派生中性值
  - 可选：把 org.cocoapods.* Bundle ID 改成 com.<seed8>.<exec>

不改主应用 Runner.app/Info.plist（业务版本号保留）。

用法:
    neutralize_framework_plist_versions.py --seed S <app_dir>
"""
from __future__ import annotations

import hashlib
import os
import plistlib
import sys


def _ver(seed: str, name: str) -> str:
    h = hashlib.sha1(f"{seed}|fwver|{name}".encode()).hexdigest()
    major = 1 + (int(h[0:2], 16) % 9)
    minor = int(h[2:4], 16) % 20
    patch = int(h[4:6], 16) % 50
    return f"{major}.{minor}.{patch}"


def _build(seed: str, name: str) -> str:
    h = hashlib.sha1(f"{seed}|fwbuild|{name}".encode()).hexdigest()
    # 6–10 位数字，避免像 202604091646 这种日期戳
    n = int(h[:8], 16) % 90_000_000 + 10_000_000
    return str(n)


def _bid(seed: str, exec_name: str) -> str:
    h = hashlib.sha1(f"{seed}|fwbid|{exec_name}".encode()).hexdigest()
    return f"com.{h[:8]}.{exec_name}"


def patch_app(app_dir: str, seed: str, rewrite_cocoapods_bid: bool = True) -> tuple[int, int]:
    fw_root = os.path.join(app_dir, "Frameworks")
    if not os.path.isdir(fw_root):
        return 0, 0
    files = 0
    keys = 0
    for dirpath, _dirs, filenames in os.walk(fw_root):
        if "Info.plist" not in filenames:
            continue
        # 只处理 framework 或 privacy.bundle 内的 Info.plist
        base = os.path.basename(dirpath)
        if not (base.endswith(".framework") or base.endswith(".bundle")):
            continue
        plist_path = os.path.join(dirpath, "Info.plist")
        try:
            with open(plist_path, "rb") as f:
                pl = plistlib.load(f)
        except Exception:
            continue
        if not isinstance(pl, dict):
            continue
        exec_name = pl.get("CFBundleExecutable") or base.split(".")[0]
        changed = False
        new_ver = _ver(seed, str(exec_name))
        new_build = _build(seed, str(exec_name))
        if pl.get("CFBundleShortVersionString") != new_ver:
            pl["CFBundleShortVersionString"] = new_ver
            keys += 1
            changed = True
        if pl.get("CFBundleVersion") != new_build:
            pl["CFBundleVersion"] = new_build
            keys += 1
            changed = True
        bid = str(pl.get("CFBundleIdentifier") or "")
        if rewrite_cocoapods_bid and bid.startswith("org.cocoapods."):
            pl["CFBundleIdentifier"] = _bid(seed, str(exec_name).replace(" ", "_"))
            keys += 1
            changed = True
        if changed:
            with open(plist_path, "wb") as f:
                plistlib.dump(pl, f, sort_keys=False)
            files += 1
    return files, keys


def main(argv: list[str]) -> int:
    seed = "fw"
    args = argv[1:]
    if args and args[0] == "--seed":
        seed = args[1]
        args = args[2:]
    if not args:
        print("usage: neutralize_framework_plist_versions.py --seed S <app_dir>",
              file=sys.stderr)
        return 2
    files, keys = patch_app(args[0], seed)
    print(f"TOTAL framework Info.plist version-neutralized: files={files} keys={keys}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
