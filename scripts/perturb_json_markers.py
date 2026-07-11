#!/usr/bin/env python3
"""给安全 JSON 资源写入 seed 标记键（未知键通常被忽略）。

处理：
  1) NativeAssetsManifest.json：写入 "zt"
  2) Lottie 类 JSON（含 layers/assets/v）：写入顶层 "zt"
  不碰 question*_zh.json / 域名 b64 / FontManifest / AssetManifest

用法:
    perturb_json_markers.py [--seed S] <app_dir>
"""
from __future__ import annotations

import hashlib
import json
import os
import sys


def _stamp(seed: str, path: str) -> str:
    return hashlib.sha1(f"{seed}|json|{path}".encode("utf-8")).hexdigest()[:24]


def _is_lottie(obj: object) -> bool:
    if not isinstance(obj, dict):
        return False
    keys = set(obj.keys())
    return ("layers" in keys and "v" in keys) or (
        "assets" in keys and "markers" in keys and "fr" in keys
    )


def _is_native_assets(obj: object) -> bool:
    return isinstance(obj, dict) and "native-assets" in obj and "format-version" in obj


def _should_skip(path: str) -> bool:
    base = os.path.basename(path).lower()
    if base in {"fontmanifest.json", "assetmanifest.json", "assetmanifest.bin"}:
        return True
    if "question" in base and base.endswith(".json"):
        return True
    if base.endswith(".b64"):
        return True
    return False


def perturb(app_dir: str, seed: str) -> int:
    n = 0
    for root, _dirs, files in os.walk(app_dir):
        for fn in files:
            if not fn.lower().endswith(".json"):
                continue
            path = os.path.join(root, fn)
            if _should_skip(path):
                continue
            try:
                with open(path, "rb") as f:
                    raw = f.read()
                obj = json.loads(raw.decode("utf-8"))
            except Exception:
                continue
            if not (_is_native_assets(obj) or _is_lottie(obj)):
                continue
            stamp = _stamp(seed, path)
            if isinstance(obj, dict) and obj.get("zt") == stamp:
                continue
            if isinstance(obj, dict):
                obj["zt"] = stamp
            else:
                continue
            out = (json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
            # Lottie 原文件多为 pretty；为降风险保持可读：indent=2（哈希仍变）
            if b"\n  " in raw or b"\n\t" in raw:
                out = (json.dumps(obj, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
            with open(path, "wb") as f:
                f.write(out)
            n += 1
    return n


def main(argv: list[str]) -> int:
    seed = "json"
    args = argv[1:]
    if args and args[0] == "--seed":
        seed = args[1]
        args = args[2:]
    if len(args) != 1:
        print("usage: perturb_json_markers.py [--seed S] <app_dir>", file=sys.stderr)
        return 2
    c = perturb(args[0], seed)
    print(f"TOTAL json markers perturbed: {c}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
