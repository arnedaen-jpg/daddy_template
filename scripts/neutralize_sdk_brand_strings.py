#!/usr/bin/env python3
"""等长中和 Mach-O 中 SDK 品牌指纹串（what-string + 安全 cstring）。

处理（仅 __cstring / __oslogstring / __const）：
  1) (#)PROGRAM:…PROJECT:… 中的 Rong* 片段
  2) 完整 NUL 结尾的 cn.rongcloud.* / com.rongcloud.* 队列/日志标签
  3) 白名单日志文件名 / 本地缓存名 / 日志前缀（非整类名、非域名、非路径）
  4) L282 高风险：RC*/kRC*Notification 通知名等长改写（跨串一致 seed）
  5) L283 高风险：本地存储 Key、/io.rongcloud、Rong* 产品名等长改写
  6) L284 部分回退：禁止改 /RongCloud、短标识 RCIM/RCCore、engine_cb/engine channel

不碰：
  - __LINKEDIT 绑定符号（_OBJC_CLASS_$_ / _objc_msgSend$ 等）——但会改其中的 RongCloud 品牌片段
  - 说明：L290+ SYMTAB/DYLD_INFO 内 N9RongCloud；L293 起对 brand parts 做上下文安全等长改写
  - ObjC 类名 / 协议名 / methname / SYMBOL_ALIASES（整符）
  - 域名 rongcloud.net、路径 /RongCloud、HTTP 头 RC-App-Key / RC-Token
  - Flutter engine: / engine_cb: channel 与回调键
  - ExtensionModule / ExtensionManager（NSClassFromString / CSV）
  - 协议 objectName（RC:TxtMsg 等）与 RCSendMessage 等线协议命令名
  - 短标识 RCIM / RCCore / RCChannel

用法:
    neutralize_sdk_brand_strings.py [--seed S] <binary> [<binary> ...]
"""
from __future__ import annotations

import hashlib
import re
import struct
import sys

LC_SEGMENT_64 = 0x19
SAFE_SECTS = {b"__cstring", b"__oslogstring", b"__const"}
CSTRING_ONLY = {b"__cstring", b"__oslogstring"}
CLASSNAME_SECTS = {b"__objc_classname"}
# L293：类型编码里的 RongCloud:: / VersionNumber 等
BRAND_PART_SECTS = SAFE_SECTS | {b"__objc_methtype", b"__objc_methname"}

# Pods 空壳类名里的 SDK 痕迹（无业务引用，可安全等长改）
_PODSDUMMY_RONG_RE = re.compile(rb"PodsDummy_[A-Za-z0-9_]*Rong[A-Za-z0-9_]*")

_BRAND_PARTS = sorted(
    [
        b"RongIMLibCore",
        b"RongIMWrapper",
        b"RongChatRoom",
        b"RongIMLib",
        b"RongIMKit",
        b"RongSight",
        b"RongCloud",
        b"RongCall",
        b"RongRTC",
    ],
    key=len,
    reverse=True,
)

_WHAT_RE = re.compile(rb"\(#[^\x00]*PROGRAM:[^\x00]{0,200}")
_QUEUE_LABEL_RE = re.compile(
    rb"(?:cn|com)\.rongcloud\.[A-Za-z0-9_.\-]+"
)

# 完整 cstring 白名单：日志/本地临时名/产品展示标签，非网络、非 ObjC 类
_SAFE_EXACT = {
    b"rong_debug.log",
    b"rong_sdk_timing.log",
    b"rong_sdk_full.log",
    b"rong_sdk_query_uid_list.log",
    b"rong_sdk_query_msg_content.log",
    b"rongcloud_video",
    b"rongcloud_video_%lld.mp4",
    b"rongcloudsystem",
    b"RongCloudKit",
    b"cn.rong.netdetect",
    b"Rong",  # 单独日志 tag
    b"5.36.4",  # SDK 版本字面量（等长扰动）
    # 运行时本地文件/缓存名（不在包内，仅 Documents 路径）
    b"RCFileRelation.plist",
    b"RongPushPersist.plist",
    b"RCSightCache",
    b"RCCloudConfigurationTimeStampKey",
    b"RCCloudConfigurationTimeOfCloudKey",
    b"RCCloudAreaCodeCachedName",
    b"RCCountlyLastUploadMetricDay",
    b"RongIMLib ",  # 产品展示标签（尾部空格）
    # L275：pthread 显示名（仅日志/调试，非符号）
    b"Thread_RCLogRouter",
    b"Thread_RCClientImpl",
    b"Thread_RCLog",
    b"Thread_RCSocket",
    # L276：Countly 分析本地键（非 IM 协议）
    b"RCCountlyPersistHelperDataKey",
    b"RCCountlyPersistHelperTimeKey",
    b"RCCountlyOpenID",
    # L277：本地 App UUID 存储键（非网络头）
    b"RC_APP_UUID",
    # L282 高风险：本地日志目录段（非 /RongCloud 数据路径）
    b"/rong_log/",
    # L283 高风险：sandbox 路径段 / UserDefaults / 常量
    b"/io.rongcloud",
    b"RC_NAVIDATAINFO_KEY",
    b"RC_NAVIDATAINFO_TOKEN",
    b"RC_NAVIDATAINFO_V2",
    b"RC_NAVIDATAINFO_TIMESTAMP",
    b"RCLibSecretChatMessageExtraKey",
    b"RCIMNotificationDataContextNotificationLevelUpdate",
    # L283 高风险：SDK 产品名（非 ExtensionModule 类名）
    b"RongCustomerService",
    b"RongChatRoom",
    b"RongRTCLib",
    b"RongCallKit",
    b"RongPublicService",
    b"RongContactCard",
    b"RongSticker",
    b"RongLocation",
    b"RongDiscussion",
    b"RongIMKit",
    b"RongSight",
    b"RongCallLib",
    b"RongiFlyKit",
    b"RongIMLibCore",
    b"RongCloud",
    # L284 回退：/RongCloud 本地数据路径、短标识 RCIM/RCCore 等会导致聊天室连不上
    # （见 debug session f982cc H1/H2）；仅保留下方相对安全的长本地名
    b"RCCoreSignalHandler",
    b"RCCoreUncaughtExceptionHandler",
    b"RCEnvironmentChangeNotify",
    b"RC_Ext_StreamMsgSummary",
    # L287：较长本地/展示名（非线协议命令、非短服务键）
    b"RongCloudController",
    b"RCCallPlusClient",
    b"RongRTCExtensionManager",
    b"RCTimingLogContextCacheKey",
}

# 完整 cstring：dispatch queue 标签（RC*_*Queue）
_QUEUE_LABEL_EXACT_RE = re.compile(rb"RC[A-Za-z0-9_]+_Queue")

# L282 高风险：NSNotification 名（须以 Notification 结尾；不含 Listener）
_NOTIFICATION_NAME_RE = re.compile(rb"(?:k)?RC[A-Za-z0-9_]*Notification\Z")

# L283：RC_XXX 全大写存储键（排除 Get/Set 方法名）
_STORAGE_KEY_RE = re.compile(rb"RC_[A-Z][A-Z0-9_]+\Z")

# L284 回退：不再用宽泛 Handler/Delegate/Manager 正则（易误伤运行时查找）
# 长字面量内可等长替换的片段（日志前缀等）
_SAFE_SUBSTR = sorted(
    [
        b"[Rong] Warnning:",  # 拼写错误保留长度
        b"[Rong]",
        b"loadRongExtensionModule",  # 仅日志串；methname 不动
        b"RCBDHttpDns ",  # HttpDNS 日志前缀
        b"RCFwLog,",  # 日志标签
        b"/RCSightCache/",  # 本地视频缓存路径段
        b"/RCImageCache",  # 本地图片缓存路径段
        # L274：括号日志标签（含冒号，_LOG_TOKEN_RE 匹配不到）
        b"[RCMessageMapper init]",
        b"[RC:BurnMessage]",
        b"[RC:HTTPDNS]",
        b"[RC:%@]",
        b"] [RC:",
        # L275：日志句内的 RC: 标签（勿动孤立 objectName）
        b"RC:Delivered json",
    ],
    key=len,
    reverse=True,
)

_LOG_HINTS = (
    b"%", b"error", b"Error", b"failed", b"Failed", b"dealloc",
    b"exception", b"nil", b"callback", b"Warnning", b"Warning",
    b" log", b"Log",
    b" class not found", b"destroyModule", b"setAppKey",
    # L274：更多断言/文档式日志
    b"forbiden", b"singleton", b"json is not", b"Use - (",
    b"contain non-", b"[RC:", b"subclass of ",
    # L275：连接/回执类日志
    b"Returning ", b"Receive repost", b"receive ",
    b" is not ", b"msg pull", b"Reset RMTP",
    # L284 回退：不再用 Download/Status/Event 等宽启发式（会误伤 engine_cb）
)
# RCXxx / RongXxx，或日志错误码 RC_CONN_*（不含 RC-App-Key）
_LOG_TOKEN_RE = re.compile(
    rb"\b(?:RC|Rong)(?:[A-Za-z][A-Za-z0-9_]{2,}|_[A-Z][A-Z0-9_]{2,})\b"
)
# 日志里也不要动的域名/路径碎片
_LOG_TOKEN_DENY = {
    b"RongCloud",  # 可能与路径/产品混用；路径另案处理
}


def _log_token_denied(tok: bytes) -> bool:
    if tok in _LOG_TOKEN_DENY:
        return True
    # SQL 表/索引前缀：RCT_MESSAGE / RCI_* 等，改写会毁库
    if tok.startswith((b"RCT_", b"RCI_", b"RCPS_")):
        return True
    # Flutter/ObjC 桥接类名前缀：改写会毁 engine_cb
    if tok.startswith((b"RCIMIW", b"IRCIMIW", b"RCIMWrapper")):
        return True
    return False


def _rename_same_length(name: bytes, seed: str) -> bytes:
    h = hashlib.sha1((seed + "|" + name.decode("latin1")).encode("utf-8")).digest()
    charset = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    out = bytearray()
    hi = 0
    for ch in name:
        if (ord("A") <= ch <= ord("Z") or ord("a") <= ch <= ord("z")
                or ord("0") <= ch <= ord("9") or ch == ord("_") or ch == ord(".")):
            if ch == ord("."):
                out.append(ch)
            else:
                c = charset[h[hi % len(h)] % len(charset)]
                out.append(c)
                hi += 1
        else:
            out.append(ch)
    return bytes(out)


def _slices(data: bytes):
    magic = struct.unpack_from(">I", data, 0)[0]
    if magic == 0xCAFEBABE:
        narch = struct.unpack_from(">I", data, 4)[0]
        out = []
        for i in range(narch):
            _cputype, _cpusub, off, size, _align = struct.unpack_from(
                ">IIIII", data, 8 + i * 20
            )
            out.append((off, size))
        return out
    return [(0, len(data))]


def _safe_ranges(slice_data: bytes, sect_filter=None):
    if len(slice_data) < 32:
        return []
    if isinstance(slice_data, bytearray):
        slice_data = bytes(slice_data)
    if struct.unpack_from("<I", slice_data, 0)[0] != 0xFEEDFACF:
        return []
    allow = sect_filter or SAFE_SECTS
    ncmds = struct.unpack_from("<I", slice_data, 16)[0]
    off = 32
    ranges = []
    for _ in range(ncmds):
        if off + 8 > len(slice_data):
            break
        cmd, cmdsize = struct.unpack_from("<II", slice_data, off)
        if cmdsize == 0:
            break
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from("<I", slice_data, off + 64)[0]
            so = off + 72
            for _s in range(nsects):
                sn = bytes(slice_data[so : so + 16].split(b"\0", 1)[0])
                if sn in allow:
                    ssize = struct.unpack_from("<Q", slice_data, so + 40)[0]
                    soff = struct.unpack_from("<I", slice_data, so + 48)[0]
                    if ssize and soff + ssize <= len(slice_data):
                        ranges.append((soff, ssize, sn))
                so += 80
        off += cmdsize
    return ranges


def _patch_what_blob(blob: bytearray, seed: str) -> int:
    n = 0
    for m in list(_WHAT_RE.finditer(blob)):
        seg = bytearray(m.group(0))
        if b"Rong" not in seg and b"rong" not in seg:
            continue
        changed = False
        for brand in _BRAND_PARTS:
            if brand not in seg:
                continue
            rep = _rename_same_length(brand, seed)
            if len(rep) != len(brand):
                continue
            start = 0
            while True:
                i = seg.find(brand, start)
                if i < 0:
                    break
                seg[i : i + len(brand)] = rep
                changed = True
                start = i + len(brand)
        if changed and len(seg) == (m.end() - m.start()):
            blob[m.start() : m.end()] = seg
            n += 1
    return n


def _iter_cstr_spans(blob: bytes):
    i = 0
    n = len(blob)
    while i < n:
        if blob[i] == 0:
            i += 1
            continue
        j = blob.find(b"\0", i)
        if j < 0:
            break
        yield i, j
        i = j + 1


def _looks_like_network_host(s: bytes) -> bool:
    """拒绝 API/域名类字面量（保留队列标签）。"""
    if b"://" in s or b"/" in s or b" " in s:
        return True
    # 纯域名：rongcloud.net / xxx.rongcloud.cn（无 Queue/log 语义）
    if s.endswith((b".net", b".cn", b".com", b".io")) and b"Queue" not in s \
            and b"queue" not in s and b"log" not in s and b"Log" not in s:
        # com.rongcloud.xxx 不是域名
        if s.startswith((b"com.rongcloud.", b"cn.rongcloud.")):
            return False
        return True
    return False


def _patch_queue_labels(blob: bytearray, seed: str) -> int:
    """等长改写 cn./com.rongcloud.* 队列/子系统标签。"""
    n = 0
    for start, end in list(_iter_cstr_spans(blob)):
        s = bytes(blob[start:end])
        if not (s.startswith(b"cn.rongcloud.") or s.startswith(b"com.rongcloud.")):
            continue
        if _looks_like_network_host(s):
            continue
        if not _QUEUE_LABEL_RE.fullmatch(s):
            continue
        rep = _rename_same_length(s, seed)
        if len(rep) != len(s) or rep == s:
            continue
        blob[start:end] = rep
        n += 1
    return n


def _is_exact_candidate(s: bytes) -> bool:
    if s in _SAFE_EXACT:
        return True
    if _QUEUE_LABEL_EXACT_RE.fullmatch(s):
        return True
    if _NOTIFICATION_NAME_RE.fullmatch(s):
        return True
    if _STORAGE_KEY_RE.fullmatch(s):
        return True
    return False


def _patch_safe_exact(blob: bytearray, seed: str) -> int:
    n = 0
    for start, end in list(_iter_cstr_spans(blob)):
        s = bytes(blob[start:end])
        if not _is_exact_candidate(s):
            continue
        rep = _rename_same_length(s, seed)
        if len(rep) != len(s) or rep == s:
            continue
        blob[start:end] = rep
        n += 1
    return n


def _patch_extension_module_products(blob: bytearray, seed: str) -> int:
    """仅在 ExtensionModule CSV 内等长替换 Rong* 产品名片段，不改 RC*ExtensionModule 类名。"""
    products = [
        b"RongCustomerService",
        b"RongChatRoom",
        b"RongRTCLib",
        b"RongCallKit",
        b"RongPublicService",
        b"RongContactCard",
        b"RongSticker",
        b"RongLocation",
        b"RongDiscussion",
        b"RongIMKit",
        b"RongSight",
        b"RongCallLib",
        b"RongiFlyKit",
        b"RongIMLibCore",
        b"RongCloud",
    ]
    n = 0
    for start, end in list(_iter_cstr_spans(blob)):
        raw = bytes(blob[start:end])
        if b"ExtensionModule" not in raw or b"," not in raw:
            continue
        if not any(p in raw for p in products):
            continue
        s = bytearray(raw)
        changed = False
        for old in products:
            if old not in s:
                continue
            rep = _rename_same_length(old, seed)
            if len(rep) != len(old):
                continue
            pos = 0
            while True:
                i = s.find(old, pos)
                if i < 0:
                    break
                # 避免改写更长标识符中的子串（前后须为分隔或边界）
                before_ok = i == 0 or s[i - 1] in b", "
                after = i + len(old)
                after_ok = after >= len(s) or s[after] in b", "
                if before_ok and after_ok:
                    s[i : after] = rep
                    changed = True
                pos = after
        if changed and len(s) == (end - start):
            blob[start:end] = s
            n += 1
    return n


def _patch_safe_substr(blob: bytearray, seed: str) -> int:
    """在 cstring 内替换安全片段（如日志前缀 [Rong] / RCBDHttpDns ）。"""
    n = 0
    for start, end in list(_iter_cstr_spans(blob)):
        s = bytearray(blob[start:end])
        # 任一白名单片段命中才处理（勿仅用 Rong/rong 过滤，否则漏掉 RCBDHttpDns）
        if not any(old in s for old in _SAFE_SUBSTR):
            continue
        changed = False
        for old in _SAFE_SUBSTR:
            if old not in s:
                continue
            rep = _rename_same_length(old, seed)
            if len(rep) != len(old):
                continue
            pos = 0
            while True:
                i = s.find(old, pos)
                if i < 0:
                    break
                s[i : i + len(old)] = rep
                changed = True
                pos = i + len(old)
        if changed and len(s) == (end - start):
            blob[start:end] = s
            n += 1
    return n


def _looks_like_sql(s: bytes) -> bool:
    """SQLite DDL/DML：绝不能当日志改写（含 LIKE '%…' 会被 % hint 误伤）。"""
    u = s.upper()
    if u.startswith((
        b"SELECT ", b"INSERT ", b"UPDATE ", b"DELETE ", b"CREATE ",
        b"ALTER ", b"REPLACE ", b"DROP ", b"PRAGMA ", b"WITH ",
    )):
        return True
    if b" RCT_" in s or b" RCI_" in s or s.startswith((b"RCT_", b"RCI_")):
        return True
    if b" FROM RCT_" in u or b" INTO RCT_" in u or b" TABLE RCT_" in u:
        return True
    if b" FROM RCI_" in u or b" INTO RCI_" in u or b" TABLE RCI_" in u:
        return True
    return False


def _is_log_like(s: bytes) -> bool:
    if b'@"' in s and b"@?" in s:
        # ObjC type encoding / block signature，非日志
        return False
    if _looks_like_sql(s):
        return False
    if s.startswith(b"-[") or s.startswith(b"+["):
        # 选方法调试串，可当日志处理
        return True
    return any(h in s for h in _LOG_HINTS)


def _is_bare_ident(s: bytes) -> bool:
    return bool(re.fullmatch(rb"[A-Za-z_][A-Za-z0-9_]*", s))


def _patch_log_sdk_tokens(blob: bytearray, seed: str) -> int:
    """仅在日志/断言类 cstring 内，等长替换 RC*/Rong* 标识符。

    不碰：纯类名表、域名、@"Class" 类型编码、模块名列表、SQL、
    线协议命令名（裸标识符 / pipe 别名表）。
    """
    n = 0
    # 缓存同名映射，保证本文件内一致
    cache: dict[bytes, bytes] = {}
    for start, end in list(_iter_cstr_spans(blob)):
        raw = bytes(blob[start:end])
        if _looks_like_sql(raw):
            continue
        if _is_bare_ident(raw) or b"|" in raw:
            continue
        # Flutter channel / callback keys — never rewrite
        if raw.startswith((b"engine_cb:", b"engine:")):
            continue
        if not _is_log_like(raw):
            continue
        if b"RC" not in raw and b"Rong" not in raw:
            continue
        # 扩展模块名 CSV（动态加载）
        if b"ExtensionModule" in raw and b"," in raw:
            continue
        s = bytearray(raw)
        changed = False
        # 从右向左替换，避免偏移错乱
        matches = list(_LOG_TOKEN_RE.finditer(bytes(s)))
        for m in reversed(matches):
            tok = m.group(0)
            if _log_token_denied(tok):
                continue
            # 过短或全大写缩写
            if len(tok) < 5:
                continue
            if tok not in cache:
                cache[tok] = _rename_same_length(tok, seed)
            rep = cache[tok]
            if len(rep) != len(tok) or rep == tok:
                continue
            s[m.start() : m.end()] = rep
            changed = True
        if changed and len(s) == (end - start):
            blob[start:end] = s
            n += 1
    return n


def _patch_podsdummy_classname(blob: bytearray, seed: str) -> int:
    """等长改写 __objc_classname 中的 PodsDummy_*Rong*。"""
    n = 0
    for start, end in list(_iter_cstr_spans(blob)):
        s = bytes(blob[start:end])
        if b"PodsDummy_" not in s or b"Rong" not in s:
            continue
        if not _PODSDUMMY_RONG_RE.fullmatch(s):
            continue
        rep = _rename_same_length(s, seed)
        if len(rep) != len(s) or rep == s:
            continue
        blob[start:end] = rep
        n += 1
    return n


def _patch_mangled_rongcloud(blob: bytearray, seed: str) -> int:
    """等长改写 Itanium 修饰名片段 N9RongCloud → N9<alias>（__const / cstring）。"""
    old = b"N9RongCloud"
    rep = b"N9" + _rename_same_length(b"RongCloud", seed)
    if len(rep) != len(old) or rep == old:
        return 0
    n = 0
    start = 0
    while True:
        i = blob.find(old, start)
        if i < 0:
            break
        blob[i : i + len(old)] = rep
        n += 1
        start = i + len(old)
    return n


def _brand_context_blocked(blob: bytearray, off: int, brand_len: int) -> bool:
    """路径 /RongCloud、Extension*、engine channel 等上下文禁止改 brand。"""
    if off > 0 and blob[off - 1 : off] == b"/":
        return True
    lo = max(0, off - 80)
    hi = min(len(blob), off + brand_len + 80)
    win = bytes(blob[lo:hi])
    if b"Extension" in win:
        return True
    if b"engine_cb" in win or b"engine:" in win:
        return True
    if b"rongcloud.net" in win or b"RC-App-Key" in win or b"RC-Token" in win:
        return True
    # 短标识邻接保护
    if b"\x00RCIM\x00" in win or b"\x00RCCore\x00" in win or b"\x00RCChannel\x00" in win:
        # 仍允许改窗口内其它 brand，只要命中点本身不是短标识
        pass
    return False


def _patch_brand_parts_safe(blob: bytearray, seed: str) -> int:
    """等长改写 _BRAND_PARTS（最长优先），跳过 /RongCloud 与 Extension* 上下文。

    覆盖 __ZNK9RongCloud… / _RongIMLibCoreVersionNumber 等残留指纹。
    """
    n = 0
    for brand in _BRAND_PARTS:
        rep = _rename_same_length(brand, seed)
        if len(rep) != len(brand) or rep == brand:
            continue
        start = 0
        while True:
            i = blob.find(brand, start)
            if i < 0:
                break
            if _brand_context_blocked(blob, i, len(brand)):
                start = i + len(brand)
                continue
            blob[i : i + len(brand)] = rep
            n += 1
            start = i + len(brand)
    return n


LC_SYMTAB = 0x2
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x80000022


def _symtab_strtab_ranges(slice_data: bytes):
    """返回相对 slice 的 (soff, ssize)；若 stroff 为文件绝对偏移则调用方再校正。"""
    if len(slice_data) < 32:
        return []
    if struct.unpack_from("<I", slice_data, 0)[0] != 0xFEEDFACF:
        return []
    ncmds = struct.unpack_from("<I", slice_data, 16)[0]
    off = 32
    out = []
    for _ in range(ncmds):
        if off + 8 > len(slice_data):
            break
        cmd, cmdsize = struct.unpack_from("<II", slice_data, off)
        if cmdsize == 0:
            break
        if cmd == LC_SYMTAB and off + 24 <= len(slice_data):
            stroff = struct.unpack_from("<I", slice_data, off + 16)[0]
            strsize = struct.unpack_from("<I", slice_data, off + 20)[0]
            out.append((stroff, strsize))
        off += cmdsize
    return out


def _dyld_info_blob_ranges(slice_data: bytes):
    """L291：DYLD_INFO 的 bind/export 等区域内可能残留 N9RongCloud 字面量。"""
    if len(slice_data) < 32:
        return []
    if struct.unpack_from("<I", slice_data, 0)[0] != 0xFEEDFACF:
        return []
    ncmds = struct.unpack_from("<I", slice_data, 16)[0]
    off = 32
    out = []
    for _ in range(ncmds):
        if off + 8 > len(slice_data):
            break
        cmd, cmdsize = struct.unpack_from("<II", slice_data, off)
        if cmdsize == 0:
            break
        if cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY) and off + 48 <= len(slice_data):
            # rebase/bind/weak_bind/lazy_bind/export — 各 off+size @ +8
            for i in range(5):
                doff, dsize = struct.unpack_from("<II", slice_data, off + 8 + i * 8)
                if dsize:
                    out.append((doff, dsize))
        off += cmdsize
    return out


def _patch_podsdummy_bytes(blob: bytearray, seed: str) -> int:
    """任意 blob 内等长改写 PodsDummy_*Rong*。"""
    n = 0
    for m in list(_PODSDUMMY_RONG_RE.finditer(bytes(blob))):
        old = m.group(0)
        rep = _rename_same_length(old, seed)
        if len(rep) != len(old) or rep == old:
            continue
        blob[m.start() : m.end()] = rep
        n += 1
    return n


def _patch_linkedit_brand_blobs(data: bytearray, slice_off: int, slice_bytes: bytes,
                                seed: str, ranges) -> int:
    """对 SYMTAB/DYLD_INFO 等文件偏移区间做 N9/PodsDummy 等长改写。"""
    total = 0
    for stroff, strsize in ranges:
        candidates = []
        for abs_off in (slice_off + stroff, stroff):
            if abs_off >= 0 and abs_off + strsize <= len(data):
                candidates.append(abs_off)
        seen = set()
        chosen = None
        for abs_off in candidates:
            if abs_off in seen:
                continue
            seen.add(abs_off)
            probe = bytes(data[abs_off : abs_off + min(strsize, 1 << 20)])
            if b"N9RongCloud" in probe or b"PodsDummy_" in probe or chosen is None:
                chosen = abs_off
                if b"N9RongCloud" in probe or b"PodsDummy_" in probe:
                    break
        if chosen is None:
            continue
        blob = bytearray(data[chosen : chosen + strsize])
        c = _patch_mangled_rongcloud(blob, seed)
        c += _patch_brand_parts_safe(blob, seed)
        c += _patch_podsdummy_bytes(blob, seed)
        if c:
            data[chosen : chosen + strsize] = blob
            total += c
    return total



def neutralize(path: str, seed: str) -> int:
    with open(path, "rb") as f:
        data = bytearray(f.read())
    total = 0
    for slice_off, slice_size in _slices(data):
        slice_bytes = data[slice_off : slice_off + slice_size]
        for soff, ssize, sn in _safe_ranges(
                slice_bytes, SAFE_SECTS | CLASSNAME_SECTS | BRAND_PART_SECTS):
            abs_off = slice_off + soff
            blob = bytearray(data[abs_off : abs_off + ssize])
            c = 0
            if sn in SAFE_SECTS:
                c += _patch_what_blob(blob, seed)
                c += _patch_mangled_rongcloud(blob, seed)
                c += _patch_brand_parts_safe(blob, seed)
                c += _patch_podsdummy_bytes(blob, seed)
            elif sn in BRAND_PART_SECTS:
                # methname/methtype：只做 brand parts，避免动 selector/通知逻辑
                c += _patch_brand_parts_safe(blob, seed)
            if sn in CSTRING_ONLY:
                c += _patch_queue_labels(blob, seed)
                c += _patch_safe_exact(blob, seed)
                c += _patch_extension_module_products(blob, seed)
                c += _patch_safe_substr(blob, seed)
                c += _patch_log_sdk_tokens(blob, seed)
            if sn in CLASSNAME_SECTS:
                c += _patch_podsdummy_classname(blob, seed)
            if c:
                data[abs_off : abs_off + ssize] = blob
                total += c
        # L290/L291：SYMTAB + DYLD_INFO(bind/export) 内 N9RongCloud / PodsDummy
        # 不碰 _OBJC_CLASS_$_ / _objc_msgSend$（SYMBOL_ALIASES 已验证启动失败）
        total += _patch_linkedit_brand_blobs(
            data, slice_off, slice_bytes, seed,
            list(_symtab_strtab_ranges(slice_bytes))
            + list(_dyld_info_blob_ranges(slice_bytes)))
    if total:
        with open(path, "wb") as f:
            f.write(data)
    return total


def main(argv: list[str]) -> int:
    seed = "sdk-brand"
    args = argv[1:]
    if args and args[0] == "--seed":
        seed = args[1]
        args = args[2:]
    if not args:
        print("usage: neutralize_sdk_brand_strings.py [--seed S] <binary>...",
              file=sys.stderr)
        return 2
    total = 0
    for p in args:
        try:
            c = neutralize(p, seed)
        except Exception as e:
            print(f"{p}: 跳过 ({e})")
            continue
        total += c
        if c:
            print(f"{p}: {c}")
    print(f"TOTAL sdk-brand strings neutralized: {total}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
