#!/usr/bin/env python3
"""从 .app 内 framework 剥离运行时不需要的 Headers/Modules 目录。

减小包体与头文件指纹面；真机加载不依赖这些目录。

用法:
    strip_framework_headers.py <app_dir>
"""
from __future__ import annotations

import os
import shutil
import sys


def strip(app_dir: str) -> tuple[int, int]:
    fw_root = os.path.join(app_dir, "Frameworks")
    if not os.path.isdir(fw_root):
        return 0, 0
    removed_dirs = 0
    removed_bytes = 0
    for name in os.listdir(fw_root):
        if not name.endswith(".framework"):
            continue
        fw = os.path.join(fw_root, name)
        for sub in ("Headers", "PrivateHeaders", "Modules"):
            path = os.path.join(fw, sub)
            if not os.path.isdir(path):
                continue
            for dirpath, _dirs, files in os.walk(path):
                for fn in files:
                    try:
                        removed_bytes += os.path.getsize(os.path.join(dirpath, fn))
                    except OSError:
                        pass
            shutil.rmtree(path, ignore_errors=True)
            removed_dirs += 1
    return removed_dirs, removed_bytes


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: strip_framework_headers.py <app_dir>", file=sys.stderr)
        return 2
    d, b = strip(argv[1])
    print(f"TOTAL framework Headers/Modules stripped: dirs={d} bytes={b}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
