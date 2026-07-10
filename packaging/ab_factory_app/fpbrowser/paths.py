"""AB 包工厂内指纹浏览器的数据目录约定。"""
from __future__ import annotations

import os
from pathlib import Path

# 与 AB 包工厂其它状态一致，放在 Application Support 下
ROOT = Path.home() / "Library" / "Application Support" / "ABFactory" / "fingerprint-browsers"

PROFILES_FILE = ROOT / "profiles.json"
DATA_DIR = ROOT / "data"
USER_DATA_DIR = DATA_DIR / "user_data"
CHROME_USER_DATA_DIR = DATA_DIR / "chrome_user_data"
FINGERPRINT_DIR = DATA_DIR / "fingerprints"


def ensure_dirs() -> None:
    ROOT.mkdir(parents=True, exist_ok=True)
    DATA_DIR.mkdir(parents=True, exist_ok=True)


def profile_user_data_dir(name: str) -> Path:
    ensure_dirs()
    p = USER_DATA_DIR / name
    p.mkdir(parents=True, exist_ok=True)
    return p


def profile_chrome_user_data_dir(name: str) -> Path:
    ensure_dirs()
    p = CHROME_USER_DATA_DIR / name
    p.mkdir(parents=True, exist_ok=True)
    return p


def profile_fingerprint_file(name: str) -> Path:
    ensure_dirs()
    FINGERPRINT_DIR.mkdir(parents=True, exist_ok=True)
    return FINGERPRINT_DIR / f"{name}.json"


def launch_heartbeat_file(name: str) -> Path:
    """launch 子进程心跳文件；浏览器崩溃后若 Playwright 清理卡住，主应用可据此杀残留进程。"""
    ensure_dirs()
    return ROOT / f".launch-heartbeat-{name}"
