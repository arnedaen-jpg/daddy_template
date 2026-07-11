#!/usr/bin/env python3
"""用 seed 派生的统一时间戳重打包 IPA，抹掉各文件原始 mtime 指纹。

L280 增强：
  - 条目写入顺序按 seed 置换（改变中央目录布局）
  - 各条目 date_time 在 seed 基线上做确定性微扰（避免「全包同一秒」指纹）

注意（L281 回退）：
  - 不写 ZIP comment（CoreDevice/真机安装会失败）
  - 不用 ZIP_STORED（iOS 安装器对 IPA 内 STORE 条目不友好）
  - 统一 DEFLATE；压缩级别可按 seed 在 6–9 微变

用法:
    pack_ipa_seeded.py --seed S --out out.ipa <Payload目录的父目录>
"""
from __future__ import annotations

import hashlib
import os
import sys
import zipfile


def _date_tuple(seed: str) -> tuple[int, int, int, int, int, int]:
    h = hashlib.sha1(f"{seed}|zip-date".encode()).digest()
    year = 2024 + (h[0] % 3)
    month = 1 + (h[1] % 12)
    day = 1 + (h[2] % 28)
    hour = h[3] % 24
    minute = h[4] % 60
    second = h[5] % 60
    return (year, month, day, hour, minute, second)


def _date_for_entry(seed: str, arc: str) -> tuple[int, int, int, int, int, int]:
    base = _date_tuple(seed)
    h = hashlib.sha1(f"{seed}|zip-entry|{arc}".encode()).digest()
    year, month, day, hour, minute, _second = base
    hour = (hour + (h[0] % 3)) % 24
    minute = (minute + (h[1] % 17)) % 60
    second = h[2] % 60
    return (year, month, day, hour, minute, second)


def _entry_sort_key(seed: str, arc: str) -> str:
    return hashlib.sha1(f"{seed}|zip-order|{arc}".encode()).hexdigest()


def _compresslevel(seed: str, arc: str) -> int:
    h = hashlib.sha1(f"{seed}|zip-level|{arc}".encode()).digest()
    return 6 + (h[0] % 4)  # 6..9，避开过低压缩


def pack(root: str, out_ipa: str, seed: str) -> int:
    payload = os.path.join(root, "Payload")
    if not os.path.isdir(payload):
        raise SystemExit(f"no Payload/ under {root}")

    files: list[tuple[str, str]] = []
    dirs: list[str] = []
    for dirpath, _dirnames, filenames in os.walk(payload):
        for fn in filenames:
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            files.append((rel, full))
        if not filenames and not os.listdir(dirpath):
            rel = os.path.relpath(dirpath, root).replace(os.sep, "/") + "/"
            dirs.append(rel)

    files.sort(key=lambda x: _entry_sort_key(seed, x[0]))
    dirs.sort(key=lambda a: _entry_sort_key(seed, a))

    n = 0
    with zipfile.ZipFile(out_ipa, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        # 明确不写 comment：部分 CoreDevice 安装路径会失败
        zf.comment = b""
        for arc, full in files:
            with open(full, "rb") as f:
                data = f.read()
            info = zipfile.ZipInfo(arc, date_time=_date_for_entry(seed, arc))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            level = _compresslevel(seed, arc)
            zf.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED,
                        compresslevel=level)
            n += 1
        for rel in dirs:
            info = zipfile.ZipInfo(rel, date_time=_date_for_entry(seed, rel))
            info.external_attr = 0o755 << 16 | 0x10
            zf.writestr(info, b"")
            n += 1
    return n


def main(argv: list[str]) -> int:
    seed = "ipa"
    out = ""
    args = argv[1:]
    while args:
        if args[0] == "--seed":
            seed = args[1]
            args = args[2:]
        elif args[0] == "--out":
            out = args[1]
            args = args[2:]
        else:
            break
    if not out or not args:
        print("usage: pack_ipa_seeded.py --seed S --out out.ipa <work_dir_with_Payload>",
              file=sys.stderr)
        return 2
    n = pack(args[0], out, seed)
    print(f"PACKED entries={n} date={_date_tuple(seed)} -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
