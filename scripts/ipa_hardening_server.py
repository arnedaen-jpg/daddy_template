#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""本地 IPA 加固小工具 —— 浏览器 UI + 调用 harden_ipa_standalone.sh"""

import json
import os
import plistlib
import re
import subprocess
import sys
import threading
import webbrowser
import zipfile
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import urlparse

SCRIPT_DIR = Path(__file__).resolve().parent
STANDALONE_SH = SCRIPT_DIR / "harden_ipa_standalone.sh"
UI_HTML = SCRIPT_DIR / "ipa_hardening_ui.html"
DEFAULT_PORT = 8765


def bundle_id_from_ipa(ipa_path: str) -> str:
    try:
        with zipfile.ZipFile(ipa_path) as zf:
            for name in zf.namelist():
                if re.match(r"Payload/[^/]+\.app/Info\.plist$", name):
                    with zf.open(name) as f:
                        info = plistlib.load(f)
                        bid = info.get("CFBundleIdentifier")
                        if isinstance(bid, str) and bid:
                            return bid
    except (OSError, zipfile.BadZipFile, plistlib.InvalidFileException):
        pass
    return ""


def run_hardening(body: dict) -> dict:
    ipa = (body.get("ipa_path") or "").strip()
    if not ipa:
        return {"ok": False, "error": "请填写 IPA 路径"}
    ipa = os.path.expanduser(ipa)
    if not os.path.isfile(ipa):
        return {"ok": False, "error": f"文件不存在: {ipa}"}

    cmd = ["bash", str(STANDALONE_SH), "--ipa", ipa]
    out = (body.get("out_path") or "").strip()
    if out:
        cmd += ["--out", os.path.expanduser(out)]
    seed = (body.get("seed") or "").strip()
    if not seed:
        seed = bundle_id_from_ipa(ipa)
    if seed:
        cmd += ["--seed", seed]
    if body.get("resources", True):
        cmd.append("--resources")
    else:
        cmd.append("--no-resources")
    if body.get("macho"):
        cmd.append("--macho")
    profile = (body.get("profile_path") or "").strip()
    if profile:
        profile = os.path.expanduser(profile)
        if not os.path.isfile(profile):
            return {"ok": False, "error": f"描述文件不存在: {profile}"}
        cmd += ["--profile", profile]
    bundle_id = (body.get("bundle_id") or "").strip()
    if bundle_id:
        cmd += ["--bundle-id", bundle_id]
    identity = (body.get("identity") or "").strip()
    if identity:
        cmd += ["--identity", identity]

    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=3600,
            cwd=str(SCRIPT_DIR),
        )
        log = (proc.stdout or "") + (proc.stderr or "")
        if proc.returncode != 0:
            return {"ok": False, "error": f"执行失败 (exit {proc.returncode})", "log": log}
        out_path = out or str(Path(ipa).with_name(Path(ipa).stem + "_hardened.ipa"))
        return {"ok": True, "log": log, "output_path": os.path.expanduser(out_path)}
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "执行超时（>1h）"}
    except OSError as e:
        return {"ok": False, "error": str(e)}


class Handler(BaseHTTPRequestHandler):
    server_version = "IPAHardeningTool/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send_json(self, code: int, data: dict):
        raw = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _send_html(self, content: bytes):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/", "/index.html"):
            if UI_HTML.is_file():
                self._send_html(UI_HTML.read_bytes())
            else:
                self._send_json(404, {"error": "缺少 ipa_hardening_ui.html"})
            return
        if path == "/api/health":
            self._send_json(200, {"ok": True, "script": str(STANDALONE_SH)})
            return
        self.send_error(404)

    def do_POST(self):
        path = urlparse(self.path).path
        if path != "/api/harden":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", 0))
        try:
            body = json.loads(self.rfile.read(length).decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            self._send_json(400, {"ok": False, "error": "无效 JSON"})
            return
        self._send_json(200, run_hardening(body))


def main():
    port = DEFAULT_PORT
    if len(sys.argv) > 1:
        try:
            port = int(sys.argv[1])
        except ValueError:
            pass
    if not STANDALONE_SH.is_file():
        print("错误: 未找到", STANDALONE_SH, file=sys.stderr)
        sys.exit(1)
    os.chmod(STANDALONE_SH, 0o755)

    httpd = HTTPServer(("127.0.0.1", port), Handler)
    url = f"http://127.0.0.1:{port}/"
    print(f"IPA 加固工具: {url}")
    print("关闭此终端窗口即停止服务。")
    threading.Timer(0.4, lambda: webbrowser.open(url)).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止。")


if __name__ == "__main__":
    main()
