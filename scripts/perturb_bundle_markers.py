#!/usr/bin/env python3
"""包内轻量标记扰动（不改业务逻辑）。

处理：
  1) PkgInfo：保留 APPL，后 4 字节改为 seed 创造者码
  2) 空 .gitkeep：写入 seed 行
  3) .html：在 </html> 前插入 <!-- zt:... --> 注释
  4) .js：末尾追加 // zt:... 注释

改完须重签名。

用法:
    perturb_bundle_markers.py [--seed S] <app_dir>
"""
from __future__ import annotations

import hashlib
import os
import re
import sys

_HTML_COMMENT_RE = re.compile(
    br"<!--\s*zt:[0-9a-f]{8,64}\s*-->\s*", re.IGNORECASE
)


def _hex(seed: str, tag: str, path: str, n: int = 16) -> str:
    return hashlib.sha1(f"{seed}|{tag}|{path}".encode("utf-8")).hexdigest()[:n]


def _creator(seed: str, path: str) -> bytes:
    h = hashlib.sha1(f"{seed}|pkginfo|{path}".encode("utf-8")).digest()
    alphabet = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    return bytes(alphabet[h[i] % 26] for i in range(4))


def _patch_pkginfo(path: str, seed: str) -> bool:
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError:
        return False
    if len(raw) != 8 or not raw.startswith(b"APPL"):
        return False
    new = b"APPL" + _creator(seed, path)
    if new == raw:
        return False
    with open(path, "wb") as f:
        f.write(new)
    return True


def _patch_gitkeep(path: str, seed: str) -> bool:
    try:
        st = os.stat(path)
    except OSError:
        return False
    if st.st_size > 64:
        return False
    line = f"zt:{_hex(seed, 'gitkeep', path, 24)}\n".encode("ascii")
    try:
        with open(path, "rb") as f:
            old = f.read()
    except OSError:
        return False
    if old == line:
        return False
    with open(path, "wb") as f:
        f.write(line)
    return True


def _patch_html(path: str, seed: str) -> bool:
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError:
        return False
    if b"<html" not in raw.lower() and b"<!doctype" not in raw.lower():
        return False
    mark = f"<!-- zt:{_hex(seed, 'html', path, 32)} -->".encode("ascii")
    body = _HTML_COMMENT_RE.sub(b"", raw)
    low = body.lower()
    idx = low.rfind(b"</html>")
    if idx >= 0:
        out = body[:idx] + mark + b"\n" + body[idx:]
    else:
        out = body + b"\n" + mark + b"\n"
    if out == raw:
        return False
    with open(path, "wb") as f:
        f.write(out)
    return True


def _patch_js(path: str, seed: str) -> bool:
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError:
        return False
    # 跳过明显二进制
    if b"\0" in raw[:64]:
        return False
    mark = f"\n// zt:{_hex(seed, 'js', path, 24)}\n".encode("ascii")
    if mark.strip() in raw:
        # 已有同 tag 则替换整行
        raw2 = re.sub(br"\n// zt:[0-9a-f]{8,64}\n", mark, raw)
        if raw2 == raw:
            return False
        out = raw2
    else:
        out = raw + mark
    with open(path, "wb") as f:
        f.write(out)
    return True


def perturb(app_dir: str, seed: str) -> dict[str, int]:
    counts = {"pkginfo": 0, "gitkeep": 0, "html": 0, "js": 0}
    pkg = os.path.join(app_dir, "PkgInfo")
    if os.path.isfile(pkg) and _patch_pkginfo(pkg, seed):
        counts["pkginfo"] += 1
    for root, _dirs, files in os.walk(app_dir):
        for fn in files:
            path = os.path.join(root, fn)
            low = fn.lower()
            if low == ".gitkeep" or low.endswith(".gitkeep"):
                if _patch_gitkeep(path, seed):
                    counts["gitkeep"] += 1
            elif low.endswith(".html") or low.endswith(".htm"):
                if _patch_html(path, seed):
                    counts["html"] += 1
            elif low.endswith(".js"):
                if _patch_js(path, seed):
                    counts["js"] += 1
    return counts


def main(argv: list[str]) -> int:
    seed = "markers"
    args = argv[1:]
    if args and args[0] == "--seed":
        seed = args[1]
        args = args[2:]
    if len(args) != 1:
        print("usage: perturb_bundle_markers.py [--seed S] <app_dir>",
              file=sys.stderr)
        return 2
    c = perturb(args[0], seed)
    total = sum(c.values())
    print(f"TOTAL bundle markers perturbed: {total} "
          f"(pkginfo={c['pkginfo']} gitkeep={c['gitkeep']} "
          f"html={c['html']} js={c['js']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
