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
- **自动保护**：凡是同时出现在 `__cstring` 的名字默认跳过——这些极可能被
  NSSelectorFromString / NSClassFromString / KVC / Codable 按字面量动态查找，改了会崩。
  开启 `--sync-cstring` 后改为：类名/方法名与 `__cstring` 内**同字面量**一并等长改写，
  动态查找仍一致，从而可安全覆盖 Rong 等 SDK 的 RC*/RCIMIW* 指纹。
- **SDK 前缀方法**：默认不改方法名（selector 全局 unique）。提供 `--sdk-prefixes RCIMIW,RC`
  时，自动把 methname 中匹配前缀的 selector 加入允许改名集合（仍跳过系统 selector）。
- **系统/框架白名单**：系统类前缀、常见 delegate/生命周期 selector、init/dealloc 等一律跳过。
- 幂等且确定性：同 seed 同输入产出一致（利于可复现构建 / 崩溃符号对照）。

⚠️ 仍属于有风险操作：storyboard/xib 按类名实例化、跨二进制按名字调用等场景本工具无法感知。
   必须先 `scan`（dry-run）审阅候选、真机回归通过后再进产线；改写后必须重签名。

用法：
  # 单二进制（旧）
  python3 macho_symbol_obfuscator.py scan|apply <binary> --seed S [选项]
  # 整包（推荐）：先全局收集映射，再写入每个 Mach-O —— 避免「framework 改了、Runner 没改」启动崩
  python3 macho_symbol_obfuscator.py scan-app|apply-app <Payload/Xxx.app> --seed S
      [--classes] [--methods] [--sdk-prefixes RCIMIW,RCIMWrapper,IRCIMIW,RC]
      [--sync-cstring] [--scrub-cstring] [--map-out m.json]
"""

import argparse
import hashlib
import json
import os
import re
import struct
import sys
import subprocess

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
# 参与“动态引用保护 / 同步改写”的字面量 section（不含指针表）
CSTRING_SECTS = {b"__cstring", b"__oslogstring"}

# 保护：系统/框架类名前缀（这些是别人也有、且常被 KVC/runtime 引用的）
SYSTEM_CLASS_PREFIXES = (
    "NS", "UI", "CA", "CG", "CF", "CL", "CM", "CI", "CT", "AV", "MK", "SK",
    "WK", "SC", "MP", "GK", "PK", "PH", "QL", "AB", "AD", "EK", "GLK", "MTK",
    "SCN", "RTC",
    # 注意：不要加 "RCT"——会误伤融云 RCTextMessage / RCTyping*（RC+Text…）
    "FIR", "GUL", "GTM", "FBLPromise", "Flutter", "FLT",
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

# Flutter 启动关键类：改名极易闪退
PROTECTED_CLASSES = {
    "GeneratedPluginRegistrant",
    "FlutterAppDelegate",
    "FlutterViewController",
    "AppDelegate",
    "MainSceneDelegate",
    "SceneDelegate",
}

_RENAME_CHARSET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"

# SDK 前缀 RC 易误伤 OpenSSL RC2·RC4·RC5。
# 注意：不能用 startswith("RCT")——会误伤 RCTextMessage / RCTyping*（RC+Text…）。
# 本包为 Flutter，无 React Native RCT* 类；若混入 RN 再按完整类名加白名单排除。
_SDK_PREFIX_EXCLUDES = ()
_OPENSSL_RC_RE = re.compile(r"^RC[245]([_\-]|$)")  # RC2-CBC / RC4-SHA / RC5_CTRL


def _method_sdk_prefixes(prefixes):
    """方法白名单用的前缀：不含裸「RC」/「Rong」（过宽）。

    类名可用 RC / Rong；方法另用长前缀 + L286 嵌入式 selector 规则。
    """
    return [p for p in (prefixes or []) if p not in ("RC", "Rong")]


# L286/L288：明确的 SDK 嵌入式 selector（类已改名后残留的 RC* 指纹）
_L286_RC_METH_RE = re.compile(
    r"^(?:"
    r"(?:shared|set|setLatest|latest|to|createWith|initWith|pro|is)RC|"
    r"getIW\w+(?:Class|Type)?FromRC|"
    r"RCRTC|RCSend|RCCancel|RCSet|"
    r"[A-Za-z][A-Za-z0-9_]*2RC"  # L288: cMessages2RCMessages:
    # 注意：不要加 loadRong*/recordRong*——ExtensionModule 动态加载相关
    r")[A-Za-z0-9_]*"
)


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
    end = ">" if be else "<"
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


def _parse_prefixes(s):
    if not s:
        return []
    out = []
    for part in s.split(","):
        p = part.strip()
        if p:
            out.append(p)
    # 长前缀优先，避免 RC 抢在 RCIMIW 前误判排除逻辑
    out.sort(key=len, reverse=True)
    return out


def _matches_sdk_prefix(name, prefixes):
    if not prefixes:
        return False
    # L287：__RCTimerWeakProxy 等私有类按去掉下划线后的名字匹配
    check = name.lstrip("_")
    if _OPENSSL_RC_RE.match(check) or _OPENSSL_RC_RE.match(name):
        return False
    for ex in _SDK_PREFIX_EXCLUDES:
        if name.startswith(ex) or check.startswith(ex):
            return False
    # L285：ExtensionModule 经 CSV + NSClassFromString 加载，改类名却不同步 CSV 会挂
    if name.endswith("ExtensionModule") or check.endswith("ExtensionModule"):
        return False
    for p in prefixes:
        if name.startswith(p) or check.startswith(p):
            return True
    return False


def _cstring_scrub_hit(name, scrub_prefixes, channel_only=True):
    """判断 __cstring 字面量是否应擦除。

    channel_only=True（推荐）：只擦 Flutter channel / 回调键，避免误伤其它字面量。
      - engine_cb:…RCIMIW… / IRCIMIW…
      - 含 rongcloud 且含 RCIMIW/IRCIMIW 的 path（如 cn.rongcloud.im.flutter/RCIMIWEngine）
    channel_only=False：额外擦除以 SDK 前缀开头的纯标识符字面量。
    """
    if not scrub_prefixes or not name:
        return False
    if _OPENSSL_RC_RE.match(name):
        return False
    # 回调键
    if name.startswith("engine_cb:") and (
            "RCIMIW" in name or "IRCIMIW" in name or "RCIMWrapper" in name):
        return True
    # MethodChannel / EventChannel path
    low = name.lower()
    if "rongcloud" in low and (
            "RCIMIW" in name or "IRCIMIW" in name or "RCIMWrapper" in name):
        return True
    if channel_only:
        return False
    if _matches_sdk_prefix(name, scrub_prefixes):
        return True
    return False


def _collect_sdk_methnames(buf, slices, prefixes, min_len):
    """从 __objc_methname 收集匹配 SDK 前缀/标记的 selector。"""
    out = set()
    prefixes = _method_sdk_prefixes(prefixes)
    if not prefixes:
        return out
    for (slice_off, is64, be) in slices:
        for (_seg, sect, off, size) in _sections(buf, slice_off, is64, be):
            if sect not in TARGET_METH_SECTS:
                continue
            for (_start, raw) in _iter_cstrings(buf, off, size):
                try:
                    name = raw.decode("utf-8")
                except UnicodeDecodeError:
                    continue
                if len(name) < min_len:
                    continue
                if not _is_identifier_like(name):
                    continue
                if name in PROTECTED_SELECTORS:
                    continue
                # 前缀开头，或 selector 内嵌 RCIMIW（如 toRCIMIWGroupApplicationStatus:）
                if _matches_sdk_prefix(name, prefixes):
                    out.add(name)
                elif ":" in name and any(
                        m in name for m in ("RCIMIW", "IRCIMIW", "RCIMWrapper")):
                    out.add(name)
                # L286：setRC* / toRC* / initWithRC* / RCRTC* 等嵌入式 SDK selector
                elif _L286_RC_METH_RE.match(name):
                    out.add(name)
    return out


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
                  method_allowlist, sync_cstring, sdk_prefixes,
                  sdk_classes_only=False):
    if not _is_identifier_like(name):
        return "non-identifier(type-encoding/attr)"
    if len(name) < min_len:
        return "too-short"
    if name in extra:
        return "extra-protect"
    if name.startswith("."):
        return "runtime-internal"
    if is_class:
        if name in PROTECTED_CLASSES:
            return "protected-class"
        # SDK 目标类优先于系统前缀（避免 RCT 误伤 RCTextMessage）
        is_sdk_target = bool(
            sdk_classes_only and sdk_prefixes
            and _matches_sdk_prefix(name, sdk_prefixes)
        )
        if not is_sdk_target:
            for p in SYSTEM_CLASS_PREFIXES:
                if name.startswith(p):
                    return "system-class-prefix"
        # sync-cstring：cstring 内同名会一并改写，不再因动态查找而跳过
        if not aggressive and not sync_cstring and name in cstring_names:
            return "in-cstring(dynamic-lookup)"
        if not aggressive and name.startswith("_"):
            # L287：允许 __RC* / __Rong* SDK 私有类（勿一刀切跳过）
            bare = name.lstrip("_")
            if not (sdk_classes_only and sdk_prefixes
                    and _matches_sdk_prefix(bare, sdk_prefixes)):
                return "leading-underscore"
        if sdk_classes_only and sdk_prefixes:
            if not _matches_sdk_prefix(name, sdk_prefixes):
                return "not-sdk-class"
    else:
        # 方法名极度危险：selector 由字符串内容全局 unique，
        # 一旦改到系统框架也实现的 selector（如 containsObject:/UTF8String），
        # 调用点会指向不存在的实现而崩溃。因此默认「只改显式 allowlist / SDK 前缀」。
        if method_allowlist is None:
            return "methods-disabled(no-allowlist)"
        if name not in method_allowlist:
            return "not-in-allowlist"
        if name in PROTECTED_SELECTORS:
            return "system-selector"
        if not aggressive and not sync_cstring and name in cstring_names:
            return "in-cstring(dynamic-lookup)"
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


def _sync_cstring_literals(buf, slices, mapping):
    """把 mapping 中的旧名在 __cstring/__oslogstring 里等长同步改写。"""
    if not mapping:
        return 0
    bmap = {}
    for old, new in mapping.items():
        if old == new:
            continue
        ob = old.encode("utf-8")
        nb = new.encode("utf-8")
        if len(ob) == len(nb):
            bmap[ob] = nb
    if not bmap:
        return 0
    n = 0
    for (slice_off, is64, be) in slices:
        for (_seg, sect, off, size) in _sections(buf, slice_off, is64, be):
            if sect not in CSTRING_SECTS:
                continue
            for (start, raw) in _iter_cstrings(buf, off, size):
                nb = bmap.get(raw)
                if nb is not None:
                    buf[start:start + len(nb)] = nb
                    n += 1
    return n


def _scrub_cstring_by_prefix(buf, slices, seed, scrub_prefixes, mapping, min_len):
    """直接擦除匹配 SDK 标记的 __cstring 字面量（等长，写入 mapping 保跨二进制一致）。"""
    if not scrub_prefixes:
        return 0
    n = 0
    for (slice_off, is64, be) in slices:
        for (_seg, sect, off, size) in _sections(buf, slice_off, is64, be):
            if sect not in CSTRING_SECTS:
                continue
            for (start, raw) in _iter_cstrings(buf, off, size):
                try:
                    name = raw.decode("utf-8")
                except UnicodeDecodeError:
                    continue
                if len(name) < min_len:
                    continue
                if not _cstring_scrub_hit(name, scrub_prefixes):
                    continue
                new = mapping.get(name)
                if new is None:
                    new = _rename_same_length(name, seed)
                    mapping[name] = new
                if new == name:
                    continue
                nb = new.encode("utf-8")
                if len(nb) != len(raw):
                    continue
                buf[start:start + len(nb)] = nb
                n += 1
    return n


# Dart AOT 等：__const 里非 NUL 结尾的 channel / 回调键 span
_CONST_SCRUB_SECTS = {b"__const"}
_CONST_SCRUB_RE = re.compile(
    br'(?:'
    br'cn\.rongcloud\.im\.flutter/[A-Za-z0-9_./]*|'
    br'engine_cb:I?RCIM(?:IW|Wrapper)[A-Za-z0-9_]*'
    br')'
)


def _scrub_const_sdk_spans(buf, slices, seed, mapping, min_len):
    """擦除 __const 中 channel / 回调键 span。

    警告：不得用于 App.framework（Dart AOT）——就地改字符串会破坏
    switch 的编译期 hash，导致进 B 面 IM 回调时闪退。
    """
    n = 0
    for (slice_off, is64, be) in slices:
        for (_seg, sect, off, size) in _sections(buf, slice_off, is64, be):
            if sect not in _CONST_SCRUB_SECTS:
                continue
            data = bytes(buf[off:off + size])  # 只读
            used = bytearray(len(data))
            for m in _CONST_SCRUB_RE.finditer(data):
                raw = m.group(0)
                if len(raw) < min_len:
                    continue
                try:
                    name = raw.decode("utf-8")
                except UnicodeDecodeError:
                    continue
                new = mapping.get(name)
                if new is None:
                    new = _rename_same_length(name, seed)
                    mapping[name] = new
                if new == name:
                    continue
                nb = new.encode("utf-8")
                if len(nb) != len(raw):
                    continue
                i = m.start()
                j = i + len(raw)
                if any(used[i:j]):
                    continue
                buf[off + i:off + j] = nb
                used[i:j] = b"\x01" * (j - i)
                n += 1
    return n


def _is_dart_aot_macho(path):
    """Flutter Dart AOT 在 App.framework/App；禁止对其做 channel scrub。"""
    p = path.replace("\\", "/")
    return "/App.framework/" in p or p.endswith("/Frameworks/App.framework/App")


def _patch_embedded_classnames(buf, slices, mapping, seed, sdk_prefixes, min_len):
    """在 methtype / cstring / methname 里同步 @"Class" / @"<Proto>" / ^{Class=。

    L284：cstring block；L287：属性编码；L288：多协议 @"<A><B>" 与 T^{RC*=}。
    """
    class_map = {k: v for k, v in mapping.items()
                 if k != v and ":" not in k and k.isidentifier()}
    embed_re = re.compile(r'@\"<?([A-Za-z_][A-Za-z0-9_]*)>?\"')
    proto_re = re.compile(r'<([A-Za-z_][A-Za-z0-9_]*)>')
    struct_re = re.compile(r'\^\{([A-Za-z_][A-Za-z0-9_]*)=')
    target_sects = {b"__objc_methtype", b"__cstring", b"__oslogstring", b"__objc_methname"}
    discovered = set()

    def _maybe_add(cn):
        if len(cn) < min_len:
            return
        if cn in class_map:
            discovered.add(cn)
        elif sdk_prefixes and _matches_sdk_prefix(cn, sdk_prefixes):
            discovered.add(cn)

    for (slice_off, is64, be) in slices:
        for (_seg, sect, off, size) in _sections(buf, slice_off, is64, be):
            if sect not in target_sects:
                continue
            for (_start, raw) in _iter_cstrings(buf, off, size):
                try:
                    s = raw.decode("utf-8")
                except UnicodeDecodeError:
                    continue
                for m in embed_re.finditer(s):
                    _maybe_add(m.group(1))
                if "@\"" in s and "<" in s:
                    for m in proto_re.finditer(s):
                        _maybe_add(m.group(1))
                if "^{" in s:
                    for m in struct_re.finditer(s):
                        _maybe_add(m.group(1))

    for cn in discovered:
        if cn not in mapping:
            mapping[cn] = _rename_same_length(cn, seed)
        class_map[cn] = mapping[cn]
    if not class_map:
        return 0

    n = 0
    for (slice_off, is64, be) in slices:
        for (_seg, sect, off, size) in _sections(buf, slice_off, is64, be):
            if sect not in target_sects:
                continue
            for (start, raw) in _iter_cstrings(buf, off, size):
                try:
                    s = raw.decode("utf-8")
                except UnicodeDecodeError:
                    continue
                if "@\"" not in s and "^{" not in s:
                    continue
                out = s

                def _repl_embed(m):
                    cn = m.group(1)
                    nn = class_map.get(cn)
                    if not nn or nn == cn:
                        return m.group(0)
                    if m.group(0).startswith('@\"<'):
                        return '@"<%s>"' % nn
                    return '@"%s"' % nn

                def _repl_proto(m):
                    cn = m.group(1)
                    nn = class_map.get(cn)
                    if not nn or nn == cn:
                        return m.group(0)
                    return "<%s>" % nn

                def _repl_struct(m):
                    cn = m.group(1)
                    nn = class_map.get(cn)
                    if not nn or nn == cn:
                        return m.group(0)
                    return "^{%s=" % nn

                if "@\"" in out:
                    out = embed_re.sub(_repl_embed, out)
                    if "<" in out:
                        out = proto_re.sub(_repl_proto, out)
                if "^{" in out:
                    out = struct_re.sub(_repl_struct, out)

                if out != s:
                    nb = out.encode("utf-8")
                    if len(nb) == len(raw):
                        buf[start:start + len(nb)] = nb
                        n += 1
    return n



def process(path, do_apply, seed, min_len, aggressive, do_classes,
            do_methods, extra, map_out, method_allowlist, sync_cstring=False,
            sdk_prefixes=None, scrub_cstring=False):
    buf = _read(path)
    slices = _slices(buf)
    if not slices:
        print("  [skip] 非 Mach-O 文件: %s" % path)
        return 0, 0
    sdk_prefixes = sdk_prefixes or []
    cstring_names = _collect_cstring_names(buf, slices)

    # SDK 前缀自动扩充方法白名单
    if do_methods and sdk_prefixes:
        auto = _collect_sdk_methnames(buf, slices, sdk_prefixes, min_len)
        if method_allowlist is None:
            method_allowlist = set(auto)
        else:
            method_allowlist = set(method_allowlist) | auto
        if auto:
            print("  sdk-prefixes %s → 方法候选 %d" %
                  (",".join(sdk_prefixes), len(auto)))

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
                    method_allowlist, sync_cstring, sdk_prefixes)
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

    cstring_synced = 0
    cstring_scrubbed = 0
    const_scrubbed = 0
    methtype_patched = 0
    if do_apply:
        if sync_cstring and seen:
            cstring_synced = _sync_cstring_literals(buf, slices, seen)
        if scrub_cstring and sdk_prefixes:
            # 擦除 channel/回调键等；写入同一 mapping，保证同 seed 跨二进制一致
            cstring_scrubbed = _scrub_cstring_by_prefix(
                buf, slices, seed, sdk_prefixes, seen, min_len)
            const_scrubbed = _scrub_const_sdk_spans(
                buf, slices, seed, seen, min_len)
            # scrub 后再 sync 一次，覆盖 objc 改名产生、scrub 未扫到的精确名
            if sync_cstring:
                cstring_synced += _sync_cstring_literals(buf, slices, seen)
        if seen or (scrub_cstring and sdk_prefixes):
            methtype_patched = _patch_embedded_classnames(
                buf, slices, seen, seed, sdk_prefixes, min_len)

    if do_apply:
        with open(path, "wb") as f:
            f.write(buf)
        if map_out:
            with open(map_out, "w", encoding="utf-8") as f:
                json.dump({
                    "seed": seed,
                    "sync_cstring": sync_cstring,
                    "scrub_cstring": scrub_cstring,
                    "sdk_prefixes": sdk_prefixes,
                    "mapping": seen,
                    "cstring_synced": cstring_synced,
                    "cstring_scrubbed": cstring_scrubbed,
                    "const_scrubbed": const_scrubbed,
                    "methtype_patched": methtype_patched,
                }, f, ensure_ascii=False, indent=2)
    else:
        # scan：预估 cstring scrub 候选
        scrub_est = 0
        scrub_samples = []
        if scrub_cstring and sdk_prefixes:
            for (slice_off, is64, be) in slices:
                for (_seg, sect, off, size) in _sections(buf, slice_off, is64, be):
                    if sect not in CSTRING_SECTS:
                        continue
                    for (_start, raw) in _iter_cstrings(buf, off, size):
                        try:
                            name = raw.decode("utf-8")
                        except UnicodeDecodeError:
                            continue
                        if len(name) < min_len:
                            continue
                        if _cstring_scrub_hit(name, sdk_prefixes):
                            scrub_est += 1
                            if len(scrub_samples) < 12:
                                scrub_samples.append(name)
        print("  slices=%d  候选=%d  受保护=%d  sync-cstring=%s  scrub-cstring≈%d" %
              (len(slices), len(seen), len(protected), sync_cstring, scrub_est))
        sdk_hits = [n for n in seen if _matches_sdk_prefix(n, sdk_prefixes)]
        if sdk_prefixes:
            print("  SDK 前缀命中(objc)候选: %d" % len(sdk_hits))
        shown = 0
        ordered = list(sdk_hits) + [n for n in seen if n not in set(sdk_hits)]
        for n in ordered:
            nn = seen[n]
            tag = " [sdk]" if n in set(sdk_hits) else ""
            print("    rename%s: %s -> %s" % (tag, n, nn))
            shown += 1
            if shown >= 30:
                print("    ... (%d more objc)" % (len(seen) - shown))
                break
        if scrub_samples:
            print("  cstring scrub 样例:")
            for n in scrub_samples:
                print("    scrub: %s -> %s" % (n, _rename_same_length(n, seed or "scan")))
        sdk_skipped = [
            (n, r) for n, r in protected.items()
            if _matches_sdk_prefix(n, sdk_prefixes)
        ]
        if sdk_skipped:
            print("  SDK 仍跳过（前若干）:")
            for n, r in sdk_skipped[:10]:
                print("    skip: %s (%s)" % (n, r))

    if do_apply:
        if sync_cstring:
            print("  cstring 同步改写: %d 处" % cstring_synced)
        if scrub_cstring:
            print("  cstring SDK 擦除: %d 处" % cstring_scrubbed)
            print("  __const SDK 擦除: %d 处" % const_scrubbed)
        if methtype_patched:
            print("  methtype/编码内嵌类名: %d 处" % methtype_patched)
    return (renamed if do_apply else len(seen)), len(protected)


# ---------------------------------------------------------------------------
# 整包模式：全局映射 → 各二进制统一写入（修复跨镜像 selector/channel 不一致）
# ---------------------------------------------------------------------------

def list_app_machos(app_path):
    """列出 .app 内主可执行 + Frameworks 下 Mach-O。"""
    out = []
    plist = os.path.join(app_path, "Info.plist")
    if os.path.isfile(plist):
        try:
            exe = subprocess.check_output(
                ["/usr/libexec/PlistBuddy", "-c",
                 "Print :CFBundleExecutable", plist],
                stderr=subprocess.DEVNULL).decode().strip()
            p = os.path.join(app_path, exe)
            if os.path.isfile(p):
                out.append(p)
        except (subprocess.CalledProcessError, OSError):
            pass
    fw = os.path.join(app_path, "Frameworks")
    if os.path.isdir(fw):
        for root, _dirs, files in os.walk(fw):
            for name in files:
                p = os.path.join(root, name)
                if not os.path.isfile(p):
                    continue
                try:
                    info = subprocess.check_output(
                        ["file", "-b", p], stderr=subprocess.DEVNULL).decode()
                except (subprocess.CalledProcessError, OSError):
                    continue
                if "Mach-O" in info:
                    out.append(p)
    # 去重保序
    seen = set()
    uniq = []
    for p in out:
        if p not in seen:
            seen.add(p)
            uniq.append(p)
    return uniq


def _collect_objc_candidates(buf, slices, do_classes, do_methods, method_allowlist,
                             cstring_names, min_len, aggressive, extra,
                             sync_cstring, sdk_prefixes, sdk_classes_only=False):
    """收集本 binary 可改写的类名/方法名 → (class_set, meth_set, protected)。"""
    classes, meths, protected = set(), set(), {}
    for (_so, is64, be) in slices:
        for (_seg, sect, off, size) in _sections(buf, _so, is64, be):
            is_class = sect in TARGET_CLASS_SECTS
            is_meth = sect in TARGET_METH_SECTS
            if not (is_class or is_meth):
                continue
            if is_class and not do_classes:
                continue
            if is_meth and not do_methods:
                continue
            for (_start, raw) in _iter_cstrings(buf, off, size):
                try:
                    name = raw.decode("utf-8")
                except UnicodeDecodeError:
                    continue
                reason = _is_protected(
                    name, is_class, cstring_names, min_len, aggressive, extra,
                    method_allowlist, sync_cstring, sdk_prefixes,
                    sdk_classes_only=sdk_classes_only)
                if reason:
                    protected[name] = reason
                    continue
                if is_class:
                    classes.add(name)
                else:
                    meths.add(name)
    return classes, meths, protected


def _collect_scrub_strings(buf, slices, sdk_prefixes, min_len):
    """收集 cstring + __const 中待擦除的完整字面量。"""
    found = set()
    if not sdk_prefixes:
        return found
    for (_so, is64, be) in slices:
        for (_seg, sect, off, size) in _sections(buf, _so, is64, be):
            if sect in CSTRING_SECTS:
                for (_start, raw) in _iter_cstrings(buf, off, size):
                    try:
                        name = raw.decode("utf-8")
                    except UnicodeDecodeError:
                        continue
                    if len(name) >= min_len and _cstring_scrub_hit(name, sdk_prefixes):
                        found.add(name)
            if sect in _CONST_SCRUB_SECTS:
                data = bytes(buf[off:off + size])
                for m in _CONST_SCRUB_RE.finditer(data):
                    raw = m.group(0)
                    if len(raw) < min_len:
                        continue
                    try:
                        found.add(raw.decode("utf-8"))
                    except UnicodeDecodeError:
                        continue
    return found


def _apply_exact_mapping_cstrings(buf, slices, mapping, sect_filter):
    """在指定 section 里对 NUL 结尾串做精确等长替换。"""
    if not mapping:
        return 0
    bmap = {}
    for old, new in mapping.items():
        if old == new:
            continue
        ob, nb = old.encode("utf-8"), new.encode("utf-8")
        if len(ob) == len(nb):
            bmap[ob] = nb
    if not bmap:
        return 0
    n = 0
    for (_so, is64, be) in slices:
        for (_seg, sect, off, size) in _sections(buf, _so, is64, be):
            if sect not in sect_filter:
                continue
            for (start, raw) in _iter_cstrings(buf, off, size):
                nb = bmap.get(raw)
                if nb is not None:
                    buf[start:start + len(nb)] = nb
                    n += 1
    return n


def _apply_mapping_byte_spans(buf, slices, mapping, sect_filter):
    """在 section 原始字节中按 mapping 键（长优先）做子串等长替换。"""
    if not mapping:
        return 0
    items = [(o.encode("utf-8"), n.encode("utf-8"))
             for o, n in mapping.items() if o != n]
    items = [(o, n) for o, n in items if len(o) == len(n)]
    items.sort(key=lambda x: len(x[0]), reverse=True)
    if not items:
        return 0
    n = 0
    for (_so, is64, be) in slices:
        for (_seg, sect, off, size) in _sections(buf, _so, is64, be):
            if sect not in sect_filter:
                continue
            data = bytes(buf[off:off + size])  # 只读
            used = bytearray(len(data))
            for ob, nb in items:
                start = 0
                while True:
                    i = data.find(ob, start)
                    if i < 0:
                        break
                    j = i + len(ob)
                    if not any(used[i:j]):
                        buf[off + i:off + j] = nb
                        used[i:j] = b"\x01" * (j - i)
                        n += 1
                    start = j
    return n



# L289：ObjC debug 描述串 -[Class sel] / +[Class sel]（含 block_invoke 内嵌）
_DEBUG_OBJC_RE = re.compile(
    r"^([+-])\[([A-Za-z_][A-Za-z0-9_]*)(\([A-Za-z_][A-Za-z0-9_]*\))? "
    r"([A-Za-z_][A-Za-z0-9_:]*|\.cxx_destruct)\]$"
)
_DEBUG_OBJC_EMBED_RE = re.compile(
    r"([+-])\[([A-Za-z_][A-Za-z0-9_]*)(\([A-Za-z_][A-Za-z0-9_]*\))? "
    r"([A-Za-z_][A-Za-z0-9_:]*|\.cxx_destruct)\]"
)
LC_SYMTAB = 0x2


def _iter_symtab_strtabs(buf, slices):
    """产出各 slice 的 (stroff_abs, strsize)。只碰符号字符串表，不改 nlist。"""
    for (slice_off, is64, be) in slices:
        ncmds = _u32(buf, slice_off + 16, be)
        lc = slice_off + (32 if is64 else 28)
        for _ in range(ncmds):
            cmd = _u32(buf, lc, be)
            cmdsize = _u32(buf, lc + 4, be)
            if cmd == LC_SYMTAB:
                stroff = _u32(buf, lc + 16, be)
                strsize = _u32(buf, lc + 20, be)
                abs_off = stroff if slice_off == 0 else slice_off + stroff
                if abs_off + strsize > len(buf) or (
                        slice_off and stroff > slice_off and stroff + strsize <= len(buf)):
                    abs_off = stroff
                if abs_off + strsize <= len(buf):
                    yield abs_off, strsize
            lc += cmdsize


def _rewrite_debug_objc_string(s, class_map, meth_map):
    """改写整串或内嵌的 -[Class sel]（block_invoke 符号）。"""

    def _one(sign, cls, cat, sel):
        ncls = class_map.get(cls, cls)
        nsel = meth_map.get(sel, sel)
        ncat = cat or ""
        if cat:
            inner = cat[1:-1]
            ninner = class_map.get(inner, inner)
            if ninner != inner:
                ncat = "(%s)" % ninner
        if ncls == cls and nsel == sel and ncat == (cat or ""):
            return None
        return "%s[%s%s %s]" % (sign, ncls, ncat, nsel)

    m = _DEBUG_OBJC_RE.match(s)
    if m:
        out = _one(m.group(1), m.group(2), m.group(3), m.group(4))
        return out

    changed = False

    def _repl(mo):
        nonlocal changed
        out = _one(mo.group(1), mo.group(2), mo.group(3), mo.group(4))
        if out is None:
            return mo.group(0)
        changed = True
        return out

    new = _DEBUG_OBJC_EMBED_RE.sub(_repl, s)
    return new if changed else None


def _patch_objc_debug_descriptions(buf, slices, class_map, meth_map):
    """等长改写 __cstring 与 SYMTAB 字符串表中的 -[Class method] / +[Class method]。

    不碰 _OBJC_CLASS_$_ / _objc_msgSend$ 等绑定符号（SYMBOL_ALIASES 已验证会启动失败）。
    """
    if not class_map and not meth_map:
        return 0
    n = 0
    ranges = []
    for (slice_off, is64, be) in slices:
        for (_seg, sect, off, size) in _sections(buf, slice_off, is64, be):
            if sect in CSTRING_SECTS:
                ranges.append((off, size))
    for off, size in list(_iter_symtab_strtabs(buf, slices)):
        ranges.append((off, size))

    for off, size in ranges:
        for (start, raw) in _iter_cstrings(buf, off, size):
            try:
                s = raw.decode("utf-8")
            except UnicodeDecodeError:
                continue
            if "-[" not in s and "+[" not in s:
                continue
            out = _rewrite_debug_objc_string(s, class_map, meth_map)
            if not out:
                continue
            nb = out.encode("utf-8")
            if len(nb) != len(raw):
                continue
            buf[start:start + len(nb)] = nb
            n += 1
    return n



# L290：SDK ivar / property V_rc* / _rc* / latestRC* 指纹
# 硬规则：禁止动 RCIM / RCCore / RCChannel（L284/L290 聊天室已验证会挂）
# 仅小写 rc* / latestRC*，不要用大写 RC 前缀匹配整串 cstring
_IVAR_DENY = frozenset({
    "RCIM", "RCCore", "RCChannel", "RC", "rc", "Rong", "rong",
})
_IVAR_PROP_RE = re.compile(
    r",V_((?:rc)[A-Za-z0-9_]+|latestRC[A-Za-z0-9_]+)"
)
_IVAR_EXACT_RE = re.compile(
    r"^_?((?:rc)[A-Za-z0-9_]+|latestRC[A-Za-z0-9_]+)$"
)


def _ivar_token_ok(base):
    if not base or base in _IVAR_DENY:
        return False
    if len(base) < 8:
        return False
    # 拒绝短大写 SDK 标识被误收（双保险）
    if base in ("RCIM", "RCCore", "RCChannel"):
        return False
    return True


def _patch_sdk_ivar_fingerprints(buf, slices, seed):
    """等长改写 property 的 V_rc* 与对应 ivar 名 cstring（跨串同 seed 一致）。"""
    discovered = set()
    target_sects = set(TARGET_METH_SECTS) | set(CSTRING_SECTS)
    for (slice_off, is64, be) in slices:
        for (_seg, sect, off, size) in _sections(buf, slice_off, is64, be):
            if sect not in target_sects:
                continue
            for (_start, raw) in _iter_cstrings(buf, off, size):
                try:
                    s = raw.decode("utf-8")
                except UnicodeDecodeError:
                    continue
                if ",V_" in s:
                    for m in _IVAR_PROP_RE.finditer(s):
                        if _ivar_token_ok(m.group(1)):
                            discovered.add(m.group(1))
                m2 = _IVAR_EXACT_RE.match(s)
                if m2 and _ivar_token_ok(m2.group(1)):
                    discovered.add(m2.group(1))

    if not discovered:
        return 0

    base_map = {}
    for tok in discovered:
        base = tok[1:] if tok.startswith("_") else tok
        if not _ivar_token_ok(base):
            continue
        if base not in base_map:
            base_map[base] = _rename_same_length(base, seed)

    n = 0
    for (slice_off, is64, be) in slices:
        for (_seg, sect, off, size) in _sections(buf, slice_off, is64, be):
            if sect not in target_sects:
                continue
            for (start, raw) in _iter_cstrings(buf, off, size):
                try:
                    s = raw.decode("utf-8")
                except UnicodeDecodeError:
                    continue
                out = s
                if ",V_" in out:
                    def _repl(m, _bm=base_map):
                        base = m.group(1)
                        if not _ivar_token_ok(base):
                            return m.group(0)
                        nb = _bm.get(base)
                        if not nb or nb == base:
                            return m.group(0)
                        return ",V_" + nb
                    out = _IVAR_PROP_RE.sub(_repl, out)
                m2 = _IVAR_EXACT_RE.match(out)
                if m2:
                    base = m2.group(1)
                    if _ivar_token_ok(base):
                        nb = base_map.get(base)
                        if nb and nb != base:
                            out = ("_" + nb) if out.startswith("_") else nb
                if out != s:
                    nb = out.encode("utf-8")
                    if len(nb) == len(raw):
                        buf[start:start + len(nb)] = nb
                        n += 1
    return n


def _apply_mapping_to_binary(path, seed, class_map, meth_map, scrub_map,
                             sync_cstring, scrub_cstring, sdk_prefixes, min_len,
                             symbol_aliases=False, patch_methtype=False):
    """用全局映射改写单个二进制。"""
    buf = _read(path)
    slices = _slices(buf)
    if not slices:
        return {"path": path, "skip": True}

    renamed = 0
    # classname / methname section 精确 NUL 串
    for (_so, is64, be) in slices:
        for (_seg, sect, off, size) in _sections(buf, _so, is64, be):
            mapping = None
            if sect in TARGET_CLASS_SECTS:
                mapping = class_map
            elif sect in TARGET_METH_SECTS:
                mapping = meth_map
            else:
                continue
            if not mapping:
                continue
            for (start, raw) in _iter_cstrings(buf, off, size):
                try:
                    name = raw.decode("utf-8")
                except UnicodeDecodeError:
                    continue
                new = mapping.get(name)
                if not new or new == name:
                    continue
                nb = new.encode("utf-8")
                if len(nb) == len(raw):
                    buf[start:start + len(nb)] = nb
                    renamed += 1

    all_map = {}
    all_map.update(class_map)
    all_map.update(meth_map)
    all_map.update(scrub_map)

    cstring_synced = 0
    cstring_scrubbed = 0
    const_scrubbed = 0
    linkedit_hits = 0
    if sync_cstring:
        sync_map = {}
        sync_map.update(class_map)
        sync_map.update(meth_map)
        cstring_synced = _apply_exact_mapping_cstrings(
            buf, slices, sync_map, CSTRING_SECTS)
    if scrub_cstring and scrub_map:
        # App.framework 是 Dart AOT：就地改 engine_cb / channel 字面量会破坏
        # 编译期 string switch hash，进 B 面 IM 回调时闪退（见 L3 实测）。
        if _is_dart_aot_macho(path):
            cstring_scrubbed = 0
            const_scrubbed = 0
        else:
            cstring_scrubbed = _apply_exact_mapping_cstrings(
                buf, slices, scrub_map, CSTRING_SECTS)
            const_scrubbed = _apply_mapping_byte_spans(
                buf, slices, scrub_map, _CONST_SCRUB_SECTS)

    debug_patched = _patch_objc_debug_descriptions(buf, slices, class_map, meth_map)
    ivar_patched = _patch_sdk_ivar_fingerprints(buf, slices, seed)

    if symbol_aliases:
        linkedit_hits = _apply_objc_symbol_aliases(buf, class_map, meth_map)

    methtype_patched = 0
    if patch_methtype:
        methtype_patched = _patch_embedded_classnames(
            buf, slices, all_map, seed, sdk_prefixes, min_len)

    with open(path, "wb") as f:
        f.write(buf)
    return {
        "path": path,
        "objc_sites": renamed,
        "cstring_synced": cstring_synced,
        "cstring_scrubbed": cstring_scrubbed,
        "const_scrubbed": const_scrubbed,
        "methtype_patched": methtype_patched,
        "debug_patched": debug_patched,
        "ivar_patched": ivar_patched,
        "whole_file_spans": linkedit_hits,
    }


def _apply_objc_symbol_aliases(buf, class_map, meth_map):
    """只替换 LINKEDIT/符号串中的 ObjC 别名，避免污染可执行代码。"""
    pairs = []
    for old, new in meth_map.items():
        if old == new or len(old) != len(new):
            continue
        # _objc_msgSend$oldSel  →  _objc_msgSend$newSel
        pairs.append(("_objc_msgSend$" + old, "_objc_msgSend$" + new))
    for old, new in class_map.items():
        if old == new or len(old) != len(new):
            continue
        for pref in ("_OBJC_CLASS_$_", "_OBJC_METACLASS_$_", "_OBJC_PROTOCOL_$_"):
            pairs.append((pref + old, pref + new))
    if not pairs:
        return 0
    # 转 bytes，长键优先
    items = [(a.encode("utf-8"), b.encode("utf-8")) for a, b in pairs
             if len(a.encode("utf-8")) == len(b.encode("utf-8"))]
    items.sort(key=lambda x: len(x[0]), reverse=True)
    data = bytes(buf)
    used = bytearray(len(data))
    n = 0
    for ob, nb in items:
        start = 0
        while True:
            i = data.find(ob, start)
            if i < 0:
                break
            j = i + len(ob)
            if not any(used[i:j]):
                buf[i:j] = nb
                used[i:j] = b"\x01" * (j - i)
                n += 1
            start = j
    return n


def _apply_mapping_whole_file(buf, mapping):
    """已废弃：整文件盲替换会破坏机器码。保留空壳以防外部调用。"""
    return 0


def process_app(app_path, do_apply, seed, min_len, aggressive, do_classes,
                do_methods, extra, map_out, method_allowlist, sync_cstring=False,
                sdk_prefixes=None, scrub_cstring=False, sdk_classes_only=False,
                symbol_aliases=False, patch_methtype=False):
    """整包两阶段：收集全局映射 →（可选）统一写入。"""
    sdk_prefixes = sdk_prefixes or []
    bins = list_app_machos(app_path)
    if not bins:
        print("  [skip] .app 内无 Mach-O: %s" % app_path)
        return 0, 0

    # 方法白名单：显式文件 ∪ 全包 SDK methname 并集
    allow = set(method_allowlist) if method_allowlist is not None else None
    if do_methods and sdk_prefixes:
        if allow is None:
            allow = set()
        for p in bins:
            buf = _read(p)
            slices = _slices(buf)
            if not slices:
                continue
            allow |= _collect_sdk_methnames(buf, slices, sdk_prefixes, min_len)
        print("  全包 SDK 方法候选: %d" % len(allow))
    method_allowlist = allow

    class_names = set()
    meth_names = set()
    scrub_names = set()
    protected_any = {}

    for p in bins:
        buf = _read(p)
        slices = _slices(buf)
        if not slices:
            continue
        cstring_names = _collect_cstring_names(buf, slices)
        cls, meth, prot = _collect_objc_candidates(
            buf, slices, do_classes, do_methods, method_allowlist,
            cstring_names, min_len, aggressive, extra, sync_cstring,
            sdk_prefixes, sdk_classes_only=sdk_classes_only)
        class_names |= cls
        meth_names |= meth
        protected_any.update(prot)
        if scrub_cstring and sdk_prefixes:
            # 不从 Dart AOT 收集 scrub 目标；channel 指纹应在编译期处理
            if not _is_dart_aot_macho(p):
                scrub_names |= _collect_scrub_strings(
                    buf, slices, sdk_prefixes, min_len)

    class_map = {n: _rename_same_length(n, seed) for n in class_names}
    meth_map = {n: _rename_same_length(n, seed) for n in meth_names}
    scrub_map = {n: _rename_same_length(n, seed) for n in scrub_names}

    print("  二进制=%d  类映射=%d  方法映射=%d  scrub映射=%d  sync=%s scrub=%s sdk-classes-only=%s" %
          (len(bins), len(class_map), len(meth_map), len(scrub_map),
           sync_cstring, scrub_cstring, sdk_classes_only))

    # 一致性摘要
    sdk_cls = [n for n in class_map if _matches_sdk_prefix(n, sdk_prefixes)]
    sdk_meth = [n for n in meth_map if _matches_sdk_prefix(n, sdk_prefixes)
                or (":" in n and "RCIMIW" in n)]
    print("  其中 SDK 类=%d  SDK 方法=%d  channel/回调键≈%d" %
          (len(sdk_cls), len(sdk_meth), len(scrub_map)))
    for n in (sdk_cls + sdk_meth)[:15]:
        m = class_map.get(n) or meth_map.get(n)
        print("    map: %s -> %s" % (n, m))
    if scrub_map:
        for n in list(scrub_map)[:8]:
            print("    scrub: %s -> %s" % (n, scrub_map[n]))

    if not do_apply:
        if map_out:
            with open(map_out, "w", encoding="utf-8") as f:
                json.dump({
                    "seed": seed,
                    "mode": "scan-app",
                    "binaries": bins,
                    "class_map": class_map,
                    "meth_map": meth_map,
                    "scrub_map": scrub_map,
                }, f, ensure_ascii=False, indent=2)
        return len(class_map) + len(meth_map) + len(scrub_map), len(protected_any)

    totals = {
        "objc_sites": 0, "cstring_synced": 0, "cstring_scrubbed": 0,
        "const_scrubbed": 0, "methtype_patched": 0, "debug_patched": 0,
        "ivar_patched": 0, "whole_file_spans": 0,
    }
    for p in bins:
        rel = p
        if p.startswith(app_path):
            rel = p[len(app_path):].lstrip("/")
        print("  apply %s" % rel)
        st = _apply_mapping_to_binary(
            p, seed, class_map, meth_map, scrub_map,
            sync_cstring, scrub_cstring, sdk_prefixes, min_len,
            symbol_aliases=symbol_aliases, patch_methtype=patch_methtype)
        if st.get("skip"):
            print("    [skip]")
            continue
        for k in totals:
            totals[k] += st.get(k, 0)
        print("    objc=%d sync=%d scrub=%d const=%d methtype=%d debug=%d ivar=%d file=%d" %
              (st["objc_sites"], st["cstring_synced"], st["cstring_scrubbed"],
               st["const_scrubbed"], st["methtype_patched"],
               st.get("debug_patched", 0), st.get("ivar_patched", 0),
               st.get("whole_file_spans", 0)))

    print("  ✓ 全包合计 objc=%d sync=%d scrub=%d const=%d methtype=%d debug=%d ivar=%d file_spans=%d" %
          (totals["objc_sites"], totals["cstring_synced"],
           totals["cstring_scrubbed"], totals["const_scrubbed"],
           totals["methtype_patched"], totals["debug_patched"],
           totals["ivar_patched"], totals["whole_file_spans"]))

    if map_out:
        with open(map_out, "w", encoding="utf-8") as f:
            json.dump({
                "seed": seed,
                "mode": "apply-app",
                "binaries": bins,
                "class_map": class_map,
                "meth_map": meth_map,
                "scrub_map": scrub_map,
                "totals": totals,
            }, f, ensure_ascii=False, indent=2)
    return totals["objc_sites"], len(protected_any)


def main():
    ap = argparse.ArgumentParser(description="Mach-O ObjC 符号就地等长混淆")
    ap.add_argument("mode", choices=["scan", "apply", "scan-app", "apply-app"])
    ap.add_argument("binary", help="Mach-O 路径，或 .app 路径（*-app 模式）")
    ap.add_argument("--seed", default="")
    ap.add_argument("--min-len", type=int, default=4)
    ap.add_argument("--aggressive", action="store_true",
                    help="放宽保护（跳过 __cstring/下划线保护），风险更高；"
                         "更推荐用 --sync-cstring 保持动态查找一致")
    ap.add_argument("--classes", action="store_true", help="改类名")
    ap.add_argument("--methods", action="store_true", help="改方法名（需 allowlist/sdk）")
    ap.add_argument("--protect-file", default="",
                    help="额外保护名清单（每行一个）")
    ap.add_argument("--methods-allowlist", default="",
                    help="方法名改名白名单文件（每行一个）")
    ap.add_argument("--sdk-prefixes", default="",
                    help="逗号分隔 SDK 前缀（如 RCIMIW,RCIMWrapper,IRCIMIW,RC）")
    ap.add_argument("--sync-cstring", action="store_true",
                    help="同步改写 __cstring 中与类名/方法名相同的字面量")
    ap.add_argument("--scrub-cstring", action="store_true",
                    help="擦除 RCIMIW channel/回调键（cstring+__const）；"
                         "务必用 apply-app 整包执行")
    ap.add_argument("--sdk-classes-only", action="store_true",
                    help="仅改 SDK 前缀类名（更稳，推荐与 --sdk-prefixes 同用）")
    ap.add_argument("--symbol-aliases", action="store_true",
                    help="同步改 _OBJC_CLASS_$_ / _objc_msgSend$ 符号名（易导致 dyld 闪退，默认关）")
    ap.add_argument("--patch-methtype", action="store_true",
                    help="同步改 __objc_methtype 里的 @\"Class\"（默认关）")
    ap.add_argument("--map-out", default="")
    args = ap.parse_args()

    app_mode = args.mode.endswith("-app")
    do_apply = args.mode.startswith("apply")

    if do_apply and not args.seed:
        print("错误: apply 模式必须提供 --seed", file=sys.stderr)
        return 2

    do_classes = args.classes or not (args.classes or args.methods)
    do_methods = bool(args.methods)

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
    sdk_prefixes = _parse_prefixes(args.sdk_prefixes)

    method_allowlist = None
    if do_methods and args.methods_allowlist:
        method_allowlist = _load_list(args.methods_allowlist)
    elif do_methods and sdk_prefixes:
        method_allowlist = set()

    if app_mode:
        if not os.path.isdir(args.binary):
            print("错误: apply-app/scan-app 需要 .app 目录", file=sys.stderr)
            return 2
        changed, protected = process_app(
            args.binary, do_apply, args.seed, args.min_len,
            args.aggressive, do_classes, do_methods, extra, args.map_out,
            method_allowlist, sync_cstring=args.sync_cstring,
            sdk_prefixes=sdk_prefixes, scrub_cstring=args.scrub_cstring,
            sdk_classes_only=args.sdk_classes_only,
            symbol_aliases=args.symbol_aliases,
            patch_methtype=args.patch_methtype)
        print("  ✓ app 模式完成: sites/candidates≈%d  protected记录=%d" %
              (changed, protected))
        return 0

    # 单二进制
    if sdk_prefixes and args.methods and method_allowlist is None:
        method_allowlist = set()

    changed, protected = process(
        args.binary, do_apply, args.seed, args.min_len,
        args.aggressive, do_classes, do_methods, extra, args.map_out,
        method_allowlist, sync_cstring=args.sync_cstring,
        sdk_prefixes=sdk_prefixes, scrub_cstring=args.scrub_cstring)

    if do_apply:
        print("  ✓ %s: 改写 %d 处，跳过保护 %d" %
              (args.binary, changed, protected))
    return 0


if __name__ == "__main__":
    sys.exit(main())
