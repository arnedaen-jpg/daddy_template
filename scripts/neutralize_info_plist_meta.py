#!/usr/bin/env python3
"""抹掉 Info.plist 中的 Xcode/SDK 构建元数据指纹。

删除（若存在）:
  BuildMachineOSBuild, DTCompiler, DTPlatformBuild, DTPlatformName,
  DTPlatformVersion, DTSDKBuild, DTSDKName, DTXcode, DTXcodeBuild

不影响业务键（Bundle ID / 版本 / 权限文案）。

用法:
    neutralize_info_plist_meta.py <app_or_dir>
"""
from __future__ import annotations

import os
import plistlib
import sys

DROP_KEYS = {
    "BuildMachineOSBuild",
    "DTCompiler",
    "DTPlatformBuild",
    "DTPlatformName",
    "DTPlatformVersion",
    "DTSDKBuild",
    "DTSDKName",
    "DTXcode",
    "DTXcodeBuild",
    # 融云 SDK 自定义指纹键
    "RCVersion",
    "RCCommitId",
}


def patch_plist(path: str) -> int:
    try:
        with open(path, "rb") as f:
            pl = plistlib.load(f)
    except Exception:
        return 0
    if not isinstance(pl, dict):
        return 0
    n = 0
    for k in list(pl.keys()):
        if k in DROP_KEYS:
            del pl[k]
            n += 1
    if n:
        with open(path, "wb") as f:
            plistlib.dump(pl, f, sort_keys=False)
    return n


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: neutralize_info_plist_meta.py <app_or_dir>", file=sys.stderr)
        return 2
    root = argv[1]
    total = 0
    files = 0
    for dirpath, _dirs, filenames in os.walk(root):
        for fn in filenames:
            if fn != "Info.plist":
                continue
            path = os.path.join(dirpath, fn)
            c = patch_plist(path)
            if c:
                files += 1
                total += c
    print(f"TOTAL Info.plist meta keys removed: {total} (files={files})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
