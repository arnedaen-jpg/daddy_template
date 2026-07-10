"""系统 Google Chrome：每身份独立 user-data-dir + 专属 SOCKS5 代理。"""
from __future__ import annotations

import os
import platform
import shutil
import subprocess
import sys
import time
from typing import Optional

from .config import Profile
from .paths import launch_heartbeat_file, profile_chrome_user_data_dir

DEFAULT_LAUNCH_URL = "https://appstoreconnect.apple.com/"

MAC_CHROME_PATHS = (
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
)


def find_chrome() -> str:
    system = platform.system()
    if system == "Darwin":
        for path in MAC_CHROME_PATHS:
            if os.path.isfile(path) and os.access(path, os.X_OK):
                return path
    elif system == "Windows":
        for raw in (
            os.path.expandvars(r"%ProgramFiles%\Google\Chrome\Application\chrome.exe"),
            os.path.expandvars(r"%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe"),
            os.path.expandvars(r"%LocalAppData%\Google\Chrome\Application\chrome.exe"),
        ):
            if os.path.isfile(raw):
                return raw
    else:
        for name in ("google-chrome", "google-chrome-stable", "chromium", "chromium-browser"):
            path = shutil.which(name)
            if path:
                return path
    raise FileNotFoundError(
        "未找到 Google Chrome。请安装 Chrome 后再使用「引擎 → Chrome」。"
    )


def chrome_available() -> bool:
    try:
        find_chrome()
        return True
    except FileNotFoundError:
        return False


def _touch_heartbeat(path) -> None:
    try:
        path.write_text(str(time.time()), encoding="utf-8")
    except Exception:
        pass


def _clear_heartbeat(path) -> None:
    try:
        path.unlink(missing_ok=True)
    except Exception:
        pass


def build_chrome_argv(
    profile: Profile,
    *,
    headless: bool = False,
    start_url: str = DEFAULT_LAUNCH_URL,
) -> list[str]:
    chrome = find_chrome()
    user_data = profile_chrome_user_data_dir(profile.name)
    locale = (profile.locale or "en-US").replace("_", "-")

    args = [
        chrome,
        f"--user-data-dir={user_data}",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-sync",
        "--disable-features=ChromeWhatsNewUI",
        f"--lang={locale}",
    ]

    if profile.proxy:
        proxy = profile.proxy.normalized()
        args.append(f"--proxy-server={proxy.chrome_proxy_server()}")
        if proxy.username or proxy.password:
            print(
                f"[{profile.name}] 警告: Chrome 命令行无法注入 SOCKS5 账号密码；"
                "请使用无认证代理，或先用本地工具做端口转发。",
                file=sys.stderr,
            )

    if headless:
        args.extend(["--headless=new", "--disable-gpu"])

    args.append(start_url)
    return args


def launch_chrome_blocking(profile: Profile) -> None:
    """阻塞直到 Chrome 进程结束；独立子进程内调用，结束时 os._exit。"""
    heartbeat = launch_heartbeat_file(profile.name)
    exit_reason = "未知"
    rc = 0
    _clear_heartbeat(heartbeat)
    try:
        argv = build_chrome_argv(profile)
        print(
            f"[{profile.name}] 正在启动系统 Chrome（独立配置目录 + SOCKS5）…",
            file=sys.stderr,
        )
        proc = subprocess.Popen(
            argv,
            start_new_session=True,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        while proc.poll() is None:
            _touch_heartbeat(heartbeat)
            time.sleep(0.5)
        rc = proc.returncode or 0
        exit_reason = "Chrome 已关闭" if rc == 0 else f"Chrome 退出码 {rc}"
    except KeyboardInterrupt:
        exit_reason = "用户中断"
    except Exception as exc:
        rc = 1
        exit_reason = f"启动失败: {exc}"
        print(exit_reason, file=sys.stderr)
    finally:
        _clear_heartbeat(heartbeat)
        print(f"[{profile.name}] 会话结束: {exit_reason}", file=sys.stderr)
    os._exit(rc)


def verify_chrome_ip(profile: Profile) -> tuple[str, bool, dict]:
    """经 profile 代理用 curl 探测出口 IP（与身份下拉快查一致，无需 Camoufox）。"""
    import json
    import re
    import subprocess

    proxy_url = (profile.proxy.server if profile.proxy else "").strip()
    if not proxy_url:
        raise RuntimeError("未配置代理")

    https_url = "https://api.ipify.org?format=json"
    http_urls = (
        "http://checkip.amazonaws.com",
        "http://ifconfig.me/ip",
        "http://icanhazip.com",
    )
    info = {"ua": "(系统 Chrome)", "tz": "", "lang": profile.locale}

    def _curl(url: str) -> str:
        proc = subprocess.run(
            ["curl", "-sS", "--max-time", "15", "-x", proxy_url, url],
            capture_output=True,
            text=True,
            timeout=20,
        )
        if proc.returncode != 0:
            err = (proc.stderr or proc.stdout or "").strip()[:200]
            raise RuntimeError(err or f"curl 退出码 {proc.returncode}")
        return proc.stdout or ""

    def _parse_ip(text: str) -> str:
        try:
            ip = json.loads(text).get("ip")
            if ip:
                return str(ip)
        except Exception:
            pass
        match = re.search(r"\d{1,3}(?:\.\d{1,3}){3}", text)
        return match.group(0) if match else text.strip().split()[0]

    try:
        ip = _parse_ip(_curl(https_url))
        return ip, True, info
    except Exception:
        last_err: Optional[Exception] = None
        for url in http_urls:
            try:
                ip = _parse_ip(_curl(url))
                return ip, False, info
            except Exception as exc:
                last_err = exc
        raise last_err or RuntimeError("无法获取出口 IP")
