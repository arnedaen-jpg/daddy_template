"""按 profile 启动一个可手动操作的 Camoufox 窗口。"""
from __future__ import annotations

import os
import sys
import time
import traceback

from camoufox.sync_api import Camoufox

from .config import Profile
from .fingerprint import get_or_create_fingerprint
from .paths import launch_heartbeat_file, profile_user_data_dir


def build_launch_kwargs(profile: Profile, *, headless: bool = False, regenerate_fp: bool = False) -> dict:
    fp = get_or_create_fingerprint(profile.name, profile.os, regenerate=regenerate_fp)
    kwargs: dict = {
        "fingerprint": fp,
        "os": profile.os,
        "locale": profile.locale,
        "persistent_context": True,
        "user_data_dir": str(profile_user_data_dir(profile.name)),
        "headless": headless,
        "block_webrtc": True,
        "humanize": True,
        "i_know_what_im_doing": True,
    }

    proxy = profile.proxy.as_playwright() if profile.proxy else None
    if proxy:
        kwargs["proxy"] = proxy
        kwargs["geoip"] = True
    return kwargs


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


def _wait_until_browser_gone(browser, *, heartbeat, profile_name: str) -> str:
    """等待用户关窗或 Firefox/Playwright 断开；持续刷新心跳供主应用检测僵尸进程。"""
    stopped = {"v": False}
    reason = {"msg": "用户关闭窗口"}

    def _stop(msg: str) -> None:
        if not stopped["v"]:
            stopped["v"] = True
            reason["msg"] = msg

    try:
        browser.on("close", lambda *_: _stop("浏览器上下文已关闭"))
    except Exception:
        pass

    def _bind_page(page) -> None:
        try:
            page.on("crash", lambda *_: _stop("页面崩溃（常见于人机验证/反爬拦截）"))
        except Exception:
            pass

    try:
        browser.on("page", lambda page: _bind_page(page))
    except Exception:
        pass
    for page in list(browser.pages):
        _bind_page(page)

    while not stopped["v"]:
        _touch_heartbeat(heartbeat)
        try:
            pages = browser.pages
            if not pages:
                return "所有页面已关闭"
            if not any(not page.is_closed() for page in pages):
                return "所有页面已关闭"
        except Exception as exc:
            return f"浏览器连接断开: {exc}"
        time.sleep(0.3)
    return reason["msg"]


def launch_blocking(profile: Profile, *, headless: bool = False, regenerate_fp: bool = False) -> None:
    """
    阻塞直到会话结束。结束时 os._exit，避免 Firefox 崩溃后 Playwright 清理挂死导致父界面卡在「运行中」。
    """
    kwargs = build_launch_kwargs(profile, headless=headless, regenerate_fp=regenerate_fp)
    heartbeat = launch_heartbeat_file(profile.name)
    exit_reason = "未知"
    rc = 0
    _clear_heartbeat(heartbeat)
    try:
        with Camoufox(**kwargs) as browser:
            page = browser.pages[0] if browser.pages else browser.new_page()
            try:
                page.goto("https://appstoreconnect.apple.com/", timeout=90_000)
            except Exception as nav_err:
                print(
                    f"[{profile.name}] 初始页加载失败: {nav_err}",
                    file=sys.stderr,
                )
            print(
                f"[{profile.name}] 浏览器已打开。可手动访问任意站点；"
                "关闭最后一个标签页或窗口即结束本次会话。",
                file=sys.stderr,
            )
            exit_reason = _wait_until_browser_gone(browser, heartbeat=heartbeat, profile_name=profile.name)
    except KeyboardInterrupt:
        exit_reason = "用户中断"
    except Exception:
        rc = 1
        exit_reason = "浏览器异常退出"
        traceback.print_exc(file=sys.stderr)
    finally:
        _clear_heartbeat(heartbeat)
        print(f"[{profile.name}] 会话结束: {exit_reason}", file=sys.stderr)
    os._exit(rc)
