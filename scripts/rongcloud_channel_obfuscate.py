#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""融云 Flutter MethodChannel / engine* 线协议字面量 — 编译期双边混淆。

对 Dart + ObjC(+ Android) 同步改写，保证 AOT 与原生字面量一致。
禁止只改 IPA 层（会破坏 Dart string switch）。

用法:
  python3 rongcloud_channel_obfuscate.py apply  --plugin <dir> --seed <seed> [--map-out m.json]
  python3 rongcloud_channel_obfuscate.py verify --plugin <dir> [--map m.json]
  python3 rongcloud_channel_obfuscate.py restore --plugin <dir> --map m.json
  python3 rongcloud_channel_obfuscate.py scan   --plugin <dir>
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path
from typing import Dict, Iterable, List, Set, Tuple

CHANNEL_CANON = "cn.rongcloud.im.flutter/RCIMIWEngine"
WIRE_RE = re.compile(
    r"cn\.rongcloud\.im\.flutter/[A-Za-z0-9_]+|"
    r"engine_cb:[A-Za-z0-9_]+|"
    r"engine:[A-Za-z0-9_]+"
)
FC_RE = re.compile(
    r"String\.fromCharCodes\(\[([0-9,\s]+)\]\)(\s*/\*[^*]*\*/)?"
)
OCT_CHUNK_RE = re.compile(r"(?:\\[0-7]{3})+")
MARKER = ".zt_rc_channel_map.json"

TEXT_SUFFIXES = {".dart", ".m", ".mm", ".h", ".java", ".kt", ".swift"}


def _tok(seed: str, key: str, n: int) -> str:
    h = hashlib.sha256(("%s|%s" % (seed, key)).encode("utf-8")).hexdigest()
    # 仅用 [a-z0-9]，避免 ObjC/Dart 字面量转义问题
    return h[:n]


def map_wire(seed: str, old: str) -> str:
    if old.startswith("engine_cb:"):
        return "ecb:" + _tok(seed, old, 18)
    if old.startswith("engine:"):
        return "eg:" + _tok(seed, old, 16)
    if old.startswith("cn.rongcloud."):
        return "%s.%s/%s" % (_tok(seed, "ch", 8), _tok(seed, "dom", 6), _tok(seed, "eng", 10))
    return "k" + _tok(seed, old, 15)


def to_octal(s: str) -> str:
    return "".join("\\%03o" % ord(c) for c in s)


def decode_octal_fragment(s: str) -> str:
    out = []
    i = 0
    while i < len(s):
        if s[i] == "\\" and i + 3 < len(s) and all(c in "01234567" for c in s[i + 1:i + 4]):
            out.append(chr(int(s[i + 1:i + 4], 8)))
            i += 4
        else:
            out.append(s[i])
            i += 1
    return "".join(out)


def decode_from_char_codes(nums: str) -> str:
    return "".join(chr(int(x)) for x in re.findall(r"\d+", nums))


def encode_from_char_codes(s: str) -> str:
    body = ", ".join(str(ord(c)) for c in s)
    return "String.fromCharCodes([%s]) /* %s */" % (body, s)


def iter_text_files(plugin: Path) -> Iterable[Path]:
    for p in plugin.rglob("*"):
        if not p.is_file():
            continue
        if p.suffix.lower() not in TEXT_SUFFIXES:
            continue
        # 跳过 vendored 二进制旁无关文本
        parts = {x.lower() for x in p.parts}
        if "xcframework" in parts or ".framework" in p.name:
            continue
        yield p


def collect_wires(plugin: Path) -> Set[str]:
    found: Set[str] = set()
    for path in iter_text_files(plugin):
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        found.update(WIRE_RE.findall(text))
        for m in FC_RE.finditer(text):
            decoded = decode_from_char_codes(m.group(1))
            found.update(WIRE_RE.findall(decoded))
            if WIRE_RE.fullmatch(decoded):
                found.add(decoded)
        for m in OCT_CHUNK_RE.finditer(text):
            decoded = decode_octal_fragment(m.group(0))
            found.update(WIRE_RE.findall(decoded))
            if WIRE_RE.fullmatch(decoded):
                found.add(decoded)
    # 始终纳入规范 channel（即使已被 fromCharCodes / 注释藏起）
    found.add(CHANNEL_CANON)
    return found


def build_mapping(seed: str, wires: Set[str]) -> Dict[str, str]:
    mapping: Dict[str, str] = {}
    for old in sorted(wires, key=len, reverse=True):
        # 已是混淆形态则跳过（ecb:/eg: 且无 RCIMIW/rongcloud）
        if old.startswith(("ecb:", "eg:")) and "RCIMIW" not in old and "rongcloud" not in old:
            continue
        if old.startswith("cn.") and "rongcloud" not in old:
            continue
        mapping[old] = map_wire(seed, old)
    return mapping


def apply_replacements_to_text(text: str, mapping: Dict[str, str], *, objc_octal: bool) -> Tuple[str, int]:
    if not mapping:
        return text, 0
    # 长键优先
    items = sorted(mapping.items(), key=lambda kv: len(kv[0]), reverse=True)
    n = 0
    out = text

    # 1) fromCharCodes：解码 → 替换 → 回写
    def _fc_sub(m: re.Match) -> str:
        nonlocal n
        decoded = decode_from_char_codes(m.group(1))
        new_decoded = decoded
        for old, new in items:
            if old in new_decoded:
                new_decoded = new_decoded.replace(old, new)
        if new_decoded != decoded:
            n += 1
            return encode_from_char_codes(new_decoded)
        return m.group(0)

    out2 = FC_RE.sub(_fc_sub, out)
    out = out2

    # 2) ObjC octal 整段
    if objc_octal:
        def _oct_sub(m: re.Match) -> str:
            nonlocal n
            raw = m.group(0)
            decoded = decode_octal_fragment(raw)
            new_decoded = decoded
            for old, new in items:
                if old in new_decoded:
                    new_decoded = new_decoded.replace(old, new)
            if new_decoded != decoded:
                n += 1
                return to_octal(new_decoded)
            return raw

        out = OCT_CHUNK_RE.sub(_oct_sub, out)

    # 3) 明文
    for old, new in items:
        if old in out:
            cnt = out.count(old)
            out = out.replace(old, new)
            n += cnt

    return out, n


def apply_to_plugin(plugin: Path, mapping: Dict[str, str]) -> Dict[str, int]:
    stats: Dict[str, int] = {}
    for path in iter_text_files(plugin):
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        objc = path.suffix.lower() in {".m", ".mm", ".h"}
        new_text, n = apply_replacements_to_text(text, mapping, objc_octal=objc)
        if n and new_text != text:
            path.write_text(new_text, encoding="utf-8")
            stats[str(path.relative_to(plugin))] = n
    return stats


def invert_mapping(mapping: Dict[str, str]) -> Dict[str, str]:
    inv = {v: k for k, v in mapping.items()}
    if len(inv) != len(mapping):
        raise SystemExit("映射非一一对应，拒绝 restore")
    return inv


def verify_parity(plugin: Path, mapping: Dict[str, str] | None = None) -> Tuple[bool, str]:
    dart_keys: Set[str] = set()
    objc_keys: Set[str] = set()
    java_keys: Set[str] = set()
    CHAN_RE = re.compile(
        r"(?:MethodChannel|methodChannelWithName|METHOD_CHANNEL)\s*"
        r"(?:\([^)]*?['\"]([a-z0-9./]+)['\"]|:@\"((?:\\[0-7]{3})+)\")"
    )
    CHAN_PLAIN = re.compile(r"['\"]([a-z0-9]{6,}\.[a-z0-9]{4,}/[a-z0-9]{6,})['\"]")

    def harvest(text: str, bucket: Set[str], objc: bool = False):
        bucket.update(WIRE_RE.findall(text))
        bucket.update(re.findall(r"ecb:[a-z0-9]+", text))
        bucket.update(re.findall(r"eg:[a-z0-9]+", text))
        bucket.update(CHAN_PLAIN.findall(text))
        for m in FC_RE.finditer(text):
            d = decode_from_char_codes(m.group(1))
            bucket.update(WIRE_RE.findall(d))
            bucket.update(re.findall(r"ecb:[a-z0-9]+", d))
            bucket.update(re.findall(r"eg:[a-z0-9]+", d))
            if re.fullmatch(r"[a-z0-9]+\.[a-z0-9]+/[a-z0-9]+", d):
                bucket.add(d)
        if objc:
            for m in OCT_CHUNK_RE.finditer(text):
                d = decode_octal_fragment(m.group(0))
                bucket.update(WIRE_RE.findall(d))
                bucket.update(re.findall(r"ecb:[a-z0-9]+", d))
                bucket.update(re.findall(r"eg:[a-z0-9]+", d))
                if re.fullmatch(r"[a-z0-9]+\.[a-z0-9]+/[a-z0-9]+", d):
                    bucket.add(d)

    for path in iter_text_files(plugin):
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        rel = str(path).replace("\\", "/")
        if "/lib/" in rel and path.suffix == ".dart":
            harvest(text, dart_keys, False)
        elif path.suffix.lower() in {".m", ".mm"}:
            harvest(text, objc_keys, True)
        elif path.suffix == ".java":
            harvest(text, java_keys, False)

    # 线协议明文指纹（不含 Android Java package cn.rongcloud.im.wrapper.*）
    fingerprints = (
        "cn.rongcloud.im.flutter/",
        "engine_cb:RCIMIW",
        "engine_cb:IRCIMIW",
        "engine:create",
        "engine:connect",
        "engine:destroy",
    )
    leftover = []
    for path in iter_text_files(plugin):
        if path.suffix.lower() not in {".dart", ".m", ".mm", ".java"}:
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        check = text
        if path.suffix.lower() in {".m", ".mm"}:
            for m in OCT_CHUNK_RE.finditer(text):
                check += "\n" + decode_octal_fragment(m.group(0))
        for m in FC_RE.finditer(text):
            check += "\n" + decode_from_char_codes(m.group(1))
        for fp in fingerprints:
            if fp in check:
                leftover.append("%s contains %s" % (path.name, fp))
                break

    def proto(ks: Set[str]) -> Set[str]:
        out = set()
        for k in ks:
            if k.startswith(("engine_cb:", "engine:", "ecb:", "eg:", "cn.rongcloud.")):
                out.add(k)
            elif re.fullmatch(r"[a-z0-9]{6,}\.[a-z0-9]{4,}/[a-z0-9]{6,}", k):
                out.add(k)
        return out

    d, o, j = proto(dart_keys), proto(objc_keys), proto(java_keys)
    # ObjC/Java 发出的键必须被 Dart 处理；Dart 可多出 IRCIMIW 兼容 case
    only_o = sorted(o - d)[:12]
    only_j = sorted(j - d)[:12]
    # channel 必须三端一致
    ch_d = {k for k in d if "/" in k and not k.startswith(("ecb:", "eg:", "engine"))}
    ch_o = {k for k in o if "/" in k and not k.startswith(("ecb:", "eg:", "engine"))}
    ch_j = {k for k in j if "/" in k and not k.startswith(("ecb:", "eg:", "engine"))}
    channel_mismatch = (ch_d != ch_o) or (ch_d and ch_j and ch_d != ch_j)

    ok = not leftover and not only_o and not only_j and not channel_mismatch
    msg = (
        "dart=%d objc=%d java=%d leftover=%d objc_not_in_dart=%s channel_d=%s channel_o=%s"
        % (len(d), len(o), len(j), len(leftover), only_o, sorted(ch_d), sorted(ch_o))
    )
    if leftover:
        msg += " | " + "; ".join(leftover[:8])
    if channel_mismatch:
        msg += " | channel_mismatch"
    if mapping:
        # 映射中的 ObjC 实际使用键（RCIMIW 非 IRCIMIW）应出现在 dart
        mapped_vals = set(mapping.values())
        # 至少 channel + 所有 eg:（engine:）应在 dart
        need = {v for v in mapped_vals if v.startswith("eg:") or "/" in v}
        missing = sorted(need - d)[:8]
        if missing:
            ok = False
            msg += " | dart_missing_mapped=%s" % missing
    return ok, msg


def find_default_plugin(root: Path) -> Path | None:
    cand = root / "plugins" / "remote_field_pentagon"
    if (cand / "ios" / "Classes" / "RCIMWrapperEngine.m").exists():
        return cand
    for p in (root / "plugins").glob("*"):
        if (p / "ios" / "Classes" / "RCIMWrapperEngine.m").exists():
            return p
    return None


def cmd_scan(plugin: Path) -> int:
    wires = collect_wires(plugin)
    print("plugin=%s" % plugin)
    print("wire_keys=%d" % len(wires))
    for w in sorted(wires)[:20]:
        print("  ", w)
    if len(wires) > 20:
        print("  ...")
    return 0


def cmd_apply(plugin: Path, seed: str, map_out: Path | None) -> int:
    wires = collect_wires(plugin)
    # 若已混淆（无明文 channel / engine_cb:RC*），提示
    plain = [w for w in wires if "rongcloud" in w or w.startswith("engine_cb:") or w.startswith("engine:")]
    if not plain:
        print("已无明文融云 wire 键，跳过 apply（可先 restore）")
        return 0
    mapping = build_mapping(seed, set(plain))
    print("seed=%s  mapping=%d" % (seed, len(mapping)))
    stats = apply_to_plugin(plugin, mapping)
    for rel, n in sorted(stats.items(), key=lambda x: -x[1])[:15]:
        print("  rewrite %s (%d)" % (rel, n))
    print("files_touched=%d" % len(stats))

    payload = {
        "seed": seed,
        "plugin": str(plugin),
        "mapping": mapping,
        "count": len(mapping),
    }
    out = map_out or (plugin / MARKER)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    # 插件内也留一份，便于 verify/restore
    (plugin / MARKER).write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print("map_out=%s" % out)

    ok, msg = verify_parity(plugin, mapping)
    print("verify: %s (%s)" % ("OK" if ok else "FAIL", msg))
    return 0 if ok else 2


def cmd_restore(plugin: Path, map_path: Path) -> int:
    data = json.loads(map_path.read_text(encoding="utf-8"))
    mapping = data.get("mapping") or {}
    inv = invert_mapping(mapping)
    print("restore mapping=%d from %s" % (len(inv), map_path))
    stats = apply_to_plugin(plugin, inv)
    print("files_touched=%d" % len(stats))
    marker = plugin / MARKER
    if marker.exists():
        marker.unlink()
    return 0


def cmd_verify(plugin: Path, map_path: Path | None) -> int:
    mapping = None
    mp = map_path or (plugin / MARKER)
    if mp.exists():
        mapping = json.loads(mp.read_text(encoding="utf-8")).get("mapping")
    ok, msg = verify_parity(plugin, mapping)
    print("verify: %s (%s)" % ("OK" if ok else "FAIL", msg))
    return 0 if ok else 2


def main(argv: List[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="RongCloud Flutter channel / engine_* obfuscator")
    ap.add_argument("mode", choices=["scan", "apply", "verify", "restore"])
    ap.add_argument("--plugin", default="", help="plugins/remote_field_pentagon 路径")
    ap.add_argument("--seed", default="", help="稳定 seed（建议 Bundle ID）")
    ap.add_argument("--map-out", default="", help="apply 时写出映射 JSON")
    ap.add_argument("--map", default="", help="verify/restore 使用的映射 JSON")
    ap.add_argument("--project-root", default="", help="未指定 --plugin 时在此查找")
    args = ap.parse_args(argv)

    plugin = Path(args.plugin) if args.plugin else None
    if plugin is None or not str(plugin):
        root = Path(args.project_root or os.getcwd())
        plugin = find_default_plugin(root)
    if plugin is None or not plugin.is_dir():
        print("错误: 找不到融云插件目录（含 ios/Classes/RCIMWrapperEngine.m）", file=sys.stderr)
        return 2
    plugin = plugin.resolve()

    if args.mode == "scan":
        return cmd_scan(plugin)
    if args.mode == "apply":
        if not args.seed:
            print("错误: apply 需要 --seed", file=sys.stderr)
            return 2
        map_out = Path(args.map_out) if args.map_out else None
        return cmd_apply(plugin, args.seed, map_out)
    if args.mode == "restore":
        mp = Path(args.map) if args.map else (plugin / MARKER)
        if not mp.exists():
            print("错误: 找不到映射文件", file=sys.stderr)
            return 2
        return cmd_restore(plugin, mp)
    if args.mode == "verify":
        mp = Path(args.map) if args.map else None
        return cmd_verify(plugin, mp)
    return 2


if __name__ == "__main__":
    sys.exit(main())
