#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Mach-O 符号混淆器（成品包层，无需源码）。

面向 App Store 4.3(a)：直接改写已编译 Mach-O 的
`__TEXT,__objc_classname` / `__TEXT,__objc_methname` 里的 ObjC 类名/方法名字符串，
使两个包的二进制符号指纹不同。对第三方 framework / 静态库同样生效（它们的符号也在这些 section）。

安全策略（关键）：
- **就地等长改写**：只在原字符串的字节范围内改写，长度不变、NUL 结尾保留，
  因此不需要改 string table / load command / section 偏移，所有指针引用仍指向同一地址；
  调用点 selref 与方法定义共享同一字符串，改后仍然一致，运行时可正常派发。
- **只扰动 [A-Za-z0-9_]**，保留 ':'、'.' 等结构字符（保持 selector 参数结构不变）。
- **自动保护**：凡是同时出现在 `__cstring` 的名字一律跳过——这些极可能被
  NSSelectorFromString / NSClassFromString / KVC / Codable 按字面量动态查找，改了会崩。
- **系统/框架白名单**：系统类前缀、常见 delegate/生命周期 selector、init/dealloc 等一律跳过。
- 幂等且确定性：同 seed 同输入产出一致（利于可复现构建 / 崩溃符号对照）。

⚠️ 仍属于有风险操作：storyboard/xib 按类名实例化、跨二进制按名字调用等场景本工具无法感知。
   必须先 `scan`（dry-run）审阅候选、真机回归通过后再进产线；改写后必须重签名。

用法：
  python3 macho_symbol_obfuscator.py scan  <binary> [--seed S] [--min-len N] [--aggressive]
  python3 macho_symbol_obfuscator.py apply <binary> --seed S [--min-len N] [--aggressive]
                                     [--classes] [--methods] [--protect-file f] [--map-out m.json]
默认 --classes 与 --methods 同时开启。
"""

import argparse
import hashlib
import json
import struct
import sys

# ---- Mach-O 常量 ----
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
MH_MAGIC = 0xFEEDFACE
MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM = 0xCEFAEDFE
MH_CIGAM_64 = 0xCFFAEDFE
LC_SEGMENT = 0x1
LC_SEGMENT_64 = 0x19

# 需要改写的 C 字符串 section（__TEXT 段内）
TARGET_CLASS_SECTS = {b"__objc_classname"}
TARGET_METH_SECTS = {b"__objc_methname"}
# 参与“动态引用保护”的 section：其内容视为可能被字面量查找的名字
CSTRING_SECTS = {b"__cstring", b"__objc_classlist", b"__oslogstring"}

# 保护：系统/框架类名前缀（这些是别人也有、且常被 KVC/runtime 引用的）
SYSTEM_CLASS_PREFIXES = (
    "NS", "UI", "CA", "CG", "CF", "CL", "CM", "CI", "CT", "AV", "MK", "SK",
    "WK", "SC", "MP", "GK", "PK", "PH", "QL", "AB", "AD", "EK", "GLK", "MTK",
    "SCN", "RTC", "FIR", "GUL", "GTM", "FBLPromise", "Flutter", "FLT",
)
# 保护：常见系统 / delegate / 生命周期 selector（精确名）
PROTECTED_SELECTORS = {
    "init", "initialize", "load", "dealloc", "new", "alloc", "retain",
    "release", "autorelease", "copy", "mutableCopy", "copyWithZone:",
    "mutableCopyWithZone:", "self", "class", "superclass", "description",
    "debugDescription", "hash", "isEqual:", "respondsToSelector:",
    "conformsToProtocol:", "isKindOfClass:", "isMemberOfClass:",
    "performSelector:", "performSelector:withObject:",
    "methodSignatureForSelector:", "forwardInvocation:",
    "valueForKey:", "setValue:forKey:", "valueForKeyPath:",
    "setValue:forKeyPath:", "encodeWithCoder:", "initWithCoder:",
    "supportsSecureCoding", "application:didFinishLaunchingWithOptions:",
    "applicationDidBecomeActive:", "applicationWillResignActive:",
    "applicationDidEnterBackground:", "applicationWillEnterForeground:",
    "applicationWillTerminate:", "window", "setWindow:",
    "viewDidLoad", "viewWillAppear:", "viewDidAppear:", "viewWillDisappear:",
    "viewDidDisappear:", "didReceiveMemoryWarning",
    "tableView:numberOfRowsInSection:", "tableView:cellForRowAtIndexPath:",
    "numberOfSectionsInTableView:", "tableView:didSelectRowAtIndexPath:",
    "collectionView:numberOfItemsInSection:",
    "collectionView:cellForItemAtIndexPath:",
    "registerWithRegistrar:", "handleMethodCall:result:",
    "detachFromEngineForRegistrar:",
}

_RENAME_CHARSET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"


def _read(path):
    with open(path, "rb") as f:
        return bytearray(f.read())


def _u32(buf, off, be):
    return struct.unpack_from(">I" if be else "<I", buf, off)[0]


def _slices(buf):
    """返回 [(slice_offset, is64, big_endian)] —— 支持 fat 与 thin。"""
    if len(buf) < 4:
        return []
    magic_be = struct.unpack_from(">I", buf, 0)[0]
    if magic_be in (FAT_MAGIC, FAT_MAGIC_64):
        nfat = struct.unpack_from(">I", buf, 4)[0]
        out = []
        is64 = magic_be == FAT_MAGIC_64
        rec = 8
        for _ in range(nfat):
            if is64:
                # cputype,cpusubtype,offset(u64),size(u64),align,reserved
                offset = struct.unpack_from(">Q", buf, rec + 8)[0]
                rec += 32
            else:
                offset = struct.unpack_from(">I", buf, rec + 8)[0]
                rec += 20
            out.append(offset)
        result = []
        for off in out:
            m = struct.unpack_from("<I", buf, off)[0]
            result.append(_thin_meta(m, off))
        return [r for r in result if r]
    # thin
    m = struct.unpack_from("<I", buf, 0)[0]
    r = _thin_meta(m, 0)
    return [r] if r else []


def _thin_meta(magic_le, off):
    if magic_le == MH_MAGIC_64:
        return (off, True, False)
    if magic_le == MH_MAGIC:
        return (off, False, False)
    if magic_le == MH_CIGAM_64:
        return (off, True, True)
    if magic_le == MH_CIGAM:
        return (off, False, True)
    return None


def _sections(buf, slice_off, is64, be):
    """遍历一个 slice 的所有 section，产出 (segname, sectname, abs_file_off, size)。"""
    end = "<>"[be] if False else (">" if be else "<")
    if is64:
        ncmds = struct.unpack_from(end + "I", buf, slice_off + 16)[0]
        lc = slice_off + 32
    else:
        ncmds = struct.unpack_from(end + "I", buf, slice_off + 16)[0]
        lc = slice_off + 28
    for _ in range(ncmds):
        cmd = struct.unpack_from(end + "I", buf, lc)[0]
        cmdsize = struct.unpack_from(end + "I", buf, lc + 4)[0]
        if cmdsize == 0:
            break
        if cmd == LC_SEGMENT_64 and is64:
            nsects = struct.unpack_from(end + "I", buf, lc + 64)[0]
            soff = lc + 72
            for _s in range(nsects):
                sectname = bytes(buf[soff:soff + 16]).rstrip(b"\x00")
                segname = bytes(buf[soff + 16:soff + 32]).rstrip(b"\x00")
                size = struct.unpack_from(end + "Q", buf, soff + 40)[0]
                fileoff = struct.unpack_from(end + "I", buf, soff + 48)[0]
                yield (segname, sectname, slice_off + fileoff, size)
                soff += 80
        elif cmd == LC_SEGMENT and not is64:
            nsects = struct.unpack_from(end + "I", buf, lc + 48)[0]
            soff = lc + 56
            for _s in range(nsects):
                sectname = bytes(buf[soff:soff + 16]).rstrip(b"\x00")
                segname = bytes(buf[soff + 16:soff + 32]).rstrip(b"\x00")
                size = struct.unpack_from(end + "I", buf, soff + 36)[0]
                fileoff = struct.unpack_from(end + "I", buf, soff + 40)[0]
                yield (segname, sectname, slice_off + fileoff, size)
                soff += 68
        lc += cmdsize


def _iter_cstrings(buf, abs_off, size):
    """产出 (start_abs, raw_bytes)（不含结尾 NUL）。"""
    i = abs_off
    end = abs_off + size
    while i < end:
        j = i
        while j < end and buf[j] != 0:
            j += 1
        if j > i:
            yield (i, bytes(buf[i:j]))
        i = j + 1


def _collect_cstring_names(buf, slices):
    names = set()
    for (slice_off, is64, be) in slices:
        for (seg, sect, off, size) in _sections(buf, slice_off, is64, be):
            if sect in CSTRING_SECTS:
                for (_start, raw) in _iter_cstrings(buf, off, size):
                    try:
                        names.add(raw.decode("utf-8"))
                    except UnicodeDecodeError:
                        pass
    return names


def _is_identifier_like(name):
    """只接受纯 [A-Za-z0-9_:] 组成的名字。

    这会自然排除 __objc_methname 里混入的属性类型编码
    （如 T@"NSArray",&,V_initialArguments）——那些含 '"' '@' ',' 等字符，
    改写会破坏 ivar/property 元数据并嵌入类名字面量。
    """
    for ch in name:
        if not (ch.isascii() and (ch.isalnum() or ch in "_:")):
            return False
    return True


def _is_protected(name, is_class, cstring_names, min_len, aggressive, extra,
                  method_allowlist):
    if not _is_identifier_like(name):
        return "non-identifier(type-encoding/attr)"
    if len(name) < min_len:
        return "too-short"
    if name in extra:
        return "extra-protect"
    if name.startswith("."):
        return "runtime-internal"
    if is_class:
        if not aggressive and name in cstring_names:
            return "in-cstring(dynamic-lookup)"
        if not aggressive and name.startswith("_"):
            return "leading-underscore"
        for p in SYSTEM_CLASS_PREFIXES:
            if name.startswith(p):
                return "system-class-prefix"
    else:
        # 方法名极度危险：selector 由字符串内容全局 unique，
        # 一旦改到系统框架也实现的 selector（如 containsObject:/UTF8String），
        # 调用点会指向不存在的实现而崩溃。因此默认「只改显式 allowlist 里的方法」，
        # 不提供任何自动方法改名。
        if method_allowlist is None:
            return "methods-disabled(no-allowlist)"
        if name not in method_allowlist:
            return "not-in-allowlist"
        if name in PROTECTED_SELECTORS:
            return "system-selector"
    return None


def _rename_same_length(name, seed):
    """就地等长改写：只扰动 [A-Za-z0-9_]，保留其它结构字符；确定性。"""
    h = hashlib.sha1((seed + "|" + name).encode("utf-8")).digest()
    out = []
    hi = 0
    first_ident = True
    for ch in name:
        if ch.isalnum() or ch == "_":
            b = h[hi % len(h)]
            hi += 1
            idx = b % len(_RENAME_CHARSET)
            c = _RENAME_CHARSET[idx]
            # 标识符首字符避免数字（纯美观，非运行时要求）
            if first_ident and c.isdigit():
                c = _RENAME_CHARSET[(idx + 10) % len(_RENAME_CHARSET)]
            out.append(c)
            first_ident = False
        else:
            out.append(ch)
            first_ident = True
    return "".join(out)


def process(path, do_apply, seed, min_len, aggressive, do_classes,
            do_methods, extra, map_out, method_allowlist):
    buf = _read(path)
    slices = _slices(buf)
    if not slices:
        print("  [skip] 非 Mach-O 文件: %s" % path)
        return 0, 0
    cstring_names = _collect_cstring_names(buf, slices)

    seen = {}       # name -> new_name（跨 slice 保持一致）
    protected = {}  # name -> reason
    renamed = 0
    candidates = 0

    for (slice_off, is64, be) in slices:
        for (seg, sect, off, size) in _sections(buf, slice_off, is64, be):
            is_class = sect in TARGET_CLASS_SECTS
            is_meth = sect in TARGET_METH_SECTS
            if not (is_class or is_meth):
                continue
            if is_class and not do_classes:
                continue
            if is_meth and not do_methods:
                continue
            for (start, raw) in _iter_cstrings(buf, off, size):
                try:
                    name = raw.decode("utf-8")
                except UnicodeDecodeError:
                    continue
                if name in protected:
                    continue
                reason = _is_protected(
                    name, is_class, cstring_names, min_len, aggressive, extra,
                    method_allowlist)
                if reason:
                    protected[name] = reason
                    continue
                candidates += 1
                new = seen.get(name)
                if new is None:
                    new = _rename_same_length(name, seed)
                    seen[name] = new
                if do_apply and new != name:
                    nb = new.encode("utf-8")
                    if len(nb) == len(raw):
                        buf[start:start + len(nb)] = nb
                        renamed += 1

    if do_apply:
        with open(path, "wb") as f:
            f.write(buf)
        if map_out:
            with open(map_out, "w", encoding="utf-8") as f:
                json.dump({"seed": seed, "mapping": seen}, f,
                          ensure_ascii=False, indent=2)
    else:
        # scan 模式：打印摘要
        print("  slices=%d  候选=%d  受保护=%d" %
              (len(slices), len(seen), len(protected)))
        shown = 0
        for n, nn in seen.items():
            print("    rename: %s -> %s" % (n, nn))
            shown += 1
            if shown >= 40:
                print("    ... (%d more)" % (len(seen) - shown))
                break
    return (renamed if do_apply else len(seen)), len(protected)


def main():
    ap = argparse.ArgumentParser(description="Mach-O ObjC 符号就地等长混淆")
    ap.add_argument("mode", choices=["scan", "apply"])
    ap.add_argument("binary")
    ap.add_argument("--seed", default="")
    ap.add_argument("--min-len", type=int, default=4)
    ap.add_argument("--aggressive", action="store_true",
                    help="放宽保护（跳过 __cstring/下划线/delegate 保护），风险更高")
    ap.add_argument("--classes", action="store_true", help="仅改类名")
    ap.add_argument("--methods", action="store_true", help="仅改方法名")
    ap.add_argument("--protect-file", default="",
                    help="额外保护名清单（每行一个）")
    ap.add_argument("--methods-allowlist", default="",
                    help="方法名改名白名单文件（每行一个）。不提供则完全不改方法名——"
                         "selector 全局 unique，自动改方法名极易崩溃。")
    ap.add_argument("--map-out", default="")
    args = ap.parse_args()

    if args.mode == "apply" and not args.seed:
        print("错误: apply 模式必须提供 --seed", file=sys.stderr)
        return 2

    # 默认两者都改
    do_classes = args.classes or not (args.classes or args.methods)
    do_methods = args.methods or not (args.classes or args.methods)

    def _load_list(p):
        vals = set()
        try:
            with open(p, encoding="utf-8") as f:
                for line in f:
                    s = line.strip()
                    if s and not s.startswith("#"):
                        vals.add(s)
        except OSError as e:
            print("警告: 无法读取清单 %s: %s" % (p, e), file=sys.stderr)
        return vals

    extra = _load_list(args.protect_file) if args.protect_file else set()
    # method_allowlist=None 表示「彻底禁用方法改名」（安全默认）
    method_allowlist = None
    if do_methods and args.methods_allowlist:
        method_allowlist = _load_list(args.methods_allowlist)

    changed, protected = process(
        args.binary, args.mode == "apply", args.seed, args.min_len,
        args.aggressive, do_classes, do_methods, extra, args.map_out,
        method_allowlist)

    if args.mode == "apply":
        print("  ✓ %s: 改写 %d 处，跳过保护 %d" %
              (args.binary, changed, protected))
    return 0


if __name__ == "__main__":
    sys.exit(main())
