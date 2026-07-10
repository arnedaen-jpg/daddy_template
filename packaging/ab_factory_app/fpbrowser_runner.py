"""Camoufox 专用 venv 管理与子进程调用（系统 Python 不含 camoufox）。"""
from __future__ import annotations

import os
import re
import subprocess
import sys
import threading

APP_DIR = os.path.dirname(os.path.abspath(__file__))
FP_VENV = os.path.expanduser("~/Library/Application Support/ABFactory/camoufox-venv")
FP_READY = os.path.join(FP_VENV, ".fp_ready")
FP_PYTHON = os.path.join(FP_VENV, "bin", "python")
REQUIREMENTS = "camoufox[geoip]>=0.4.0"

# macOS 系统 Python 用 LibreSSL，urllib3 v2 会刷 NotOpenSSLWarning；与功能无关。
_NOISE_LINE_RE = re.compile(
    r"NotOpenSSLWarning|urllib3 v2 only supports OpenSSL|"
    r"urllib3/__init__\.py:\d+:\s*NotOpenSSLWarning|"
    r"^\s*warnings\.warn\(",
)


def _cli_env() -> dict:
    env = os.environ.copy()
    env["PYTHONPATH"] = APP_DIR
    # 子进程内直接压制该警告（比事后过滤更干净）
    existing = env.get("PYTHONWARNINGS", "").strip()
    ignore = "ignore:urllib3 v2 only supports OpenSSL:Warning"
    env["PYTHONWARNINGS"] = f"{existing},{ignore}" if existing else ignore
    return env


def _is_noise_line(line: str) -> bool:
    s = (line or "").strip()
    if not s:
        return False
    return bool(_NOISE_LINE_RE.search(s))


def is_ready() -> bool:
    return os.path.isfile(FP_PYTHON) and os.path.isfile(FP_READY)


def is_chrome_ready() -> bool:
    try:
        from fpbrowser.chrome_launcher import chrome_available

        return chrome_available()
    except Exception:
        return False


def _uses_camoufox_venv(args: list[str]) -> bool:
    if "--engine" in args:
        idx = args.index("--engine")
        if idx + 1 < len(args) and args[idx + 1].lower() == "chrome":
            return False
    return True


def python_path(args: list[str] | None = None) -> str:
    if args and not _uses_camoufox_venv(args):
        return sys.executable
    return FP_PYTHON if is_ready() else sys.executable


def _popen_cli(args: list[str], *, cwd=APP_DIR, silent=False):
    env = _cli_env()
    cmd = [python_path(args), "-m", "fpbrowser.cli", *args]
    if silent:
        return subprocess.Popen(
            cmd,
            cwd=cwd,
            env=env,
            start_new_session=True,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
    return subprocess.Popen(
        cmd,
        cwd=cwd,
        env=env,
        start_new_session=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )


def _drain_stderr(proc) -> str:
    if proc.stderr is None:
        return ""
    lines: list[str] = []
    try:
        for line in proc.stderr:
            s = line.rstrip("\n")
            if _is_noise_line(s):
                continue
            lines.append(s)
    except Exception:
        pass
    tail = lines[-30:]
    return "\n".join(tail)


def _drain_and_wait(proc) -> tuple[int, str]:
    err_holder: list[str] = []

    def _read_err():
        err_holder.append(_drain_stderr(proc))

    t = threading.Thread(target=_read_err, daemon=True)
    t.start()
    rc = proc.wait()
    t.join(timeout=5)
    return rc, (err_holder[0] if err_holder else "")


def _run(proc, *, log_fn=print) -> int:
    log_fn(f"$ {' '.join(proc.args)}")
    assert proc.stdout is not None
    for line in proc.stdout:
        s = line.rstrip("\n")
        if _is_noise_line(s):
            continue
        log_fn(s)
    return proc.wait()


def install(log_fn=print) -> bool:
    os.makedirs(os.path.dirname(FP_VENV), exist_ok=True)
    if not os.path.isfile(FP_PYTHON):
        proc = subprocess.Popen(
            [sys.executable, "-m", "venv", FP_VENV],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        assert proc.stdout is not None
        for line in proc.stdout:
            log_fn(line.rstrip("\n"))
        if proc.wait() != 0:
            return False
    for pip_args in (
        ["-m", "pip", "install", "-q", "--upgrade", "pip"],
        ["-m", "pip", "install", "-q", REQUIREMENTS, "pyyaml"],
        ["-m", "camoufox", "fetch"],
    ):
        proc = subprocess.Popen(
            [FP_PYTHON, *pip_args],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env=_cli_env(),
        )
        assert proc.stdout is not None
        for line in proc.stdout:
            s = line.rstrip("\n")
            if _is_noise_line(s):
                continue
            log_fn(s)
        if proc.wait() != 0:
            return False
    with open(FP_READY, "w", encoding="utf-8") as f:
        f.write("ok\n")
    return True


def start_cli(args: list[str], *, silent=False):
    """在独立进程组中启动 fpbrowser CLI（关闭 Camoufox 不影响主应用）。"""
    return _popen_cli(args, silent=silent)


def wait_cli(proc, *, log_fn=print) -> int:
    return _run(proc, log_fn=log_fn)


def wait_cli_silent(proc) -> tuple[int, str]:
    """长时会话静默等待；返回 (exit_code, stderr_tail) 供界面展示崩溃原因。"""
    return _drain_and_wait(proc)


def run_cli(args: list[str], *, log_fn=print) -> int:
    proc = _popen_cli(args)
    return _run(proc, log_fn=log_fn)
