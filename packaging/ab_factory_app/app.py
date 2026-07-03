#!/usr/bin/env python3
"""
AB 包工厂 v6.6 — macOS 原生应用
步骤式创建 AB 包项目、同步 B 面代码、添加 A 面、混淆、打包 IPA
（与 ~/daddy_template 脚本及 docs/AB_MAKE.md、AGENTS.md 约定对齐）
"""

import os
import sys
import json
import glob
import signal
import shutil
import subprocess
import threading
import re
import shlex
import random
import warnings
from datetime import datetime

import objc
import Quartz
from AppKit import (
    NSApplication, NSApp, NSWindow, NSWindowStyleMaskTitled,
    NSWindowStyleMaskClosable, NSWindowStyleMaskResizable,
    NSWindowStyleMaskMiniaturizable, NSBackingStoreBuffered,
    NSView, NSTextField, NSButton, NSBezelStyleRounded,
    NSProgressIndicator, NSProgressIndicatorStyleSpinning,
    NSFont, NSColor, NSScrollView, NSTextView,
    NSApplicationActivationPolicyRegular, NSOpenPanel, NSSavePanel,
    NSPopUpButton, NSBox, NSOperationQueue, NSScreen,
    NSMenu, NSMenuItem,
    NSWorkspace, NSApplicationActivateIgnoringOtherApps,
)
from Foundation import NSObject, NSMakeRect, NSMakeSize, NSURL, NSAttributedString, NSDictionary, NSUserDefaults

ANSI_RE = re.compile(r'\x1b\[[0-9;]*m')

DEFAULT_TEMPLATE = os.path.join(os.path.expanduser("~"), "daddy_template")
DEFAULT_OUTPUT = "/Users/t-yh"
FLUTTER_BIN = os.path.expanduser("~/flutter/bin")
XCODE_DEV = "/Applications/Xcode.app/Contents/Developer"
FVM_FLUTTER_VERSION = "3.38.3"

PROJECT_CODES = [
    "dq", "lgt",
]
PROJECT_LABELS = {
    "dq": "dq — 斗球（直播）",
    "lgt": "lgt — 聊个天（IM）",
}

# 随机 Bundle ID 用本机系统英语词表（不内置词表）。常见路径见 APPLE_SYSTEM_DICT_PATHS。
APPLE_SYSTEM_DICT_PATHS = (
    "/usr/share/dict/words",
    "/usr/share/dict/web2",
    "/usr/share/dict/web2a",
)
_bundle_id_system_words = None  # lazy: tuple[str, ...] 或 () 表示已尝试但失败
_bundle_id_system_words_lock = threading.Lock()


def _load_bundle_id_words_from_system():
    """从本机词典文件加载可用于反向域名片段的单词（纯小写字母，长度有限）。"""
    global _bundle_id_system_words
    if _bundle_id_system_words is not None:
        return _bundle_id_system_words
    with _bundle_id_system_words_lock:
        if _bundle_id_system_words is not None:
            return _bundle_id_system_words
        collected = []
        for path in APPLE_SYSTEM_DICT_PATHS:
            if not os.path.isfile(path):
                continue
            chunk = []
            try:
                with open(path, "r", encoding="utf-8", errors="ignore") as f:
                    for line in f:
                        w = line.strip().lower()
                        # 与常见 Bundle 段习惯一致：仅 a–z，避免连字符/撇号等
                        if 3 <= len(w) <= 20 and w.isalpha():
                            chunk.append(w)
                if chunk:
                    collected = chunk
                    break
            except OSError:
                continue
        _bundle_id_system_words = tuple(collected) if collected else tuple()
        return _bundle_id_system_words


def generate_random_bundle_id():
    """
    生成 com.xxx.xxx：两段均从本机系统词典（如 /usr/share/dict/words）随机抽取。
    若无法读取系统词表，返回 None。
    """
    words = _load_bundle_id_words_from_system()
    if not words:
        return None
    a = random.choice(words)
    b = random.choice(words)
    for _ in range(64):
        if b != a:
            break
        b = random.choice(words)
    return f"com.{a}.{b}"


_state = {
    "is_running": False,
    "flutter_proc": None,
    "devices": [],
    "last_flutter_log": [],  # 最近一次 flutter run / pub get 的日志行，供「修Bug」交给 Cursor
    "crawl_stop": False,
    "crawl_running": False,
    "multi_pending_rel": [],  # 相对路径列表，如 ab_factory_pending/001.png
    "multi_cap_lock": False,  # 单张截图写入中，防连点
    "socks_proxy_urls": [],   # 与 cfg_proxy_popup 选项一一对应（不含首项占位）
}
PROXIFLY_US_PROXY_URL = (
    "https://raw.githubusercontent.com/proxifly/free-proxy-list/main/proxies/countries/US/data.json"
)
PROXIFLY_US_PROXY_MAX = 100  # 下拉最多展示条数（按 score 降序）
MAX_FLUTTER_LOG_LINES = 4000
MAX_MULTI_PENDING_SHOTS = 40

# 日志主线程合并 flush：避免子进程瞬间吐千行时, 主队列被同等数量的
# addOperationWithBlock_ 块淹没, 在 AppKit 的 KVO / 文本绘制路径上放大成
# ObjC↔Python 桥递归 (历史上崩溃栈里看到的 500 层 ffi_closure_unix64)。
_log_buffer = []
_log_buffer_lock = threading.Lock()
_log_flush_scheduled = False
LOG_FLUSH_DEBOUNCE_S = 0.05      # 50ms 攒一波再上主线程
LOG_FLUSH_FLOOD_LINES = 256      # 攒到这行数就立刻 flush, 不再等 debounce
APP_VERSION = "6.8"  # 与 Contents/Info.plist、窗口标题/启动日志一致
ASC_MONITOR_BASE = "https://asc-monitor.arnedaen.workers.dev"
APP_PY_PATH = os.path.abspath(__file__)

# Cursor Agent CLI：`agent chat --print --trust [--model <id>] "<prompt>"`（--print 为无头模式；--trust 仅在此模式下生效，避免 Workspace Trust 卡住）
# IDE 里看到的「Composer / GPT-5.4 / Sonnet 4.6」等是产品名；CLI 使用内部 id，完整列表以终端 `agent models` 为准（随账号与版本变化）。
# 下拉「Cursor 常用」与 `agent models` 对齐；其余为历史兼容的 API 风格 id；未列出请填右侧自定义框。
AGENT_MODEL_PRESETS = (
    ("默认（不指定 --model）", ""),
    # —— Cursor Agent CLI（与 IDE / agent models 对齐）——
    ("Auto", "auto"),
    ("Composer 2 Fast", "composer-2-fast"),
    ("Composer 2", "composer-2"),
    ("Composer 1.5", "composer-1.5"),
    ("Codex 5.3", "gpt-5.3-codex"),
    ("GPT-5.4（1M）", "gpt-5.4-medium"),
    ("GPT-5.4 Fast", "gpt-5.4-medium-fast"),
    ("Sonnet 4.6（1M）", "claude-4.6-sonnet-medium"),
    ("Sonnet 4.6 Thinking", "claude-4.6-sonnet-medium-thinking"),
    ("Opus 4.6（1M）", "claude-4.6-opus-high"),
    ("Opus 4.6 Max", "claude-4.6-opus-max"),
    ("Opus 4.6 Max Thinking", "claude-4.6-opus-max-thinking"),
    # —— OpenAI：GPT / ChatGPT ——
    ("GPT-4.1", "gpt-4.1"),
    ("GPT-4o", "gpt-4o"),
    ("GPT-4o mini", "gpt-4o-mini"),
    ("GPT-4o (2024-08-06)", "gpt-4o-2024-08-06"),
    ("GPT-4o (2024-11-20)", "gpt-4o-2024-11-20"),
    ("chatgpt-4o-latest", "chatgpt-4o-latest"),
    ("GPT-4 Turbo", "gpt-4-turbo"),
    ("GPT-4 Turbo (2024-04-09)", "gpt-4-turbo-2024-04-09"),
    ("GPT-4", "gpt-4"),
    ("GPT-4-32k", "gpt-4-32k"),
    ("GPT-3.5 Turbo", "gpt-3.5-turbo"),
    # —— OpenAI：o / 推理 ——
    ("o1", "o1"),
    ("o1 (2024-12-17)", "o1-2024-12-17"),
    ("o1-mini", "o1-mini"),
    ("o1-preview", "o1-preview"),
    ("o3-mini", "o3-mini"),
    ("o3-mini-2025-01-31", "o3-mini-2025-01-31"),
    ("o4-mini", "o4-mini"),
    ("o4-mini-deep-research", "o4-mini-deep-research"),
    # —— OpenAI：GPT-5 系（名称随 Cursor 后台更新）——
    ("gpt-5", "gpt-5"),
    ("gpt-5-mini", "gpt-5-mini"),
    ("gpt-5-nano", "gpt-5-nano"),
    ("gpt-5.1", "gpt-5.1"),
    ("gpt-5.2", "gpt-5.2"),
    ("gpt-5.1-codex", "gpt-5.1-codex"),
    ("gpt-5.1-codex-mini", "gpt-5.1-codex-mini"),
    # —— Anthropic：Claude 3.x ——
    ("Claude 3.5 Sonnet", "claude-3-5-sonnet-20241022"),
    ("Claude 3.5 Haiku", "claude-3-5-haiku-20241022"),
    ("Claude 3 Opus", "claude-3-opus-20240229"),
    ("Claude 3 Sonnet", "claude-3-sonnet-20240229"),
    ("Claude 3 Haiku", "claude-3-haiku-20240307"),
    # —— Anthropic：Claude 3.7 / 4 ——
    ("Claude 3.7 Sonnet", "claude-3-7-sonnet-20250219"),
    ("Claude Sonnet 4", "claude-sonnet-4-20250514"),
    ("Claude Opus 4", "claude-opus-4-20250514"),
    ("Claude Haiku 4.5", "claude-haiku-4-5-20251001"),
    ("Claude Sonnet 4.5", "claude-sonnet-4-5-20250929"),
    ("Claude Opus 4.5", "claude-opus-4-5-20251101"),
    # —— Google：Gemini ——
    ("Gemini 2.5 Pro", "gemini-2.5-pro"),
    ("Gemini 2.5 Flash", "gemini-2.5-flash"),
    ("Gemini 2.0 Flash", "gemini-2.0-flash"),
    ("Gemini 2.0 Flash Thinking", "gemini-2.0-flash-thinking-exp"),
    ("Gemini 1.5 Pro", "gemini-1.5-pro"),
    ("Gemini 1.5 Flash", "gemini-1.5-flash"),
    ("Gemini 1.5 Flash-8B", "gemini-1.5-flash-8b"),
    # —— xAI ——
    ("Grok 3", "grok-3"),
    ("Grok 3 mini", "grok-3-mini"),
    ("Grok 2 Vision", "grok-2-vision-1212"),
    # —— DeepSeek ——
    ("DeepSeek Chat", "deepseek-chat"),
    ("DeepSeek Reasoner", "deepseek-reasoner"),
    # —— Meta / 其它（部分环境可用）——
    ("Llama 3.3 70B", "llama-3.3-70b-versatile"),
    ("Llama 3.1 70B", "llama-3.1-70b-versatile"),
    ("Mistral Large", "mistral-large-latest"),
    ("Mixtral 8x7B", "open-mixtral-8x7b"),
)
UDK_LAST_AGENT_MODEL_ID = "ABFactoryLastAgentModelId"
UDK_LEGACY_PRESET_INDEX = "ABFactoryAgentPresetIndex"
UDK_LEGACY_CUSTOM_MODEL = "ABFactoryAgentCustomModel"
UDK_B_SIDE_CHANNEL = "ABFactoryBSideAppChannel"
UDK_APP_ENVIRONMENT = "ABFactoryAppEnvironment"
UDK_SHOW_DEV_FLOAT = "ABFactoryShowDevFloat"
UDK_TG_BOT_TOKEN = "ABFactoryTelegramBotToken"
UDK_TG_CHAT_ID = "ABFactoryTelegramChatId"
UDK_TG_ENABLED = "ABFactoryTelegramEnabled"


# Telegram 输入规整：拷贝粘贴常带零宽空格 / NBSP / 全角负号 / 引号, 直接发会 400
_TG_INVISIBLES = (
    "\u200b", "\u200c", "\u200d", "\ufeff", "\u00a0",   # 各种零宽 / NBSP
    "\u3000",                                          # 全角空格
    "\u2028", "\u2029",                                # 行/段分隔符
)


def _tg_strip_invisibles(s):
    if not s:
        return ""
    for ch in _TG_INVISIBLES:
        s = s.replace(ch, "")
    return s


def _tg_normalize_token(tok):
    """规整 Bot Token：去首尾空白、去引号、去隐形字符。"""
    if tok is None:
        return ""
    t = _tg_strip_invisibles(str(tok)).strip().strip('"').strip("'")
    return t


def _tg_normalize_chat_id(chat):
    """
    规整 chat_id：
    - 去首尾空白 / 引号 / 隐形字符
    - 全角负号 → 半角负号
    - 全角数字 → 半角数字
    - 末尾顺手去掉非法字符 (常见误粘 ',' / 中文逗号 / 等号)
    """
    if chat is None:
        return ""
    c = _tg_strip_invisibles(str(chat)).strip().strip('"').strip("'").strip()
    if not c:
        return ""
    # 全角负号 / 减号变体 → ASCII '-'
    for bad in ("\uff0d", "\u2212", "\u2013", "\u2014", "\u2010", "\u2011"):
        c = c.replace(bad, "-")
    # 全角数字 → 半角
    c = c.translate({0xff10 + i: 0x30 + i for i in range(10)})
    # @公开频道用户名保留为 @xxx; 否则裁掉数字/'-' 之外的尾巴
    if c.startswith("@"):
        return c
    out_chars = []
    for ch in c:
        if ch in "0123456789" or (ch == "-" and not out_chars):
            out_chars.append(ch)
    return "".join(out_chars)


# Telegram 接受的 chat_id 形式（与 _tg_normalize_chat_id 输出对应）：
#   123456789               私聊 / bot 收件人 user_id
#   -987654321              普通群 chat_id
#   -1001234567890          超级群 / 频道 chat_id
#   @publicchannelname      公开频道 / 公开超级群用户名
_TG_CHAT_ID_RE = re.compile(r"^(?:@[A-Za-z][A-Za-z0-9_]{4,31}|-?\d{5,20})$")
# Bot Token 形如  <数字>:<35+ char base64-ish>, BotFather 默认 46 字符, 这里宽松点
_TG_TOKEN_RE = re.compile(r"^\d{6,12}:[A-Za-z0-9_\-]{30,}$")


def strip_ansi(text):
    return ANSI_RE.sub('', text)


def get_env():
    env = os.environ.copy()
    pub_cache_bin = os.path.expanduser("~/.pub-cache/bin")
    # Apple Silicon：须让 /opt/homebrew/bin 先于 /usr/local/bin，否则会命中旧的
    # /usr/local/bin/pod（系统 Ruby + 损坏的 ffi），导致 pod install 报 ffi_c。
    extra = [
        FLUTTER_BIN, pub_cache_bin, "/opt/homebrew/bin", "/usr/local/bin",
        os.path.expanduser("~/.local/bin"),
        os.path.expanduser("~/.cursor/bin"),
    ]
    cur = env.get("PATH", "")
    for p in reversed(extra):
        if os.path.isdir(p) and p not in cur:
            cur = p + ":" + cur
    env["PATH"] = cur
    if os.path.isdir(XCODE_DEV):
        env["DEVELOPER_DIR"] = XCODE_DEV
    env["LANG"] = "en_US.UTF-8"
    return env


def _find_fvm():
    """Find fvm binary, return path or None."""
    import shutil
    fvm = shutil.which("fvm")
    if fvm:
        return fvm
    for p in ["/opt/homebrew/bin/fvm", "/usr/local/bin/fvm",
              os.path.expanduser("~/.pub-cache/bin/fvm")]:
        if os.path.isfile(p):
            return p
    return None


def flutter_cmd():
    """
    本项目统一只通过 FVM 调用 Flutter。
    返回 [fvm_bin, "flutter"]；未安装 FVM 时返回 None。
    """
    fvm = _find_fvm()
    return [fvm, "flutter"] if fvm else None


# App Store 营销截图标准尺寸（宽 × 高，竖屏）— 供「商店截图转换」独立功能使用
IPHONE_APP_STORE_SCREENSHOT = (1242, 2688)
IPAD_APP_STORE_SCREENSHOT = (2064, 2752)


def _png_pixel_size(path):
    try:
        r = subprocess.run(
            ["sips", "-g", "pixelWidth", "-g", "pixelHeight", path],
            capture_output=True, text=True, timeout=15, env=get_env(),
        )
        w = h = None
        for line in (r.stdout or "").splitlines():
            if "pixelWidth:" in line:
                w = int(line.split(":")[-1].strip())
            elif "pixelHeight:" in line:
                h = int(line.split(":")[-1].strip())
        if w and h:
            return w, h
    except Exception:
        pass
    return None, None


def _resize_png_to_app_store_size(path, target_w, target_h):
    """将 PNG 精确缩放到 App Store 目标像素（sips -z 高 宽）。"""
    cur_w, cur_h = _png_pixel_size(path)
    if cur_w == target_w and cur_h == target_h:
        return True, ""
    try:
        r = subprocess.run(
            ["sips", "-z", str(target_h), str(target_w), path],
            capture_output=True, text=True, timeout=60, env=get_env(),
        )
        if r.returncode != 0:
            err = (r.stderr or r.stdout or "").strip() or f"exit {r.returncode}"
            return False, err
        return True, ""
    except Exception as e:
        return False, str(e)


def _convert_png_file_to_app_store(src_path, dst_path, target_w, target_h):
    """复制并缩放单张 PNG 到 App Store 尺寸，返回 (ok, detail_msg)。"""
    src_w, src_h = _png_pixel_size(src_path)
    if not src_w or not src_h:
        return False, "无法读取图片尺寸"
    try:
        shutil.copy2(src_path, dst_path)
    except OSError as e:
        return False, f"复制失败: {e}"
    ok, err = _resize_png_to_app_store_size(dst_path, target_w, target_h)
    if not ok:
        try:
            os.remove(dst_path)
        except OSError:
            pass
        return False, err
    if src_w == target_w and src_h == target_h:
        return True, f"已是 {target_w}×{target_h}px"
    return True, f"{src_w}×{src_h} → {target_w}×{target_h}"


def _app_store_target_for_simulator(device_label):
    """根据模拟器名称判定 App Store 截图尺寸。"""
    if "ipad" in (device_label or "").lower():
        return IPAD_APP_STORE_SCREENSHOT, "iPad", "2064x2752"
    return IPHONE_APP_STORE_SCREENSHOT, "iPhone", "1242x2688"


def _app_store_screenshot_dir(project_root):
    """工程内 App Store 截图输出目录。"""
    return os.path.join(project_root, "screenshots", "app_store")


def _capture_and_convert_app_store_screenshot(udid, out_path, target_w, target_h):
    """
    截取模拟器画面并转为 App Store 尺寸写入 out_path（不保留原始分辨率文件）。
    返回 (True, detail) 或 (False, error)。
    """
    raw_path = out_path + ".__raw__.png"
    try:
        ok, err = _capture_ios_simulator_screenshot(udid, raw_path)
        if not ok:
            return False, err
        ok2, detail = _convert_png_file_to_app_store(raw_path, out_path, target_w, target_h)
        if not ok2:
            return False, detail
        return True, detail
    finally:
        try:
            if os.path.isfile(raw_path):
                os.remove(raw_path)
        except OSError:
            pass


def _capture_ios_simulator_screenshot(udid, out_path):
    """
    截取指定模拟器当前显示画面（需模拟器已启动）。
    返回 (True, "") 或 (False, 错误信息)。
    """
    _dir = os.path.dirname(out_path)
    if _dir:
        try:
            os.makedirs(_dir, exist_ok=True)
        except Exception:
            pass
    try:
        r = subprocess.run(
            ["xcrun", "simctl", "io", udid, "screenshot", out_path],
            capture_output=True, text=True, timeout=45,
            env=get_env(),
        )
        if r.returncode != 0:
            err = (r.stderr or r.stdout or "").strip() or f"exit {r.returncode}"
            return False, err
        if not os.path.isfile(out_path) or os.path.getsize(out_path) < 100:
            return False, "截图文件未生成或过小"
        return True, ""
    except FileNotFoundError:
        return False, "未找到 xcrun（请安装 Xcode Command Line Tools）"
    except Exception as e:
        return False, str(e)


def _main_screen_height():
    from AppKit import NSScreen
    return float(NSScreen.mainScreen().frame().size.height)


def _pick_simulator_phone_window_bounds():
    """
    从当前屏幕窗口列表中选取 Simulator 前台设备画面窗口（优先竖屏手机比例）。
    返回 dict: x,y,w,h（屏幕坐标，Y 为自屏幕顶部向下的距离，用于与 _click_simulator_window_normalized 配套）或 None。
    """
    windows = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID)
    candidates = []
    for w in windows:
        owner = w.get(Quartz.kCGWindowOwnerName) or ""
        if owner != "Simulator":
            continue
        layer = w.get(Quartz.kCGWindowLayer, 0)
        if layer != 0:
            continue
        bdict = w.get(Quartz.kCGWindowBounds)
        if not bdict:
            continue
        try:
            x = float(bdict["X"])
            y = float(bdict["Y"])
            bw = float(bdict["Width"])
            bh = float(bdict["Height"])
        except (KeyError, TypeError, ValueError):
            continue
        if bw < 220 or bh < 400:
            continue
        area = bw * bh
        candidates.append((area, bw, bh, x, y))
    if not candidates:
        return None
    candidates.sort(key=lambda t: t[0], reverse=True)
    for _a, bw, bh, x, y in candidates[:8]:
        if 260 <= bw <= 520 and bh >= 560:
            return {"x": x, "y": y, "w": bw, "h": bh}
    _a, bw, bh, x, y = candidates[0]
    return {"x": x, "y": y, "w": bw, "h": bh}


def _cg_click_screen(x, y):
    """在 Quartz 全局坐标（左下为原点）下模拟左键点击。"""
    pt = Quartz.CGPointMake(float(x), float(y))
    for typ in (Quartz.kCGEventLeftMouseDown, Quartz.kCGEventLeftMouseUp):
        ev = Quartz.CGEventCreateMouseEvent(None, typ, pt, Quartz.kCGMouseButtonLeft)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)


def _click_simulator_window_normalized(bounds, nx, ny, screen_h):
    """
    在 Simulator 设备窗口内按归一化坐标点击 (nx,ny ∈ [0,1]，相对可点区域)。
    bounds 的 y 为自屏幕顶部向下（与 CGWindow 字典一致）。
    """
    inset_x = 0.07 * bounds["w"]
    inset_y = 0.09 * bounds["h"]
    cw = bounds["w"] - 2 * inset_x
    ch = bounds["h"] - 2 * inset_y
    cx = bounds["x"] + inset_x + nx * cw
    cy_from_top = bounds["y"] + inset_y + ny * ch
    qy = screen_h - cy_from_top
    _cg_click_screen(cx, qy)


def _activate_simulator_app():
    """将 Simulator 应用置于前台。"""
    ws = NSWorkspace.sharedWorkspace()
    for app in ws.runningApplications():
        bid = app.bundleIdentifier() or ""
        if "Simulator" in bid or app.localizedName() == "Simulator":
            app.activateWithOptions_(NSApplicationActivateIgnoringOtherApps)
            return True
    subprocess.Popen(["open", "-a", "Simulator"], env=get_env())
    return False


def _find_cursor_agent_cli():
    """
    Cursor 官方 Agent CLI（文档：curl https://cursor.com/install），无头调用一般为:
      agent chat --print --trust "..."
    亦尝试 cursor-agent 等别名。
    """
    for name in ("agent", "cursor-agent"):
        p = shutil.which(name)
        if p:
            return p
    for p in (
        os.path.expanduser("~/.local/bin/agent"),
        os.path.expanduser("~/.cursor/bin/agent"),
        "/opt/homebrew/bin/agent",
        "/usr/local/bin/agent",
    ):
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


def _append_flutter_log_line(line):
    buf = _state.setdefault("last_flutter_log", [])
    buf.append(line)
    over = len(buf) - MAX_FLUTTER_LOG_LINES
    if over > 0:
        del buf[:over]


def _read_fvm_version_from_template(template_dir):
    """Read Flutter version string from template .fvmrc JSON."""
    path = os.path.join(template_dir, ".fvmrc")
    if not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        v = data.get("flutter")
        return str(v).strip() if v else None
    except Exception:
        return None


def _git_head_info(template_dir):
    """
    读取本地 git 仓库当前分支、短提交、最新提交说明。
    返回 (branch, short_sha, subject)；非仓库或失败时三项可能为空字符串。
    """
    if not template_dir or not os.path.isdir(template_dir):
        return "", "", ""
    if not os.path.isdir(os.path.join(template_dir, ".git")):
        return "", "", ""
    env = get_env()

    def _g(args):
        try:
            r = subprocess.run(args, capture_output=True, text=True, timeout=20, env=env)
            if r.returncode == 0 and (r.stdout or "").strip():
                return (r.stdout or "").strip()
        except Exception:
            pass
        return ""

    branch = _g(["git", "-C", template_dir, "rev-parse", "--abbrev-ref", "HEAD"])
    short_h = _g(["git", "-C", template_dir, "rev-parse", "--short", "HEAD"])
    subj = _g(["git", "-C", template_dir, "log", "-1", "--format=%s"])
    subj = subj.replace("\n", " ").strip()
    return branch, short_h, subj


def _format_template_git_status_line(template_dir):
    """单行展示用文案（用于界面与日志）。"""
    b, h, s = _git_head_info(template_dir)
    if not b and not h:
        if template_dir and os.path.isdir(template_dir) and not os.path.isdir(
                os.path.join(template_dir, ".git")):
            return "（当前目录不是 git 仓库）"
        return "（无法读取）"
    parts = []
    if b:
        parts.append(f"分支 {b}")
    if h:
        parts.append(h)
    line = " · ".join(parts) if parts else ""
    if s:
        suf = s if len(s) <= 72 else s[:69] + "…"
        line = f"{line} · {suf}" if line else suf
    return line


def _parse_project_codes_from_sync_script(template_dir):
    """Parse -p project list from scripts/sync_secondary.sh help text."""
    path = os.path.join(template_dir, "scripts", "sync_secondary.sh")
    if not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except Exception:
        return None
    m = re.search(r"项目代码 \(([^)]+)\)", text)
    if not m:
        return None
    return [p.strip() for p in m.group(1).split(",") if p.strip()]


def _try_copy_self_from_template(template_dir):
    """
    If template ships a newer app.py under known paths, copy over current bundle script.
    Returns relative path copied or None.
    """
    for rel in (
        "packaging/ab_factory_app/app.py",
        "packaging/ab_factory/app.py",
        "tools/ab_package_factory/app.py",
    ):
        src = os.path.join(template_dir, rel)
        if os.path.isfile(src):
            try:
                shutil.copy2(src, APP_PY_PATH)
                return rel
            except Exception:
                return None
    return None


def _apply_pubspec_version(pubspec_path, version_str):
    """
    Set top-level `version:` in pubspec.yaml. Accepts e.g. 1.0.0+42 or 1.0.0.
    """
    version_str = version_str.strip()
    if not version_str:
        return False
    if not re.match(r"^[\w.+\-~]+$", version_str):
        raise ValueError("版本号格式无效，示例: 1.0.0+42")
    with open(pubspec_path, encoding="utf-8-sig") as f:
        content = f.read()
    if not re.search(r"(?m)^version:\s", content):
        raise ValueError("pubspec.yaml 中未找到 version: 行")
    new_content, n = re.subn(
        r"(?m)^version:\s.*$",
        f"version: {version_str}",
        content,
        count=1,
    )
    if n != 1:
        raise ValueError("未能替换 version 行")
    with open(pubspec_path, "w", encoding="utf-8") as f:
        f.write(new_content)
    return True


def _apply_app_data_version(project_root, version_str):
    """
    跟随版本号修改：同步更新工程内 app_data_manager.dart 中
    `String version = "x.x.x";` 的值。

    取 pubspec 版本号的 semver 部分（去掉 +build，如 1.1.0+5 -> 1.1.0）。
    在 lib/ 下自动搜索，兼容两种工程布局：
      - 原始/B 面工程：lib/main/config/app_data_manager.dart
      - AB 壳：lib/modules/secondary/main/config/app_data_manager.dart
    会更新所有含 `String version = "..."` 行的同名文件。
    找不到任何匹配文件时静默返回（不报错）。
    返回 (updated: list[str], unchanged: list[str], semver: str, found_any: bool)。
    """
    semver = (version_str or "").strip().split("+", 1)[0].strip()
    if not semver:
        return ([], [], "", False)
    lib_dir = os.path.join(project_root, "lib")
    if not os.path.isdir(lib_dir):
        return ([], [], semver, False)
    # 匹配 `String version = "..."`（兼容单/双引号），仅替换引号内的值
    pattern = r"""(String\s+version\s*=\s*)(["'])[^"']*\2"""
    updated, unchanged = [], []
    found_any = False
    for root, _dirs, files in os.walk(lib_dir):
        if "app_data_manager.dart" not in files:
            continue
        fp = os.path.join(root, "app_data_manager.dart")
        try:
            with open(fp, encoding="utf-8-sig") as f:
                content = f.read()
        except Exception:
            continue
        if not re.search(pattern, content):
            continue
        found_any = True
        new_content = re.sub(
            pattern, lambda m: f'{m.group(1)}"{semver}"', content, count=1
        )
        if new_content == content:
            unchanged.append(fp)
            continue
        with open(fp, "w", encoding="utf-8") as f:
            f.write(new_content)
        updated.append(fp)
    return (updated, unchanged, semver, found_any)


# 品牌替换：B 面所有「星火」字符串改为填入文字
BRAND_REPLACE_SRC = "星火"
_BRAND_TEXT_ASSET_EXT = {
    ".html", ".htm", ".json", ".txt", ".md", ".xml",
    ".yaml", ".yml", ".js", ".css", ".csv", ".strings",
}
_FROMCHARCODES_RE = re.compile(r"String\.fromCharCodes\(\s*\[([0-9,\s]+)\]\s*\)")


def _replace_brand_in_dart(content, src, dst):
    """
    在单个 .dart 文本中把品牌串 src 替换为 dst。两步：
    1) String.fromCharCodes([...]) 数组：解码 -> 若含 src 则替换 -> 重编码
       （仅改数组本体；解码后不含 src 的数组，如「星期」原样保留）。
    2) 整段做明文替换 src->dst，覆盖普通字面量与注释 /* ... */ 提示。
    返回 (new_content, cc_blocks_changed, plain_replacements)。
    """
    cc_changed = 0

    def _cc_sub(m):
        nonlocal cc_changed
        nums_raw = [x for x in re.split(r"[,\s]+", m.group(1).strip()) if x]
        try:
            s = "".join(chr(int(n)) for n in nums_raw)
        except (ValueError, OverflowError):
            return m.group(0)
        if src not in s:
            return m.group(0)
        s2 = s.replace(src, dst)
        new_nums = ", ".join(str(ord(c)) for c in s2)
        cc_changed += 1
        return f"String.fromCharCodes([{new_nums}])"

    content2 = _FROMCHARCODES_RE.sub(_cc_sub, content)
    plain_n = content2.count(src)
    content3 = content2.replace(src, dst) if plain_n else content2
    return content3, cc_changed, plain_n


def _bside_roots(project_root):
    """
    返回 B 面代码/资源根目录，自适应两种工程布局：
      - AB 壳：lib/modules/secondary（+ assets/secondary）
      - 原始/B 面工程：整个 lib（+ assets）
    """
    roots = []
    sec = os.path.join(project_root, "lib", "modules", "secondary")
    if os.path.isdir(sec):
        roots.append(sec)
        asec = os.path.join(project_root, "assets", "secondary")
        if os.path.isdir(asec):
            roots.append(asec)
    else:
        lib = os.path.join(project_root, "lib")
        if os.path.isdir(lib):
            roots.append(lib)
        a = os.path.join(project_root, "assets")
        if os.path.isdir(a):
            roots.append(a)
    return roots


def _replace_brand_in_bside(project_root, src, dst, dry_run=False):
    """
    遍历 B 面，把 src 替换为 dst。.dart 走 charcode+明文两步，文本资产仅明文。
    返回 dict: files_changed, cc_blocks, plain_count, scanned, details[(rel, cc, plain)]。
    """
    res = {"files_changed": 0, "cc_blocks": 0, "plain_count": 0,
           "scanned": 0, "details": []}
    src = (src or "").strip()
    if not src:
        return res
    for root in _bside_roots(project_root):
        for dirpath, _dirs, files in os.walk(root):
            for fn in files:
                ext = os.path.splitext(fn)[1].lower()
                is_dart = ext == ".dart"
                if not is_dart and ext not in _BRAND_TEXT_ASSET_EXT:
                    continue
                fp = os.path.join(dirpath, fn)
                try:
                    with open(fp, encoding="utf-8") as f:
                        content = f.read()
                except (UnicodeDecodeError, OSError):
                    continue
                res["scanned"] += 1
                if is_dart:
                    new_content, cc, plain = _replace_brand_in_dart(content, src, dst)
                else:
                    plain = content.count(src)
                    cc = 0
                    new_content = content.replace(src, dst) if plain else content
                if new_content == content:
                    continue
                res["files_changed"] += 1
                res["cc_blocks"] += cc
                res["plain_count"] += plain
                res["details"].append((os.path.relpath(fp, project_root), cc, plain))
                if not dry_run:
                    with open(fp, "w", encoding="utf-8") as f:
                        f.write(new_content)
    return res


def _read_pubspec_version(pubspec_path):
    """
    读取根目录 pubspec.yaml 顶层 version（忽略 UTF-8 BOM、行尾 # 注释）。
    """
    try:
        with open(pubspec_path, encoding="utf-8-sig") as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                m = re.match(r"^version:\s*([^#\n]+?)\s*(?:#.*)?$", line)
                if m:
                    return m.group(1).strip().strip('"').strip("'")
    except Exception:
        pass
    return ""


def _b_side_config_dart_path(project_root):
    return os.path.join(
        project_root, "lib", "modules", "secondary", "config", "config.dart")


def _read_b_side_config_channel(project_root):
    """读取 B 面 config.dart 中 xxChannel 的 APP_CHANNEL defaultValue。"""
    path = _b_side_config_dart_path(project_root)
    if not os.path.isfile(path):
        return "", f"未找到 B 面配置: {path}"
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    except OSError as e:
        return "", f"读取 config.dart 失败: {e}"
    pat = (
        r"const\s+xxChannel\s*=\s*String\.fromEnvironment\s*\(\s*"
        r"['\"]APP_CHANNEL['\"]\s*,\s*defaultValue:\s*['\"]([^'\"]+)['\"]"
    )
    m = re.search(pat, text)
    if not m:
        return "", "config.dart 中未匹配到 xxChannel / APP_CHANNEL 行（可能非 dq 模板）"
    return m.group(1).strip(), None


def _pubspec_top_level_section_bounds(lines):
    """返回顶层段名 -> (start_line, end_line_exclusive)。"""
    markers = []
    for i, line in enumerate(lines):
        m = re.match(r"^([a-z][a-z0-9_-]*):\s*", line)
        if m:
            markers.append((m.group(1), i))
    bounds = {}
    for j, (name, start) in enumerate(markers):
        end = markers[j + 1][1] if j + 1 < len(markers) else len(lines)
        bounds[name] = (start, end)
    return bounds


def _iter_pubspec_dep_blocks(lines, sec_start, sec_end):
    """遍历 dependencies / dependency_overrides 段内的依赖块。"""
    i = sec_start + 1
    while i < sec_end:
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        m = re.match(r"^  ([A-Za-z0-9_-]+):\s*(.*)$", line)
        if not m:
            i += 1
            continue
        name = m.group(1)
        start = i
        i += 1
        while i < sec_end:
            ln = lines[i]
            if re.match(r"^  [A-Za-z0-9_-]+:\s", ln):
                break
            if re.match(r"^[a-z][a-z0-9_-]*:\s", ln):
                break
            i += 1
        yield name, start, i, lines[start:i]


def _pubspec_dep_block_missing_path(block_lines):
    """依赖块仅有包名、无 version/path/git 时视为需补齐 path。"""
    if not block_lines:
        return False
    m = re.match(r"^  ([A-Za-z0-9_-]+):\s*(.*)$", block_lines[0])
    if not m:
        return False
    rest = (m.group(2) or "").strip()
    if rest and not rest.startswith("#"):
        return False
    for line in block_lines[1:]:
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if s.startswith("path:") or s.startswith("git:") or s.startswith("hosted:"):
            return False
    return True


def _shell_plugin_dir_name(project_root):
    """dq/xty 同步后本地插件多在 plugin/；部分工程为 plugins/。"""
    if os.path.isdir(os.path.join(project_root, "plugin")):
        return "plugin"
    return "plugins"


def _resolve_local_plugin_dir(project_root, plugin_name):
    """返回 (相对 path 前缀 plugin|plugins, 目录名) 或 (None, None)。"""
    for base in ("plugin", "plugins"):
        root = os.path.join(project_root, base)
        if not os.path.isdir(root):
            continue
        direct = os.path.join(root, plugin_name)
        if os.path.isfile(os.path.join(direct, "pubspec.yaml")):
            return base, plugin_name
        for d in os.listdir(root):
            if not os.path.isfile(os.path.join(root, d, "pubspec.yaml")):
                continue
            if d == plugin_name or d.startswith(plugin_name):
                return base, d
    return None, None


def _local_plugin_ready(project_root, plugin_name):
    base, _ = _resolve_local_plugin_dir(project_root, plugin_name)
    return base is not None


def _is_pubspec_pollution_line(line):
    """sync_secondary 的 log_warning 曾被 $(...) 捕获并写入 pubspec，需剔除（不修改模板脚本，由工厂后处理）。"""
    if not line or not line.strip():
        return False
    if "\x1b[" in line or "[WARNING]" in line or "[ERROR]" in line:
        return True
    s = line.strip()
    if "跳过 dependency_override" in s:
        return True
    if s.startswith("[WARNING]") or s.startswith("[ERROR]"):
        return True
    # 误把顶格/段内注释当依赖块时产生的畸形行
    if re.match(r"^#Align", s) or re.match(r"^#.*path/git", s):
        return True
    return False


def _parse_pubspec_override_blocks(pubspec_path):
    """解析 dependency_overrides 段为 (name, block_lines)；跳过纯注释块。"""
    try:
        with open(pubspec_path, encoding="utf-8-sig") as f:
            lines = f.read().splitlines()
    except OSError:
        return []
    bounds = _pubspec_top_level_section_bounds(lines)
    if "dependency_overrides" not in bounds:
        return []
    sec_start, sec_end = bounds["dependency_overrides"]
    blocks = []
    for name, start, end, block in _iter_pubspec_dep_blocks(lines, sec_start, sec_end):
        if name.startswith("#") or not re.match(r"^[A-Za-z]", name):
            continue
        if all(
            (not ln.strip()) or ln.strip().startswith("#")
            for ln in block
        ):
            continue
        blocks.append((name, block))
    return blocks


def _remap_plugin_path_line(path_line, project_root):
    """B 面 ./plugin/xxx → 壳工程 plugins/xxx（与 sync_plugins 目录一致）。"""
    m = re.match(r"^(\s*path:\s*)(.+?)\s*$", path_line)
    if not m:
        return path_line
    prefix, raw = m.group(1), m.group(2).strip().strip("'\"")
    raw = raw.replace("\\", "/")
    rel = raw
    for stem in ("./plugin/", "plugin/", "./plugins/", "plugins/"):
        if rel.startswith(stem):
            rel = rel[len(stem) :]
            break
    rel = rel.strip("/")
    if not rel:
        return path_line
    leaf = rel.split("/")[0]
    for base in ("plugin", "plugins"):
        plugins_dir = os.path.join(project_root, base)
        if not os.path.isdir(plugins_dir):
            continue
        candidates = [
            d
            for d in os.listdir(plugins_dir)
            if os.path.isfile(os.path.join(plugins_dir, d, "pubspec.yaml"))
        ]
        chosen = None
        if os.path.isfile(os.path.join(plugins_dir, rel, "pubspec.yaml")):
            chosen = rel.replace("/", os.sep)
        else:
            for d in candidates:
                if d == leaf or d.startswith(leaf) or leaf in d:
                    chosen = d
                    break
        if chosen:
            return f"{prefix}{base}/{chosen}"
    return path_line


def _override_block_for_shell(project_root, name, block_lines):
    """将 B 面 override 块转为可写入壳工程 pubspec 的行。"""
    out = []
    has_path_git = False
    for ln in block_lines:
        if re.match(r"^\s+(path|git):", ln):
            has_path_git = True
            if ln.strip().startswith("path:"):
                out.append(_remap_plugin_path_line(ln, project_root))
            else:
                out.append(ln)
        else:
            out.append(ln)
    if has_path_git:
        return out
    m = re.match(r"^  ([A-Za-z0-9_-]+):\s*(.*)$", block_lines[0])
    if m and (m.group(2) or "").strip() and not (m.group(2) or "").strip().startswith("#"):
        return block_lines
    base, dir_name = _resolve_local_plugin_dir(project_root, name)
    if base and dir_name:
        return [f"  {name}:", f"    path: {base}/{dir_name}"]
    return block_lines


def _repair_pubspec_after_b_side_sync(project_root, source_root=None):
    """
    同步后修复壳工程 pubspec（替代改模板 sync_secondary.sh）：
    - 剔除被误写入的 WARNING/日志行
    - 按 B 面源 pubspec 重建 dependency_overrides（保留 path/git 多行）
    - 将 ./plugin/ 映射为壳工程 plugin/ 或 plugins/
    - 补齐缺失的本地插件 path
    """
    pubspec_path = os.path.join(project_root, "pubspec.yaml")
    if not os.path.isfile(pubspec_path):
        return False, "未找到 pubspec.yaml", []

    try:
        with open(pubspec_path, encoding="utf-8-sig") as f:
            lines = f.read().splitlines()
    except OSError as e:
        return False, f"读取 pubspec 失败: {e}", []

    cleaned = [ln for ln in lines if not _is_pubspec_pollution_line(ln)]
    removed = len(lines) - len(cleaned)
    lines = cleaned

    merged_override_names = []
    if source_root and os.path.isfile(os.path.join(source_root, "pubspec.yaml")):
        src_blocks = _parse_pubspec_override_blocks(
            os.path.join(source_root, "pubspec.yaml")
        )
        bounds = _pubspec_top_level_section_bounds(lines)
        if "dependency_overrides" in bounds:
            sec_start, sec_end = bounds["dependency_overrides"]
            header = lines[sec_start:sec_start + 1]
            new_body = []
            seen = set()
            for name, block in src_blocks:
                shell_block = _override_block_for_shell(project_root, name, block)
                new_body.extend(shell_block)
                new_body.append("")
                seen.add(name)
                merged_override_names.append(name)
            while new_body and not new_body[-1].strip():
                new_body.pop()
            lines = lines[: sec_start + 1] + new_body + lines[sec_end:]
        elif src_blocks:
            insert_at = bounds.get("dev_dependencies", (len(lines),))[0]
            chunk = ["", "dependency_overrides:"]
            for name, block in src_blocks:
                chunk.extend(_override_block_for_shell(project_root, name, block))
                chunk.append("")
                merged_override_names.append(name)
            lines = lines[:insert_at] + chunk + lines[insert_at:]

    path_fixed = []
    bounds = _pubspec_top_level_section_bounds(lines)
    for section in ("dependencies", "dependency_overrides"):
        if section not in bounds:
            continue
        sec_start, sec_end = bounds[section]
        for i in range(sec_start + 1, sec_end):
            if lines[i].strip().startswith("path:"):
                new_ln = _remap_plugin_path_line(lines[i], project_root)
                if new_ln != lines[i]:
                    lines[i] = new_ln
                    path_fixed.append(lines[i].strip())

    lines, plugin_fixed = _fix_pubspec_missing_plugin_paths_lines(lines, project_root)
    try:
        with open(pubspec_path, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
    except OSError as e:
        return False, f"写入 pubspec 失败: {e}", []

    msg_parts = []
    if removed:
        msg_parts.append(f"移除污染行 {removed}")
    if merged_override_names:
        msg_parts.append(f"合并 overrides {len(merged_override_names)}")
    if plugin_fixed:
        msg_parts.append(f"补齐 path {len(plugin_fixed)}")
    if not msg_parts:
        return False, "pubspec 检查完成", []
    return True, "；".join(msg_parts), plugin_fixed


def _fix_pubspec_missing_plugin_paths_lines(lines, project_root):
    """在内存中的 pubspec 行列表上补齐 plugins path，返回 (lines, fixed_names)。"""
    bounds = _pubspec_top_level_section_bounds(lines)
    replacements = []
    fixed_names = []
    skip_names = frozenset({"flutter", "flutter_localizations"})

    for section in ("dependencies", "dependency_overrides"):
        if section not in bounds:
            continue
        sec_start, sec_end = bounds[section]
        for name, start, end, block in _iter_pubspec_dep_blocks(lines, sec_start, sec_end):
            if name in skip_names:
                continue
            if not _pubspec_dep_block_missing_path(block):
                continue
            base, dir_name = _resolve_local_plugin_dir(project_root, name)
            if not base:
                continue
            replacements.append((start, end, [f"  {name}:", f"    path: {base}/{dir_name}"]))
            fixed_names.append(name)

    replacements.sort(key=lambda x: x[0], reverse=True)
    for start, end, new_block in replacements:
        lines[:] = lines[:start] + new_block + lines[end:]
    return lines, fixed_names


def _fix_pubspec_missing_plugin_paths(project_root):
    """
    同步 B 面后：为 pubspec 中缺少 path/git 的条目补齐 plugins/<name>（仅当本地插件目录存在）。
    返回 (changed, message, fixed_names)。
    """
    pubspec_path = os.path.join(project_root, "pubspec.yaml")
    if not os.path.isfile(pubspec_path):
        return False, "未找到 pubspec.yaml", []

    try:
        with open(pubspec_path, encoding="utf-8-sig") as f:
            lines = f.read().splitlines()
    except OSError as e:
        return False, f"读取 pubspec 失败: {e}", []

    lines, fixed_names = _fix_pubspec_missing_plugin_paths_lines(lines, project_root)
    if not fixed_names:
        return False, "pubspec 本地插件 path 检查完成，无需补齐", []

    try:
        with open(pubspec_path, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
    except OSError as e:
        return False, f"写入 pubspec 失败: {e}", fixed_names

    return True, "ok", fixed_names


def _restore_pubspec_clean(project_root):
    """
    将 pubspec.yaml 还原为工程内「干净」副本。
    优先级：pubspec.yaml.clean > git HEAD > pubspec.yaml.bak（sync 合并前备份）。
    还原前会把当前文件备份为 pubspec.yaml.before_restore。
    返回 (ok, message)。
    """
    pubspec_path = os.path.join(project_root, "pubspec.yaml")
    if not os.path.isfile(pubspec_path):
        return False, "未找到 pubspec.yaml"

    try:
        shutil.copy2(pubspec_path, os.path.join(project_root, "pubspec.yaml.before_restore"))
    except OSError as e:
        return False, f"备份当前 pubspec 失败: {e}"

    clean_path = os.path.join(project_root, "pubspec.yaml.clean")
    if os.path.isfile(clean_path):
        try:
            shutil.copy2(clean_path, pubspec_path)
        except OSError as e:
            return False, f"从 pubspec.yaml.clean 还原失败: {e}"
        return True, "已从 pubspec.yaml.clean 还原"

    git_dir = os.path.join(project_root, ".git")
    if os.path.isdir(git_dir):
        try:
            r = subprocess.run(
                ["git", "show", "HEAD:pubspec.yaml"],
                cwd=project_root,
                capture_output=True,
                text=True,
                timeout=30,
            )
        except (subprocess.TimeoutExpired, OSError) as e:
            return False, f"读取 git HEAD pubspec 失败: {e}"
        if r.returncode == 0 and r.stdout.strip():
            try:
                content = r.stdout
                if not content.endswith("\n"):
                    content += "\n"
                with open(pubspec_path, "w", encoding="utf-8") as f:
                    f.write(content)
            except OSError as e:
                return False, f"写入 pubspec 失败: {e}"
            return True, "已从 git HEAD 还原 pubspec.yaml"

    bak_path = os.path.join(project_root, "pubspec.yaml.bak")
    if os.path.isfile(bak_path):
        try:
            shutil.copy2(bak_path, pubspec_path)
        except OSError as e:
            return False, f"从 pubspec.yaml.bak 还原失败: {e}"
        return True, "已从 pubspec.yaml.bak 还原（sync 合并前备份）"

    return False, "未找到 pubspec.yaml.clean、git HEAD 或 pubspec.yaml.bak，无法还原"


def _run_flutter_pub_get(project_root, log_fn):
    """在工程目录执行 fvm flutter pub get，返回是否成功。"""
    fc = flutter_cmd()
    if not fc:
        log_fn("  ⚠ 未安装 FVM，跳过 pub get")
        return False
    env = get_env()
    log_fn("  fvm flutter pub get …（补齐 path 后）")
    try:
        r = subprocess.run(
            [*fc, "pub", "get"],
            capture_output=True,
            text=True,
            cwd=project_root,
            env=env,
            timeout=180,
        )
    except subprocess.TimeoutExpired:
        log_fn("  ❌ pub get 超时")
        return False
    if r.returncode == 0:
        log_fn("  pub get ✓")
        return True
    log_fn("  ❌ pub get 失败（补齐 path 后）")
    for line in (r.stderr or r.stdout or "").splitlines()[-12:]:
        cl = strip_ansi(line.rstrip())
        if cl:
            log_fn(f"    {cl}")
    return False


def _declared_pubspec_packages(project_root):
    """
    读取 pubspec.yaml 中 dependencies / dependency_overrides 下声明的包名集合。
    用于判断某个 import 的「文件名」是否对应一个真实依赖（而非混淆名）。
    """
    p = os.path.join(project_root, "pubspec.yaml")
    names = set()
    if not os.path.isfile(p):
        return names
    try:
        lines = open(p, encoding="utf-8-sig").read().splitlines()
    except OSError:
        return names
    in_sec = False
    for ln in lines:
        stripped = ln.strip()
        if not stripped or stripped.startswith("#"):
            continue
        # 顶格（无缩进）的是顶层 section 头
        if re.match(r"^\S", ln):
            in_sec = ln.startswith("dependencies:") or ln.startswith("dependency_overrides:")
            continue
        if in_sec:
            m = re.match(r"^\s{2}([A-Za-z0-9_]+)\s*:", ln)
            if m:
                names.add(m.group(1))
    return names


def _deobfuscate_dart_imports(project_root):
    """
    同步后修复：把 A 面 lib/ 中残留的「混淆包名」import 还原为标准包名。

    Framework 混淆会把真实包重命名为随机名（如 shared_preferences→orbit_layout），
    并改写 import 为  package:orbit_layout/shared_preferences.dart。
    sync 会用模板重建 pubspec（恢复标准包名），但不会动 A 面 lib/ 源码，
    于是出现「import 用混淆名、pubspec 用标准名」的不匹配，导致 Couldn't resolve the package。

    识别规则（不写死混淆名，按工程 pubspec 自动判断）：
        import 'package:<X>/<Y>.dart'  且  <Y> 是 pubspec 已声明的真实依赖
        且 <X> 不是已声明依赖且 X != Y  →  还原为 package:<Y>/<Y>.dart
    （形如 package:flutter/material.dart 不会被动，因为 material 不是声明依赖）

    返回 (changed_count, changed_files)。可在同步前/后任意时刻重复执行（幂等）。
    """
    lib = os.path.join(project_root, "lib")
    if not os.path.isdir(lib):
        return 0, []
    declared = _declared_pubspec_packages(project_root)
    if not declared:
        return 0, []
    pat = re.compile(r"package:([A-Za-z0-9_]+)/([A-Za-z0-9_]+)\.dart")

    def repl(m):
        pkg, fil = m.group(1), m.group(2)
        if fil in declared and pkg not in declared and pkg != fil:
            return f"package:{fil}/{fil}.dart"
        return m.group(0)

    changed = []
    for dp, _dirs, files in os.walk(lib):
        for fn in files:
            if not fn.endswith(".dart"):
                continue
            fp = os.path.join(dp, fn)
            try:
                src = open(fp, encoding="utf-8").read()
            except OSError:
                continue
            new = pat.sub(repl, src)
            if new != src:
                try:
                    open(fp, "w", encoding="utf-8").write(new)
                    changed.append(os.path.relpath(fp, project_root))
                except OSError:
                    pass
    return len(changed), changed


def _read_flutter_version_from_generated_xcconfig(project_root):
    """
    读取 ios/Flutter/Generated.xcconfig 中 FLUTTER_BUILD_NAME + NUMBER（flutter pub get / build 生成）。
    返回如 1.0.2+5，失败返回空字符串。
    """
    p = os.path.join(project_root, "ios", "Flutter", "Generated.xcconfig")
    if not os.path.isfile(p):
        return ""
    name = num = None
    try:
        with open(p, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line.startswith("FLUTTER_BUILD_NAME="):
                    name = line.split("=", 1)[1].strip()
                elif line.startswith("FLUTTER_BUILD_NUMBER="):
                    num = line.split("=", 1)[1].strip()
        if name is not None and num is not None:
            return f"{name}+{num}"
    except Exception:
        pass
    return ""


class FlippedView(NSView):
    def isFlipped(self):
        return True


def make_label(text, x, y, w, h, size=13, bold=False, color=None):
    label = NSTextField.alloc().initWithFrame_(NSMakeRect(x, y, w, h))
    label.setStringValue_(text)
    label.setBezeled_(False)
    label.setDrawsBackground_(False)
    label.setEditable_(False)
    label.setSelectable_(False)
    if bold:
        label.setFont_(NSFont.boldSystemFontOfSize_(size))
    else:
        label.setFont_(NSFont.systemFontOfSize_(size))
    if color:
        label.setTextColor_(color)
    return label


def make_input(x, y, w, h, placeholder="", mono=False):
    field = NSTextField.alloc().initWithFrame_(NSMakeRect(x, y, w, h))
    field.setPlaceholderString_(placeholder)
    if mono:
        field.setFont_(NSFont.monospacedSystemFontOfSize_weight_(12, 0.0))
    else:
        field.setFont_(NSFont.systemFontOfSize_(13))
    return field


def make_button(title, x, y, w, h, target, action_sel, bold=False):
    btn = NSButton.alloc().initWithFrame_(NSMakeRect(x, y, w, h))
    btn.setTitle_(title)
    btn.setBezelStyle_(NSBezelStyleRounded)
    if bold:
        btn.setFont_(NSFont.boldSystemFontOfSize_(13))
    else:
        btn.setFont_(NSFont.systemFontOfSize_(12))
    btn.setTarget_(target)
    btn.setAction_(action_sel)
    return btn


def make_section_box(title, x, y, w, h):
    box = NSBox.alloc().initWithFrame_(NSMakeRect(x, y, w, h))
    box.setTitle_(title)
    box.setTitleFont_(NSFont.boldSystemFontOfSize_(13))
    box.setContentViewMargins_(NSMakeSize(10, 8))
    return box


def list_simulators():
    """
    解析 `xcrun simctl list devices available` 输出。
    返回 [(name_with_os, udid, state), ...]；其中 name_with_os 形如
    `iPhone 16 Pro Max · iOS 18.1`，确保跨 runtime 同名机型可区分。
    """
    try:
        env = get_env()
        r = subprocess.run(
            ["xcrun", "simctl", "list", "devices", "available"],
            capture_output=True, text=True, timeout=10, env=env,
        )
        results = []
        cur_os = ""
        for raw in r.stdout.splitlines():
            line = raw.strip()
            mh = re.match(r"^--\s*(.+?)\s*--$", line)
            if mh:
                cur_os = mh.group(1).strip()
                continue
            if not cur_os or not cur_os.lower().startswith(("ios", "ipados", "tvos", "watchos", "visionos")):
                # 仅采集 iOS / iPadOS 等设备分组，避免把分隔标题当成设备名
                if mh is None and line.startswith("== "):
                    cur_os = ""
                continue
            m = re.match(r'^(.+?)\s+\(([0-9A-Fa-f-]{20,})\)\s+\((\w+)\)\s*$', line)
            if m:
                name = m.group(1).strip()
                udid = m.group(2).strip()
                state = m.group(3).strip()
                results.append((f"{name} · {cur_os}", udid, state))
        return results
    except Exception:
        return []


def _resolve_simulator_selection(fresh, device_label, device_id, device_state):
    """
    升级 Xcode / 删模拟器 / 多系统版本并存时，下拉框里保存的 UDID 可能已被系统回收，
    xcodebuild 会报 Unable to find a destination。若 UDID 不在最新列表中，按设备名重新匹配。
    返回 (label, udid, state) 或 None。
    """
    if device_id == "macos":
        return (device_label, device_id, device_state)
    valid = {u for _, u, _ in fresh}
    if device_id in valid:
        for name, udid, state in fresh:
            if udid == device_id:
                tag = " [已启动]" if state == "Booted" else ""
                return (f"{name}{tag}", udid, state)
        return (device_label, device_id, device_state)
    base = device_label.split(" [")[0].strip()
    candidates = [(n, u, s) for n, u, s in fresh if n == base]
    if not candidates:
        candidates = [(n, u, s) for n, u, s in fresh if base in n]
    if not candidates:
        return None
    candidates.sort(key=lambda x: (0 if x[2] == "Booted" else 1))
    name, udid, state = candidates[0]
    tag = " [已启动]" if state == "Booted" else ""
    return (f"{name}{tag}", udid, state)


def _xcodebuild_showdestinations_text(project_root, env):
    """
    执行 `xcodebuild -scheme Runner -showdestinations`，返回 (全文, 是否成功)。
    与 Flutter/Xcode 报错里的「Available destinations」同源。
    """
    ios_dir = os.path.join(project_root, "ios")
    if not os.path.isdir(ios_dir):
        return None, False
    ws = os.path.join(ios_dir, "Runner.xcworkspace")
    xp = os.path.join(ios_dir, "Runner.xcodeproj")
    if os.path.isdir(ws):
        cmd = [
            "xcodebuild", "-workspace", "Runner.xcworkspace",
            "-scheme", "Runner", "-showdestinations",
        ]
    elif os.path.isdir(xp):
        cmd = [
            "xcodebuild", "-project", "Runner.xcodeproj",
            "-scheme", "Runner", "-showdestinations",
        ]
    else:
        return None, False
    try:
        r = subprocess.run(
            cmd, capture_output=True, text=True, timeout=120, env=env, cwd=ios_dir)
        text = (r.stdout or "") + "\n" + (r.stderr or "")
        return text, (r.returncode == 0)
    except Exception:
        return None, False


def _xcode_destination_uuid_ids(project_root, env):
    """
    showdestinations 中出现的 UUID 形式 destination id（真机、模拟器、My Mac 等）。
    用于过滤「Flutter 仍列出但 Runner scheme 不可用」的模拟器。
    失败返回 None；成功但无 UUID 则返回空 set。
    """
    text, ok = _xcodebuild_showdestinations_text(project_root, env)
    if not ok or text is None:
        return None
    return set(
        m.group(1)
        for m in re.finditer(r"\bid:([0-9A-Fa-f-]{36})\b", text)
    )


def _xcode_runner_simulator_ids(project_root, env):
    """
    以 `xcodebuild -showdestinations` 中 `platform:iOS Simulator` 行为准。
    返回 set（可为空）；无法执行时返回 None。
    注意：空 set 表示 Xcode 当前未给 Runner 分配任何模拟器目标（与 Flutter 列表可能不一致）。
    """
    text, ok = _xcodebuild_showdestinations_text(project_root, env)
    if not ok or text is None:
        return None
    ids = set()
    for line in text.splitlines():
        if "platform:iOS Simulator" not in line:
            continue
        m = re.search(r"id:([0-9A-Fa-f-]{36})", line)
        if m:
            ids.add(m.group(1))
    return ids


def _is_fvm_flutter_cmd(fc):
    return bool(fc) and len(fc) >= 2 and os.path.basename(str(fc[0])) == "fvm"


def _flutter_devices_machine_raw(fc, env, project_root=None):
    """
    执行 `fvm flutter devices --machine` 并返回 JSON 数组。
    优先在含 pubspec 的工程目录下执行（解析 .fvmrc）；否则走 FVM 默认解析。
    """
    if not fc:
        return []
    pr = (project_root or "").strip()
    pub_ok = pr and os.path.isdir(pr) and os.path.isfile(os.path.join(pr, "pubspec.yaml"))

    def _run(argv, cwd):
        try:
            r = subprocess.run(
                [*argv, "devices", "--machine"],
                capture_output=True, text=True, timeout=45, env=env, cwd=cwd,
            )
            if r.returncode != 0 or not (r.stdout or "").strip():
                return []
            return json.loads(r.stdout)
        except Exception:
            return []

    def _nonempty(arr):
        return arr if isinstance(arr, list) and len(arr) > 0 else []

    if _is_fvm_flutter_cmd(fc):
        if pub_ok:
            arr = _nonempty(_run(fc, pr))
            if arr:
                return arr
        return _nonempty(_run(fc, None))

    use_cwd = pr if pub_ok else None
    return _nonempty(_run(fc, use_cwd))


def _flutter_ios_devices_machine(fc, env, cwd=None):
    """
    `flutter devices --machine` 中的 iOS 设备；需与 `_xcode_runner_simulator_ids` 求交才可靠。
    返回 [(name, id), ...]；失败返回 []。
    """
    try:
        arr = _flutter_devices_machine_raw(fc, env, project_root=cwd)
        out = []
        for d in arr:
            if not isinstance(d, dict):
                continue
            did = d.get("id")
            nm = (d.get("name") or "").strip()
            if not did or not nm:
                continue
            if did == "macos":
                continue
            tp = (d.get("targetPlatform") or "").lower()
            if tp != "ios":
                continue
            out.append((nm, did))
        return out
    except Exception:
        return []


def _flutter_devices_machine_parsed(fc, env, project_root=None):
    """
    解析 `flutter devices --machine` 为结构化列表（供「运行」设备下拉）。
    仅保留 iOS（排除 macOS / Web / Android 及其它平台）。
    """
    if not fc:
        return []
    try:
        arr = _flutter_devices_machine_raw(fc, env, project_root=project_root)
        out = []
        for d in arr:
            if not isinstance(d, dict):
                continue
            if d.get("isSupported") is False or d.get("supported") is False:
                continue
            did = d.get("id")
            if not did:
                continue
            nm = (d.get("name") or "").strip()
            tp = (d.get("targetPlatform") or "").lower()
            if str(did).lower() == "macos" or tp == "darwin":
                continue
            if tp.startswith("web"):
                continue
            if tp == "android":
                continue
            if tp != "ios":
                continue
            out.append({
                "id": did,
                "name": nm or str(did),
                "target_platform": tp,
                "emulator": d.get("emulator"),
            })
        return out
    except Exception:
        return []


def _filter_ios_sim_devices_by_xcode(items, project_root, env):
    """
    去掉「Flutter/simctl 有、但 Runner 的 xcodebuild destinations 里没有」的模拟器，
    避免选到后报 Unable to find a destination matching the provided destination specifier。
    """
    pr = (project_root or "").strip()
    if not pr or not items:
        return items
    uuids = _xcode_destination_uuid_ids(pr, env)
    if not uuids:
        return items
    uu = {u.upper() for u in uuids}
    out = []
    for it in items:
        if len(it) >= 4 and it[3] == "ios_sim":
            if str(it[1]).upper() not in uu:
                continue
        out.append(it)
    return out


def _sort_run_device_items(items):
    """下拉展示顺序：iOS 真机 → iOS 模拟器（本工具仅支持 iOS）。"""
    order = {"ios_device": 0, "ios_sim": 1}

    def _key(it):
        kind = it[3]
        boot_pri = 0 if it[2] == "Booted" else 1
        return (order.get(kind, 99), boot_pri, (it[0] or "").lower())

    return sorted(items, key=_key)


def _build_run_device_items(fc, env, project_root=None):
    """
    合并 simctl 与 `flutter devices --machine`，供「运行」下拉使用（仅 iOS）。
    每项为四元组：(展示名, device_id, 状态文案, run_kind)。
    run_kind: ios_device | ios_sim。
    """
    sims = list_simulators()
    sim_udids_upper = {u.upper() for _, u, _ in sims}
    sim_by_upper = {u.upper(): (n, st) for n, u, st in sims}
    rows = _flutter_devices_machine_parsed(fc, env, project_root=project_root)
    items = []
    seen = set()
    seen_udid_upper = set()

    def _mark(did):
        seen.add(did)
        if len(str(did)) >= 8 and "-" in str(did):
            seen_udid_upper.add(str(did).upper())

    if not rows:
        for name, udid, state in sims:
            tag = " [已启动]" if state == "Booted" else ""
            items.append((f"{name}{tag}", udid, state, "ios_sim"))
        items = _filter_ios_sim_devices_by_xcode(items, project_root, env)
        return _sort_run_device_items(items)

    for d in rows:
        did = d["id"]
        if not did or did in seen:
            continue
        tp = d["target_platform"]
        name = d["name"]

        if tp == "ios":
            em = d.get("emulator")
            up = did.upper()
            in_sim = up in sim_udids_upper
            if em is True:
                kind = "ios_sim"
            elif em is False:
                kind = "ios_device"
            else:
                kind = "ios_sim" if in_sim else "ios_device"
            _mark(did)
            if kind == "ios_sim":
                sn, st = sim_by_upper.get(up, (name, "Shutdown"))
                tag = " [已启动]" if st == "Booted" else ""
                items.append((f"{sn}{tag}", did, st, "ios_sim"))
            else:
                items.append((f"{name} [真机]", did, "Connected", "ios_device"))
            continue

    # `flutter devices` 通常只列部分模拟器；补上 simctl 中全部「可用」机型，便于切换
    for name, udid, state in sims:
        uu = udid.upper()
        if uu in seen_udid_upper:
            continue
        _mark(udid)
        tag = " [已启动]" if state == "Booted" else ""
        items.append((f"{name}{tag}", udid, state, "ios_sim"))

    items = _filter_ios_sim_devices_by_xcode(items, project_root, env)
    return _sort_run_device_items(items)


def _unpack_device_row(row):
    """兼容旧三元组，默认非 macos 视为 iOS 模拟器。"""
    if len(row) >= 4:
        return row[0], row[1], row[2], row[3]
    a, b, c = row[0], row[1], row[2]
    rk = "macos" if b == "macos" else "ios_sim"
    return a, b, c, rk


def _resolve_simulator_for_run(fc, env, fresh, device_label, device_id, device_state, project_root=None):
    """
    用 Runner 的 xcodebuild destinations ∩ flutter devices 得到「真正可编译」的模拟器，
    再校验/按名称重选。避免 Flutter 仍列出、Xcode 已不接受的 UDID（如旧 C327…）。
    """
    if device_id == "macos":
        return (device_label, device_id, device_state)

    def _state_for(udid):
        for _name, u, st in fresh:
            if u == udid:
                return st
        return "Shutdown"

    def _label(name, st):
        tag = " [已启动]" if st == "Booted" else ""
        return f"{name}{tag}"

    xcode_ids = (
        _xcode_runner_simulator_ids(project_root, env) if project_root else None)
    # 无结果或 Xcode 未列出任何模拟器时，不按模拟器 UDID 与 Xcode 求交（避免误杀）
    if not xcode_ids:
        x_set = None
    else:
        x_set = {u.upper() for u in xcode_ids}

    def _in_x(u):
        return x_set is None or u.upper() in x_set

    flutter_pairs = _flutter_ios_devices_machine(fc, env, cwd=project_root) or []
    booted_udids = {u for _n, u, st in fresh if st == "Booted"}

    prim = [(n, i) for n, i in flutter_pairs if _in_x(i)]
    if x_set and not prim:
        prim = [
            (n, u) for n, u, _s in fresh
            if u != "macos" and _in_x(u)
        ]
    if not prim:
        prim = list(flutter_pairs)
    if not prim:
        return _resolve_simulator_selection(
            fresh, device_label, device_id, device_state)

    by_id = {}
    for n, i in prim:
        if i.upper() not in by_id:
            by_id[i.upper()] = (n, i)

    did = device_id.upper()
    if did in by_id:
        n, i = by_id[did]
        st = _state_for(i)
        return (_label(n, st), i, st)

    base = device_label.split(" [")[0].strip()
    cands = [(n, i) for n, i in prim if n == base]
    if not cands:
        cands = [(n, i) for n, i in prim if base in n]
    if not cands:
        # Flutter 设备名常与 simctl 列表不一致，或仅部分机型出现在 flutter devices 中；
        # 仍允许使用当前 simctl 列表里有效的 UDID/名称（由 _resolve_simulator_selection 校验）。
        return _resolve_simulator_selection(
            fresh, device_label, device_id, device_state)
    for n, i in cands:
        if i in booted_udids:
            st = _state_for(i)
            return (_label(n, st), i, st)
    n, i = cands[0]
    st = _state_for(i)
    return (_label(n, st), i, st)




class AppDelegate(NSObject):
    window = objc.ivar()
    log_view = objc.ivar()

    template_field = objc.ivar()
    template_git_status_label = objc.ivar()
    project_name_field = objc.ivar()
    bundle_id_field = objc.ivar()
    display_name_field = objc.ivar()
    output_field = objc.ivar()
    create_btn = objc.ivar()

    project_popup = objc.ivar()
    source_field = objc.ivar()
    target_field = objc.ivar()
    b_side_channel_field = objc.ivar()
    sync_btn = objc.ivar()

    aside_project_field = objc.ivar()

    run_project_field = objc.ivar()
    device_popup = objc.ivar()
    mode_popup = objc.ivar()
    app_environment_popup = objc.ivar()
    show_dev_float_switch = objc.ivar()
    run_btn = objc.ivar()
    clear_ios_cache_btn = objc.ivar()
    stop_btn = objc.ivar()
    hot_reload_btn = objc.ivar()
    hot_restart_btn = objc.ivar()
    screenshot_fix_btn = objc.ivar()
    multi_shot_note_field = objc.ivar()
    multi_shot_capture_btn = objc.ivar()
    multi_shot_clear_btn = objc.ivar()
    multi_shot_count_label = objc.ivar()
    multi_shot_submit_btn = objc.ivar()
    agent_model_popup = objc.ivar()
    agent_model_custom_field = objc.ivar()

    obf_project_field = objc.ivar()
    obf_project_popup = objc.ivar()
    fw_obf_btn = objc.ivar()
    code_obf_btn = objc.ivar()
    silent_days_field = objc.ivar()

    ipa_project_field = objc.ivar()
    ipa_workdir_field = objc.ivar()
    ipa_silent_days_field = objc.ivar()
    build_ipa_btn = objc.ivar()

    cfg_bundle_field = objc.ivar()
    cfg_team_field = objc.ivar()
    cfg_keyid_field = objc.ivar()
    cfg_issuer_field = objc.ivar()
    cfg_profile_field = objc.ivar()
    cfg_cert_field = objc.ivar()
    cfg_privkey_field = objc.ivar()
    cfg_p8_field = objc.ivar()
    cfg_proxy_field = objc.ivar()
    cfg_proxy_popup = objc.ivar()
    refresh_proxy_btn = objc.ivar()
    upload_ipa_btn = objc.ivar()
    add_asc_monitor_btn = objc.ivar()

    ipa_version_field = objc.ivar()
    read_ipa_version_btn = objc.ivar()
    ipa_harden_path_field = objc.ivar()
    ipa_harden_macho_switch = objc.ivar()
    harden_ipa_btn = objc.ivar()
    ipa_harden_status = objc.ivar()
    app_store_capture_btn = objc.ivar()
    fix_bug_btn = objc.ivar()
    agent_fix_spinner = objc.ivar()
    sim_crawl_btn = objc.ivar()
    sim_crawl_stop_btn = objc.ivar()

    step1_status = objc.ivar()
    step2_status = objc.ivar()
    step3_status = objc.ivar()
    step4_status = objc.ivar()
    step5_status = objc.ivar()
    relaunch_app_btn = objc.ivar()

    tg_window = objc.ivar()
    tg_token_field = objc.ivar()
    tg_chat_id_field = objc.ivar()
    tg_enabled_switch = objc.ivar()
    tg_status_label = objc.ivar()

    def applicationDidFinishLaunching_(self, notification):
        _state["is_running"] = False
        _state["flutter_proc"] = None
        _state["crawl_running"] = False
        _state["crawl_stop"] = False
        _state["multi_pending_rel"] = []
        _state["multi_cap_lock"] = False
        _state["devices"] = []
        warnings.filterwarnings("ignore")

        win_w, win_h = 720, 1060
        frame = NSMakeRect(0, 0, win_w, win_h)
        style = (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                 NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable)
        self.window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            frame, style, NSBackingStoreBuffered, False
        )
        self.window.setTitle_("AB 包工厂")
        self.window.setMinSize_((650, 600))
        self.window.center()
        content = self.window.contentView()

        pad = 14
        inner_w = win_w - pad * 2
        row_h = 24
        sp = 24
        gap = 6
        mid_x = 240
        bw = inner_w - 30

        # ── Fixed bottom: Log area ──
        log_pad = 10
        log_h = 160
        log_scroll = NSScrollView.alloc().initWithFrame_(NSMakeRect(pad, log_pad, inner_w, log_h))
        log_scroll.setHasVerticalScroller_(True)
        log_scroll.setBorderType_(1)
        log_scroll.setAutoresizingMask_(0x01 | 0x02)
        self.log_view = NSTextView.alloc().initWithFrame_(NSMakeRect(0, 0, inner_w - 4, log_h))
        self.log_view.setEditable_(False)
        self.log_view.setFont_(NSFont.monospacedSystemFontOfSize_weight_(11, 0.0))
        self.log_view.setBackgroundColor_(
            NSColor.colorWithCalibratedRed_green_blue_alpha_(0.12, 0.12, 0.14, 1.0))
        self.log_view.setTextColor_(NSColor.whiteColor())
        self.log_view.setAutoresizingMask_(0x01 | 0x10)
        log_scroll.setDocumentView_(self.log_view)
        content.addSubview_(log_scroll)

        toolbar_y = log_pad + log_h + 4
        content.addSubview_(make_label("运行日志", pad, toolbar_y, 80, 16, size=11, bold=True))
        _spin_s = 16
        self.agent_fix_spinner = NSProgressIndicator.alloc().initWithFrame_(
            NSMakeRect(pad + 84, toolbar_y, _spin_s, _spin_s))
        self.agent_fix_spinner.setStyle_(NSProgressIndicatorStyleSpinning)
        self.agent_fix_spinner.setIndeterminate_(True)
        self.agent_fix_spinner.setDisplayedWhenStopped_(False)
        self.agent_fix_spinner.setToolTip_("Cursor Agent 正在执行一键/截屏修复")
        content.addSubview_(self.agent_fix_spinner)

        self.runtime_fvm_version = FVM_FLUTTER_VERSION

        # ── Run Project panel (above log) ──
        # 四行布局。NSBox 的 contentView 在首次构建时 bounds 常未扣掉标题/边线，若用 bounds 算 y 会把子视图放到负坐标，画出灰底外并压住「运行日志」工具栏。
        # 这里用外框高度推算内容区高度，并收窄可用宽度；开启 masksToBounds 裁剪溢出。
        # 与「运行日志」标题紧挨，减少大块空白；「打开项目」「清空」放在面板内与运行按钮同一行
        run_panel_y = toolbar_y + 6
        run_panel_h = 404
        run_row_gap = 14
        run_line_h = 26
        run_box = make_section_box("运行项目（每步完成后可运行验证）", pad, run_panel_y, inner_w, run_panel_h)
        rcv = run_box.contentView()
        rcv.setWantsLayer_(True)
        rcv.layer().setMasksToBounds_(True)
        # 标题栏 + NSBox 边框 + contentViewMargins 约占垂直空间；水平方向再减一档防止贴边裁切
        _run_chrome_v = 52
        _inner_h = max(140, run_panel_h - _run_chrome_v)
        _bw_cap = max(200, inner_w - 36)
        rbw = int(min(max(50.0, float(rcv.bounds().size.width)), _bw_cap))
        _rx = 10
        _uw = rbw - 2 * _rx
        rby = _inner_h - run_line_h - 8
        btn_h = 26
        _refresh_w = 52
        _choose_w = 56
        _mode_w = 88
        _run_w = 56
        _stop_w = 52
        _hr_w = 58
        _rs_w = 52
        _fix_w = 108

        rcv.addSubview_(make_label("项目:", _rx, rby, 36, run_line_h, size=11))
        self.run_project_field = make_input(
            _rx + 38, rby, _uw - 38 - _choose_w - 8, run_line_h, "Flutter 项目路径", mono=True)
        rcv.addSubview_(self.run_project_field)
        rcv.addSubview_(make_button("选择…", _rx + _uw - _choose_w, rby, _choose_w, run_line_h, self, self.browseRunProject_))

        rby -= run_row_gap + run_line_h
        rcv.addSubview_(make_label("设备:", _rx, rby, 36, run_line_h, size=11))
        self.device_popup = NSPopUpButton.alloc().initWithFrame_pullsDown_(
            NSMakeRect(_rx + 38, rby, _uw - 38 - _refresh_w - 8, run_line_h), False)
        self.device_popup.setFont_(NSFont.systemFontOfSize_(11))
        rcv.addSubview_(self.device_popup)
        rcv.addSubview_(make_button("刷新", _rx + _uw - _refresh_w, rby, _refresh_w, run_line_h, self, self.refreshDevices_))

        rby -= run_row_gap + run_line_h
        rcv.addSubview_(make_label("模式:", _rx, rby, 40, run_line_h, size=11))
        self.mode_popup = NSPopUpButton.alloc().initWithFrame_pullsDown_(
            NSMakeRect(_rx + 42, rby, _mode_w, run_line_h), False)
        self.mode_popup.setFont_(NSFont.systemFontOfSize_(11))
        self.mode_popup.addItemWithTitle_("Debug")
        self.mode_popup.addItemWithTitle_("Release")
        rcv.addSubview_(self.mode_popup)
        _st_x = _rx + 42 + _mode_w + 10
        self.step3_status = make_label("", _st_x, rby + 2, max(40, _rx + _uw - _st_x), 20, size=10)
        rcv.addSubview_(self.step3_status)

        rby -= run_row_gap + run_line_h
        rcv.addSubview_(make_label("修复模型:", _rx, rby, 72, run_line_h, size=11))
        _model_pop_w = min(340, max(220, _uw - 120))
        self.agent_model_popup = NSPopUpButton.alloc().initWithFrame_pullsDown_(
            NSMakeRect(_rx + 76, rby, _model_pop_w, run_line_h), False)
        self.agent_model_popup.setFont_(NSFont.systemFontOfSize_(11))
        for _lbl, _ in AGENT_MODEL_PRESETS:
            self.agent_model_popup.addItemWithTitle_(_lbl)
        rcv.addSubview_(self.agent_model_popup)
        self.agent_model_custom_field = make_input(
            _rx + 76 + _model_pop_w + 8, rby, _uw - 76 - _model_pop_w - 16, run_line_h,
            "自定义 id（优先）；下拉未列出的模型写这里", mono=True)
        rcv.addSubview_(self.agent_model_custom_field)
        self._load_agent_model_from_defaults()

        rby -= run_row_gap + run_line_h
        rcv.addSubview_(make_label("自动探查:", _rx, rby, 64, run_line_h, size=11))
        _scw, _ssw = 92, 48
        self.sim_crawl_btn = make_button(
            "模拟器巡检", _rx + 68, rby, _scw, btn_h, self, self.simulatorCrawlStart_, bold=True)
        self.sim_crawl_btn.setToolTip_(
            "启动/前置模拟器，在设备画面内网格点击并逐张截图，生成报告后可交 Cursor Agent 汇总疑似界面问题。"
            " 需在「系统设置 › 隐私与安全性 › 辅助功能」中允许本应用，否则无法模拟点击。"
            " 无法替代业务自动化测试，不保证遍历所有页面。")
        rcv.addSubview_(self.sim_crawl_btn)
        self.sim_crawl_stop_btn = make_button(
            "停止", _rx + 68 + _scw + 8, rby, _ssw, btn_h, self, self.simulatorCrawlStop_)
        self.sim_crawl_stop_btn.setEnabled_(False)
        rcv.addSubview_(self.sim_crawl_stop_btn)
        _hint_left = _rx + 68 + _scw + 8 + _ssw + 10
        _hint_w = max(80, int(_uw - _hint_left + _rx))
        rcv.addSubview_(make_label(
            "网格点击→截图→可选 Agent；须辅助功能授权；请先 ▶ 运行 再巡检",
            _hint_left, rby + 3, _hint_w, run_line_h, size=9, color=NSColor.secondaryLabelColor()))

        rby -= run_row_gap + run_line_h
        rcv.addSubview_(make_label("多图说明:", _rx, rby, 56, run_line_h, size=11))
        self.multi_shot_note_field = make_input(
            _rx + 58, rby, _uw - 58 - 8, run_line_h,
            "一句话描述问题（可选）；多次点「截一张」暂存，最后点「多图提交修Bug」", mono=False)
        self.multi_shot_note_field.setFont_(NSFont.systemFontOfSize_(11))
        rcv.addSubview_(self.multi_shot_note_field)

        rby -= run_row_gap + run_line_h
        _capw, _clrw, _subw = 64, 52, 118
        self.multi_shot_capture_btn = make_button(
            "截一张", _rx, rby, _capw, btn_h, self, self.multiShotCaptureOne_, bold=True)
        self.multi_shot_capture_btn.setToolTip_("截取当前模拟器画面，追加到待提交列表（可切换界面后再截）")
        rcv.addSubview_(self.multi_shot_capture_btn)
        self.multi_shot_clear_btn = make_button(
            "清空", _rx + _capw + 6, rby, _clrw, btn_h, self, self.multiShotClearPending_)
        self.multi_shot_clear_btn.setToolTip_("清空待提交列表并删除 ab_factory_pending 下已暂存的 PNG")
        rcv.addSubview_(self.multi_shot_clear_btn)
        self.multi_shot_count_label = make_label(
            "已 0 张", _rx + _capw + 6 + _clrw + 10, rby + 2, 120, run_line_h, size=11)
        rcv.addSubview_(self.multi_shot_count_label)
        self.multi_shot_submit_btn = make_button(
            "多图提交修Bug", _rx + _uw - _subw, rby, _subw, btn_h,
            self, self.multiScreensSubmitFixBug_, bold=True)
        self.multi_shot_submit_btn.setToolTip_(
            "将当前暂存的多张截图与说明、日志一并交给 Cursor Agent（与「截屏修Bug」单张流程独立）")
        rcv.addSubview_(self.multi_shot_submit_btn)

        rby -= run_row_gap + run_line_h
        _cache_w = min(260, max(196, _uw - 2 * _rx))
        self.clear_ios_cache_btn = make_button(
            "清 iOS 引擎与 Xcode 缓存", _rx, rby, _cache_w, btn_h,
            self, self.clearFlutterIosCache_)
        self.clear_ios_cache_btn.setToolTip_(
            "在「运行项目」目录执行 fvm flutter precache --ios；删除 FVM 下本工具锁定版本的 "
            "ios/ios-profile/ios-release 引擎缓存；并移除 ~/Library/Developer/Xcode/DerivedData/Runner-*。"
            " 可能耗时数分钟。")
        rcv.addSubview_(self.clear_ios_cache_btn)

        rby -= run_row_gap + run_line_h
        _gap_btn = 8
        _btn_total = (
            _fix_w + _gap_btn + _run_w + _gap_btn + _stop_w
            + _gap_btn + _hr_w + _gap_btn + _rs_w
        )
        _bx0 = _rx + _uw - _btn_total
        _opw = 76
        _clw = 48
        _shotw = 100
        rcv.addSubview_(make_button("打开项目", _rx, rby, _opw, btn_h, self, self.openProjectDir_))
        rcv.addSubview_(make_button("清空", _rx + _opw + 6, rby, _clw, btn_h, self, self.clearLog_))
        self.screenshot_fix_btn = make_button(
            "截屏修Bug", _rx + _opw + 6 + _clw + 6, rby, _shotw, btn_h,
            self, self.screenshotSimulatorFixBug_, bold=True)
        self.screenshot_fix_btn.setToolTip_(
            "对当前所选 iOS 模拟器窗口截图（须已启动），结合运行日志生成说明并交给 Cursor Agent 分析界面与代码")
        rcv.addSubview_(self.screenshot_fix_btn)
        self.fix_bug_btn = make_button(
            "一键修Bug", _bx0, rby, _fix_w, btn_h, self, self.fixBugWithCursor_, bold=True)
        self.fix_bug_btn.setToolTip_(
            "优先调用 Cursor Agent CLI 根据日志自动改代码；未安装 CLI 则打开 Cursor 与说明文档。"
            " CLI 安装: https://cursor.com/install")
        rcv.addSubview_(self.fix_bug_btn)
        self.run_btn = make_button(
            "▶ 运行", _bx0 + _fix_w + _gap_btn, rby, _run_w, btn_h, self, self.runFlutter_, bold=True)
        rcv.addSubview_(self.run_btn)
        self.stop_btn = make_button(
            "■ 停止", _bx0 + _fix_w + _gap_btn + _run_w + _gap_btn, rby, _stop_w, btn_h, self, self.stopFlutter_)
        self.stop_btn.setEnabled_(False)
        rcv.addSubview_(self.stop_btn)
        _x_hr = _bx0 + _fix_w + _gap_btn + _run_w + _gap_btn + _stop_w + _gap_btn
        self.hot_reload_btn = make_button(
            "热更新", _x_hr, rby, _hr_w, btn_h, self, self.flutterHotReload_)
        self.hot_reload_btn.setToolTip_("向 flutter run 发送 r：热重载（保留状态）")
        self.hot_reload_btn.setEnabled_(False)
        rcv.addSubview_(self.hot_reload_btn)
        self.hot_restart_btn = make_button(
            "重启", _x_hr + _hr_w + _gap_btn, rby, _rs_w, btn_h, self, self.flutterHotRestart_)
        self.hot_restart_btn.setToolTip_("向 flutter run 发送 R：热重启（重新执行 main）")
        self.hot_restart_btn.setEnabled_(False)
        rcv.addSubview_(self.hot_restart_btn)

        content.addSubview_(run_box)
        steps_bottom = run_panel_y + run_panel_h + 4

        # ── Scrollable steps area ──
        steps_scroll = NSScrollView.alloc().initWithFrame_(
            NSMakeRect(0, steps_bottom, win_w, win_h - steps_bottom))
        steps_scroll.setHasVerticalScroller_(True)
        steps_scroll.setBorderType_(0)
        steps_scroll.setDrawsBackground_(False)
        steps_scroll.setAutoresizingMask_(0x01 | 0x02 | 0x10)

        doc_view = FlippedView.alloc().initWithFrame_(NSMakeRect(0, 0, win_w, 100))
        y = 8

        # ── Title ──
        doc_view.addSubview_(make_label("AB 包工厂", pad, y, 200, 24, size=18, bold=True))
        doc_view.addSubview_(make_label(
            "创建项目 · 同步B面 · 添加A面 · 混淆 · 打包",
            pad + 120, y + 3, 350, 18, size=11, color=NSColor.secondaryLabelColor()
        ))
        _reload_w = 100
        self.relaunch_app_btn = make_button(
            "重新载入", win_w - pad - _reload_w, y + 1, _reload_w, 26,
            self, self.relaunchAppFromDisk_, bold=False)
        self.relaunch_app_btn.setToolTip_(
            "用当前磁盘上的 app.py 重新启动本应用（请先保存文件）。"
            "效果等同快捷重启，无需手动退出再打开。")
        doc_view.addSubview_(self.relaunch_app_btn)
        y += 30

        doc_view.addSubview_(make_label(
            "B面 ENVIRONMENT（▶ 运行；打包固定 release）",
            pad, y, 280, row_h, size=11))
        self.app_environment_popup = NSPopUpButton.alloc().initWithFrame_pullsDown_(
            NSMakeRect(pad + 286, y, 110, row_h), False)
        self.app_environment_popup.setFont_(NSFont.systemFontOfSize_(11))
        for _env_title in ("test", "beta", "release"):
            self.app_environment_popup.addItemWithTitle_(_env_title)
        self.app_environment_popup.setToolTip_(
            "注入 --dart-define=ENVIRONMENT=…，B 面 config.dart 与壳工程 EnvConfig（AB 状态查询域名）共用。"
            "test/beta/release → 测试/预发/正式。仅影响「▶ 运行」；「打包 IPA」固定 ENVIRONMENT=release。")
        doc_view.addSubview_(self.app_environment_popup)
        _dev_sw_x = pad + 286 + 110 + 14
        self.show_dev_float_switch = NSButton.alloc().initWithFrame_(
            NSMakeRect(_dev_sw_x, y, 220, row_h))
        self.show_dev_float_switch.setButtonType_(3)
        self.show_dev_float_switch.setTitle_("开发者选项悬浮按钮")
        self.show_dev_float_switch.setTarget_(self)
        self.show_dev_float_switch.setAction_("showDevFloatChanged:")
        self.show_dev_float_switch.setState_(1)
        self.show_dev_float_switch.setToolTip_(
            "Debug 运行时在壳工程注入 --dart-define=AB_SHOW_DEV_FLOAT=true/false，"
            "控制 EnvFloatingIndicator 悬浮按钮（仅 kDebugMode 生效；Release 始终不显示）。")
        doc_view.addSubview_(self.show_dev_float_switch)
        y += row_h + 10

        # ── Step 1: Create project ──
        # NSBox 的 contentView 首次构建时 bounds 高度常偏大，若用 bounds 算 by 会把各行挤到可视区下方，中间留出大块空白
        step1_h = 248
        _s1_chrome_v = 52
        _s1_inner_h = max(160, step1_h - _s1_chrome_v)
        box1 = make_section_box("步骤 1 · 创建新项目", pad, y, inner_w, step1_h)
        cv1 = box1.contentView()
        cv1.setWantsLayer_(True)
        cv1.layer().setMasksToBounds_(True)
        by = _s1_inner_h - row_h - 4

        cv1.addSubview_(make_label("模板路径:", 0, by, 62, row_h, size=11))
        _tpl_choose_w = 52
        _tpl_pull_w = 78
        _tpl_gap = 6
        _tpl_right_choose = bw - _tpl_choose_w
        _tpl_right_pull = _tpl_right_choose - _tpl_gap - _tpl_pull_w
        self.template_field = make_input(62, by, _tpl_right_pull - 62 - _tpl_gap, row_h, DEFAULT_TEMPLATE, mono=True)
        self.template_field.setStringValue_(DEFAULT_TEMPLATE)
        cv1.addSubview_(self.template_field)
        cv1.addSubview_(make_button("拉取更新", _tpl_right_pull, by, _tpl_pull_w, row_h, self, self.updateTemplateFromGit_))
        cv1.addSubview_(make_button("选择…", _tpl_right_choose, by, _tpl_choose_w, row_h, self, self.browseTemplate_))

        _tpl_row_top = by
        _git_gap = 8
        _git_h = 42
        # Flipped coords: 模板行在区块底部；Git 放在模板行上方，避免与输入框重叠
        _git_y = _tpl_row_top - _git_gap - _git_h
        self.template_git_status_label = make_label(
            "模板 Git：—", 0, _git_y, bw, _git_h, size=10, color=NSColor.secondaryLabelColor())
        self.template_git_status_label.setToolTip_("模板目录当前分支与提交，拉取更新前后会刷新")
        self.template_git_status_label.setMaximumNumberOfLines_(2)
        cv1.addSubview_(self.template_git_status_label)

        by = _git_y - run_row_gap - row_h
        cv1.addSubview_(make_label("项目名称:", 0, by, 62, row_h, size=11))
        self.project_name_field = make_input(62, by, 158, row_h, "my_app", mono=True)
        cv1.addSubview_(self.project_name_field)
        cv1.addSubview_(make_label("Bundle ID:", mid_x, by, 68, row_h, size=11))
        _bid_rnd_w = 44
        _bid_gap = 4
        self.bundle_id_field = make_input(
            mid_x + 68, by, bw - mid_x - 68 - _bid_rnd_w - _bid_gap,
            row_h, "com.example.myapp", mono=True)
        cv1.addSubview_(self.bundle_id_field)
        _bid_rnd_btn = make_button("随机", bw - _bid_rnd_w, by, _bid_rnd_w, row_h, self, self.randomBundleIdStep1_)
        _bid_rnd_btn.setToolTip_("从本机系统英语词典（/usr/share/dict/words 等）随机生成 com.xxx.xxx")
        cv1.addSubview_(_bid_rnd_btn)

        by -= sp
        cv1.addSubview_(make_label("显示名称:", 0, by, 62, row_h, size=11))
        self.display_name_field = make_input(62, by, 158, row_h, "可选，留空用项目名")
        cv1.addSubview_(self.display_name_field)
        cv1.addSubview_(make_label("输出目录:", mid_x, by, 62, row_h, size=11))
        self.output_field = make_input(mid_x + 68, by, bw - mid_x - 132, row_h, DEFAULT_OUTPUT, mono=True)
        self.output_field.setStringValue_(DEFAULT_OUTPUT)
        cv1.addSubview_(self.output_field)
        cv1.addSubview_(make_button("选择…", bw - 54, by, 54, row_h, self, self.browseOutput_))

        by -= sp + 4
        self.step1_status = make_label("", 0, by + 2, bw - 110, 20, size=11)
        cv1.addSubview_(self.step1_status)
        self.create_btn = make_button("创建项目", bw - 90, by, 90, 28, self, self.createProject_, bold=True)
        cv1.addSubview_(self.create_btn)
        doc_view.addSubview_(box1)
        y += step1_h + gap

        # ── Step 2: Sync secondary ──
        step2_h = 192
        box2 = make_section_box("步骤 2 · 同步 B 面代码", pad, y, inner_w, step2_h)
        cv2 = box2.contentView()
        by = int(cv2.bounds().size.height) - row_h - 4

        cv2.addSubview_(make_label("项目代号:", 0, by, 62, row_h, size=11))
        self.project_popup = NSPopUpButton.alloc().initWithFrame_pullsDown_(NSMakeRect(62, by, 158, row_h), False)
        self.project_popup.setFont_(NSFont.systemFontOfSize_(11))
        for code in PROJECT_CODES:
            self.project_popup.addItemWithTitle_(PROJECT_LABELS.get(code, code))
        cv2.addSubview_(self.project_popup)
        cv2.addSubview_(make_label("源码路径:", mid_x, by, 62, row_h, size=11))
        self.source_field = make_input(mid_x + 68, by, bw - mid_x - 132, row_h, "/path/to/app", mono=True)
        cv2.addSubview_(self.source_field)
        cv2.addSubview_(make_button("选择…", bw - 54, by, 54, row_h, self, self.browseSource_))

        by -= sp
        cv2.addSubview_(make_label("目标工程:", 0, by, 62, row_h, size=11))
        self.target_field = make_input(62, by, bw - 132, row_h, "步骤1创建的项目路径（自动填入）", mono=True)
        cv2.addSubview_(self.target_field)
        cv2.addSubview_(make_button("选择…", bw - 54, by, 54, row_h, self, self.browseTarget_))

        by -= sp
        # B面渠道：须保留「读」「写」双按钮；输入框宽度 bw-162，为右侧 88px 按钮区留空（勿改 bw-102，会盖住「读」）
        cv2.addSubview_(make_label("B面渠道:", 0, by, 62, row_h, size=11))
        self.b_side_channel_field = make_input(
            62, by, bw - 162, row_h, "APP_CHANNEL，如 GT001", mono=True)
        self.b_side_channel_field.setStringValue_("GT001")
        self.b_side_channel_field.setToolTip_(
            "点「读」从目标工程 config.dart 填入；点「写」写回；"
            "运行/打包/同步不自动改此文件")
        cv2.addSubview_(self.b_side_channel_field)
        read_ch_btn = make_button("读", bw - 90, by, 44, row_h, self, self.readBSideChannel_)
        read_ch_btn.setToolTip_("从目标工程 config.dart 读取 xxChannel 的 APP_CHANNEL defaultValue")
        cv2.addSubview_(read_ch_btn)
        write_ch_btn = make_button("写", bw - 44, by, 44, row_h, self, self.writeBSideChannel_)
        write_ch_btn.setToolTip_(
            "将上方渠道写入目标工程 B 面 config.dart 的 xxChannel defaultValue")
        cv2.addSubview_(write_ch_btn)

        by -= sp + 2
        self.step2_status = make_label("", 0, by + 2, bw - 464, 20, size=11)
        cv2.addSubview_(self.step2_status)
        self.repair_imports_btn = make_button(
            "修正导入", bw - 454, by, 104, 28, self, self.repairObfImports_)
        self.repair_imports_btn.setToolTip_(
            "同步后修复：把 A 面 lib/ 中残留的混淆包名 import 还原为标准包名"
            "（如 package:orbit_layout/shared_preferences.dart → package:shared_preferences/shared_preferences.dart），"
            "随后自动 pub get。混淆名按 pubspec 已声明的真实依赖自动识别，可在同步前/后随时点，幂等安全。")
        cv2.addSubview_(self.repair_imports_btn)
        self.restore_pubspec_btn = make_button(
            "还原 pubspec", bw - 340, by, 100, 28, self, self.restorePubspecClean_)
        self.restore_pubspec_btn.setToolTip_(
            "将目标工程 pubspec.yaml 还原为干净副本：优先 pubspec.yaml.clean，"
            "其次 git HEAD，再次 pubspec.yaml.bak；当前文件备份为 pubspec.yaml.before_restore")
        cv2.addSubview_(self.restore_pubspec_btn)
        align_btn = make_button("对齐模板脚本", bw - 230, by, 114, 28, self, self.alignScriptsFromTemplate_)
        align_btn.setToolTip_(
            "把模板 scripts/ 覆盖到目标工程，确保同步用的是工程自身的最新脚本"
            "（修复 Base64 byPath 绝对路径、重名图错配等问题）。建议同步前点一次。")
        cv2.addSubview_(align_btn)
        self.sync_btn = make_button("同步 B 面代码", bw - 110, by, 110, 28, self, self.syncSecondary_, bold=True)
        cv2.addSubview_(self.sync_btn)

        by -= sp + 6
        cv2.addSubview_(make_label(
            "💡 一键跑完整链路（等价 full_obfuscate.sh，含工厂 pubspec 修复）：同步 → 修复pubspec → 代码混淆(--all) → Framework 混淆(run)",
            0, by + 4, bw - 158, 18, size=10, color=NSColor.secondaryLabelColor()))
        self.pipeline_btn = make_button("一键同步+混淆", bw - 150, by, 150, 28, self, self.oneClickSyncObf_, bold=True)
        self.pipeline_btn.setToolTip_(
            "串联执行：sync_secondary → 修复 pubspec → obfuscate_code --all → obfuscate_frameworks run；"
            "任一步失败即中止。适合确认源码路径无误后一次跑完。")
        cv2.addSubview_(self.pipeline_btn)
        doc_view.addSubview_(box2)
        y += step2_h + gap

        # ── Step 3: Add A-side code (Cursor) ──
        step3a_h = 72
        box3a = make_section_box("步骤 3 · 添加 A 面代码", pad, y, inner_w, step3a_h)
        cv3a = box3a.contentView()
        by = int(cv3a.bounds().size.height) - row_h - 4

        cv3a.addSubview_(make_label("项目路径:", 0, by, 62, row_h, size=11))
        self.aside_project_field = make_input(62, by, bw - 200, row_h, "步骤1创建的项目路径（自动填入）", mono=True)
        cv3a.addSubview_(self.aside_project_field)
        cv3a.addSubview_(make_button("选择…", bw - 132, by, 54, row_h, self, self.browseAsideProject_))
        cv3a.addSubview_(make_button("Cursor 打开", bw - 72, by, 72, row_h, self, self.openInCursor_, bold=True))

        cv3a.addSubview_(make_label(
            "💡 先完成步骤1、2并运行验证 · A 面仅 lib/modules/primary/ · 兼容 iOS 且需适配 iPad 审核",
            0, by - 18, bw, 16, size=10, color=NSColor.secondaryLabelColor()
        ))
        doc_view.addSubview_(box3a)
        y += step3a_h + gap

        # ── Step 4: Obfuscation ──
        step4_h = 190
        box4 = make_section_box("步骤 4 · 混淆与配置", pad, y, inner_w, step4_h)
        cv4 = box4.contentView()
        by = int(cv4.bounds().size.height) - row_h - 4

        cv4.addSubview_(make_label("项目路径:", 0, by, 62, row_h, size=11))
        self.obf_project_field = make_input(62, by, bw - 132, row_h, "步骤1创建的项目路径（自动填入）", mono=True)
        cv4.addSubview_(self.obf_project_field)
        cv4.addSubview_(make_button("选择…", bw - 54, by, 54, row_h, self, self.browseObfProject_))

        by -= sp
        cv4.addSubview_(make_label("混淆代号:", 0, by, 62, row_h, size=11))
        self.obf_project_popup = NSPopUpButton.alloc().initWithFrame_pullsDown_(
            NSMakeRect(62, by, 240, row_h), False)
        self.obf_project_popup.setFont_(NSFont.systemFontOfSize_(11))
        for code in PROJECT_CODES:
            self.obf_project_popup.addItemWithTitle_(PROJECT_LABELS.get(code, code))
        cv4.addSubview_(self.obf_project_popup)
        cv4.addSubview_(make_label(
            "须与步骤2 同步的 -p 一致（obfuscate_* 显式 -p，保证多包差异化）",
            308, by + 2, bw - 308, 18, size=10, color=NSColor.secondaryLabelColor()))

        by -= sp
        self.fw_obf_btn = make_button("Framework 混淆", 0, by, 120, 26, self, self.obfFrameworks_, bold=True)
        cv4.addSubview_(self.fw_obf_btn)
        self.code_obf_btn = make_button("代码混淆（全部）", 126, by, 126, 26, self, self.obfCode_, bold=True)
        cv4.addSubview_(self.code_obf_btn)
        self.one_click_obf_btn = make_button("一键混淆", bw - 100, by, 100, 26, self, self.oneClickObf_, bold=True)
        self.one_click_obf_btn.setToolTip_(
            "依次执行：代码混淆(--all) → Framework 混淆(run)；等价 full_obfuscate.sh 的后两步（不重新同步）")
        cv4.addSubview_(self.one_click_obf_btn)
        self.step4_status = make_label("", 258, by + 2, bw - 258 - 106, 20, size=11)
        cv4.addSubview_(self.step4_status)

        by -= sp
        cv4.addSubview_(make_label("静默期:", 0, by, 48, row_h, size=11))
        self.silent_days_field = make_input(48, by, 40, row_h, "3")
        self.silent_days_field.setStringValue_("3")
        self.silent_days_field.setAlignment_(1)
        cv4.addSubview_(self.silent_days_field)
        cv4.addSubview_(make_label("天 (0=禁用)", 92, by, 80, row_h, size=11, color=NSColor.secondaryLabelColor()))
        cv4.addSubview_(make_button("修改静默期", 178, by, 80, 24, self, self.applySilentPeriod_))
        cv4.addSubview_(make_button("读取", 262, by, 40, 24, self, self.readSilentPeriod_))
        cv4.addSubview_(make_label(
            "💡 同步完成后自动补齐 plugins 缺失 path · Base64 图片映射 · 官方 dart 混淆在打包时",
            310, by + 2, bw - 310, 16, size=10, color=NSColor.secondaryLabelColor()
        ))

        by -= sp + 2
        cv4.addSubview_(make_label("替换星火:", 0, by, 62, row_h, size=11))
        self.brand_replace_field = make_input(62, by, 200, row_h, "新品牌名，替换所有「星火」")
        self.brand_replace_field.setToolTip_(
            "把 B 面所有「星火」替换为此文字：明文字面量/注释 + 混淆 "
            "String.fromCharCodes 编码串都会改；「星期」等无关字符不动。")
        cv4.addSubview_(self.brand_replace_field)
        cv4.addSubview_(make_button("预览", 268, by, 48, 24, self, self.previewBrandReplace_))
        cv4.addSubview_(make_button("替换星火", 322, by, 80, 24, self, self.replaceBrandText_, bold=True))
        cv4.addSubview_(make_label(
            "💡 先「预览」看命中，确认后「替换」；改完建议 git diff 复核",
            410, by + 2, bw - 410, 16, size=10, color=NSColor.secondaryLabelColor()
        ))
        doc_view.addSubview_(box4)
        y += step4_h + gap

        # ── Step 5: Build IPA ──
        step5_h = 424
        box5 = make_section_box("步骤 5 · 打包 IPA", pad, y, inner_w, step5_h)
        cv5 = box5.contentView()
        lw = 72
        col2 = mid_x
        by = int(cv5.bounds().size.height) - row_h - 4

        cv5.addSubview_(make_label("Flutter工程:", 0, by, lw, row_h, size=11))
        self.ipa_project_field = make_input(lw, by, bw - lw - 58, row_h, "步骤1创建的项目路径（自动填入）", mono=True)
        cv5.addSubview_(self.ipa_project_field)
        cv5.addSubview_(make_button("选择…", bw - 54, by, 54, row_h, self, self.browseIpaProject_))

        by -= sp
        cv5.addSubview_(make_label("工作目录:", 0, by, lw, row_h, size=11))
        self.ipa_workdir_field = make_input(lw, by, bw - lw - 58, row_h, "存放证书和配置的目录", mono=True)
        cv5.addSubview_(self.ipa_workdir_field)
        cv5.addSubview_(make_button("选择…", bw - 54, by, 54, row_h, self, self.browseIpaWorkdir_))

        by -= sp
        cv5.addSubview_(make_label("版本号:", 0, by, lw, row_h, size=11))
        self.ipa_version_field = make_input(lw, by, bw - lw - 100, row_h, "pubspec version，如 1.0.0+1，留空打包不改", mono=True)
        cv5.addSubview_(self.ipa_version_field)
        self.read_ipa_version_btn = make_button("读取", bw - 90, by, 44, row_h, self, self.readIpaPubspecVersion_)
        cv5.addSubview_(self.read_ipa_version_btn)
        cv5.addSubview_(make_button("写入", bw - 44, by, 44, row_h, self, self.writeIpaPubspecVersion_))

        by -= sp
        cv5.addSubview_(make_label("商店截图:", 0, by, lw, row_h, size=11))
        _as_cap_w = 118
        self.app_store_capture_btn = make_button(
            "截图并转换", lw, by, _as_cap_w, row_h,
            self, self.captureAppStoreScreenshot_, bold=True)
        self.app_store_capture_btn.setToolTip_(
            "对「运行项目」区当前所选 iOS 模拟器截屏，自动转为 App Store 尺寸"
            "（iPhone 1242×2688 / iPad 2064×2752），保存到工程 screenshots/app_store/")
        cv5.addSubview_(self.app_store_capture_btn)
        cv5.addSubview_(make_label(
            "独立功能；需在上方运行区选好模拟器并先 ▶ 运行；iPhone/iPad 按设备名自动识别",
            lw + _as_cap_w + 8, by + 2, bw - lw - _as_cap_w - 16, 16,
            size=10, color=NSColor.secondaryLabelColor()))

        by -= sp + 4
        cv5.addSubview_(make_label(
            "── build_config.json ──", 0, by + 2, 200, 16, size=10,
            color=NSColor.secondaryLabelColor()))
        self.add_asc_monitor_btn = make_button(
            "添加监控", bw - 250, by - 1, 120, 20, self, self.addAscMonitor_, bold=True)
        self.add_asc_monitor_btn.setToolTip_(
            "将当前 Apple API 配置推送到 ASC 监控页并打开浏览器")
        cv5.addSubview_(self.add_asc_monitor_btn)
        cv5.addSubview_(make_button("生成 CSR & 私钥", bw - 120, by - 1, 120, 20, self, self.genCsr_))
        by -= 26

        cv5.addSubview_(make_label("Bundle ID:", 0, by, lw, row_h, size=11))
        _cfg_bid_rnd_w = 44
        _cfg_bid_gap = 4
        _cfg_bid_in_w = col2 - lw - 10 - _cfg_bid_rnd_w - _cfg_bid_gap
        self.cfg_bundle_field = make_input(lw, by, _cfg_bid_in_w, row_h, "com.example.app", mono=True)
        cv5.addSubview_(self.cfg_bundle_field)
        _cfg_bid_btn = make_button("随机", col2 - 10 - _cfg_bid_rnd_w, by, _cfg_bid_rnd_w, row_h, self, self.randomBundleIdCfg_)
        _cfg_bid_btn.setToolTip_("从本机系统英语词典（/usr/share/dict/words 等）随机生成 com.xxx.xxx")
        cv5.addSubview_(_cfg_bid_btn)
        cv5.addSubview_(make_label("Team ID:", col2, by, 56, row_h, size=11))
        self.cfg_team_field = make_input(col2 + 56, by, bw - col2 - 56, row_h, "XXXXXXXXXX", mono=True)
        cv5.addSubview_(self.cfg_team_field)

        by -= sp
        cv5.addSubview_(make_label("API Key ID:", 0, by, lw, row_h, size=11))
        self.cfg_keyid_field = make_input(lw, by, col2 - lw - 10, row_h, "Key ID", mono=True)
        cv5.addSubview_(self.cfg_keyid_field)
        cv5.addSubview_(make_label("Issuer ID:", col2, by, 60, row_h, size=11))
        self.cfg_issuer_field = make_input(col2 + 60, by, bw - col2 - 60, row_h, "Issuer ID", mono=True)
        cv5.addSubview_(self.cfg_issuer_field)

        by -= sp
        cv5.addSubview_(make_label("描述文件:", 0, by, lw, row_h, size=11))
        self.cfg_profile_field = make_input(lw, by, col2 - lw - 10, row_h, "appstore.mobileprovision")
        self.cfg_profile_field.setStringValue_("appstore.mobileprovision")
        cv5.addSubview_(self.cfg_profile_field)
        cv5.addSubview_(make_label("证书:", col2, by, 34, row_h, size=11))
        self.cfg_cert_field = make_input(col2 + 34, by, bw - col2 - 34, row_h, "ios_distribution.cer")
        self.cfg_cert_field.setStringValue_("ios_distribution.cer")
        cv5.addSubview_(self.cfg_cert_field)

        by -= sp
        cv5.addSubview_(make_label("私钥:", 0, by, 34, row_h, size=11))
        self.cfg_privkey_field = make_input(34, by, col2 - 44, row_h, "mykey.key")
        self.cfg_privkey_field.setStringValue_("mykey.key")
        cv5.addSubview_(self.cfg_privkey_field)
        cv5.addSubview_(make_label("P8文件:", col2, by, 48, row_h, size=11))
        self.cfg_p8_field = make_input(col2 + 48, by, bw - col2 - 48, row_h, "private_keys/AuthKey_XXX.p8")
        cv5.addSubview_(self.cfg_p8_field)

        by -= sp
        _px_lbl, _px_dd_x, _px_dd_w = 34, 34, 210
        _px_rf_w, _px_rf_x = 44, _px_dd_x + _px_dd_w + 4
        _px_up_w, _px_in_x = 100, _px_rf_x + _px_rf_w + 4
        _px_in_w = bw - _px_in_x - _px_up_w - 4
        cv5.addSubview_(make_label("代理:", 0, by, _px_lbl, row_h, size=11))
        self.cfg_proxy_popup = NSPopUpButton.alloc().initWithFrame_pullsDown_(
            NSMakeRect(_px_dd_x, by, _px_dd_w, row_h), False)
        self.cfg_proxy_popup.setFont_(NSFont.systemFontOfSize_(10))
        self.cfg_proxy_popup.addItemWithTitle_("— 选择 proxifly US 代理 —")
        self.cfg_proxy_popup.setTarget_(self)
        self.cfg_proxy_popup.setAction_(objc.selector(
            self.proxyListPopupChanged_, signature=b'v@:@'))
        cv5.addSubview_(self.cfg_proxy_popup)
        self.refresh_proxy_btn = make_button(
            "刷新", _px_rf_x, by, _px_rf_w, row_h, self, self.refreshProxyList_)
        cv5.addSubview_(self.refresh_proxy_btn)
        self.cfg_proxy_field = make_input(
            _px_in_x, by, max(80, _px_in_w), row_h,
            "socks5://host:port:user:pass（上传用）", mono=True)
        cv5.addSubview_(self.cfg_proxy_field)
        self.upload_ipa_btn = make_button(
            "上传 IPA", bw - _px_up_w, by, _px_up_w, 26, self, self.uploadIpa_, bold=True)
        cv5.addSubview_(self.upload_ipa_btn)

        by -= sp + 4
        cv5.addSubview_(make_label(
            "── 成品包混淆（独立）──", 0, by + 2, 200, 16, size=10,
            color=NSColor.secondaryLabelColor()))
        by -= 22
        cv5.addSubview_(make_label("IPA 路径:", 0, by, lw, row_h, size=11))
        self.ipa_harden_path_field = make_input(
            lw, by, bw - lw - 168, row_h,
            "工厂打包产物或任意 .ipa 绝对路径", mono=True)
        cv5.addSubview_(self.ipa_harden_path_field)
        cv5.addSubview_(make_button("选择…", bw - 160, by, 54, row_h, self, self.browseIpaHarden_))
        self.ipa_harden_macho_switch = NSButton.alloc().initWithFrame_(
            NSMakeRect(bw - 100, by + 2, 96, row_h))
        self.ipa_harden_macho_switch.setButtonType_(3)
        self.ipa_harden_macho_switch.setTitle_("Mach-O")
        self.ipa_harden_macho_switch.setState_(0)
        self.ipa_harden_macho_switch.setToolTip_(
            "启用 Mach-O 类名混淆（中高风险，提审前需真机回归）。默认仅资源指纹差异化。")
        cv5.addSubview_(self.ipa_harden_macho_switch)
        by -= sp
        cv5.addSubview_(make_label(
            "💡 与「打包 IPA」分离：可混淆本工厂产物，也可选外部 IPA；"
            "使用上方工作目录的描述文件加固后重签",
            0, by + 2, bw, 16, size=10, color=NSColor.secondaryLabelColor()))
        by -= sp + 2
        cv5.addSubview_(make_label("静默期:", 0, by, 48, row_h, size=11))
        self.ipa_silent_days_field = make_input(48, by, 36, row_h, "3")
        self.ipa_silent_days_field.setStringValue_("3")
        self.ipa_silent_days_field.setAlignment_(1)
        cv5.addSubview_(self.ipa_silent_days_field)
        cv5.addSubview_(make_label("天", 86, by, 16, row_h, size=11, color=NSColor.secondaryLabelColor()))
        cv5.addSubview_(make_button("生成配置", 110, by, 72, 26, self, self.genConfig_, bold=True))
        cv5.addSubview_(make_button("读取", 186, by, 40, 26, self, self.readConfig_))
        self.step5_status = make_label("", 234, by + 2, bw - 344, 20, size=11)
        cv5.addSubview_(self.step5_status)
        self.harden_ipa_btn = make_button("混淆 IPA", bw - 204, by, 100, 28, self, self.hardenIpa_, bold=True)
        self.harden_ipa_btn.setToolTip_(
            "对 IPA 路径执行资源指纹差异化；可选 Mach-O；"
            "若工作目录有描述文件则自动重签")
        cv5.addSubview_(self.harden_ipa_btn)
        self.ipa_harden_status = make_label("", bw - 298, by + 4, 88, 20, size=10)
        cv5.addSubview_(self.ipa_harden_status)
        self.build_ipa_btn = make_button("打包 IPA", bw - 100, by, 100, 28, self, self.buildIpa_, bold=True)
        cv5.addSubview_(self.build_ipa_btn)

        doc_view.addSubview_(box5)
        y += step5_h + 10

        # ── Set document view height ──
        doc_view.setFrame_(NSMakeRect(0, 0, win_w, y))
        steps_scroll.setDocumentView_(doc_view)
        content.addSubview_(steps_scroll)

        self.window.makeKeyAndOrderFront_(None)
        NSApp.activateIgnoringOtherApps_(True)

        self._log(f"AB 包工厂 v{APP_VERSION} 已启动 (Flutter {self.runtime_fvm_version} / FVM)")
        if os.path.isdir(DEFAULT_TEMPLATE):
            self._log(f"模板目录: {DEFAULT_TEMPLATE} ✓")
        else:
            self._log(f"⚠ 默认模板目录不存在: {DEFAULT_TEMPLATE}")

        fvm = _find_fvm()
        if fvm:
            self._log(f"FVM: {fvm} ✓")
        else:
            self._log(
                "❌ 未检测到 FVM；本工具仅通过 FVM 运行 Flutter。"
                "请安装（如 brew install fvm）并加入 PATH。")

        self._load_b_side_prefs()
        self._install_notify_menu()

        def kick_devices():
            proj = self._run_project_path_for_devices()
            threading.Thread(
                target=self._refresh_device_list, args=(proj,), daemon=True).start()

        NSOperationQueue.mainQueue().addOperationWithBlock_(kick_devices)
        NSOperationQueue.mainQueue().addOperationWithBlock_(
            lambda: self._refresh_template_git_status_label())
        threading.Thread(
            target=self._refresh_socks_proxy_list, kwargs={"log": False}, daemon=True).start()

    # ── Devices ──

    @objc.python_method
    def _run_project_path_for_devices(self):
        """供 FVM / flutter devices 使用的工程目录（须含 pubspec）；仅主线程读 UI。"""
        for field in (
            self.run_project_field,
            self.aside_project_field,
            self.target_field,
            self.obf_project_field,
            self.ipa_project_field,
        ):
            p = str(field.stringValue()).strip()
            if p and os.path.isdir(p) and os.path.isfile(os.path.join(p, "pubspec.yaml")):
                return p
        return ""

    @objc.python_method
    def _refresh_device_list(self, project_root=None):
        self._log("正在检测可用设备…")
        env = get_env()
        fc = flutter_cmd()
        pr = (project_root or "").strip()
        if not fc:
            self._log(
                "❌ 未检测到 FVM，无法列出 Flutter 设备。"
                "请安装后重试，并在工程根执行 `fvm use`。")
            normalized = []
            _state["devices"] = []

            def _empty_popup():
                self.device_popup.removeAllItems()
            NSOperationQueue.mainQueue().addOperationWithBlock_(_empty_popup)
            return

        items = _build_run_device_items(fc, env, project_root=pr or None)

        # NSPopUpButton.addItemWithTitle_ 会按标题去重，导致跨 iOS 版本同名模拟器
        # 只保留一项、index 与 _state["devices"] 错位（出现「选 iPhone 实际跑 iPad」）。
        # 这里强制把同名标题去重为唯一字符串，并保留原始展示名供日志使用。
        title_count = {}
        for it in items:
            title_count[it[0]] = title_count.get(it[0], 0) + 1
        title_seen = {}
        normalized = []
        for it in items:
            base = it[0]
            udid = str(it[1])
            if title_count.get(base, 0) > 1:
                title_seen[base] = title_seen.get(base, 0) + 1
                short = udid[-6:].upper() if len(udid) >= 6 else udid
                label = f"{base} · {short}"
            else:
                label = base
            normalized.append((label, it[1], it[2], it[3]))

        _state["devices"] = normalized

        def _update():
            self.device_popup.removeAllItems()
            menu = self.device_popup.menu()
            for i, row in enumerate(normalized):
                label = row[0]
                self.device_popup.addItemWithTitle_(label)
                # 由于 NSPopUpButton 会按标题去重；这里取「同名标题中最后一项」，
                # 通过 representedObject 把行索引绑到菜单项，运行时按对象取而非按下拉 index。
                last = menu.itemAtIndex_(menu.numberOfItems() - 1)
                if last is not None:
                    last.setTitle_(label)
                    last.setRepresentedObject_(i)
        NSOperationQueue.mainQueue().addOperationWithBlock_(_update)
        n_phys = sum(1 for it in items if len(it) >= 4 and it[3] == "ios_device")
        self._log(
            f"检测到 {len(items)} 台 iOS 相关目标（真机 + 模拟器）；"
            f"其中 iOS 真机 {n_phys} 台")
        if not pr and fc and _is_fvm_flutter_cmd(fc) and n_phys == 0:
            self._log(
                "💡 若仍无真机：请在「运行项目」填写含 pubspec 的 Flutter 工程路径后点「刷新」"
                "（FVM 依赖工程目录或 ~/fvm/versions 下已缓存的 SDK）。")

    @objc.python_method
    def _verify_flutter_xcodebuild_patch(self, env):
        """
        自检：当前正在用的 Flutter SDK 必须已打过 xcodeproj.dart 的
        `-workspace` 补丁。否则 AB 工厂从 launchd 启动时，`flutter run`
        内部第一次调 `xcodebuild -project ... -sdk iphonesimulator
        -destination id=UDID -showBuildSettings` 会丢全部 simulator
        destinations、立刻失败。
        检查方式：直接读 SDK 源码里这条命令构造点是否含 -workspace 分支。
        """
        try:
            fc = flutter_cmd()
            if not fc:
                self._log("  ⚠ 未检测到 FVM，跳过 Flutter SDK 补丁自检")
                return
            v = ""
            try:
                vr = subprocess.run(
                    [*fc, "--version", "--machine"],
                    capture_output=True, text=True, env=env, timeout=15)
                m = re.search(r'"frameworkVersion"\s*:\s*"([^"]+)"', vr.stdout or "")
                v = m.group(1) if m else ""
            except Exception:
                pass
            home = os.path.expanduser("~")
            candidates = []
            if v:
                candidates.append(os.path.join(
                    home, "fvm", "versions", v,
                    "packages", "flutter_tools", "lib", "src", "ios",
                    "xcodeproj.dart"))
            candidates.append(os.path.join(
                home, "flutter",
                "packages", "flutter_tools", "lib", "src", "ios",
                "xcodeproj.dart"))
            src_path = next((p for p in candidates if os.path.isfile(p)), None)
            if src_path is None:
                self._log(
                    "  ⚠ 找不到 Flutter SDK 的 xcodeproj.dart，跳过补丁自检")
                return
            with open(src_path, "r", encoding="utf-8") as f:
                src = f.read()
            patched = "AB-Factory patch" in src and "workspaceForProject" in src
            if patched:
                self._log("  Flutter SDK -workspace 补丁: 已应用 ✓")
                return
            self._log(
                "  ❌ 检测到 Flutter SDK 未打 -workspace 补丁，AB 工厂从 launchd "
                "启动时 `flutter run` 必然失败！")
            self._log(f"     SDK 源文件: {src_path}")
            self._log(
                "     请在终端运行: 找到上面这个文件，把 getBuildSettings() 里 "
                "硬编码的 `'-project', _fileSystem.path.absolute(projectPath)` "
                "改为「若同目录存在 Runner.xcworkspace 则用 -workspace」分支，"
                "然后 `rm <fvm 路径>/bin/cache/flutter_tools.snapshot && "
                "fvm flutter --version` 触发重建快照。")
        except Exception as e:
            self._log(f"  ⚠ Flutter SDK 补丁自检异常: {e}")

    @objc.python_method
    def _selected_run_device_row(self):
        """
        返回当前下拉所选设备四元组 (label, id, state, run_kind) 或 None。
        优先按 NSMenuItem.representedObject 中保存的行索引取，避免 NSPopUpButton
        按标题去重导致 indexOfSelectedItem 与 _state["devices"] 错位。

        注意：必须保留 @objc.python_method 装饰器。否则 PyObjC 会按
        "下划线转冒号" 规则把它误注册成多入参 ObjC selector
        (`_selected:run:device:row:`), 在 first-responder 链 / KVC 路径上被错误
        派发, 可能引发 ObjC↔Python 桥递归并触发主线程 SIGSEGV。
        """
        devices = _state.get("devices") or []
        if not devices:
            return None
        try:
            item = self.device_popup.selectedItem()
        except Exception:
            item = None
        if item is not None:
            try:
                ro = item.representedObject()
            except Exception:
                ro = None
            if isinstance(ro, int) and 0 <= ro < len(devices):
                return _unpack_device_row(devices[ro])
            try:
                title = str(item.title())
            except Exception:
                title = ""
            if title:
                for row in devices:
                    if str(row[0]) == title:
                        return _unpack_device_row(row)
        try:
            idx = int(self.device_popup.indexOfSelectedItem())
        except Exception:
            idx = -1
        if 0 <= idx < len(devices):
            return _unpack_device_row(devices[idx])
        return None

    # ── Logging ──

    @objc.python_method
    def _log(self, msg):
        """
        线程安全地排队一行日志, 由 _flush_log_buffer 在主线程合并 flush。
        - 同一时刻最多只挂一个 main-queue block (用 _log_flush_scheduled 去重),
          避免子进程瞬间吐千行时把 NSOperationQueue 主队列灌爆。
        - 攒到 LOG_FLUSH_FLOOD_LINES 行立即 flush, 不再等 debounce, 以免日志
          积压看起来"卡住"。
        """
        ts = datetime.now().strftime("%H:%M:%S")
        line = f"[{ts}] {msg}\n"
        global _log_flush_scheduled
        need_immediate = False
        need_schedule = False
        with _log_buffer_lock:
            _log_buffer.append(line)
            backlog = len(_log_buffer)
            if _log_flush_scheduled:
                pass
            elif backlog >= LOG_FLUSH_FLOOD_LINES:
                _log_flush_scheduled = True
                need_immediate = True
            else:
                _log_flush_scheduled = True
                need_schedule = True
        if need_immediate:
            NSOperationQueue.mainQueue().addOperationWithBlock_(self._flush_log_buffer)
        elif need_schedule:
            threading.Timer(
                LOG_FLUSH_DEBOUNCE_S,
                lambda: NSOperationQueue.mainQueue().addOperationWithBlock_(
                    self._flush_log_buffer),
            ).start()

    @objc.python_method
    def _flush_log_buffer(self):
        """主线程: 把缓冲区里所有行一次性 append 到 NSTextView。"""
        global _log_flush_scheduled
        with _log_buffer_lock:
            if not _log_buffer:
                _log_flush_scheduled = False
                return
            chunk = "".join(_log_buffer)
            _log_buffer.clear()
            _log_flush_scheduled = False
        try:
            self._append_log(chunk)
        except Exception:
            # 主线程刷新日志失败也别再 _log 自激, 直接吞掉
            pass

    @objc.python_method
    def _append_log(self, line):
        attrs = NSDictionary.dictionaryWithObjectsAndKeys_(
            NSColor.whiteColor(), "NSColor",
            NSFont.monospacedSystemFontOfSize_weight_(11, 0.0), "NSFont",
        )
        astr = NSAttributedString.alloc().initWithString_attributes_(line, attrs)
        storage = self.log_view.textStorage()
        storage.beginEditing()
        storage.appendAttributedString_(astr)
        storage.endEditing()
        length = storage.length()
        if length > 0:
            self.log_view.scrollRangeToVisible_((length - 1, 1))

    @objc.python_method
    def _set_status(self, label, text, success=None):
        def _do():
            label.setStringValue_(text)
            if success is True:
                label.setTextColor_(NSColor.colorWithCalibratedRed_green_blue_alpha_(0.15, 0.65, 0.15, 1.0))
            elif success is False:
                label.setTextColor_(NSColor.redColor())
            else:
                label.setTextColor_(NSColor.secondaryLabelColor())
        NSOperationQueue.mainQueue().addOperationWithBlock_(_do)

    @objc.python_method
    def _set_btn(self, btn, enabled, title=None):
        def _do():
            btn.setEnabled_(enabled)
            if title:
                btn.setTitle_(title)
        NSOperationQueue.mainQueue().addOperationWithBlock_(_do)

    @objc.python_method
    def _set_agent_fix_ui_busy(self, busy):
        """一键/截屏 调用 Cursor Agent 期间：转圈动画 + 禁用相关按钮，避免重复触发。"""

        def _do():
            if busy:
                self.agent_fix_spinner.startAnimation_(None)
            else:
                self.agent_fix_spinner.stopAnimation_(None)
            self.fix_bug_btn.setEnabled_(not busy)
            self.screenshot_fix_btn.setEnabled_(not busy)
            if busy:
                self.multi_shot_capture_btn.setEnabled_(False)
                self.multi_shot_clear_btn.setEnabled_(False)
                self.multi_shot_submit_btn.setEnabled_(False)
                self.sim_crawl_btn.setEnabled_(False)
                self.sim_crawl_stop_btn.setEnabled_(False)
            else:
                self._apply_multi_shot_buttons_state()

        NSOperationQueue.mainQueue().addOperationWithBlock_(_do)

    @objc.python_method
    def _set_crawl_ui_busy(self, running):
        """模拟器网格巡检进行中：禁用「开始」、启用「停止」。"""
        _state["crawl_running"] = running

        def _do():
            self.sim_crawl_btn.setEnabled_(not running)
            self.sim_crawl_stop_btn.setEnabled_(running)
            self._apply_multi_shot_buttons_state()

        NSOperationQueue.mainQueue().addOperationWithBlock_(_do)

    @objc.python_method
    def _apply_multi_shot_buttons_state(self):
        """根据巡检 / 单张截图锁，更新多图与截屏类按钮（Agent 忙时由 _set_agent_fix_ui_busy 单独处理）。"""
        cr = _state.get("crawl_running", False)
        lk = _state.get("multi_cap_lock", False)

        def _do():
            self.multi_shot_capture_btn.setEnabled_(not cr and not lk)
            self.multi_shot_clear_btn.setEnabled_(not cr and not lk)
            self.multi_shot_submit_btn.setEnabled_(not cr and not lk)
            self.screenshot_fix_btn.setEnabled_(not cr and not lk)
            self.fix_bug_btn.setEnabled_(not cr and not lk)

        NSOperationQueue.mainQueue().addOperationWithBlock_(_do)

    @objc.python_method
    def _refresh_multi_pending_label(self):
        n = len(_state.get("multi_pending_rel") or [])

        def _do():
            self.multi_shot_count_label.setStringValue_(f"已 {n} 张")

        NSOperationQueue.mainQueue().addOperationWithBlock_(_do)

    @objc.python_method
    def _refresh_template_git_status_label(self, template_dir=None):
        """刷新步骤 1「模板 Git」行：分支、短提交、最新提交说明。"""
        if template_dir is None:
            template_dir = str(self.template_field.stringValue()).strip() or DEFAULT_TEMPLATE
        line = _format_template_git_status_line(template_dir)
        b, h, s = _git_head_info(template_dir)
        tip = f"分支: {b}\n提交: {h}\n说明: {s}" if (b or h) else line

        def _do():
            self.template_git_status_label.setStringValue_(f"模板 Git：{line}")
            self.template_git_status_label.setToolTip_(tip)

        NSOperationQueue.mainQueue().addOperationWithBlock_(_do)

    # ── Browse ──

    def browseTemplate_(self, sender):
        self._browse_folder(self.template_field)
        self._refresh_template_git_status_label()
    def browseOutput_(self, sender): self._browse_folder(self.output_field)
    def browseSource_(self, sender): self._browse_folder(self.source_field)
    def browseTarget_(self, sender): self._browse_folder(self.target_field)
    def browseRunProject_(self, sender): self._browse_folder(self.run_project_field)
    def browseAsideProject_(self, sender): self._browse_folder(self.aside_project_field)
    def browseObfProject_(self, sender): self._browse_folder(self.obf_project_field)
    def browseIpaProject_(self, sender): self._browse_folder(self.ipa_project_field)
    def browseIpaWorkdir_(self, sender): self._browse_folder(self.ipa_workdir_field)
    def browseIpaHarden_(self, sender): self._browse_ipa_file(self.ipa_harden_path_field)

    @objc.python_method
    def _browse_ipa_file(self, field):
        panel = NSOpenPanel.openPanel()
        panel.setCanChooseDirectories_(False)
        panel.setCanChooseFiles_(True)
        panel.setAllowsMultipleSelection_(False)
        panel.setAllowedFileTypes_(["ipa"])
        current = str(field.stringValue()).strip()
        if current and os.path.isfile(current):
            panel.setDirectoryURL_(NSURL.fileURLWithPath_(os.path.dirname(current)))
        elif current and os.path.isdir(current):
            panel.setDirectoryURL_(NSURL.fileURLWithPath_(current))
        if panel.runModal() == 1:
            field.setStringValue_(str(panel.URLs()[0].path()))

    @objc.python_method
    def _resolve_harden_script(self, project):
        template = str(self.template_field.stringValue()).strip()
        for base in (project, template, DEFAULT_TEMPLATE):
            if not base:
                continue
            script = os.path.join(base, "scripts", "harden_ipa_standalone.sh")
            if os.path.isfile(script):
                return script
        return None

    @objc.python_method
    def _guess_latest_ipa(self, workdir):
        if not workdir or not os.path.isdir(workdir):
            return None
        ipa_dir = os.path.join(workdir, "ipa")
        if not os.path.isdir(ipa_dir):
            return None
        ipas = glob.glob(os.path.join(ipa_dir, "*.ipa"))
        if not ipas:
            return None
        return max(ipas, key=os.path.getmtime)

    @objc.python_method
    def _browse_folder(self, field):
        panel = NSOpenPanel.openPanel()
        panel.setCanChooseDirectories_(True)
        panel.setCanChooseFiles_(False)
        panel.setAllowsMultipleSelection_(False)
        current = str(field.stringValue()).strip()
        if current and os.path.isdir(current):
            panel.setDirectoryURL_(NSURL.fileURLWithPath_(current))
        if panel.runModal() == 1:
            field.setStringValue_(str(panel.URLs()[0].path()))

    # ── Toolbar ──

    def clearLog_(self, sender):
        self.log_view.textStorage().mutableString().setString_("")

    def openProjectDir_(self, sender):
        for field in [self.ipa_project_field, self.run_project_field, self.target_field]:
            path = str(field.stringValue()).strip()
            if path and os.path.isdir(path):
                subprocess.Popen(["open", path]); return
        self._log("⚠ 项目目录不存在")

    def updateTemplateFromGit_(self, sender):
        if _state["is_running"]:
            self._log("⚠ 有任务正在执行中")
            return
        template = str(self.template_field.stringValue()).strip() or DEFAULT_TEMPLATE
        if not os.path.isdir(template):
            self._log(f"❌ 模板目录不存在: {template}")
            return
        if not os.path.isdir(os.path.join(template, ".git")):
            self._log("❌ 模板目录不是 git 仓库，无法执行 git pull（请先 git clone 远程 daddy_template）")
            return
        idx = int(self.project_popup.indexOfSelectedItem())
        prev_code = PROJECT_CODES[idx] if 0 <= idx < len(PROJECT_CODES) else None
        _state["is_running"] = True
        pre_line = _format_template_git_status_line(template)
        self._log(f"  拉取前 · {pre_line}")
        self._refresh_template_git_status_label(template)
        self._log(f"▶ git -C {template} pull")
        threading.Thread(target=self._run_template_git_pull, args=(template, prev_code), daemon=True).start()

    @objc.python_method
    def _run_template_git_pull(self, template, prev_code=None):
        global PROJECT_CODES, PROJECT_LABELS
        try:
            env = get_env()
            proc = subprocess.run(
                ["git", "-C", template, "pull"],
                capture_output=True, text=True, timeout=300, env=env,
            )
            out = (proc.stdout or "") + (proc.stderr or "")
            for line in out.splitlines():
                if line.strip():
                    self._log(f"  {strip_ansi(line)}")
            if proc.returncode != 0:
                self._log(f"❌ git pull 失败 (exit {proc.returncode})")
                self._notify_telegram("模板更新（git pull）", ok=False,
                                      detail=f"exit={proc.returncode}\n{out[-400:]}")
                return
            self._log("✅ 模板代码已更新")
            self._notify_telegram("模板更新（git pull）", ok=True,
                                  detail=_format_template_git_status_line(template))
            post_line = _format_template_git_status_line(template)
            self._log(f"  拉取后 · {post_line}")
            NSOperationQueue.mainQueue().addOperationWithBlock_(
                lambda: self._refresh_template_git_status_label(template))

            fv_tpl = _read_fvm_version_from_template(template)
            if fv_tpl and fv_tpl != FVM_FLUTTER_VERSION:
                self._log(
                    f"  → 模板 .fvmrc 为 Flutter {fv_tpl}；本工具固定使用 {FVM_FLUTTER_VERSION}")
            self.runtime_fvm_version = FVM_FLUTTER_VERSION

            new_codes = _parse_project_codes_from_sync_script(template)
            if new_codes:
                PROJECT_CODES = new_codes
                for c in new_codes:
                    PROJECT_LABELS.setdefault(c, c)
                self._reload_project_popups(prev_code)
                self._log(f"  → 已同步 B 面项目代号列表: {', '.join(new_codes)}")

            copied = _try_copy_self_from_template(template)
            if copied:
                self._log(f"  ✅ 已用模板中的 {copied} 覆盖本应用脚本，请重启「AB 包工厂」使界面生效")

            doc_hints = [
                os.path.join(template, "docs", "AB_MAKE.md"),
                os.path.join(template, "AGENTS.md"),
            ]
            for p in doc_hints:
                if os.path.isfile(p):
                    self._log(f"  📄 文档已就绪: {p}")
        except Exception as e:
            self._log(f"❌ 更新异常: {e}")
        finally:
            _state["is_running"] = False

    @objc.python_method
    def _load_agent_model_from_defaults(self):
        ud = NSUserDefaults.standardUserDefaults()
        mid = None
        try:
            s = ud.stringForKey_(UDK_LAST_AGENT_MODEL_ID)
            if s is not None:
                mid = str(s)
        except Exception:
            pass
        if mid is None or mid == "":
            try:
                cs = ud.stringForKey_(UDK_LEGACY_CUSTOM_MODEL)
                if cs:
                    mid = str(cs)
            except Exception:
                pass
        if mid is None or mid == "":
            return
        n = int(self.agent_model_popup.numberOfItems())
        for i in range(n):
            if i < len(AGENT_MODEL_PRESETS) and AGENT_MODEL_PRESETS[i][1] == mid:
                self.agent_model_popup.selectItemAtIndex_(i)
                self.agent_model_custom_field.setStringValue_("")
                return
        self.agent_model_popup.selectItemAtIndex_(0)
        self.agent_model_custom_field.setStringValue_(mid)

    @objc.python_method
    def _save_agent_model_prefs(self):
        ud = NSUserDefaults.standardUserDefaults()
        try:
            mid = self._current_agent_model_id()
            ud.setObject_forKey_(mid, UDK_LAST_AGENT_MODEL_ID)
        except Exception:
            pass

    @objc.python_method
    def _load_b_side_prefs(self):
        ud = NSUserDefaults.standardUserDefaults()
        try:
            ch = ud.stringForKey_(UDK_B_SIDE_CHANNEL)
            if ch is not None and str(ch).strip() != "":
                self.b_side_channel_field.setStringValue_(str(ch).strip())
        except Exception:
            pass
        try:
            ev = ud.stringForKey_(UDK_APP_ENVIRONMENT)
            if ev is not None:
                es = str(ev).strip().lower()
                if self.app_environment_popup.indexOfItemWithTitle_(es) >= 0:
                    self.app_environment_popup.selectItemWithTitle_(es)
        except Exception:
            pass
        try:
            ud = NSUserDefaults.standardUserDefaults()
            if ud.objectForKey_(UDK_SHOW_DEV_FLOAT) is None:
                show_dev = True
            else:
                show_dev = bool(ud.boolForKey_(UDK_SHOW_DEV_FLOAT))
            self.show_dev_float_switch.setState_(1 if show_dev else 0)
        except Exception:
            pass

    @objc.python_method
    def _save_b_side_prefs(self):
        ud = NSUserDefaults.standardUserDefaults()
        try:
            ud.setObject_forKey_(
                str(self.b_side_channel_field.stringValue()).strip(), UDK_B_SIDE_CHANNEL)
        except Exception:
            pass
        try:
            idx = int(self.app_environment_popup.indexOfSelectedItem())
            if 0 <= idx < 3:
                ud.setObject_forKey_(
                    str(self.app_environment_popup.itemTitleAtIndex_(idx)), UDK_APP_ENVIRONMENT)
        except Exception:
            pass

    def showDevFloatChanged_(self, sender):
        try:
            NSUserDefaults.standardUserDefaults().setBool_forKey_(
                self.show_dev_float_switch.state() != 0, UDK_SHOW_DEV_FLOAT)
        except Exception:
            pass
        shown = self.show_dev_float_switch.state() != 0
        self._log(
            f"  开发者选项悬浮按钮：{'显示' if shown else '隐藏'}"
            f"（下次 ▶ 运行生效，AB_SHOW_DEV_FLOAT={'true' if shown else 'false'}）")

    @objc.python_method
    def _show_dev_float_dart_define(self):
        show = self.show_dev_float_switch.state() != 0
        return f"--dart-define=AB_SHOW_DEV_FLOAT={'true' if show else 'false'}"

    # ── Telegram 通知 ──────────────────────────────────────────────

    @objc.python_method
    def _install_notify_menu(self):
        mb = NSApp.mainMenu()
        if mb is None:
            return
        for i in range(int(mb.numberOfItems())):
            it = mb.itemAtIndex_(i)
            if it and it.submenu() is not None and str(it.submenu().title()) == "通知":
                return
        notify_item = NSMenuItem.alloc().init()
        mb.addItem_(notify_item)
        notify_menu = NSMenu.alloc().initWithTitle_("通知")
        item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Telegram 设置…", "openTelegramSettings:", ",")
        item.setTarget_(self)
        item.setKeyEquivalentModifierMask_(1 << 20 | 1 << 17)
        notify_menu.addItem_(item)
        notify_item.setSubmenu_(notify_menu)

    def openTelegramSettings_(self, sender):
        self._show_tg_settings_window()

    @objc.python_method
    def _show_tg_settings_window(self):
        if self.tg_window is None:
            self._build_tg_window()
        ud = NSUserDefaults.standardUserDefaults()
        tok = ud.stringForKey_(UDK_TG_BOT_TOKEN) or ""
        chat = ud.stringForKey_(UDK_TG_CHAT_ID) or ""
        en = bool(ud.boolForKey_(UDK_TG_ENABLED))
        self.tg_token_field.setStringValue_(str(tok))
        self.tg_chat_id_field.setStringValue_(str(chat))
        self.tg_enabled_switch.setState_(1 if en else 0)
        self.tg_status_label.setStringValue_("已启用" if en and tok and chat else "未启用")
        self.tg_window.makeKeyAndOrderFront_(None)
        self.tg_window.center()
        NSApp.activateIgnoringOtherApps_(True)

    @objc.python_method
    def _build_tg_window(self):
        w = 520
        h = 280
        frame = NSMakeRect(0, 0, w, h)
        style = (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
        self.tg_window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            frame, style, NSBackingStoreBuffered, False)
        self.tg_window.setTitle_("Telegram 通知设置")
        cv = self.tg_window.contentView()

        y = h - 40
        cv.addSubview_(make_label("Bot Token", 16, y, 90, 20, bold=True))
        self.tg_token_field = make_input(110, y - 2, w - 126, 24,
                                         placeholder="123456789:ABCdefGhIJKlmNoPQRstuVWxyZ", mono=True)
        cv.addSubview_(self.tg_token_field)

        y -= 38
        cv.addSubview_(make_label("Chat ID", 16, y, 90, 20, bold=True))
        self.tg_chat_id_field = make_input(110, y - 2, w - 126, 24,
                                           placeholder="个人 chat_id 或 -100xxx 群/频道 id", mono=True)
        cv.addSubview_(self.tg_chat_id_field)

        y -= 36
        self.tg_enabled_switch = NSButton.alloc().initWithFrame_(NSMakeRect(110, y, 280, 22))
        self.tg_enabled_switch.setButtonType_(3)
        self.tg_enabled_switch.setTitle_("启用：每个步骤完成时自动通知")
        cv.addSubview_(self.tg_enabled_switch)

        y -= 56
        hint = ("提示：\n"
                "  1) 找 @BotFather 创建机器人拿到 Token；\n"
                "  2) 用 https://api.telegram.org/bot<TOKEN>/getUpdates 取 chat_id（先随便给机器人发一条消息）。")
        hint_lbl = make_label(hint, 16, y - 6, w - 32, 50, size=11,
                              color=NSColor.secondaryLabelColor())
        cv.addSubview_(hint_lbl)

        self.tg_status_label = make_label("未启用", 16, 18, 200, 20, size=11,
                                          color=NSColor.secondaryLabelColor())
        cv.addSubview_(self.tg_status_label)

        test_btn = make_button("测试发送", w - 250, 14, 110, 28, self, "tgTestSend:")
        cv.addSubview_(test_btn)
        save_btn = make_button("保存", w - 130, 14, 110, 28, self, "tgSave:", bold=True)
        save_btn.setKeyEquivalent_("\r")
        cv.addSubview_(save_btn)

    def tgSave_(self, sender):
        ud = NSUserDefaults.standardUserDefaults()
        tok = _tg_normalize_token(str(self.tg_token_field.stringValue()))
        chat = _tg_normalize_chat_id(str(self.tg_chat_id_field.stringValue()))
        # 把规整后的值回填到 UI, 让用户下次打开看到的就是干净值
        self.tg_token_field.setStringValue_(tok)
        self.tg_chat_id_field.setStringValue_(chat)
        en = self.tg_enabled_switch.state() != 0
        ud.setObject_forKey_(tok, UDK_TG_BOT_TOKEN)
        ud.setObject_forKey_(chat, UDK_TG_CHAT_ID)
        ud.setBool_forKey_(en, UDK_TG_ENABLED)
        try:
            ud.synchronize()
        except Exception:
            pass
        if en and (not tok or not chat):
            self._log("[Telegram] ⚠ 已勾选启用，但 token 或 chat_id 为空，通知不会生效")
            self.tg_status_label.setStringValue_("启用但配置不完整")
        elif en:
            self._log(f"[Telegram] 配置已保存（已启用，chat_id={chat}）")
            self.tg_status_label.setStringValue_("已启用 ✓")
        else:
            self._log("[Telegram] 配置已保存（未启用）")
            self.tg_status_label.setStringValue_("未启用")
        if self.tg_window is not None:
            self.tg_window.orderOut_(None)

    def tgTestSend_(self, sender):
        tok = _tg_normalize_token(str(self.tg_token_field.stringValue()))
        chat = _tg_normalize_chat_id(str(self.tg_chat_id_field.stringValue()))
        if not tok or not chat:
            self._log("[Telegram] 测试失败：请先填写 Bot Token 和 Chat ID")
            return
        if not _TG_TOKEN_RE.match(tok):
            self._log(f"[Telegram] Bot Token 格式不对（应形如 12345:AAA...）: {tok[:8]}…")
            return
        if not _TG_CHAT_ID_RE.match(chat):
            self._log(
                f"[Telegram] Chat ID 格式不对：{chat!r}\n"
                "  · 私聊：纯数字, 如 123456789\n"
                "  · 群组：负数, 如 -987654321\n"
                "  · 超级群/频道：以 -100 开头, 如 -1001234567890\n"
                "  · 也可用 @公开频道用户名（必须是公开频道）")
            return
        # 同步把规范化后的值写回输入框, 避免用户下次保存又把粘贴时的空格/全角符号写进去
        self.tg_token_field.setStringValue_(tok)
        self.tg_chat_id_field.setStringValue_(chat)
        text = (f"🤖 <b>AB 包工厂</b> 测试消息\n"
                f"<i>{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</i>\n"
                f"连接成功 ✅")
        self._log(f"[Telegram] 正在发送测试消息… (chat_id={chat})")
        threading.Thread(target=self._send_telegram_raw,
                         args=(tok, chat, text, True),
                         daemon=True).start()

    @objc.python_method
    def _send_telegram_raw(self, token, chat_id, html_text, verbose=False):
        """
        给 Telegram Bot API sendMessage 发一条消息。

        关键点：urlopen 在 4xx/5xx 上会抛 HTTPError, 但 HTTPError 仍能 .read()
        响应体——Telegram 的真正错误描述就在响应体 JSON 的 description 字段里。
        如果不专门捕获 HTTPError, 只会看到泛泛的 "HTTP Error 400: Bad Request",
        无法定位 chat_id 错、bot 被屏蔽、群里没添加 bot 等真实原因。
        """
        import urllib.request
        import urllib.parse
        import urllib.error
        import json as _json

        url = f"https://api.telegram.org/bot{token}/sendMessage"
        payload = {
            "chat_id": chat_id,
            "text": html_text,
            "parse_mode": "HTML",
            "disable_web_page_preview": "true",
        }
        data = urllib.parse.urlencode(payload).encode("utf-8")
        req = urllib.request.Request(url, data=data, method="POST")

        def _parse(body_bytes):
            try:
                return _json.loads(body_bytes.decode("utf-8", errors="replace"))
            except Exception:
                return None

        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                body = resp.read()
                j = _parse(body)
                if resp.status == 200 and j and j.get("ok"):
                    if verbose:
                        self._log("[Telegram] 测试发送成功 ✅")
                    return
                desc = (j or {}).get("description") or body[:200].decode(
                    "utf-8", errors="replace")
                self._log(f"[Telegram] 发送失败 ({resp.status}): {desc}")
        except urllib.error.HTTPError as he:
            # Telegram 的 description 在 4xx 响应体里, 必须 .read() 出来
            body = b""
            try:
                body = he.read() or b""
            except Exception:
                pass
            j = _parse(body)
            desc = (j or {}).get("description") or body[:200].decode(
                "utf-8", errors="replace") or str(he)
            code = (j or {}).get("error_code") or he.code
            self._log(f"[Telegram] 发送失败 (HTTP {he.code}, error_code={code}): {desc}")
            if verbose:
                self._tg_explain_failure(token, chat_id, desc, he.code)
        except urllib.error.URLError as ue:
            # DNS / TLS / 连接超时等
            self._log(f"[Telegram] 网络不可达: {ue.reason}")
        except Exception as e:
            self._log(f"[Telegram] 异常: {e}")

    @objc.python_method
    def _tg_explain_failure(self, token, chat_id, description, http_code):
        """
        测试发送失败时给一行人话提示, 并尽量调一次 getMe 验证 token 是否本身就废了。
        只在 tgTestSend_ 调用 _send_telegram_raw(verbose=True) 时触发, 平时通知步骤完成
        不会刷这堆诊断行。
        """
        import urllib.request
        import urllib.error
        import json as _json

        d = (description or "").lower()
        if "chat not found" in d:
            self._log(
                "[Telegram] 提示：chat_id 找不到。常见原因：")
            self._log(
                "  · 私聊：必须用「数字 user_id」(如 123456789), 不要填 @用户名；")
            self._log(
                "    且你必须先用这个账号给 bot 发过至少一条消息, 否则 bot 没权限主动找你。")
            self._log(
                "  · 群组：chat_id 是负数 (如 -987654321), 且 bot 必须已经被加入该群。")
            self._log(
                "  · 频道/超级群：chat_id 形如 -1001234567890, bot 必须是该频道管理员。")
            self._log(
                f"  · 拿 chat_id：浏览器打开 https://api.telegram.org/bot{token}/getUpdates "
                "(先随便给 bot 发一条新消息), 在返回 JSON 里找 message.chat.id。")
        elif "bot was blocked" in d or "user is deactivated" in d:
            self._log("[Telegram] 提示：目标用户屏蔽了这个 bot, 或账号已停用。"
                      "请让对方在 Telegram 里取消屏蔽, 或换一个 chat_id。")
        elif "not enough rights" in d or "have no rights" in d:
            self._log("[Telegram] 提示：bot 在该群/频道里没有发送消息的权限。"
                      "去群设置把 bot 设成管理员或解除限制。")
        elif "unauthorized" in d or http_code == 401:
            self._log("[Telegram] 提示：Bot Token 不对或已被 BotFather 撤销, "
                      "重新去 @BotFather 用 /mybots 拿一次新 token。")

        # 顺手验证 token 本身是否还有效, 帮助区分 "chat_id 问题" 还是 "token 问题"
        try:
            with urllib.request.urlopen(
                    f"https://api.telegram.org/bot{token}/getMe",
                    timeout=8) as resp:
                body = resp.read().decode("utf-8", errors="replace")
                try:
                    j = _json.loads(body)
                except Exception:
                    j = None
                if j and j.get("ok") and isinstance(j.get("result"), dict):
                    me = j["result"]
                    self._log(
                        f"[Telegram] (getMe ok) bot=@{me.get('username','?')} "
                        f"id={me.get('id','?')} —— token 本身没问题, "
                        "请检查 chat_id 是否正确以及 bot 是否已被加入对方会话/群。")
                else:
                    self._log(f"[Telegram] (getMe 异常) {body[:200]}")
        except urllib.error.HTTPError as he:
            self._log(f"[Telegram] (getMe HTTP {he.code}) Token 可能已失效, "
                      "请去 @BotFather 重新获取。")
        except Exception as e:
            self._log(f"[Telegram] (getMe 失败) {e}")

    @objc.python_method
    def _notify_telegram(self, title, ok=True, detail=None):
        """步骤完成（成功/失败）异步发送一条 Telegram 通知。

        - 仅在 UDK_TG_ENABLED 为 True、且 token / chat_id 都已配置时才发送
        - 网络请求在后台线程，不阻塞主流程
        - 任何异常都只写一行日志，不会抛出
        """
        try:
            ud = NSUserDefaults.standardUserDefaults()
            if not ud.boolForKey_(UDK_TG_ENABLED):
                return
            tok_obj = ud.stringForKey_(UDK_TG_BOT_TOKEN)
            chat_obj = ud.stringForKey_(UDK_TG_CHAT_ID)
            tok = str(tok_obj).strip() if tok_obj is not None else ""
            chat = str(chat_obj).strip() if chat_obj is not None else ""
            if not tok or not chat:
                return
        except Exception:
            return

        icon = "✅" if ok else "❌"
        safe_title = str(title).replace("<", "&lt;").replace(">", "&gt;")
        body = f"{icon} <b>{safe_title}</b>"
        if detail:
            safe_detail = str(detail).replace("<", "&lt;").replace(">", "&gt;")
            if len(safe_detail) > 600:
                safe_detail = safe_detail[:600] + "…"
            body += f"\n<pre>{safe_detail}</pre>"
        body += f"\n<i>{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} · AB 包工厂 v{APP_VERSION}</i>"
        threading.Thread(target=self._send_telegram_raw,
                         args=(tok, chat, body, False),
                         daemon=True).start()

    @objc.python_method
    def _patch_b_side_config_channel(self, project_root, channel):
        """将 B 面 xxChannel 的 APP_CHANNEL defaultValue 写入目标工程（dq 等模板）。"""
        if not channel:
            return False, "渠道为空，已跳过写入 config.dart"
        path = _b_side_config_dart_path(project_root)
        if not os.path.isfile(path):
            return False, f"未找到 B 面配置: {path}"
        esc = channel.replace("\\", "\\\\").replace("'", "\\'")
        try:
            with open(path, "r", encoding="utf-8") as f:
                text = f.read()
        except OSError as e:
            return False, f"读取 config.dart 失败: {e}"
        pat = (
            r"(const\s+xxChannel\s*=\s*String\.fromEnvironment\(\s*"
            r"['\"]APP_CHANNEL['\"]\s*,\s*defaultValue:\s*)'[^']*'(\s*\)\s*;)"
        )
        if not re.search(pat, text):
            return False, "config.dart 中未匹配到 xxChannel / APP_CHANNEL 行（可能非 dq 模板）"
        new_text, n = re.subn(pat, r"\1'" + esc + r"'\2", text, count=1)
        if n != 1:
            return False, "替换 xxChannel 行失败"
        try:
            with open(path, "w", encoding="utf-8") as f:
                f.write(new_text)
        except OSError as e:
            return False, f"写入 config.dart 失败: {e}"
        return True, f"已写入 B 面渠道 APP_CHANNEL defaultValue: {channel}"

    def readBSideChannel_(self, sender):
        """从目标工程 B 面 config.dart 读取 xxChannel defaultValue 填入输入框。"""
        target = str(self.target_field.stringValue()).strip()
        if not target or not os.path.isdir(target):
            target = str(self.run_project_field.stringValue()).strip()
        if not target or not os.path.isdir(target):
            self._log("❌ 请填写目标工程路径（步骤2）或运行项目路径")
            return
        ch, err = _read_b_side_config_channel(target)
        if err:
            self._log(f"⚠ {err}")
            return
        if not ch:
            self._log("⚠ config.dart 中 APP_CHANNEL defaultValue 为空")
            return

        def _set():
            self.b_side_channel_field.setStringValue_(ch)
        NSOperationQueue.mainQueue().addOperationWithBlock_(_set)
        self._save_b_side_prefs()
        cfg_path = _b_side_config_dart_path(target)
        self._log(f"  渠道来源文件: {os.path.abspath(cfg_path)}")
        self._log(f"  APP_CHANNEL defaultValue: {ch}")

    def writeBSideChannel_(self, sender):
        """仅手动写入 B 面 config.dart 的 xxChannel defaultValue（不同步、不运行自动改）。"""
        self._save_b_side_prefs()
        target = str(self.target_field.stringValue()).strip()
        if not target or not os.path.isdir(target):
            target = str(self.run_project_field.stringValue()).strip()
        if not target or not os.path.isdir(target):
            self._log("❌ 请填写目标工程路径（步骤2）或运行项目路径")
            return
        ch = str(self.b_side_channel_field.stringValue()).strip()
        if not ch:
            self._log("❌ 请填写 B 面渠道")
            return
        ok, msg = self._patch_b_side_config_channel(target, ch)
        if ok:
            self._log(f"✅ {msg}")
        else:
            self._log(f"❌ {msg}")

    @objc.python_method
    def _selected_app_environment(self):
        idx = int(self.app_environment_popup.indexOfSelectedItem())
        for i, name in enumerate(("test", "beta", "release")):
            if idx == i:
                return name
        return "test"

    @objc.python_method
    def _current_agent_model_id(self):
        """返回传给 `agent chat --model` 的模型 id；空字符串表示不传 --model。"""
        custom = str(self.agent_model_custom_field.stringValue()).strip()
        if custom:
            return custom
        idx = int(self.agent_model_popup.indexOfSelectedItem())
        if 0 <= idx < len(AGENT_MODEL_PRESETS):
            return AGENT_MODEL_PRESETS[idx][1]
        return ""

    @objc.python_method
    def _reload_project_popups(self, prefer_code=None):
        def _ui():
            for pop in (self.project_popup, self.obf_project_popup):
                pop.removeAllItems()
                for code in PROJECT_CODES:
                    pop.addItemWithTitle_(PROJECT_LABELS.get(code, code))
            sel = 0
            if prefer_code and prefer_code in PROJECT_CODES:
                sel = PROJECT_CODES.index(prefer_code)
            self.project_popup.selectItemAtIndex_(sel)
            self.obf_project_popup.selectItemAtIndex_(sel)
        NSOperationQueue.mainQueue().addOperationWithBlock_(_ui)

    def fixBugWithCursor_(self, sender):
        project = str(self.run_project_field.stringValue()).strip()
        if not project or not os.path.isdir(project):
            project = self._find_project_path()
            if project:
                def _f():
                    self.run_project_field.setStringValue_(project)
                NSOperationQueue.mainQueue().addOperationWithBlock_(_f)
        if not project or not os.path.isdir(project):
            self._log("❌ 请先填写「运行项目」中的 Flutter 工程路径")
            return
        if not os.path.isfile(os.path.join(project, "pubspec.yaml")):
            self._log(f"❌ 不是 Flutter 项目: {project}")
            return

        lines = _state.get("last_flutter_log") or []
        log_text = "\n".join(lines) if lines else "（尚无本进程内捕获的运行日志，请先在上方「▶ 运行」复现问题后再点本按钮；或把日志粘贴进下方文件。）"

        md_path = os.path.join(project, "AB_FACTORY_CURSOR_FIX.md")
        body = f"""# AB 包工厂 — 待修复问题

请在修复后删除本文件。

## 说明

以下日志来自 AB 包工厂 最近一次 **flutter run / pub get** 输出。请分析报错并修改项目代码（A 面仅在 `lib/modules/primary/`）。

## 错误日志

```
{log_text}
```

## 建议步骤

1. `fvm flutter pub get`
2. `fvm flutter analyze`
3. 根据报错定位并修复；勿在未确认前修改 `lib/modules/secondary/`（B 面同步产物）。

---
生成时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}
"""
        try:
            with open(md_path, "w", encoding="utf-8") as f:
                f.write(body)
            self._log(f"  已写入: {md_path}")
        except Exception as e:
            self._log(f"❌ 无法写入说明文件: {e}")
            return

        agent = _find_cursor_agent_cli()
        if agent:
            self._save_agent_model_prefs()
            model_id = self._current_agent_model_id()
            self._log(f"▶ 检测到 Cursor Agent CLI: {agent}")
            if model_id:
                self._log(f"  使用模型: {model_id}")
            else:
                self._log("  模型: 默认（未传 --model）")
            self._log("  正在后台执行「一键修复」（输出会出现在下方日志）…")
            self._set_agent_fix_ui_busy(True)
            threading.Thread(
                target=self._run_cursor_agent_autofix,
                args=(project, md_path, agent, None, model_id),
                daemon=True,
            ).start()
        else:
            self._log("⚠ 未检测到 Cursor Agent CLI（命令名一般为 agent）")
            self._log("  将改为打开 Cursor 与说明文档；若需终端内自动修复，请先安装:")
            self._log("    curl https://cursor.com/install -fsSL | bash")
            self._log("  安装后把 ~/.local/bin 加入 PATH，再点「一键修Bug」。")
            self._open_cursor_gui_with_fix_doc(project, md_path)

    @objc.python_method
    def _run_cursor_agent_autofix(self, project, md_path, agent_bin, prompt=None, model_id=None):
        """调用 `agent chat --print --trust [--model] "..."`（无头 + 信任当前 cwd 工程，否则会停在 Workspace Trust）。"""
        try:
            if prompt is None:
                prompt = (
                    "You are a senior Flutter/Dart engineer. The workspace is an AB-shell Flutter project. "
                    "First read the file AB_FACTORY_CURSOR_FIX.md at the repo root (it contains flutter run / pub get error logs). "
                    "Then locate and fix the issues. Constraints: prefer changes under lib/modules/primary/ only (A-side); "
                    "avoid editing lib/modules/secondary/ (B-side sync output) unless the error clearly requires it. "
                    "When done, briefly summarize which files you changed."
                )
            env = get_env()
            mid = (model_id or "").strip()
            cmd = [agent_bin, "chat", "--print", "--trust"]
            if mid:
                cmd.extend(["--model", mid])
            cmd.append(prompt)
            try:
                self._log(
                    f"  $ {agent_bin} chat --print --trust{' --model ' + mid if mid else ''} …"
                )
                proc = subprocess.Popen(
                    cmd,
                    cwd=project,
                    env=env,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                )
                auth_hint_shown = False
                for line in proc.stdout:
                    clean = strip_ansi(line.rstrip())
                    if clean:
                        self._log(f"  [agent] {clean}")
                        if (not auth_hint_shown
                                and "authentication required" in clean.lower()):
                            auth_hint_shown = True
                            self._log(
                                "  💡 Agent 未登录：请在终端执行 `agent login` 完成浏览器授权；"
                                "或在 Cursor 设置 → API 中创建 Key 后设置环境变量 CURSOR_API_KEY。"
                                " AB 包工厂从 .app 启动时不会继承终端里的 export，"
                                "登录一次 agent login 后通常即可。")
                proc.wait()
                if proc.returncode == 0:
                    self._log("✅ Cursor Agent 执行结束（退出码 0）。请在工程内验证编译。")
                else:
                    self._log(f"⚠ Cursor Agent 退出码 {proc.returncode}，请检查上方输出或改用手动在 Cursor 里修复。")
            except Exception as e:
                self._log(f"❌ 调用 Agent CLI 失败: {e}")
                self._log("  正在尝试打开 Cursor 与说明文档…")
                self._open_cursor_gui_with_fix_doc(project, md_path)
        finally:
            self._set_agent_fix_ui_busy(False)

    @objc.python_method
    def _open_cursor_gui_with_fix_doc(self, project, md_path, extra_paths=None):
        """打开 Cursor：工程、主说明 md，可选额外文件（如截图）。"""
        extra_paths = extra_paths or []
        opened = False
        cursor_bin = shutil.which("cursor")
        to_open = [project, md_path] + [p for p in extra_paths if p and os.path.isfile(p)]
        if cursor_bin:
            try:
                for p in to_open:
                    subprocess.Popen([cursor_bin, p])
                opened = True
            except Exception:
                pass
        if not opened:
            try:
                for p in to_open:
                    subprocess.Popen(["open", "-a", "Cursor", p])
                opened = True
            except Exception:
                pass
        if opened:
            self._log("✅ 已尝试用 Cursor 打开工程与说明文件")
        else:
            self._log("⚠ 无法启动 Cursor，请手动打开工程与说明 / 截图文件")

    def screenshotSimulatorFixBug_(self, sender):
        """截取当前所选 iOS 模拟器画面，写入说明并交给 Cursor Agent（或打开 GUI）。"""
        project = str(self.run_project_field.stringValue()).strip()
        if not project or not os.path.isdir(project):
            project = self._find_project_path()
            if project:
                def _f():
                    self.run_project_field.setStringValue_(project)
                NSOperationQueue.mainQueue().addOperationWithBlock_(_f)
        if not project or not os.path.isdir(project):
            self._log("❌ 请先填写「运行项目」中的 Flutter 工程路径")
            return
        if not os.path.isfile(os.path.join(project, "pubspec.yaml")):
            self._log(f"❌ 不是 Flutter 项目: {project}")
            return

        row = self._selected_run_device_row()
        if not row:
            self._log("❌ 请先在下拉框中选择模拟器设备")
            return
        _label, udid, state, rk = row
        if udid == "macos" or rk != "ios_sim":
            self._log("❌ 「截屏修Bug」仅支持 iOS 模拟器，请选择 iPhone/iPad 模拟器并先运行 App")
            return

        png_name = "ab_factory_sim_screen.png"
        png_path = os.path.join(project, png_name)
        self._log(f"▶ 正在截取模拟器画面 …（设备: {_label[:40]}）")
        ok, err = _capture_ios_simulator_screenshot(udid, png_path)
        if not ok:
            self._log(f"❌ 截图失败: {err}")
            self._log("  请确认：已安装 Xcode、模拟器已启动、当前选中设备与运行目标一致；可先点 ▶ 运行再截屏。")
            return
        self._log(f"  ✅ 已保存截图: {png_path}")

        lines = _state.get("last_flutter_log") or []
        log_tail = "\n".join(lines[-500:]) if lines else "（尚无本进程内运行日志，请结合截图单独分析界面。）"
        if len(log_tail) > 20000:
            log_tail = log_tail[-20000:]

        md_path = os.path.join(project, "AB_FACTORY_VISUAL_FIX.md")
        body = f"""# AB 包工厂 — 模拟器截图 + 日志（Cursor 修 Bug）

## 模拟器截图

绝对路径：`{png_path}`

![simulator]({png_name})

（请在 Cursor 中打开上述 PNG，结合界面分析布局/渲染问题。）

## 终端日志（节选）

```
{log_tail}
```

## 任务

根据截图中的 UI 与下方日志，修复 Flutter 工程中的问题。优先修改 `lib/modules/primary/`，非必要不改 `lib/modules/secondary/`。

---
生成时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}
"""
        try:
            with open(md_path, "w", encoding="utf-8") as f:
                f.write(body)
            self._log(f"  已写入: {md_path}")
        except Exception as e:
            self._log(f"❌ 无法写入说明文件: {e}")
            return

        prompt_visual = (
            "You are a senior Flutter/Dart engineer. Read AB_FACTORY_VISUAL_FIX.md at the repo root. "
            "Open and analyze the image file ab_factory_sim_screen.png (iOS Simulator screenshot of this app) for visual bugs: layout overflow, missing UI, red error screens, incorrect text, obvious crashes shown in UI. "
            "Also read the console log section in the same markdown. "
            "Apply fixes preferring lib/modules/primary/; avoid lib/modules/secondary/ unless necessary. "
            "If your environment cannot load images, infer what you can from logs and tell the user to confirm the PNG. "
            "Summarize files changed when done."
        )

        agent = _find_cursor_agent_cli()
        if agent:
            self._save_agent_model_prefs()
            model_id = self._current_agent_model_id()
            self._log(f"▶ 检测到 Cursor Agent CLI: {agent}")
            if model_id:
                self._log(f"  使用模型: {model_id}")
            self._log("  正在后台执行「截屏修复」（请稍候）…")
            self._set_agent_fix_ui_busy(True)
            threading.Thread(
                target=self._run_cursor_agent_autofix,
                args=(project, md_path, agent, prompt_visual, model_id),
                daemon=True,
            ).start()
        else:
            self._log("⚠ 未检测到 agent CLI，将打开 Cursor 与截图、说明文档")
            self._log("    安装 CLI: curl https://cursor.com/install -fsSL | bash")
            self._open_cursor_gui_with_fix_doc(project, md_path, [png_path])

    @objc.python_method
    def _multi_shot_validate_project_and_device(self):
        """
        返回 (project, udid, device_label) 或 (None, None, None) 并打日志。

        注意：必须保留 @objc.python_method 装饰器。否则 PyObjC 会按
        "下划线转冒号" 规则尝试把它注册成
        `_multi:shot:validate:project:and:device:` (6 个入参), 注册失败或者
        被 first-responder / KVC 误派发, 都可能在 ObjC↔Python 桥上递归。
        """
        project = str(self.run_project_field.stringValue()).strip()
        if not project or not os.path.isdir(project):
            project = self._find_project_path()
            if project:
                def _f():
                    self.run_project_field.setStringValue_(project)
                NSOperationQueue.mainQueue().addOperationWithBlock_(_f)
        if not project or not os.path.isdir(project):
            self._log("❌ 请先填写「运行项目」中的 Flutter 工程路径")
            return None, None, None
        if not os.path.isfile(os.path.join(project, "pubspec.yaml")):
            self._log(f"❌ 不是 Flutter 项目: {project}")
            return None, None, None
        row = self._selected_run_device_row()
        if not row:
            self._log("❌ 请先在下拉框中选择模拟器设备")
            return None, None, None
        device_label, udid, _, rk = row
        if udid == "macos" or rk != "ios_sim":
            self._log("❌ 本功能仅支持 iOS 模拟器")
            return None, None, None
        return project, udid, device_label

    def multiShotCaptureOne_(self, sender):
        """将当前模拟器画面追加到待提交列表。"""
        if _state.get("multi_cap_lock"):
            return
        project, udid, device_label = self._multi_shot_validate_project_and_device()
        if not project:
            return
        rel_list = _state.setdefault("multi_pending_rel", [])
        if len(rel_list) >= MAX_MULTI_PENDING_SHOTS:
            self._log(f"⚠ 最多暂存 {MAX_MULTI_PENDING_SHOTS} 张，请先提交或清空")
            return

        idx = len(rel_list) + 1
        rel_fn = f"ab_factory_pending/{idx:03d}.png"
        fp = os.path.join(project, rel_fn)
        _state["multi_cap_lock"] = True
        self._apply_multi_shot_buttons_state()
        threading.Thread(
            target=self._run_multi_capture_one_thread,
            args=(project, udid, device_label, rel_fn, fp),
            daemon=True,
        ).start()

    @objc.python_method
    def _run_multi_capture_one_thread(self, project, udid, device_label, rel_fn, fp):
        try:
            self._log(f"▶ 截取一张…（设备: {device_label[:44]}）")
            os.makedirs(os.path.dirname(fp), exist_ok=True)
            ok, err = _capture_ios_simulator_screenshot(udid, fp)
            if not ok:
                self._log(f"❌ 截图失败: {err}")
                return
            _state.setdefault("multi_pending_rel", []).append(rel_fn)
            n = len(_state["multi_pending_rel"])
            self._log(f"  ✅ 已暂存 {rel_fn}（共 {n} 张），可继续截或点「多图提交修Bug」")
            self._refresh_multi_pending_label()
        except Exception as e:
            self._log(f"❌ 截图异常: {e}")
        finally:
            _state["multi_cap_lock"] = False
            self._apply_multi_shot_buttons_state()

    def multiShotClearPending_(self, sender):
        """清空待提交列表并删除 ab_factory_pending 下 PNG。"""
        project = str(self.run_project_field.stringValue()).strip()
        if not project or not os.path.isdir(project):
            project = self._find_project_path()
            if project:
                def _f():
                    self.run_project_field.setStringValue_(project)
                NSOperationQueue.mainQueue().addOperationWithBlock_(_f)
        if not project or not os.path.isdir(project):
            self._log("❌ 请先填写「运行项目」路径"); return
        pd = os.path.join(project, "ab_factory_pending")
        for rel in list(_state.get("multi_pending_rel") or []):
            p = os.path.join(project, rel)
            if os.path.isfile(p):
                try:
                    os.remove(p)
                except OSError:
                    pass
        if os.path.isdir(pd):
            try:
                for fn in os.listdir(pd):
                    if fn.lower().endswith(".png"):
                        try:
                            os.remove(os.path.join(pd, fn))
                        except OSError:
                            pass
            except OSError:
                pass
        _state["multi_pending_rel"] = []
        self._refresh_multi_pending_label()
        self._log("  已清空多图暂存（ab_factory_pending/）")

    def multiScreensSubmitFixBug_(self, sender):
        """将已暂存的多张图 + 说明提交给 Cursor Agent。"""
        project, udid, device_label = self._multi_shot_validate_project_and_device()
        if not project:
            return
        paths_rel = list(_state.get("multi_pending_rel") or [])
        if not paths_rel:
            self._log("❌ 请先多次点「截一张」暂存截图，再提交")
            return
        note = str(self.multi_shot_note_field.stringValue()).strip()
        self._log(
            f"▶ 多图提交修 Bug（共 {len(paths_rel)} 张）"
            + (f"；说明：{note}" if note else "")
        )
        threading.Thread(
            target=self._run_multi_submit_fix_worker,
            args=(project, udid, device_label, paths_rel, note),
            daemon=True,
        ).start()

    @objc.python_method
    def _run_multi_submit_fix_worker(self, project, udid, device_label, paths_rel, note):
        md_path = os.path.join(project, "AB_FACTORY_MULTI_VISUAL_FIX.md")
        try:
            self._log(f"  设备: {device_label[:52]}")
            for rel in paths_rel:
                p = os.path.join(project, rel)
                if not os.path.isfile(p):
                    self._log(f"❌ 文件不存在: {rel}，请重新截取")
                    return

            lines = _state.get("last_flutter_log") or []
            log_tail = "\n".join(lines[-500:]) if lines else "（尚无本进程内运行日志。）"
            if len(log_tail) > 20000:
                log_tail = log_tail[-20000:]

            note_block = note if note else "（未填写）"
            parts = [
                "# AB 包工厂 — 多图截屏 + 说明（Cursor 修 Bug）",
                "",
                "## 补充说明（用户）",
                "",
                note_block,
                "",
                "## 模拟器截图（按时间顺序，暂存于 ab_factory_pending/）",
                "",
            ]
            for fn in paths_rel:
                parts.append(f"![{fn}]({fn})")
                parts.append("")
            parts.extend([
                "## 终端日志（节选）",
                "",
                "```",
                log_tail,
                "```",
                "",
                "## 任务",
                "",
                "根据多张截图、补充说明与日志修复问题；优先修改 `lib/modules/primary/`，非必要不改 `lib/modules/secondary/`。",
                "",
                f"---\n生成时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n",
            ])
            with open(md_path, "w", encoding="utf-8") as f:
                f.write("\n".join(parts))
            self._log(f"  已写入: {md_path}")

            _state["multi_pending_rel"] = []
            self._refresh_multi_pending_label()

            prompt_multi = (
                "You are a senior Flutter/Dart engineer. Read AB_FACTORY_MULTI_VISUAL_FIX.md at the repo root. "
                "Open and analyze every PNG under ab_factory_pending/ referenced in that markdown, in order. "
                "Pay strong attention to the user note in section 「补充说明」. "
                "Identify UI/logic bugs across screens: layout overflow, navigation issues, wrong content, red error screens. "
                "Also read the console log section. Apply fixes preferring lib/modules/primary/; avoid lib/modules/secondary/ unless necessary. "
                "If images cannot be loaded, rely on logs and the user note. Summarize files changed when done."
            )

            agent = _find_cursor_agent_cli()
            if agent:
                self._save_agent_model_prefs()
                model_id = self._current_agent_model_id()
                self._log(f"▶ 检测到 Cursor Agent CLI: {agent}")
                if model_id:
                    self._log(f"  使用模型: {model_id}")
                self._log("  正在后台执行「多图提交修复」…")
                self._set_agent_fix_ui_busy(True)
                threading.Thread(
                    target=self._run_cursor_agent_autofix,
                    args=(project, md_path, agent, prompt_multi, model_id),
                    daemon=True,
                ).start()
            else:
                self._log("⚠ 未检测到 agent CLI，将打开 Cursor 与多图、说明")
                self._log("    安装: curl https://cursor.com/install -fsSL | bash")
                extras = [
                    os.path.join(project, p) for p in paths_rel
                    if os.path.isfile(os.path.join(project, p))
                ]
                self._open_cursor_gui_with_fix_doc(project, md_path, extras)
        except Exception as e:
            self._log(f"❌ 多图提交流程异常: {e}")

    def simulatorCrawlStop_(self, sender):
        _state["crawl_stop"] = True
        self._log("  已请求停止模拟器巡检…")

    def simulatorCrawlStart_(self, sender):
        if _state.get("crawl_running"):
            self._log("⚠ 模拟器巡检已在进行中"); return
        if _state.get("is_running"):
            self._log("⚠ 有打包/混淆等任务正在执行，请稍后再试"); return

        project = str(self.run_project_field.stringValue()).strip()
        if not project or not os.path.isdir(project):
            project = self._find_project_path()
            if project:
                def _f():
                    self.run_project_field.setStringValue_(project)
                NSOperationQueue.mainQueue().addOperationWithBlock_(_f)
        if not project or not os.path.isdir(project):
            self._log("❌ 请先填写「运行项目」中的 Flutter 工程路径"); return
        if not os.path.isfile(os.path.join(project, "pubspec.yaml")):
            self._log(f"❌ 不是 Flutter 项目: {project}"); return

        row = self._selected_run_device_row()
        if not row:
            self._log("❌ 请先在下拉框中选择模拟器设备"); return
        device_label, udid, device_state, rk = row
        if udid == "macos" or rk != "ios_sim":
            self._log("❌ 「模拟器巡检」仅支持 iOS 模拟器，请选择 iPhone/iPad 模拟器"); return

        _state["crawl_stop"] = False
        self._set_crawl_ui_busy(True)
        threading.Thread(
            target=self._run_simulator_crawl_thread,
            args=(project, udid, device_label, device_state),
            daemon=True,
        ).start()

    @objc.python_method
    def _run_simulator_crawl_thread(self, project, udid, device_label, device_state):
        """启动/前置模拟器，网格点击 + 截图，写 AB_FACTORY_SIM_CRAWL.md，可选 Agent 分析。"""
        import time

        env = get_env()
        crawl_dir = os.path.join(project, "ab_factory_crawl")
        md_path = os.path.join(project, "AB_FACTORY_SIM_CRAWL.md")
        run_agent = False
        agent_bin = None
        model_id = ""

        try:
            self._log(f"▶ 模拟器自动探查开始（设备: {device_label[:48]}）")
            self._log("  提示：在「系统设置 › 隐私与安全性 › 辅助功能」中允许本应用，否则无法模拟点击。")
            self._log("  请先保持 ▶ 运行 中的 App 在模拟器内；本功能为启发式网格点击，无法保证遍历所有业务页面。")
            os.makedirs(crawl_dir, exist_ok=True)

            if udid != "macos" and device_state != "Booted":
                self._log("  正在启动模拟器…")
                subprocess.run(
                    ["xcrun", "simctl", "boot", udid],
                    capture_output=True, timeout=60, env=env,
                )
                subprocess.Popen(["open", "-a", "Simulator"], env=env)
                self._log("  等待模拟器就绪…")
                time.sleep(10)
            else:
                subprocess.Popen(["open", "-a", "Simulator"], env=env)
                time.sleep(1.2)

            _activate_simulator_app()
            time.sleep(0.8)

            screen_h = _main_screen_height()

            def _shot(tag, idx):
                p = os.path.join(crawl_dir, f"shot_{idx:03d}.png")
                ok, err = _capture_ios_simulator_screenshot(udid, p)
                if ok:
                    self._log(f"  📷 {tag}: {os.path.basename(p)}")
                else:
                    self._log(f"  ⚠ 截图失败 {tag}: {err}")
                return ok

            _shot("初始", 0)

            cols, rows = 4, 4
            taps = []
            for ri in range(rows):
                for ci in range(cols):
                    nx = 0.12 + (0.76) * (ci + 0.5) / cols
                    ny = 0.12 + (0.76) * (ri + 0.5) / rows
                    taps.append((nx, ny))

            step = 0
            for nx, ny in taps:
                if _state.get("crawl_stop"):
                    self._log("  ⏹ 已停止巡检（用户）")
                    break
                _activate_simulator_app()
                time.sleep(0.12)
                bounds = _pick_simulator_phone_window_bounds()
                if not bounds:
                    time.sleep(0.45)
                    bounds = _pick_simulator_phone_window_bounds()
                if not bounds:
                    self._log("  ⚠ 未找到 Simulator 设备窗口，跳过本次点击（请把模拟器放在主屏、窗口勿最小化）")
                    continue
                try:
                    _click_simulator_window_normalized(bounds, nx, ny, screen_h)
                except Exception as ex:
                    self._log(f"  ⚠ 点击异常: {ex}")
                time.sleep(0.48)
                step += 1
                _shot(f"步骤{step}", step)

            lines = _state.get("last_flutter_log") or []
            log_tail = "\n".join(lines[-1200:]) if lines else "（无本进程捕获的运行日志）"
            if len(log_tail) > 35000:
                log_tail = log_tail[-35000:]

            png_sorted = sorted(
                f for f in os.listdir(crawl_dir) if f.endswith(".png") and f.startswith("shot_")
            )

            body = ["# AB 包工厂 — 模拟器自动探查", "",
                    "以下为启发式网格点击采集的界面序列与运行日志节选，用于排查溢出、红屏、异常栈等。",
                    "", "## 截图序列", ""]
            for fn in png_sorted:
                body.append(f"![{fn}](ab_factory_crawl/{fn})")
                body.append("")
            body.extend([
                "## 终端 / Flutter 日志（节选）", "",
                "```",
                log_tail,
                "```",
                "",
                "## 说明",
                "",
                "在 Cursor 中逐张查看 `ab_factory_crawl/` 下 PNG；完整业务覆盖请使用项目内 `integration_test`。",
                "",
                f"---\n生成时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n",
            ])
            with open(md_path, "w", encoding="utf-8") as f:
                f.write("\n".join(body))
            self._log(f"  ✅ 已写入报告: {md_path}")

            agent_bin = _find_cursor_agent_cli()
            if agent_bin:
                self._save_agent_model_prefs()
                model_id = self._current_agent_model_id()
                run_agent = True
                self._log(f"▶ 调用 Cursor Agent 分析 {len(png_sorted)} 张截图与日志（请稍候）…")
            else:
                self._log("⚠ 未检测到 Cursor Agent CLI，请在 Cursor 中手动打开报告与 ab_factory_crawl/")
                self._log("    安装: curl https://cursor.com/install -fsSL | bash")
                self._open_cursor_gui_with_fix_doc(project, md_path)

        except Exception as e:
            self._log(f"❌ 模拟器巡检异常: {e}")
        finally:
            _state["crawl_stop"] = False

            def _finish():
                self._set_crawl_ui_busy(False)
                if run_agent and agent_bin:
                    self._set_agent_fix_ui_busy(True)
                    pr = (
                        "You are a senior Flutter/Dart engineer. Read AB_FACTORY_SIM_CRAWL.md at the repo root. "
                        "Open every PNG under ab_factory_crawl/ referenced in that file (iOS Simulator crawl). "
                        "Identify suspected bugs: RenderFlex overflow, red error screens, missing widgets, broken navigation, crash dialogs. "
                        "Cross-check with the log section in the same markdown. "
                        "Propose concrete fixes preferring lib/modules/primary/; avoid lib/modules/secondary/ unless necessary. "
                        "If you cannot view images, state limitations and rely on logs. Summarize files to edit when done."
                    )
                    threading.Thread(
                        target=self._run_cursor_agent_autofix,
                        args=(project, md_path, agent_bin, pr, model_id),
                        daemon=True,
                    ).start()

            NSOperationQueue.mainQueue().addOperationWithBlock_(_finish)

    def readIpaPubspecVersion_(self, sender):
        project = str(self.ipa_project_field.stringValue()).strip()
        if not project or not os.path.isdir(project):
            self._log("❌ 请先选择 Flutter 工程目录")
            return
        pub = os.path.join(project, "pubspec.yaml")
        if not os.path.isfile(pub):
            self._log(f"❌ 未找到 {pub}")
            return
        v_pub = _read_pubspec_version(pub)
        v_gen = _read_flutter_version_from_generated_xcconfig(project)
        v = v_pub or v_gen
        if not v:
            self._log("⚠ pubspec / Generated.xcconfig 均未解析到版本")
            return

        def _set():
            self.ipa_version_field.setStringValue_(v)
        NSOperationQueue.mainQueue().addOperationWithBlock_(_set)
        self._log(f"  版本来源文件: {os.path.abspath(pub)}")
        if v_pub:
            self._log(f"  pubspec version: {v_pub}")
        if v_gen:
            self._log(
                f"  Generated.xcconfig: {v_gen} "
                f"({os.path.abspath(os.path.join(project, 'ios', 'Flutter', 'Generated.xcconfig'))})"
            )
        if v_pub and v_gen and v_pub != v_gen:
            self._log(
                "  ⚠ 二者不一致：以 pubspec 为准填入了输入框；若刚改过版本请执行 "
                "`flutter pub get` 再读取，或检查是否仅改了原生工程未同步 pubspec。"
            )
        elif not v_pub and v_gen:
            self._log("  （pubspec 未解析到 version，已使用 Generated.xcconfig）")

    def writeIpaPubspecVersion_(self, sender):
        project = str(self.ipa_project_field.stringValue()).strip()
        if not project or not os.path.isdir(project):
            self._log("❌ 请先选择 Flutter 工程目录")
            return
        ver = str(self.ipa_version_field.stringValue()).strip()
        if not ver:
            self._log("❌ 版本号为空")
            return
        pub = os.path.join(project, "pubspec.yaml")
        if not os.path.isfile(pub):
            self._log(f"❌ 未找到 {pub}")
            return
        try:
            _apply_pubspec_version(pub, ver)
            self._log(f"✅ 已写入 pubspec version: {ver}")
        except Exception as e:
            self._log(f"❌ {e}")
            return
        try:
            updated, _unchanged, dver, found = _apply_app_data_version(project, ver)
            if updated:
                for p in updated:
                    self._log(
                        f"✅ 已同步 app_data_manager.dart version: {dver}  "
                        f"({os.path.relpath(p, project)})"
                    )
            elif not found:
                self._log("  （未发现 app_data_manager.dart 的 version 行，跳过 dart 版本同步）")
            else:
                self._log(f"  dart version 已是 {dver}，无需修改")
        except Exception as e:
            self._log(f"⚠ dart 版本同步失败: {e}")

    def captureAppStoreScreenshot_(self, sender):
        """独立功能：截当前模拟器并转为 App Store 尺寸，保存到工程 screenshots/app_store/。"""
        project = str(self.ipa_project_field.stringValue()).strip()
        if not project or not os.path.isdir(project):
            project = str(self.run_project_field.stringValue()).strip()
        if not project or not os.path.isdir(project):
            project = self._find_project_path()
        if not project or not os.path.isdir(project):
            self._log("❌ 请填写 Flutter 工程路径（步骤5 或运行项目）")
            return
        if not os.path.isfile(os.path.join(project, "pubspec.yaml")):
            self._log(f"❌ 不是 Flutter 项目: {project}")
            return

        row = self._selected_run_device_row()
        if not row:
            self._log("❌ 请先在运行区下拉框选择 iOS 模拟器")
            return
        device_label, udid, _state_str, run_kind = row
        if udid == "macos" or run_kind != "ios_sim":
            self._log("❌ 商店截图仅支持 iOS 模拟器，请在运行区选择 iPhone/iPad 模拟器")
            return

        (tw, th), kind, tag = _app_store_target_for_simulator(device_label)

        out_dir = _app_store_screenshot_dir(project)
        os.makedirs(out_dir, exist_ok=True)
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        out_path = os.path.join(out_dir, f"{kind.lower()}_{tag}_{ts}.png")
        n = 2
        while os.path.isfile(out_path):
            out_path = os.path.join(out_dir, f"{kind.lower()}_{tag}_{ts}_{n}.png")
            n += 1

        self._log(
            f"▶ App Store 商店截图（{kind} {tw}×{th}px，设备: {device_label[:48]}）…")
        ok, detail = _capture_and_convert_app_store_screenshot(udid, out_path, tw, th)
        if not ok:
            self._log(f"❌ {detail}")
            self._log("  请确认模拟器已启动且 App 在前台；可先点 ▶ 运行再截图。")
            return
        self._log(f"✅ 已保存: {out_path}")
        if detail:
            self._log(f"  {detail}")

    def refreshDevices_(self, sender):
        proj = self._run_project_path_for_devices()
        threading.Thread(target=self._refresh_device_list, args=(proj,), daemon=True).start()

    @objc.python_method
    def _fetch_proxifly_us_proxies(self):
        import urllib.request
        import urllib.error

        req = urllib.request.Request(
            PROXIFLY_US_PROXY_URL,
            headers={"User-Agent": f"AB-Factory/{APP_VERSION}"},
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read().decode("utf-8", errors="replace")
            items = json.loads(raw)
            if not isinstance(items, list):
                return [], "proxifly 返回格式异常"
            socks_items = [
                x for x in items
                if isinstance(x, dict)
                and str(x.get("protocol") or "").lower() == "socks5"
                and str(x.get("proxy") or "").startswith("socks5://")
            ]
            socks_items.sort(
                key=lambda x: (
                    int(x.get("score") or 0),
                    str(x.get("ip") or ""),
                    int(x.get("port") or 0),
                ),
                reverse=True,
            )
            entries = []
            seen = set()
            for item in socks_items:
                url = str(item.get("proxy") or "").strip()
                if not url or url in seen:
                    continue
                seen.add(url)
                ip = str(item.get("ip") or "").strip()
                port = str(item.get("port") or "").strip()
                geo = item.get("geolocation") or {}
                city = str(geo.get("city") or "").strip() or "—"
                country = str(geo.get("country") or "US").strip() or "US"
                anonymity = str(item.get("anonymity") or "—").strip() or "—"
                label = f"{country} · {city} · {ip}:{port} ({anonymity})"
                if len(label) > 120:
                    label = label[:117] + "..."
                entries.append((label, url))
                if len(entries) >= PROXIFLY_US_PROXY_MAX:
                    break
            if not entries:
                return [], "proxifly 未找到可用 US socks5 代理"
            return entries, None
        except urllib.error.URLError as e:
            reason = getattr(e, "reason", e)
            return [], f"网络错误: {reason}"
        except Exception as e:
            return [], str(e)

    @objc.python_method
    def _apply_proxy_popup_entries(self, entries):
        popup = self.cfg_proxy_popup
        popup.removeAllItems()
        popup.addItemWithTitle_("— 选择 proxifly US 代理 —")
        urls = []
        for label, url in entries:
            popup.addItemWithTitle_(label)
            urls.append(url)
        _state["socks_proxy_urls"] = urls
        popup.selectItemAtIndex_(0)

    @objc.python_method
    def _refresh_socks_proxy_list(self, log=True):
        entries, err = self._fetch_proxifly_us_proxies()

        def finish():
            if err:
                if log:
                    self._log(f"❌ 拉取 proxifly US 代理失败: {err}")
                return
            self._apply_proxy_popup_entries(entries)
            if log:
                self._log(f"✅ 已加载 {len(entries)} 个 US socks5 代理（proxifly）")

        NSOperationQueue.mainQueue().addOperationWithBlock_(finish)

    def refreshProxyList_(self, sender):
        self._set_btn(self.refresh_proxy_btn, False, "…")

        def run():
            self._refresh_socks_proxy_list(log=True)
            NSOperationQueue.mainQueue().addOperationWithBlock_(
                lambda: self._set_btn(self.refresh_proxy_btn, True, "刷新"))

        threading.Thread(target=run, daemon=True).start()

    def proxyListPopupChanged_(self, sender):
        idx = self.cfg_proxy_popup.indexOfSelectedItem()
        urls = _state.get("socks_proxy_urls") or []
        if idx <= 0 or idx - 1 >= len(urls):
            return
        self.cfg_proxy_field.setStringValue_(urls[idx - 1])

    # ── Step 1: Create project ──

    def createProject_(self, sender):
        if _state["is_running"]:
            self._log("⚠ 有任务正在执行中"); return

        template = str(self.template_field.stringValue()).strip()
        name = str(self.project_name_field.stringValue()).strip()
        bundle_id = str(self.bundle_id_field.stringValue()).strip()
        display = str(self.display_name_field.stringValue()).strip()
        output = str(self.output_field.stringValue()).strip()

        if not template: self._log("❌ 请填写模板路径"); return
        if not name: self._log("❌ 请填写项目名称"); return
        if not bundle_id: self._log("❌ 请填写 Bundle ID"); return
        if not output: self._log("❌ 请填写输出目录"); return

        script = os.path.join(template, "scripts", "create_ab_project.sh")
        if not os.path.isfile(script): self._log(f"❌ 脚本不存在: {script}"); return

        project_path = os.path.join(output, name)
        if os.path.isdir(project_path): self._log(f"❌ 目标已存在: {project_path}"); return

        _state["is_running"] = True
        self._set_btn(self.create_btn, False, "创建中…")
        self._set_status(self.step1_status, "正在创建…")

        cmd = [script, "-n", name, "-b", bundle_id, "-o", output]
        if display: cmd.extend(["-d", display])

        self._log(f"▶ {' '.join(cmd)}")
        threading.Thread(target=self._run_cmd,
            args=(cmd, self.create_btn, "创建项目", self.step1_status, project_path, None, None),
            daemon=True).start()

    def randomBundleIdStep1_(self, sender):
        bid = generate_random_bundle_id()
        if not bid:
            self._log("❌ 无法读取本机系统英语词典（已尝试 /usr/share/dict/words、web2、web2a）")
            return
        self.bundle_id_field.setStringValue_(bid)

    def randomBundleIdCfg_(self, sender):
        bid = generate_random_bundle_id()
        if not bid:
            self._log("❌ 无法读取本机系统英语词典（已尝试 /usr/share/dict/words、web2、web2a）")
            return
        self.cfg_bundle_field.setStringValue_(bid)

    # ── Step 2: Sync secondary ──

    def alignScriptsFromTemplate_(self, sender):
        if _state["is_running"]:
            self._log("⚠ 有任务正在执行中"); return
        template = str(self.template_field.stringValue()).strip() or DEFAULT_TEMPLATE
        target = str(self.target_field.stringValue()).strip()
        src = os.path.join(template, "scripts")
        if not os.path.isdir(src):
            self._log(f"❌ 模板 scripts 目录不存在: {src}"); return
        if not target:
            self._log("❌ 请填写目标工程路径"); return
        if not os.path.isdir(target):
            self._log(f"❌ 目标工程不存在: {target}"); return
        if os.path.realpath(template) == os.path.realpath(target):
            self._log("⚠ 目标工程即模板本身，无需对齐"); return
        _state["is_running"] = True
        self._set_btn(sender, False, "对齐中…")
        self._set_status(self.step2_status, "对齐脚本…")
        dst = os.path.join(target, "scripts")
        self._log(f"▶ 对齐模板脚本: {src} → {dst}")
        threading.Thread(target=self._run_align_scripts, args=(src, dst, sender), daemon=True).start()

    @objc.python_method
    def _run_align_scripts(self, src, dst, btn):
        try:
            n = 0
            for root, _dirs, files in os.walk(src):
                rel = os.path.relpath(root, src)
                out_dir = dst if rel == "." else os.path.join(dst, rel)
                os.makedirs(out_dir, exist_ok=True)
                for f in files:
                    d = os.path.join(out_dir, f)
                    shutil.copy2(os.path.join(root, f), d)
                    if f.endswith(".sh"):
                        os.chmod(d, os.stat(d).st_mode | 0o111)
                    n += 1
            self._log(f"✅ 已对齐 {n} 个脚本文件到工程 scripts/（覆盖同名文件，保留工程额外文件）")
            self._log("  现在可放心点「同步 B 面代码」，产出的 Base64 映射会是相对路径。")
            self._set_status(self.step2_status, "脚本已对齐 ✓", success=True)
        except Exception as e:
            self._log(f"❌ 对齐脚本失败: {e}")
            self._set_status(self.step2_status, "对齐失败", success=False)
        finally:
            _state["is_running"] = False
            self._set_btn(btn, True, "对齐模板脚本")

    def restorePubspecClean_(self, sender):
        if _state["is_running"]:
            self._log("⚠ 有任务正在执行中")
            return
        target = str(self.target_field.stringValue()).strip()
        if not target:
            self._log("❌ 请填写目标工程路径")
            return
        if not os.path.isdir(target):
            self._log(f"❌ 目标工程不存在: {target}")
            return
        if not os.path.isfile(os.path.join(target, "pubspec.yaml")):
            self._log("❌ 目标工程缺少 pubspec.yaml")
            return

        self._log("▶ 一键还原 pubspec.yaml …")
        ok, msg = _restore_pubspec_clean(target)
        if ok:
            self._log(f"✅ {msg}")
            self._log("  原文件已备份为 pubspec.yaml.before_restore")
            _run_flutter_pub_get(target, self._log)
            self._set_status(self.step2_status, "pubspec 已还原 ✓", success=True)
        else:
            self._log(f"❌ {msg}")
            self._set_status(self.step2_status, "还原失败", success=False)

    def repairObfImports_(self, sender):
        if _state["is_running"]:
            self._log("⚠ 有任务正在执行中")
            return
        target = str(self.target_field.stringValue()).strip()
        if not target:
            self._log("❌ 请填写目标工程路径")
            return
        if not os.path.isdir(target):
            self._log(f"❌ 目标工程不存在: {target}")
            return
        if not os.path.isfile(os.path.join(target, "pubspec.yaml")):
            self._log("❌ 目标工程缺少 pubspec.yaml")
            return

        self._log("▶ 修正 A 面混淆 import → 标准包名 …")
        try:
            n, changed = _deobfuscate_dart_imports(target)
        except Exception as e:
            self._log(f"❌ 修正导入失败: {e}")
            self._set_status(self.step2_status, "修正失败", success=False)
            return

        if n == 0:
            self._log("  未发现残留混淆 import，无需修正（lib/ 已是标准包名）")
            self._set_status(self.step2_status, "导入无需修正 ✓", success=True)
            return

        self._log(f"✅ 已修正 {n} 个文件的混淆 import：")
        for c in changed:
            self._log(f"  - {c}")
        _run_flutter_pub_get(target, self._log)
        self._set_status(self.step2_status, f"导入已修正 {n} 处 ✓", success=True)

    def syncSecondary_(self, sender):
        if _state["is_running"]:
            self._log("⚠ 有任务正在执行中"); return

        idx = self.project_popup.indexOfSelectedItem()
        code = PROJECT_CODES[idx] if 0 <= idx < len(PROJECT_CODES) else ""
        source = str(self.source_field.stringValue()).strip()
        target = str(self.target_field.stringValue()).strip()

        if not code: self._log("❌ 请选择项目代号"); return
        if not source: self._log("❌ 请填写源码路径"); return
        if not os.path.isdir(source): self._log(f"❌ 源码路径不存在: {source}"); return
        if not target: self._log("❌ 请填写目标工程路径"); return
        if not os.path.isdir(target): self._log(f"❌ 目标工程不存在: {target}"); return

        self._save_b_side_prefs()
        template_dir = str(self.template_field.stringValue()).strip() or DEFAULT_TEMPLATE
        # 优先使用「工程自身」的 sync 脚本：脚本与 assets 同在工程内，
        # PROJECT_ROOT=dirname(scripts)=工程根，Base64 等相对路径才正确（与原始 zeus_template 模型一致）。
        # 注意：不再兜底跑模板那份——模板 sync 现按 dirname 解析工程根，拿模板脚本跑会写进 daddy_template。
        script_prj = os.path.join(target, "scripts", "sync_secondary.sh")
        if os.path.isfile(script_prj):
            script = script_prj
        else:
            self._log("❌ 工程内缺少 scripts/sync_secondary.sh。请用步骤1重建工程，或先把模板 scripts/ 复制进工程后再同步 B 面。"); return

        _state["is_running"] = True
        self._set_btn(self.sync_btn, False, "同步中…")
        self._set_status(self.step2_status, "正在同步…")

        cmd = [script, "-p", code, "-s", source]
        self._log(f"▶ {' '.join(cmd)}")
        idx_sel = self.project_popup.indexOfSelectedItem()

        def on_sync_ok():
            self._log("  修复 pubspec（B 面源重建 overrides / 去污染 / plugin path）…")
            _changed, pmsg, fixed = _repair_pubspec_after_b_side_sync(target, source)
            if _changed:
                self._log(f"  📦 pubspec: {pmsg}")
                _run_flutter_pub_get(target, self._log)
            elif pmsg:
                self._log(f"  {pmsg}")

            # 注：原先在此处调用三个 B 面同步后钩子
            # (_install_b_side_shell_bridges / _install_b_side_podfile_hooks /
            #  _ensure_arm64_simulator_excluded)
            # 现已通过 dq 项目源码本身（plugin/fijkplayer/ios/fijkplayer.podspec
            # 的 EXCLUDED_ARCHS）与模板侧 compat_dq.sh 的自包含入口/iOS 部署目标对齐解决，
            # 不再需要 AB 包工厂在同步后做任何补丁。
            # B 面渠道写入 config.dart 须用户点「写」，不在同步后自动改源码。

            def _ui():
                n = int(self.obf_project_popup.numberOfItems())
                if 0 <= idx_sel < n:
                    self.obf_project_popup.selectItemAtIndex_(idx_sel)
            NSOperationQueue.mainQueue().addOperationWithBlock_(_ui)

        threading.Thread(target=self._run_cmd,
            args=(cmd, self.sync_btn, "同步 B 面代码", self.step2_status, None, target, on_sync_ok),
            daemon=True).start()

    def oneClickSyncObf_(self, sender):
        if _state["is_running"]:
            self._log("⚠ 有任务正在执行中"); return

        idx = self.project_popup.indexOfSelectedItem()
        code = PROJECT_CODES[idx] if 0 <= idx < len(PROJECT_CODES) else ""
        source = str(self.source_field.stringValue()).strip()
        target = str(self.target_field.stringValue()).strip()

        if not code: self._log("❌ 请选择项目代号"); return
        if not source or not os.path.isdir(source): self._log(f"❌ 源码路径无效: {source}"); return
        if not target or not os.path.isdir(target): self._log(f"❌ 目标工程无效: {target}"); return

        sync_script = os.path.join(target, "scripts", "sync_secondary.sh")
        code_script = os.path.join(target, "scripts", "obfuscate_code.sh")
        fw_script = os.path.join(target, "scripts", "obfuscate_frameworks.sh")
        for s in (sync_script, code_script, fw_script):
            if not os.path.isfile(s):
                self._log(f"❌ 脚本不存在: {s}"); return

        self._save_b_side_prefs()
        _state["is_running"] = True
        self._set_btn(self.pipeline_btn, False, "执行中…")
        self._set_btn(self.sync_btn, False)
        self._set_status(self.step2_status, "一键同步+混淆中…")

        self._log(f"▶ 一键同步+混淆 (-p {code})：同步 → 修复pubspec → 代码混淆(--all) → Framework 混淆(run)")
        threading.Thread(target=self._run_full_pipeline,
            args=(code, source, target, int(idx)), daemon=True).start()

    @objc.python_method
    def _run_full_pipeline(self, code, source, target, idx_sel):
        title = "一键同步+混淆"
        sync_script = os.path.join(target, "scripts", "sync_secondary.sh")
        code_script = os.path.join(target, "scripts", "obfuscate_code.sh")
        fw_script = os.path.join(target, "scripts", "obfuscate_frameworks.sh")
        try:
            # 1. 同步 B 面
            self._log(f"▶ [1/4 同步 B 面] {sync_script} -p {code} -s {source}")
            rc = self._exec_stream([sync_script, "-p", code, "-s", source], target)
            if rc != 0:
                self._log(f"❌ 同步失败 (exit {rc})，已中止后续步骤")
                self._set_status(self.step2_status, "❌ 同步失败", success=False)
                self._notify_telegram(title, ok=False, detail=f"sync exit={rc}"); return
            self._log("✅ 同步完成")

            # 2. 修复 pubspec（与手动同步一致的工厂后处理）
            self._log("  [2/4 修复 pubspec] B 面源重建 overrides / 去污染 / plugin path …")
            _changed, pmsg, _fixed = _repair_pubspec_after_b_side_sync(target, source)
            if _changed:
                self._log(f"  📦 pubspec: {pmsg}")
                _run_flutter_pub_get(target, self._log)
            elif pmsg:
                self._log(f"  {pmsg}")

            def _ui():
                n = int(self.obf_project_popup.numberOfItems())
                if 0 <= idx_sel < n:
                    self.obf_project_popup.selectItemAtIndex_(idx_sel)
            NSOperationQueue.mainQueue().addOperationWithBlock_(_ui)

            # 3. Dart 代码全量混淆
            self._log(f"▶ [3/4 代码混淆] {code_script} -p {code} --all")
            rc = self._exec_stream([code_script, "-p", code, "--all"], target)
            if rc != 0:
                self._log(f"❌ 代码混淆失败 (exit {rc})，已中止后续步骤")
                self._set_status(self.step2_status, "❌ 代码混淆失败", success=False)
                self._notify_telegram(title, ok=False, detail=f"code exit={rc}"); return
            self._log("✅ 代码混淆完成")

            # 4. Framework / Pod / 依赖字符串混淆
            self._log(f"▶ [4/4 Framework 混淆] {fw_script} run -p {code}")
            rc = self._exec_stream([fw_script, "run", "-p", code], target)
            if rc != 0:
                self._log(f"❌ Framework 混淆失败 (exit {rc})")
                self._set_status(self.step2_status, "❌ Framework 混淆失败", success=False)
                self._notify_telegram(title, ok=False, detail=f"fw exit={rc}"); return
            self._log("✅ Framework 混淆完成")

            self._log("✅ 一键同步+混淆全部完成（同步 → pubspec → 代码 → Framework）")
            self._set_status(self.step2_status, "✅ 一键完成", success=True)
            self._notify_telegram(title, ok=True)
        except Exception as e:
            self._log(f"❌ 异常: {e}")
            self._set_status(self.step2_status, f"❌ {e}", success=False)
            self._notify_telegram(title, ok=False, detail=str(e))
        finally:
            _state["is_running"] = False
            self._set_btn(self.pipeline_btn, True, "一键同步+混淆")
            self._set_btn(self.sync_btn, True)

    # ── Step 3: A-side / Cursor ──

    def openInCursor_(self, sender):
        project = str(self.aside_project_field.stringValue()).strip()
        if not project or not os.path.isdir(project):
            self._log("❌ 请选择有效的项目目录"); return

        self._ensure_cursor_rules(project)

        opened = False
        try:
            subprocess.Popen(["cursor", project])
            opened = True
        except FileNotFoundError:
            try:
                subprocess.Popen(["open", "-a", "Cursor", project])
                opened = True
            except Exception:
                pass

        if opened:
            self._log(f"已在 Cursor 中打开: {project}")
            self._log("  ⚠ A 面代码只能写在 lib/modules/primary/；本工程仅面向 iOS")
        else:
            self._log("❌ 无法打开 Cursor，请确认已安装")

    @objc.python_method
    def _ensure_cursor_rules(self, project):
        rules_path = os.path.join(project, ".cursorrules")
        fv = getattr(self, "runtime_fvm_version", None) or FVM_FLUTTER_VERSION
        rules_content = f"""# AB 包 A 面开发规则 — Cursor 必须严格遵守

## 技术栈
- **Flutter**: {fv}（通过 FVM 管理，命令前缀 `fvm flutter`）
- **平台**: 仅 iOS
- **语言**: Dart
- **状态管理**: ChangeNotifier + Singleton
- **中文注释**: 允许

## 核心约束（违反即为错误）

### 1. 代码位置限制
- **所有 A 面业务代码只能写在 `lib/modules/primary/` 目录中**
- 禁止修改 `lib/modules/secondary/` 下的任何文件（B 面由 `sync_secondary.sh` 同步；统一入口 `lib/modules/secondary/module_entry.dart`）
- 禁止修改 `lib/services/`、`lib/config/`、`lib/router/` 等框架核心文件，除非用户明确要求
- 新建页面、组件、工具类等都必须放在 `lib/modules/primary/` 的子目录下

### 2. 平台（仅 iOS）
- 禁止添加或使用任何非 iOS 目标相关能力（含 Android、Web、桌面等）
- 第三方包须以 iOS 为交付目标验证通过后再合入
- 平台相关 API 仅考虑 iOS（权限、路径、人机界面指南等）

### 3. Dart 代码规范
- 使用 `const` 构造函数、`final` 不可变变量、尾部逗号
- 遵循 `flutter_lints` 规则
- 导入顺序: dart SDK → Flutter → 第三方 → 相对路径

### 4. 命令
- `fvm flutter pub get` — 安装依赖
- `fvm flutter run` — 运行
- `fvm flutter analyze` — 静态分析
"""
        try:
            with open(rules_path, 'w', encoding='utf-8') as f:
                f.write(rules_content)
            self._log("  ✅ 已写入 .cursorrules 规则文件")
        except Exception as e:
            self._log(f"  ⚠ 写入 .cursorrules 失败: {e}")

    # ── Run Flutter ──

    @objc.python_method
    def _find_project_path(self):
        for field in [self.run_project_field, self.aside_project_field,
                      self.target_field, self.obf_project_field, self.ipa_project_field]:
            p = str(field.stringValue()).strip()
            if p and os.path.isdir(p) and os.path.isfile(os.path.join(p, "pubspec.yaml")):
                return p
        return None

    def clearFlutterIosCache_(self, sender):
        if _state["flutter_proc"] is not None:
            self._log("⚠ 请先停止正在运行的 Flutter 再清缓存"); return
        if _state["is_running"]:
            self._log("⚠ 有任务正在执行中，请稍后"); return

        project = str(self.run_project_field.stringValue()).strip()
        if not project or not os.path.isdir(project):
            project = self._find_project_path()
            if project:
                def _fill():
                    self.run_project_field.setStringValue_(project)
                NSOperationQueue.mainQueue().addOperationWithBlock_(_fill)
        if not project or not os.path.isdir(project):
            self._log("❌ 请先填写「运行项目」中的 Flutter 工程路径"); return
        if not os.path.isfile(os.path.join(project, "pubspec.yaml")):
            self._log(f"❌ 不是 Flutter 项目: {project}"); return
        fc = flutter_cmd()
        if not fc:
            self._log("❌ 未检测到 FVM，无法执行 precache"); return

        self._set_btn(self.clear_ios_cache_btn, False, "…")
        threading.Thread(
            target=self._clear_flutter_ios_cache_thread,
            args=(project, list(fc)),
            daemon=True).start()

    @objc.python_method
    def _clear_flutter_ios_cache_thread(self, project, fc):
        env = get_env()
        home = os.path.expanduser("~")
        ver = FVM_FLUTTER_VERSION
        base = os.path.join(
            home, "fvm", "versions", ver, "bin", "cache", "artifacts", "engine")
        trio = ("ios", "ios-profile", "ios-release")
        try:
            self._log(f"── 清缓存开始（FVM Flutter {ver}）──")
            self._log("  (1/3) 删除 iOS engine artifacts …")
            for name in trio:
                p = os.path.join(base, name)
                if os.path.isdir(p):
                    shutil.rmtree(p, ignore_errors=True)
                    self._log(f"     已删 {p}")
                elif os.path.isfile(p) or os.path.islink(p):
                    try:
                        os.remove(p)
                    except OSError:
                        pass
                    self._log(f"     已移除 {p}")
                else:
                    self._log(f"     （不存在，跳过）{p}")

            self._log("  (2/3) 在项目目录执行 fvm flutter precache --ios …")
            r = subprocess.run(
                [*fc, "precache", "--ios"],
                cwd=project, env=env, capture_output=True, text=True,
                timeout=1200, errors="replace",
            )
            if r.returncode != 0:
                self._log(f"  ❌ precache 退出码 {r.returncode}")
                tail = (r.stderr or r.stdout or "").splitlines()[-25:]
                for line in tail:
                    self._log(f"     {strip_ansi(line.rstrip())}")
            else:
                self._log("     precache --ios ✓")

            self._log("  (3/3) 删除 Xcode DerivedData/Runner-* …")
            dd_pat = os.path.join(
                home, "Library", "Developer", "Xcode", "DerivedData", "Runner-*")
            matches = sorted(glob.glob(dd_pat))
            if not matches:
                self._log("     （无匹配 Runner-* 目录）")
            for p in matches:
                if os.path.isdir(p):
                    shutil.rmtree(p, ignore_errors=True)
                    self._log(f"     已删 {p}")

            self._log("── 清缓存结束 ──")
        except subprocess.TimeoutExpired:
            self._log("❌ precache 超时（>20 分钟），请检查网络后重试")
        except Exception as e:
            self._log(f"❌ 清缓存异常: {e}")
        finally:
            self._set_btn(
                self.clear_ios_cache_btn, True, "清 iOS 引擎与 Xcode 缓存")

    def runFlutter_(self, sender):
        if _state["flutter_proc"] is not None:
            self._log("⚠ Flutter 正在运行中，请先停止"); return
        if _state["is_running"]:
            self._log("⚠ 有任务正在执行中"); return

        self._save_b_side_prefs()
        project = str(self.run_project_field.stringValue()).strip()
        if not project or not os.path.isdir(project):
            project = self._find_project_path()
            if project:
                def _fill():
                    self.run_project_field.setStringValue_(project)
                NSOperationQueue.mainQueue().addOperationWithBlock_(_fill)
        if not project or not os.path.isdir(project):
            self._log("❌ 请选择有效的 Flutter 项目目录"); return
        if not os.path.isfile(os.path.join(project, "pubspec.yaml")):
            self._log(f"❌ 不是 Flutter 项目: {project}"); return

        row = self._selected_run_device_row()
        if not row:
            self._log("❌ 请选择目标设备（点击刷新按钮检测设备）"); return
        device_label, device_id, device_state, run_kind = row
        mode_idx = self.mode_popup.indexOfSelectedItem()
        is_release = (mode_idx == 1)

        if is_release and run_kind == "ios_sim":
            is_release = False
            self._log("⚠ 模拟器不支持 Release 模式，已自动切换为 Debug")

        self._set_btn(self.run_btn, False, "…")
        self._set_btn(self.stop_btn, True)
        self._set_status(self.step3_status, "准备…")

        threading.Thread(target=self._run_flutter_thread,
            args=(project, device_id, device_state, device_label, is_release, run_kind),
            daemon=True).start()

    @objc.python_method
    def _run_flutter_thread(self, project, device_id, device_state, device_label,
                           is_release=False, run_kind="ios_sim"):
        import time
        _state["last_flutter_log"] = []
        env = get_env()

        try:
            # 运行前自动修正：把 A 面 lib/ 残留的混淆 import 还原为标准包名。
            # 幂等且自守卫：仅当 pubspec 声明的是标准包名时才改写，故混淆构建态不会被误伤。
            # 根治「混淆中断 / 同步 B 面后 lib 仍是混淆名 → flutter run 解析失败」的反复问题。
            try:
                _n_fix, _ = _deobfuscate_dart_imports(project)
                if _n_fix:
                    self._log(f"  运行前修正 import：{_n_fix} 个文件已还原为标准包名")
            except Exception as _e_fix:
                self._log(f"  ⚠ import 自动修正跳过：{_e_fix}")

            fc = flutter_cmd()
            if not fc:
                self._log(
                    "❌ 未检测到 FVM。本工具统一使用 `fvm flutter` 运行工程。"
                    "请安装 FVM 后在工程根执行 `fvm use <版本>`。")
                self._set_status(self.step3_status, "❌", success=False)
                return
            mode_label = "Release" if is_release else "Debug"

            if run_kind == "ios_sim":
                fresh = list_simulators()
                remapped = _resolve_simulator_for_run(
                    fc, env, fresh, device_label, device_id, device_state,
                    project_root=project)
                if remapped is None:
                    self._log(
                        "❌ 所选模拟器已不存在或无法按名称匹配，请点击「刷新设备」后重新选择。")
                    self._set_status(self.step3_status, "❌", success=False)
                    return
                nl, nid, nst = remapped
                if nid != device_id:
                    self._log(
                        f"⚠ 模拟器 UDID 与 Flutter/Xcode 不一致，已自动改用: {nid} "
                        f"（原 {device_id}）")
                device_label, device_id, device_state = nl, nid, nst

                def _is_booted(udid):
                    try:
                        cb = subprocess.run(
                            ["xcrun", "simctl", "list", "devices", "booted"],
                            capture_output=True, text=True, timeout=10, env=env)
                        return udid.upper() in (cb.stdout or "").upper()
                    except Exception:
                        return False

                def _booted_other_udids(target):
                    try:
                        cb = subprocess.run(
                            ["xcrun", "simctl", "list", "devices", "booted"],
                            capture_output=True, text=True, timeout=10, env=env)
                    except Exception:
                        return []
                    out = []
                    for ln in (cb.stdout or "").splitlines():
                        m = re.search(r"\(([0-9A-F-]{36})\)\s+\(Booted\)", ln)
                        if m and m.group(1).upper() != str(target).upper():
                            out.append(m.group(1))
                    return out

                def _simulator_app_anchored_udid():
                    try:
                        ps = subprocess.run(
                            ["pgrep", "-fla", "Simulator.app/Contents/MacOS/Simulator"],
                            capture_output=True, text=True, timeout=5)
                    except Exception:
                        return None
                    for ln in (ps.stdout or "").splitlines():
                        m = re.search(r"-CurrentDeviceUDID\s+([0-9A-Fa-f-]{36})", ln)
                        if m:
                            return m.group(1).upper()
                        if "Simulator.app/Contents/MacOS/Simulator" in ln:
                            return ""
                    return None

                # 关闭非目标的 booted simulator，避免 launchd 槽位拥堵
                # （多 sim 同时 booted 时会触发 FBSOpenApplication 拒绝拉起 + EAGAIN）
                others = _booted_other_udids(device_id)
                if others:
                    self._log(
                        f"  关闭其它 {len(others)} 台 booted 模拟器以释放 launchd 槽位…")
                    for ou in others:
                        try:
                            subprocess.run(
                                ["xcrun", "simctl", "shutdown", ou],
                                capture_output=True, text=True, timeout=20, env=env)
                        except Exception:
                            pass

                # 若 Simulator.app 当前锚到了别的 UDID（或没传 UDID），
                # 必须先 kill 再以目标 UDID 重新打开，否则前台显示与
                # SpringBoard 上下文会和真正 build 进的 UDID 不一致，
                # 严重时直接 SBMainWorkspace 拒绝 launchApplicationWithID。
                anchored = _simulator_app_anchored_udid()
                if anchored is not None and anchored != str(device_id).upper():
                    self._log(
                        f"  Simulator.app 当前锚定 UDID={anchored or '∅'}，"
                        f"与目标 {device_id} 不一致，正在重新锚定…")
                    try:
                        subprocess.run(
                            ["pkill", "-9", "-f",
                             "Simulator.app/Contents/MacOS/Simulator"],
                            capture_output=True, text=True, timeout=5)
                    except Exception:
                        pass
                    time.sleep(1)

                if not _is_booted(device_id):
                    self._log(f"正在启动模拟器: {device_label}…")
                    br = subprocess.run(
                        ["xcrun", "simctl", "boot", device_id],
                        capture_output=True, text=True, timeout=60, env=env)
                    bmsg = ((br.stdout or "") + (br.stderr or "")).strip()
                    if br.returncode != 0 and "already booted" not in bmsg.lower() and "current state: booted" not in bmsg.lower():
                        self._log(f"  ⚠ simctl boot 返回 {br.returncode}: {bmsg[-240:]}")
                    subprocess.Popen(
                        ["open", "-a", "Simulator", "--args",
                         "-CurrentDeviceUDID", device_id],
                        env=env)
                    self._log("等待模拟器就绪…")
                    deadline = time.time() + 90
                    while time.time() < deadline:
                        if _is_booted(device_id):
                            break
                        time.sleep(2)
                    else:
                        self._log("  ⚠ 90 秒内未检测到模拟器进入 Booted 状态，将仍尝试构建。")
                else:
                    self._log(f"模拟器已在运行: {device_label}")
                    # 即便已 booted，也确保 Simulator.app 锚到目标
                    if _simulator_app_anchored_udid() != str(device_id).upper():
                        subprocess.Popen(
                            ["open", "-a", "Simulator", "--args",
                             "-CurrentDeviceUDID", device_id],
                            env=env)

                uuids = None
                for attempt in range(4):
                    uuids = _xcode_destination_uuid_ids(project, env)
                    if uuids and str(device_id).upper() in {u.upper() for u in uuids}:
                        break
                    if attempt == 0:
                        try:
                            subprocess.run(
                                ["xcrun", "simctl", "list", "runtimes"],
                                capture_output=True, text=True, timeout=15, env=env)
                        except Exception:
                            pass
                    time.sleep(2 + attempt * 2)
                if uuids is None:
                    self._log("  ⚠ 无法读取 Runner scheme 的 destinations（xcodebuild 失败/未安装），跳过校验。")
                else:
                    in_xcode = str(device_id).upper() in {u.upper() for u in uuids}
                    self._log(
                        f"  Xcode 可见 destinations: {len(uuids)} 项，含本机 UDID = {in_xcode}")
                    # 自检：Flutter SDK 必须已打过 xcodeproj.dart 的 -workspace 补丁，
                    # 否则在 launchd 派生的 GUI 进程链里调 `xcodebuild -project ...
                    # -sdk iphonesimulator -destination id=UDID -showBuildSettings`
                    # 会丢失全部 simulator destinations、报 "Unable to find a
                    # destination matching the provided destination specifier"。
                    # （根因：launchd 派生上下文 + -project 形式的组合，xcodebuild
                    # 解析 scheme destinations 时拿不到 IDESimulator 列表；改用
                    # -workspace 形式即可绕过。）
                    self._verify_flutter_xcodebuild_patch(env)
                    if not in_xcode:
                        self._log(
                            f"❌ Xcode 不接受该模拟器 UDID（{device_id}）。常见原因：")
                        self._log(
                            "  1) iOS Simulator runtime 未安装或损坏 → Xcode → Settings → Platforms 安装对应 iOS 版本；")
                        self._log(
                            "  2) `xcode-select -p` 指向 Command Line Tools → 执行 `sudo xcode-select -s /Applications/Xcode.app`；")
                        self._log(
                            "  3) Xcode 未授权完整 → 在 Xcode 里打开 ios/Runner.xcworkspace，菜单 Product → Destination 看是否出现模拟器；")
                        self._log(
                            f"  4) 终端复核：在 ios/ 目录执行 `xcodebuild -workspace Runner.xcworkspace -scheme Runner -showdestinations`，确认含 `id:{device_id}`。")
                        self._set_status(self.step3_status, "❌", success=False)
                        return

            ios_dir = os.path.join(project, "ios")
            if run_kind in ("ios_sim", "ios_device") and not os.path.isdir(ios_dir):
                self._log("项目缺少 iOS 配置，正在添加…")
                r = subprocess.run([*fc, "create", "--platforms", "ios", "."],
                    capture_output=True, text=True, cwd=project, env=env, timeout=60)
                if r.returncode == 0:
                    self._log("  iOS 平台已添加 ✓")
                else:
                    self._log(f"  ❌ 添加 iOS 平台失败: {r.stderr[-200:]}")
                    self._set_status(self.step3_status, "❌", success=False)
                    return

            self._log("fvm flutter pub get …")
            self._set_status(self.step3_status, "依赖…")
            r = subprocess.run([*fc, "pub", "get"],
                capture_output=True, text=True, cwd=project, env=env, timeout=120)
            if r.returncode != 0:
                self._log(f"❌ flutter pub get 失败")
                for line in (r.stderr or r.stdout or "").splitlines():
                    cl = strip_ansi(line.rstrip())
                    if cl:
                        _append_flutter_log_line(cl)
                for line in (r.stderr or r.stdout or "").splitlines()[-15:]:
                    self._log(f"  {strip_ansi(line)}")
                self._set_status(self.step3_status, "❌", success=False)
                return
            self._log("  pub get ✓")

            run_fc = fc
            cmd_prefix_log = "fvm flutter"

            run_cmd = [*run_fc, "run", "-d", device_id, "--no-pub"]
            if is_release:
                run_cmd.append("--release")
            env_run = self._selected_app_environment()
            run_cmd.append(f"--dart-define=ENVIRONMENT={env_run}")
            dev_float_def = self._show_dev_float_dart_define()
            run_cmd.append(dev_float_def)
            dev_float_on = dev_float_def.endswith("=true")
            self._log(
                f"{cmd_prefix_log} run -d {device_id} [{mode_label}] "
                f"(ENVIRONMENT={env_run}；AB_SHOW_DEV_FLOAT={'true' if dev_float_on else 'false'}；"
                f"APP_CHANNEL 使用工程 config.dart defaultValue，不读输入框)")
            self._set_status(self.step3_status, "编译…")

            def _preexec_run():
                os.setsid()
                try:
                    import resource
                    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
                    if soft < 8192:
                        hard_cap = hard if hard != resource.RLIM_INFINITY else 65536
                        resource.setrlimit(
                            resource.RLIMIT_NOFILE,
                            (min(8192, hard_cap), min(8192, hard_cap)))
                except Exception:
                    pass

            proc = subprocess.Popen(
                run_cmd,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, encoding='utf-8', errors='replace',
                cwd=project, env=env, preexec_fn=_preexec_run,
            )
            _state["flutter_proc"] = proc
            self._set_btn(self.hot_reload_btn, True)
            self._set_btn(self.hot_restart_btn, True)

            skip_patterns = ("Failed to index", "Failed to check availability",
                             "WFIsolatedShortcutRunner", "Indexing for request",
                             "Inserted en/", "Resolved Preferred", "indexing: the changeset")

            for line in proc.stdout:
                if _state["flutter_proc"] is None:
                    break
                clean = strip_ansi(line.rstrip())
                if clean:
                    _append_flutter_log_line(clean)
                if clean and not any(clean.startswith(p) for p in skip_patterns):
                    self._log(f"  {clean}")
                    if "Syncing files to device" in clean:
                        self._set_status(self.step3_status, "✅运行", success=True)

            proc.wait()
            code = proc.returncode
            if code in (0, -15, -9, -2):
                self._log("Flutter 已停止")
            else:
                self._log(f"Flutter 退出 (code {code})")
                tail = (_state.get("last_flutter_log") or [])[-50:]
                if tail:
                    self._log("  ── 最近构建/运行日志（节选，便于定位 Xcode 报错）──")
                    for ln in tail:
                        self._log(f"  {ln}")
                self._log(
                    "  💡 若上面没有具体错误行：请在工程根目录终端执行 "
                    "`fvm flutter build ios --simulator --no-codesign -v` 查看完整 -v 输出；"
                    "或 `fvm flutter clean` 后在本工具再点 ▶ 运行。")
            self._set_status(self.step3_status, "已停止")

        except Exception as e:
            self._log(f"❌ Flutter 运行异常: {e}")
            self._set_status(self.step3_status, "❌", success=False)
        finally:
            _state["flutter_proc"] = None
            self._set_btn(self.run_btn, True, "▶ 运行")
            self._set_btn(self.stop_btn, False)
            self._set_btn(self.hot_reload_btn, False)
            self._set_btn(self.hot_restart_btn, False)
            threading.Thread(
                target=self._refresh_device_list, args=(project,), daemon=True).start()

    @objc.python_method
    def _send_flutter_stdin(self, payload, action_label):
        proc = _state.get("flutter_proc")
        if proc is None or proc.poll() is not None:
            self._log(f"⚠ Flutter 未在运行，无法{action_label}")
            return
        si = proc.stdin
        if si is None:
            self._log(f"⚠ 无法{action_label}（stdin 不可用）")
            return
        try:
            si.write(payload)
            si.flush()
        except (BrokenPipeError, OSError) as e:
            self._log(f"⚠ {action_label} 失败: {e}")
            return
        self._log(f"  → {action_label}")

    def flutterHotReload_(self, sender):
        self._send_flutter_stdin("r\n", "热更新")

    def flutterHotRestart_(self, sender):
        self._send_flutter_stdin("R\n", "重启")

    def stopFlutter_(self, sender):
        proc = _state.get("flutter_proc")
        if proc is not None:
            self._log("正在停止 Flutter…")
            _state["flutter_proc"] = None
            self._set_btn(self.hot_reload_btn, False)
            self._set_btn(self.hot_restart_btn, False)
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
            except Exception:
                try: proc.terminate()
                except Exception: pass
            self._set_btn(self.stop_btn, False)
            self._set_status(self.step3_status, "停止…")
        else:
            self._log("Flutter 未在运行")

    # ── Step 4: Obfuscation ──

    def obfFrameworks_(self, sender):
        if _state["is_running"]:
            self._log("⚠ 有任务正在执行中"); return
        project = str(self.obf_project_field.stringValue()).strip()
        if not project or not os.path.isdir(project):
            self._log("❌ 请选择有效的项目目录"); return
        script = os.path.join(project, "scripts", "obfuscate_frameworks.sh")
        if not os.path.isfile(script):
            self._log(f"❌ 脚本不存在: {script}"); return

        idx = int(self.obf_project_popup.indexOfSelectedItem())
        pcode = PROJECT_CODES[idx] if 0 <= idx < len(PROJECT_CODES) else PROJECT_CODES[0]

        _state["is_running"] = True
        self._set_btn(self.fw_obf_btn, False, "混淆中…")
        self._set_btn(self.code_obf_btn, False)
        self._set_status(self.step4_status, "Framework 混淆中…")

        cmd = [script, "run", "-p", pcode]
        self._log(f"▶ {' '.join(cmd)}")
        threading.Thread(target=self._run_obf_cmd,
            args=(cmd, self.fw_obf_btn, "Framework 混淆", project),
            daemon=True).start()

    def obfCode_(self, sender):
        if _state["is_running"]:
            self._log("⚠ 有任务正在执行中"); return
        project = str(self.obf_project_field.stringValue()).strip()
        if not project or not os.path.isdir(project):
            self._log("❌ 请选择有效的项目目录"); return
        script = os.path.join(project, "scripts", "obfuscate_code.sh")
        if not os.path.isfile(script):
            self._log(f"❌ 脚本不存在: {script}"); return

        idx = int(self.obf_project_popup.indexOfSelectedItem())
        pcode = PROJECT_CODES[idx] if 0 <= idx < len(PROJECT_CODES) else PROJECT_CODES[0]

        _state["is_running"] = True
        self._set_btn(self.code_obf_btn, False, "混淆中…")
        self._set_btn(self.fw_obf_btn, False)
        self._set_status(self.step4_status, "代码混淆中…")

        cmd = [script, "-p", pcode, "--all"]
        self._log(f"▶ {' '.join(cmd)}")
        self._log("  将执行: 字符串混淆 + 调用栈混淆 + 文件膨胀 + 业务噪音 + AST变异 + 符号扭曲")
        threading.Thread(target=self._run_obf_cmd,
            args=(cmd, self.code_obf_btn, "代码混淆（全部）", project),
            daemon=True).start()

    @objc.python_method
    def _run_obf_cmd(self, cmd, active_btn, btn_title, cwd):
        try:
            env = get_env()
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, encoding='utf-8', errors='replace', cwd=cwd, env=env)
            for line in proc.stdout:
                clean = strip_ansi(line.rstrip())
                if clean:
                    self._log(f"  {clean}")
            proc.wait()

            if proc.returncode == 0:
                self._log(f"✅ {btn_title}完成")
                self._set_status(self.step4_status, f"✅ {btn_title}完成", success=True)
                self._notify_telegram(btn_title, ok=True)
            else:
                self._log(f"❌ {btn_title}失败 (exit {proc.returncode})")
                self._set_status(self.step4_status, f"❌ {btn_title}失败", success=False)
                self._notify_telegram(btn_title, ok=False,
                                      detail=f"exit={proc.returncode}")
        except Exception as e:
            self._log(f"❌ 异常: {e}")
            self._set_status(self.step4_status, f"❌ {e}", success=False)
            self._notify_telegram(btn_title, ok=False, detail=str(e))
        finally:
            _state["is_running"] = False
            self._set_btn(active_btn, True, btn_title)
            self._set_btn(self.fw_obf_btn, True)
            self._set_btn(self.code_obf_btn, True)

    def oneClickObf_(self, sender):
        if _state["is_running"]:
            self._log("⚠ 有任务正在执行中"); return
        project = str(self.obf_project_field.stringValue()).strip()
        if not project or not os.path.isdir(project):
            self._log("❌ 请选择有效的项目目录"); return
        code_script = os.path.join(project, "scripts", "obfuscate_code.sh")
        fw_script = os.path.join(project, "scripts", "obfuscate_frameworks.sh")
        for s in (code_script, fw_script):
            if not os.path.isfile(s):
                self._log(f"❌ 脚本不存在: {s}"); return

        idx = int(self.obf_project_popup.indexOfSelectedItem())
        pcode = PROJECT_CODES[idx] if 0 <= idx < len(PROJECT_CODES) else PROJECT_CODES[0]

        _state["is_running"] = True
        self._set_btn(self.one_click_obf_btn, False, "混淆中…")
        self._set_btn(self.fw_obf_btn, False)
        self._set_btn(self.code_obf_btn, False)
        self._set_status(self.step4_status, "一键混淆中…")

        steps = [
            ("代码混淆（全部）", [code_script, "-p", pcode, "--all"]),
            ("Framework 混淆", [fw_script, "run", "-p", pcode]),
        ]
        self._log(f"▶ 一键混淆 (-p {pcode})：代码混淆(--all) → Framework 混淆(run)")
        threading.Thread(target=self._run_obf_chain,
            args=(steps, project), daemon=True).start()

    @objc.python_method
    def _run_obf_chain(self, steps, cwd):
        title = "一键混淆"
        try:
            for label, cmd in steps:
                self._log(f"▶ [{label}] {' '.join(cmd)}")
                rc = self._exec_stream(cmd, cwd)
                if rc != 0:
                    self._log(f"❌ {label}失败 (exit {rc})，已中止后续步骤")
                    self._set_status(self.step4_status, f"❌ {label}失败", success=False)
                    self._notify_telegram(title, ok=False, detail=f"{label} exit={rc}")
                    return
                self._log(f"✅ {label}完成")
            self._log("✅ 一键混淆完成（代码 + Framework）")
            self._set_status(self.step4_status, "✅ 一键混淆完成", success=True)
            self._notify_telegram(title, ok=True)
        except Exception as e:
            self._log(f"❌ 异常: {e}")
            self._set_status(self.step4_status, f"❌ {e}", success=False)
            self._notify_telegram(title, ok=False, detail=str(e))
        finally:
            _state["is_running"] = False
            self._set_btn(self.one_click_obf_btn, True, "一键混淆")
            self._set_btn(self.fw_obf_btn, True)
            self._set_btn(self.code_obf_btn, True)

    @objc.python_method
    def _exec_stream(self, cmd, cwd):
        """运行单条命令，实时把输出写入日志，返回退出码。供一键链路顺序调用。"""
        env = get_env()
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, encoding='utf-8', errors='replace', cwd=cwd, env=env)
        for line in proc.stdout:
            clean = strip_ansi(line.rstrip())
            if clean:
                self._log(f"  {clean}")
        proc.wait()
        return proc.returncode

    def applySilentPeriod_(self, sender):
        project = str(self.obf_project_field.stringValue()).strip()
        if not project or not os.path.isdir(project):
            self._log("❌ 请先选择项目路径"); return
        config_file = os.path.join(project, "lib", "config", "app_config.dart")
        if not os.path.isfile(config_file):
            self._log(f"❌ 配置文件不存在: {config_file}"); return

        days_str = str(self.silent_days_field.stringValue()).strip()
        if not days_str.isdigit():
            self._log("❌ 静默期天数必须是非负整数"); return
        days = int(days_str)

        try:
            with open(config_file, 'r', encoding='utf-8') as f:
                text = f.read()

            import time
            ts = int(time.time() * 1000)
            ts_str = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

            def _set_period(m):
                return f"static const int {m} = {days};"
            if re.search(r"static const int silentPeriodDays = \d+;", text):
                text = re.sub(
                    r"static const int silentPeriodDays = \d+;",
                    _set_period("silentPeriodDays"), text
                )
            elif re.search(r"static const int quietPeriodDays = \d+;", text):
                text = re.sub(
                    r"static const int quietPeriodDays = \d+;",
                    _set_period("silentPeriodDays"), text
                )
            else:
                self._log("❌ 未找到 silentPeriodDays / quietPeriodDays 行"); return

            text = re.sub(r'static const int buildTimestamp = \d+;.*',
                          f'static const int buildTimestamp = {ts}; // {ts_str}', text)

            with open(config_file, 'w', encoding='utf-8') as f:
                f.write(text)

            self._log(f"✅ 静默期已设为 {days} 天，打包时间戳已更新为 {ts_str}")
            self._set_status(self.step4_status, f"✅ 静默期 {days} 天", success=True)
        except Exception as e:
            self._log(f"❌ 修改静默期失败: {e}")

    def readSilentPeriod_(self, sender):
        project = str(self.obf_project_field.stringValue()).strip()
        if not project or not os.path.isdir(project):
            self._log("❌ 请先选择项目路径"); return
        config_file = os.path.join(project, "lib", "config", "app_config.dart")
        if not os.path.isfile(config_file):
            self._log(f"❌ 配置文件不存在: {config_file}"); return

        try:
            with open(config_file, 'r', encoding='utf-8') as f:
                text = f.read()

            m_days = re.search(
                r"static const int (?:silent|quiet)PeriodDays = (\d+);", text
            )
            m_ts = re.search(r'static const int buildTimestamp = (\d+);', text)

            if m_days:
                days = m_days.group(1)
                def _update():
                    self.silent_days_field.setStringValue_(days)
                NSOperationQueue.mainQueue().addOperationWithBlock_(_update)
                self._log(f"  静默期: {days} 天")
            if m_ts:
                ts = int(m_ts.group(1))
                dt = datetime.fromtimestamp(ts / 1000)
                self._log(f"  打包时间: {dt.strftime('%Y-%m-%d %H:%M:%S')}")
        except Exception as e:
            self._log(f"❌ 读取失败: {e}")

    def _brand_replace_run(self, dry_run):
        project = str(self.obf_project_field.stringValue()).strip()
        if not project or not os.path.isdir(project):
            self._log("❌ 请先选择项目路径（步骤4 项目路径）"); return
        roots = _bside_roots(project)
        if not roots:
            self._log(f"❌ 未找到 B 面目录（lib/modules/secondary 或 lib）: {project}"); return
        dst = str(self.brand_replace_field.stringValue()).strip()
        src = BRAND_REPLACE_SRC
        if not dry_run:
            if not dst:
                self._log("❌ 替换文字为空（留空会删除「星火」，已阻止）"); return
            if "*/" in dst or "\n" in dst:
                self._log("❌ 替换文字不能包含换行或 */"); return
            if src in dst:
                self._log(f"⚠ 替换文字本身含「{src}」，可能无意义，已阻止"); return
        try:
            res = _replace_brand_in_bside(project, src, dst, dry_run=dry_run)
        except Exception as e:
            self._log(f"❌ 替换失败: {e}"); return

        tag = "预览" if dry_run else "替换"
        if res["files_changed"] == 0:
            self._log(f"  [{tag}] 未发现「{src}」（已扫描 {res['scanned']} 个文本文件）")
            return
        arrow = f" → 「{dst}」" if dst else ""
        self._log(
            f"  [{tag}] 命中 {res['files_changed']} 个文件 · "
            f"charcode 编码块 {res['cc_blocks']} · 明文 {res['plain_count']} 处{arrow}"
        )
        for rel, cc, plain in res["details"][:60]:
            self._log(f"     {rel}  (charcode {cc} / 明文 {plain})")
        if len(res["details"]) > 60:
            self._log(f"     … 其余 {len(res['details']) - 60} 个文件略")
        if dry_run:
            self._log("  ↑ 仅预览未写入；确认无误后点「替换星火」执行。")
        else:
            self._log(f"✅ 已将 B 面「{src}」全部替换为「{dst}」（建议 git diff 复核后再打包）")
            self._set_status(self.step4_status, f"✅ 星火→{dst}", success=True)

    def previewBrandReplace_(self, sender):
        self._brand_replace_run(True)

    def replaceBrandText_(self, sender):
        self._brand_replace_run(False)

    def hardenIpa_(self, sender):
        if _state["is_running"]:
            self._log("⚠ 有任务正在执行中")
            return

        ipa_path = str(self.ipa_harden_path_field.stringValue()).strip()
        if not ipa_path or not os.path.isfile(ipa_path):
            self._log("❌ 请填写或选择有效的 IPA 路径")
            return

        project = str(self.ipa_project_field.stringValue()).strip()
        workdir = str(self.ipa_workdir_field.stringValue()).strip()
        script = self._resolve_harden_script(project)
        if not script:
            self._log("❌ 未找到 scripts/harden_ipa_standalone.sh")
            self._log("  请更新 daddy_template 或工程 scripts/，或点「对齐脚本」")
            return

        bundle_id = str(self.cfg_bundle_field.stringValue()).strip()
        profile_name = str(self.cfg_profile_field.stringValue()).strip() or "appstore.mobileprovision"
        profile_path = ""
        if workdir and os.path.isdir(workdir):
            candidate = os.path.join(workdir, profile_name)
            if os.path.isfile(candidate):
                profile_path = candidate

        macho = bool(self.ipa_harden_macho_switch.state())
        cmd = [script, "--ipa", ipa_path, "--resources"]
        if macho:
            cmd.append("--macho")
        if bundle_id:
            cmd += ["--seed", bundle_id]
        if profile_path:
            cmd += ["--profile", profile_path]
            if bundle_id:
                cmd += ["--bundle-id", bundle_id]
        else:
            self._log("  ⚠ 工作目录未找到描述文件，将输出未签名 IPA")

        _state["is_running"] = True
        self._set_btn(self.harden_ipa_btn, False, "混淆中…")
        self._set_btn(self.build_ipa_btn, False)
        self._set_status(self.ipa_harden_status, "混淆中…")
        self._log(f"▶ {' '.join(cmd)}")

        threading.Thread(
            target=self._run_harden_ipa,
            args=(cmd, project or os.path.dirname(script)),
            daemon=True,
        ).start()

    @objc.python_method
    def _run_harden_ipa(self, cmd, cwd):
        try:
            env = get_env()
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
                cwd=cwd,
                env=env,
            )
            for line in proc.stdout:
                clean = strip_ansi(line.rstrip())
                if clean:
                    self._log(f"  {clean}")
            proc.wait()

            if proc.returncode == 0:
                self._log("✅ IPA 成品包混淆完成")
                self._set_status(self.ipa_harden_status, "✅ 完成", success=True)
                self._notify_telegram("IPA 成品包混淆", ok=True)
            else:
                self._log(f"❌ IPA 混淆失败 (exit {proc.returncode})")
                self._set_status(self.ipa_harden_status, "❌ 失败", success=False)
                self._notify_telegram("IPA 成品包混淆", ok=False,
                                      detail=f"exit={proc.returncode}")
        except Exception as e:
            self._log(f"❌ 混淆异常: {e}")
            self._set_status(self.ipa_harden_status, "❌ 异常", success=False)
            self._notify_telegram("IPA 成品包混淆", ok=False, detail=str(e))
        finally:
            _state["is_running"] = False
            self._set_btn(self.harden_ipa_btn, True, "混淆 IPA")
            self._set_btn(self.build_ipa_btn, True, "打包 IPA")

    # ── Step 5: Build IPA ──

    def genCsr_(self, sender):
        if _state["is_running"]:
            self._log("⚠ 有任务正在执行中"); return

        workdir = str(self.ipa_workdir_field.stringValue()).strip()
        if not workdir or not os.path.isdir(workdir):
            self._log("❌ 请先选择工作目录"); return

        template = str(self.template_field.stringValue()).strip()
        script = os.path.join(template, "scripts", "gen_csr.sh") if template else ""
        if not os.path.isfile(script):
            self._log(f"❌ gen_csr.sh 不存在: {script}")
            self._log("  请确认步骤1中的模板路径正确")
            return

        key_path = os.path.join(workdir, "mykey.key")
        if os.path.isfile(key_path):
            self._log(f"⚠ 私钥已存在: {key_path}，跳过生成")
            self._log("  如需重新生成，请先手动删除旧文件")
            return

        _state["is_running"] = True
        self._set_status(self.step5_status, "生成 CSR…")
        cmd = [script, workdir]
        self._log(f"▶ {' '.join(cmd)}")

        threading.Thread(target=self._run_gen_csr, args=(cmd,), daemon=True).start()

    @objc.python_method
    def _run_gen_csr(self, cmd):
        try:
            env = get_env()
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, encoding='utf-8', errors='replace', env=env)
            for line in proc.stdout:
                clean = strip_ansi(line.rstrip())
                if clean:
                    self._log(f"  {clean}")
            proc.wait()

            if proc.returncode == 0:
                self._log("✅ CSR 和私钥已生成，私钥已导入钥匙串")
                self._log("  → CertificateSigningRequest.certSigningRequest（上传到 Apple 创建证书）")
                self._log("  → mykey.key（打包签名用）")
                self._set_status(self.step5_status, "✅ CSR 已生成", success=True)
            else:
                self._log(f"❌ CSR 生成失败 (exit {proc.returncode})")
                self._set_status(self.step5_status, "❌ CSR 失败", success=False)
        except Exception as e:
            self._log(f"❌ 异常: {e}")
            self._set_status(self.step5_status, f"❌ {e}", success=False)
        finally:
            _state["is_running"] = False

    def genConfig_(self, sender):
        workdir = str(self.ipa_workdir_field.stringValue()).strip()
        if not workdir or not os.path.isdir(workdir):
            self._log("❌ 请先选择工作目录"); return

        bundle_id = str(self.cfg_bundle_field.stringValue()).strip()
        team_id = str(self.cfg_team_field.stringValue()).strip()
        key_id = str(self.cfg_keyid_field.stringValue()).strip()
        issuer_id = str(self.cfg_issuer_field.stringValue()).strip()
        profile = str(self.cfg_profile_field.stringValue()).strip() or "appstore.mobileprovision"
        cert = str(self.cfg_cert_field.stringValue()).strip() or "ios_distribution.cer"
        privkey = str(self.cfg_privkey_field.stringValue()).strip() or "mykey.key"
        p8 = str(self.cfg_p8_field.stringValue()).strip()

        if not bundle_id:
            self._log("❌ 请填写 Bundle ID"); return
        if not team_id:
            self._log("❌ 请填写 Team ID"); return

        if not p8 and key_id:
            p8 = f"private_keys/AuthKey_{key_id}.p8"
            def _fill():
                self.cfg_p8_field.setStringValue_(p8)
            NSOperationQueue.mainQueue().addOperationWithBlock_(_fill)

        proxy = str(self.cfg_proxy_field.stringValue()).strip()

        config = {
            "bundle_id": bundle_id,
            "team_id": team_id,
            "profile": profile,
            "certificate": cert,
            "private_key": privkey,
            "export_dir": "ipa",
            "export_method": "app-store",
            "code_sign_identity": "Apple Distribution",
            "signing_style": "manual",
            "flutter_build_mode": "release",
        }
        if key_id or issuer_id or p8:
            config["apple_api_key"] = {
                "key_id": key_id,
                "issuer_id": issuer_id,
                "p8_file": p8,
            }
        if proxy:
            config["proxy"] = {"socks5": proxy}

        config_path = os.path.join(workdir, "build_config.json")
        try:
            with open(config_path, 'w', encoding='utf-8') as f:
                json.dump(config, f, indent=2, ensure_ascii=False)
            self._log(f"✅ 已生成: {config_path}")
            self._set_status(self.step5_status, "✅ 配置已生成", success=True)
        except Exception as e:
            self._log(f"❌ 生成配置失败: {e}")
            self._set_status(self.step5_status, "❌ 生成失败", success=False)

    def readConfig_(self, sender):
        workdir = str(self.ipa_workdir_field.stringValue()).strip()
        if not workdir or not os.path.isdir(workdir):
            self._log("❌ 请先选择工作目录"); return

        config_path = os.path.join(workdir, "build_config.json")
        if not os.path.isfile(config_path):
            self._log(f"❌ 配置文件不存在: {config_path}"); return

        try:
            with open(config_path, 'r', encoding='utf-8') as f:
                cfg = json.load(f)

            api = cfg.get("apple_api_key", {})
            proxy = cfg.get("proxy", {})

            def _fill():
                self.cfg_bundle_field.setStringValue_(cfg.get("bundle_id", ""))
                self.cfg_team_field.setStringValue_(cfg.get("team_id", ""))
                self.cfg_profile_field.setStringValue_(cfg.get("profile", "appstore.mobileprovision"))
                self.cfg_cert_field.setStringValue_(cfg.get("certificate", "ios_distribution.cer"))
                self.cfg_privkey_field.setStringValue_(cfg.get("private_key", "mykey.key"))
                self.cfg_keyid_field.setStringValue_(api.get("key_id", ""))
                self.cfg_issuer_field.setStringValue_(api.get("issuer_id", ""))
                self.cfg_p8_field.setStringValue_(api.get("p8_file", ""))
                self.cfg_proxy_field.setStringValue_(proxy.get("socks5", ""))
            NSOperationQueue.mainQueue().addOperationWithBlock_(_fill)
            self._log(f"✅ 已读取配置: {config_path}")
            self._set_status(self.step5_status, "✅ 已读取", success=True)
        except Exception as e:
            self._log(f"❌ 读取配置失败: {e}")

    @objc.python_method
    def _resolve_workdir_path(self, workdir, rel_path):
        rel_path = str(rel_path or "").strip()
        if not rel_path:
            return ""
        if os.path.isabs(rel_path):
            return rel_path
        return os.path.join(workdir, rel_path)

    @objc.python_method
    def _collect_asc_monitor_payload(self):
        workdir = str(self.ipa_workdir_field.stringValue()).strip()
        if not workdir or not os.path.isdir(workdir):
            return None, "请先选择工作目录"

        bundle_id = str(self.cfg_bundle_field.stringValue()).strip()
        team_id = str(self.cfg_team_field.stringValue()).strip()
        key_id = str(self.cfg_keyid_field.stringValue()).strip()
        issuer_id = str(self.cfg_issuer_field.stringValue()).strip()
        p8_rel = str(self.cfg_p8_field.stringValue()).strip()

        if not bundle_id:
            return None, "请填写 Bundle ID"
        if not team_id:
            return None, "请填写 Team ID"
        if not key_id:
            return None, "请填写 API Key ID"
        if not issuer_id:
            return None, "请填写 Issuer ID"

        if not p8_rel and key_id:
            p8_rel = f"private_keys/AuthKey_{key_id}.p8"

        p8_path = self._resolve_workdir_path(workdir, p8_rel)
        if not p8_path or not os.path.isfile(p8_path):
            return None, f"P8 文件不存在: {p8_path or p8_rel}"

        try:
            with open(p8_path, "r", encoding="utf-8") as f:
                p8_pem = f.read().strip()
        except Exception as e:
            return None, f"读取 P8 失败: {e}"

        if not p8_pem:
            return None, "P8 文件内容为空"

        ud = NSUserDefaults.standardUserDefaults()
        tg_token = _tg_normalize_token(ud.stringForKey_(UDK_TG_BOT_TOKEN) or "")
        tg_chat = _tg_normalize_chat_id(ud.stringForKey_(UDK_TG_CHAT_ID) or "")

        payload = {
            "bundle_id": bundle_id,
            "team_id": team_id,
            "issuer_id": issuer_id,
            "key_id": key_id,
            "p8_pem": p8_pem,
            "enabled": True,
        }
        if tg_chat:
            payload["tg_chat_id"] = tg_chat
        if tg_token:
            payload["tg_bot_token"] = tg_token

        return payload, None

    @objc.python_method
    def _post_asc_monitor(self, payload):
        import urllib.request
        import urllib.error

        url = f"{ASC_MONITOR_BASE}/api/monitors"
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=data,
            method="POST",
            headers={
                "Content-Type": "application/json",
                "User-Agent": f"AB-Factory/{APP_VERSION}",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                body = resp.read().decode("utf-8", errors="replace")
                if resp.status not in (200, 201):
                    return False, f"HTTP {resp.status}: {body[:200]}"
                return True, body
        except urllib.error.HTTPError as he:
            body = ""
            try:
                body = he.read().decode("utf-8", errors="replace")
            except Exception:
                pass
            err = body
            try:
                j = json.loads(body)
                err = j.get("error") or body
            except Exception:
                pass
            return False, f"HTTP {he.code}: {err or he.reason}"
        except urllib.error.URLError as ue:
            return False, f"网络错误: {getattr(ue, 'reason', ue)}"
        except Exception as e:
            return False, str(e)

    def addAscMonitor_(self, sender):
        payload, err = self._collect_asc_monitor_payload()
        if err:
            self._log(f"❌ {err}")
            self._set_status(self.step5_status, f"❌ {err}", success=False)
            return

        bundle_id = payload["bundle_id"]
        self._set_btn(self.add_asc_monitor_btn, False, "推送中…")
        self._set_status(self.step5_status, "正在推送到 ASC 监控…")
        self._log(f"推送到 ASC 监控: {bundle_id}")

        def run():
            ok, msg = self._post_asc_monitor(payload)

            def finish():
                self._set_btn(self.add_asc_monitor_btn, True, "添加监控")
                if ok:
                    self._log(f"✅ 已推送到 ASC 监控: {bundle_id}")
                    self._set_status(self.step5_status, "✅ 已添加监控", success=True)
                    import urllib.parse
                    url = (
                        f"{ASC_MONITOR_BASE}/?bundle="
                        f"{urllib.parse.quote(bundle_id, safe='')}"
                    )
                    subprocess.Popen(["open", url], env=get_env())
                else:
                    self._log(f"❌ ASC 监控推送失败: {msg}")
                    self._set_status(self.step5_status, "❌ 推送失败", success=False)

            NSOperationQueue.mainQueue().addOperationWithBlock_(finish)

        threading.Thread(target=run, daemon=True).start()

    def uploadIpa_(self, sender):
        if _state["is_running"]:
            self._log("⚠ 有任务正在执行中"); return

        project = str(self.ipa_project_field.stringValue()).strip()
        workdir = str(self.ipa_workdir_field.stringValue()).strip()

        if not project or not os.path.isdir(project):
            self._log("❌ 请选择 Flutter 工程目录"); return
        if not workdir or not os.path.isdir(workdir):
            self._log("❌ 请选择工作目录"); return

        config_json = os.path.join(workdir, "build_config.json")
        if not os.path.isfile(config_json):
            self._log(f"❌ 未找到 build_config.json: {config_json}"); return

        script = os.path.join(project, "scripts", "upload_ipa.sh")
        if not os.path.isfile(script):
            self._log(f"❌ 上传脚本不存在: {script}"); return

        proxy = str(self.cfg_proxy_field.stringValue()).strip()
        if not proxy:
            self._log("❌ 请填写代理地址（上传需要代理）"); return

        try:
            with open(config_json, 'r', encoding='utf-8') as f:
                cfg = json.load(f)
            cfg.setdefault("proxy", {})["socks5"] = proxy
            with open(config_json, 'w', encoding='utf-8') as f:
                json.dump(cfg, f, indent=2, ensure_ascii=False)
            self._log("  已更新 build_config.json 中的代理配置")
        except Exception as e:
            self._log(f"⚠ 更新代理配置失败: {e}")

        _state["is_running"] = True
        self._set_btn(self.upload_ipa_btn, False, "上传中…")
        self._set_btn(self.build_ipa_btn, False)
        self._set_status(self.step5_status, "正在上传…")

        cmd = [script, workdir]
        self._log(f"▶ {' '.join(cmd)}")
        self._log(f"  工作目录: {workdir}")
        self._log(f"  代理: {proxy}")
        self._log("  上传可能需要几分钟，请耐心等待…")

        threading.Thread(target=self._run_upload_ipa, args=(cmd, project), daemon=True).start()

    @objc.python_method
    def _run_upload_ipa(self, cmd, cwd):
        try:
            env = get_env()
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, encoding='utf-8', errors='replace', cwd=cwd, env=env, preexec_fn=os.setsid)

            for line in proc.stdout:
                clean = strip_ansi(line.rstrip())
                if clean:
                    self._log(f"  {clean}")
                    if "[SUCCESS]" in clean:
                        self._set_status(self.step5_status, "✅ 上传成功", success=True)

            proc.wait()

            if proc.returncode == 0:
                self._log("✅ IPA 上传完成，请到 App Store Connect 查看")
                self._set_status(self.step5_status, "✅ 上传成功", success=True)
                self._notify_telegram("IPA 上传", ok=True,
                                      detail="请到 App Store Connect 查看")
            else:
                self._log(f"❌ IPA 上传失败 (exit {proc.returncode})")
                self._set_status(self.step5_status, "❌ 上传失败", success=False)
                self._notify_telegram("IPA 上传", ok=False,
                                      detail=f"exit={proc.returncode}")
        except Exception as e:
            self._log(f"❌ 上传异常: {e}")
            self._set_status(self.step5_status, f"❌ {e}", success=False)
            self._notify_telegram("IPA 上传", ok=False, detail=str(e))
        finally:
            _state["is_running"] = False
            self._set_btn(self.upload_ipa_btn, True, "上传 IPA")
            self._set_btn(self.build_ipa_btn, True)

    def buildIpa_(self, sender):
        if _state["is_running"]:
            self._log("⚠ 有任务正在执行中"); return

        project = str(self.ipa_project_field.stringValue()).strip()
        workdir = str(self.ipa_workdir_field.stringValue()).strip()
        silent_str = str(self.ipa_silent_days_field.stringValue()).strip()
        ver_input = str(self.ipa_version_field.stringValue()).strip()

        if not project or not os.path.isdir(project):
            self._log("❌ 请选择 Flutter 工程目录"); return
        pubspec_path = os.path.join(project, "pubspec.yaml")
        if not os.path.isfile(pubspec_path):
            self._log(f"❌ 不是 Flutter 项目: {project}"); return
        if not workdir or not os.path.isdir(workdir):
            self._log("❌ 请选择工作目录"); return

        if ver_input:
            try:
                _apply_pubspec_version(pubspec_path, ver_input)
                self._log(f"  已设置 pubspec version: {ver_input}（打包将使用该版本）")
            except Exception as e:
                self._log(f"❌ 版本号无效: {e}")
                return
            try:
                updated, _unchanged, dver, found = _apply_app_data_version(project, ver_input)
                for p in updated:
                    self._log(
                        f"  已同步 app_data_manager.dart version: {dver}  "
                        f"({os.path.relpath(p, project)})"
                    )
                if found and not updated:
                    self._log(f"  dart version 已是 {dver}")
            except Exception as e:
                self._log(f"⚠ dart 版本同步失败（不阻断打包）: {e}")

        config_json = os.path.join(workdir, "build_config.json")
        if not os.path.isfile(config_json):
            bid = str(self.cfg_bundle_field.stringValue()).strip()
            tid = str(self.cfg_team_field.stringValue()).strip()
            if bid and tid:
                self._log("  build_config.json 不存在，自动生成…")
                self.genConfig_(None)
            if not os.path.isfile(config_json):
                self._log(f"❌ 未找到 build_config.json: {config_json}")
                self._log("  请填写配置信息后点击「生成配置」")
                return

        script = os.path.join(project, "scripts", "build_flutter_ipa.sh")
        if not os.path.isfile(script):
            self._log(f"❌ 打包脚本不存在: {script}"); return

        if not silent_str.isdigit():
            self._log("❌ 静默期天数必须是非负整数"); return

        self._save_b_side_prefs()
        _state["is_running"] = True
        self._set_btn(self.build_ipa_btn, False, "打包中…")
        self._set_status(self.step5_status, "正在打包…")

        cmd = [script, workdir, f"--silent={silent_str}"]
        self._log(f"▶ {' '.join(cmd)}")
        self._log(f"  Flutter 工程: {project}")
        self._log(f"  工作目录: {workdir}")
        if ver_input:
            self._log(f"  版本: {ver_input} (已写入 pubspec)")
        else:
            self._log(f"  版本: 保持 pubspec 现有值（版本号输入框留空）")
        self._log(f"  静默期: {silent_str} 天")
        self._log("  B面 dart-define: ENVIRONMENT=release（打包固定，与 dq 模板一致）")
        self._log("  APP_CHANNEL: 使用工程 config.dart defaultValue（不读输入框）")
        self._log("  打包过程可能需要 10-20 分钟，请耐心等待…")

        threading.Thread(target=self._run_build_ipa,
            args=(cmd, project, workdir),
            daemon=True).start()

    @objc.python_method
    def _run_build_ipa(self, cmd, cwd, workdir=None):
        try:
            env = get_env()
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, encoding='utf-8', errors='replace', cwd=cwd, env=env, preexec_fn=os.setsid)
            _state["build_proc"] = proc

            for line in proc.stdout:
                clean = strip_ansi(line.rstrip())
                if clean:
                    self._log(f"  {clean}")
                    if "构建完成" in clean or "IPA 文件已成功" in clean:
                        self._set_status(self.step5_status, "✅ 打包完成", success=True)

            proc.wait()

            if proc.returncode == 0:
                self._log("✅ IPA 打包完成")
                self._set_status(self.step5_status, "✅ 打包完成", success=True)
                self._notify_telegram("IPA 打包", ok=True)
                latest = self._guess_latest_ipa(workdir)
                if latest:
                    def _fill_ipa(p=latest):
                        self.ipa_harden_path_field.setStringValue_(p)
                    NSOperationQueue.mainQueue().addOperationWithBlock_(_fill_ipa)
                    self._log(f"  → 已填入「IPA 路径」供成品包混淆: {latest}")
            else:
                self._log(f"❌ IPA 打包失败 (exit {proc.returncode})")
                self._set_status(self.step5_status, "❌ 打包失败", success=False)
                self._notify_telegram("IPA 打包", ok=False,
                                      detail=f"exit={proc.returncode}")
        except Exception as e:
            self._log(f"❌ 打包异常: {e}")
            self._set_status(self.step5_status, f"❌ {e}", success=False)
            self._notify_telegram("IPA 打包", ok=False, detail=str(e))
        finally:
            _state["is_running"] = False
            _state.pop("build_proc", None)
            self._set_btn(self.build_ipa_btn, True, "打包 IPA")

    # ── Generic runner ──

    @objc.python_method
    def _run_cmd(self, cmd, btn, btn_title, status_label, auto_fill_path=None, cwd=None, on_success=None):
        try:
            env = get_env()
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, encoding='utf-8', errors='replace', cwd=cwd, env=env)
            for line in proc.stdout:
                clean = strip_ansi(line.rstrip())
                if clean:
                    self._log(f"  {clean}")
            proc.wait()

            if proc.returncode == 0:
                self._log(f"✅ {btn_title}完成")
                self._set_status(status_label, f"✅ 完成", success=True)
                self._notify_telegram(btn_title, ok=True)
                if on_success:
                    on_success()
                if auto_fill_path and os.path.isdir(auto_fill_path):
                    bid = str(self.bundle_id_field.stringValue()).strip()
                    pidx = int(self.project_popup.indexOfSelectedItem())
                    def _fill(p=auto_fill_path, b=bid, pi=pidx):
                        self.target_field.setStringValue_(p)
                        self.aside_project_field.setStringValue_(p)
                        self.run_project_field.setStringValue_(p)
                        self.obf_project_field.setStringValue_(p)
                        self.ipa_project_field.setStringValue_(p)
                        n = int(self.obf_project_popup.numberOfItems())
                        if 0 <= pi < n:
                            self.obf_project_popup.selectItemAtIndex_(pi)
                        if b and not str(self.cfg_bundle_field.stringValue()).strip():
                            self.cfg_bundle_field.setStringValue_(b)
                    NSOperationQueue.mainQueue().addOperationWithBlock_(_fill)
                    self._log(f"  → 已自动填入: {auto_fill_path}")
            else:
                self._log(f"❌ {btn_title}失败 (exit {proc.returncode})")
                self._set_status(status_label, f"❌ 失败", success=False)
                self._notify_telegram(btn_title, ok=False,
                                      detail=f"exit={proc.returncode}")
        except Exception as e:
            self._log(f"❌ 异常: {e}")
            self._set_status(status_label, f"❌ {e}", success=False)
            self._notify_telegram(btn_title, ok=False, detail=str(e))
        finally:
            _state["is_running"] = False
            self._set_btn(btn, True, btn_title)

    def applicationShouldTerminateAfterLastWindowClosed_(self, app):
        return True

    @objc.python_method
    def _terminate_child_processes(self):
        proc = _state.get("flutter_proc")
        if proc:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
            except Exception:
                try:
                    proc.terminate()
                except Exception:
                    pass
        proc = _state.get("build_proc")
        if proc:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
            except Exception:
                try:
                    proc.terminate()
                except Exception:
                    pass

    def relaunchAppFromDisk_(self, sender):
        """结束当前进程并用同一解释器重新执行 app.py，以加载已保存的修改。"""
        try:
            self._log("⟳ 正在重新载入应用（加载最新 app.py）…")
        except Exception:
            pass
        self._terminate_child_processes()
        py = sys.executable
        script = APP_PY_PATH
        try:
            os.execl(py, py, script)
        except Exception as e:
            try:
                self._log(f"❌ 重新载入失败: {e}")
            except Exception:
                pass

    def applicationWillTerminate_(self, notification):
        self._terminate_child_processes()


def _setup_menu_bar():
    menubar = NSMenu.alloc().init()
    app_menu_item = NSMenuItem.alloc().init()
    menubar.addItem_(app_menu_item)

    edit_menu_item = NSMenuItem.alloc().init()
    menubar.addItem_(edit_menu_item)
    edit_menu = NSMenu.alloc().initWithTitle_("Edit")

    edit_menu.addItemWithTitle_action_keyEquivalent_("Cut", "cut:", "x")
    edit_menu.addItemWithTitle_action_keyEquivalent_("Copy", "copy:", "c")
    edit_menu.addItemWithTitle_action_keyEquivalent_("Paste", "paste:", "v")
    edit_menu.addItemWithTitle_action_keyEquivalent_("Select All", "selectAll:", "a")
    edit_menu_item.setSubmenu_(edit_menu)

    NSApp.setMainMenu_(menubar)


def main():
    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(NSApplicationActivationPolicyRegular)
    delegate = AppDelegate.alloc().init()
    app.setDelegate_(delegate)
    _setup_menu_bar()
    app.run()


if __name__ == "__main__":
    main()
