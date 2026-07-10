"""命令行入口：管理 profile、启动浏览器、验证指纹与代理。"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import sys
import tempfile
import warnings

# macOS 系统 Python + LibreSSL 会触发 urllib3 的 NotOpenSSLWarning，与功能无关。
warnings.filterwarnings(
    "ignore",
    message=r"urllib3 v2 only supports OpenSSL.*",
)
try:
    from urllib3.exceptions import NotOpenSSLWarning

    warnings.filterwarnings("ignore", category=NotOpenSSLWarning)
except Exception:
    pass

from .config import Profile, Proxy, load_config, save_config
from .chrome_launcher import chrome_available, launch_chrome_blocking, verify_chrome_ip

IP_CHECK_HTTPS = "https://api.ipify.org?format=json"
# api.ipify.org 的 HTTP 会 302 到 HTTPS，回落须用不跳转的纯文本接口
IP_CHECK_HTTP_URLS = (
    "http://checkip.amazonaws.com",
    "http://ifconfig.me/ip",
    "http://icanhazip.com",
)
PROBE_GOTO_TIMEOUT_MS = 25000


def _looks_like_ip(value: str) -> bool:
    parts = (value or "").strip().split(".")
    if len(parts) != 4:
        return False
    try:
        return all(0 <= int(p) <= 255 for p in parts)
    except ValueError:
        return False


def _parse_ip_text(ip_txt: str) -> str:
    try:
        ip = json.loads(ip_txt).get("ip")
        if ip:
            return str(ip)
    except Exception:
        pass
    text = (ip_txt or "").strip()
    match = re.search(r"\d{1,3}(?:\.\d{1,3}){3}", text)
    if match:
        return match.group(0)
    return text.split()[0] if text else ""


def _is_ssl_goto_error(exc: BaseException) -> bool:
    err = str(exc)
    low = err.lower()
    return (
        "SEC_ERROR" in err
        or "SSL" in err
        or "certificate" in low
        or "unknown issuer" in low
        or "interrupted by another navigation" in low
    )


def _safe_close_page(page) -> None:
    if page is None:
        return
    try:
        page.close()
    except Exception:
        pass


def _collect_browser_info(page) -> dict:
    return page.evaluate(
        "() => ({ua: navigator.userAgent, platform: navigator.platform, "
        "lang: navigator.language, cores: navigator.hardwareConcurrency, "
        "screen: screen.width + 'x' + screen.height, "
        "tz: Intl.DateTimeFormat().resolvedOptions().timeZone})"
    )


def _fetch_ip_via_browser(browser, *, prefer_https: bool = True) -> tuple[str, bool, object]:
    """返回 (ip, https_ok, page)。page 留给调用方读取指纹字段。"""
    if prefer_https:
        page = browser.new_page()
        try:
            page.goto(IP_CHECK_HTTPS, timeout=PROBE_GOTO_TIMEOUT_MS)
            ip = _parse_ip_text(page.inner_text("body"))
            if ip and _looks_like_ip(ip):
                return ip, True, page
        except Exception as e:
            if not _is_ssl_goto_error(e):
                _safe_close_page(page)
                raise
        _safe_close_page(page)

    last_err = None
    for url in IP_CHECK_HTTP_URLS:
        page = browser.new_page()
        try:
            page.goto(url, timeout=PROBE_GOTO_TIMEOUT_MS)
            ip = _parse_ip_text(page.inner_text("body"))
            if ip and _looks_like_ip(ip):
                return ip, False, page
            last_err = RuntimeError(f"无法解析 {url} 返回内容")
        except Exception as e:
            last_err = e
        _safe_close_page(page)

    if last_err:
        raise last_err
    raise RuntimeError("无法通过 HTTP 回落获取出口 IP")


def _probe_profile_name(proxy_url: str) -> str:
    digest = hashlib.sha256(proxy_url.encode("utf-8")).hexdigest()[:12]
    return f"_probe_{digest}"


def cmd_list(args) -> int:
    from .fingerprint import fingerprint_summary

    cfg = load_config()
    if not cfg.profiles:
        print("还没有任何 profile。用 `add` 添加，或编辑 profiles.json。")
        return 0
    for p in cfg.profiles:
        proxy = p.proxy.server if p.proxy else "（无代理）"
        summary = fingerprint_summary(p.name)
        fp_state = "已固化" if summary else "未生成（首次启动时生成）"
        print(f"- {p.name}  os={p.os}  locale={p.locale}")
        print(f"    proxy: {proxy}")
        print(f"    指纹: {fp_state}")
        if summary:
            print(f"      UA: {summary['userAgent'][:70]}")
            print(f"      屏幕: {summary['screen']}  平台: {summary['platform']}")
    return 0


def cmd_add(args) -> int:
    cfg = load_config()
    if args.name in cfg.names():
        print(f"已存在同名 profile: {args.name}", file=sys.stderr)
        return 1
    proxy = None
    if args.proxy:
        proxy = Proxy(server=args.proxy, username=args.user or "", password=args.password or "")
    p = Profile(name=args.name, os=args.os, locale=args.locale, proxy=proxy, notes=args.notes or "")
    p.validate()
    cfg.profiles.append(p)
    save_config(cfg)
    print(f"已添加 profile: {args.name}")
    return 0


def cmd_launch(args) -> int:
    cfg = load_config()
    try:
        profile = cfg.get(args.name)
    except KeyError as e:
        print(str(e), file=sys.stderr)
        return 1
    if not profile.proxy and not args.allow_no_proxy:
        print(
            f"profile {args.name} 未配置代理。若确实要直连，加 --allow-no-proxy。",
            file=sys.stderr,
        )
        return 1
    engine = (args.engine or "chrome").lower()
    if engine == "chrome":
        if not chrome_available():
            print("未找到 Google Chrome，请先安装。", file=sys.stderr)
            return 1
        launch_chrome_blocking(profile)
        return 0
    if engine == "camoufox":
        from .launcher import launch_blocking

        launch_blocking(profile, headless=args.headless, regenerate_fp=args.regen_fingerprint)
        return 0
    print(f"未知引擎: {args.engine}", file=sys.stderr)
    return 1


def cmd_verify(args) -> int:
    cfg = load_config()
    profile = cfg.get(args.name)
    engine = (args.engine or "chrome").lower()

    if engine == "chrome":
        if not chrome_available():
            print("未找到 Google Chrome，请先安装。", file=sys.stderr)
            return 1
        ip, https_ok, info = verify_chrome_ip(profile)
    else:
        from camoufox.sync_api import Camoufox

        from .launcher import build_launch_kwargs

        kwargs = build_launch_kwargs(profile, headless=True)
        with Camoufox(**kwargs) as browser:
            ip, https_ok, page = _fetch_ip_via_browser(browser)
            info = _collect_browser_info(page)
            _safe_close_page(page)

    print(f"profile: {profile.name}  engine: {engine}")
    if https_ok:
        print("  HTTPS   : 通过")
    else:
        print("  HTTPS   : 失败（证书不可信，出口 IP 为 HTTP 回落结果）")
    print(f"  出口 IP : {ip}")
    if info.get("tz"):
        print(f"  时区    : {info['tz']}")
    print(f"  UA      : {info.get('ua', '')}")
    if info.get("platform"):
        print(
            f"  平台    : {info['platform']}   语言: {info.get('lang', '')}   "
            f"核心: {info.get('cores', '')}   屏幕: {info.get('screen', '')}"
        )
    return 0


def cmd_probe_proxy(args) -> int:
    """供工厂「检验」调用：与 cmd_verify 相同的 Camoufox 栈探测代理。"""
    proxy_url = (args.proxy or "").strip()
    if not proxy_url:
        print("FAIL|缺少代理地址", file=sys.stderr)
        return 1

    profile = Profile(
        name=_probe_profile_name(proxy_url),
        os="macos",
        locale="en-US",
        proxy=Proxy(server=proxy_url),
    )
    td = tempfile.mkdtemp(prefix="fp_probe_")
    try:
        from camoufox.sync_api import Camoufox

        from .launcher import build_launch_kwargs

        kwargs = build_launch_kwargs(profile, headless=True)
        kwargs["user_data_dir"] = td
        with Camoufox(**kwargs) as browser:
            ip, https_ok, page = _fetch_ip_via_browser(browser)
            _safe_close_page(page)
        if https_ok:
            print(f"HTTPS_OK|{ip}")
        else:
            print(f"HTTP_ONLY|{ip}")
        return 0
    except Exception as e:
        reason = str(e).replace("\n", " ")[:120]
        print(f"FAIL|{reason}")
        return 1
    finally:
        shutil.rmtree(td, ignore_errors=True)


def cmd_regen(args) -> int:
    from .fingerprint import get_or_create_fingerprint

    cfg = load_config()
    profile = cfg.get(args.name)
    get_or_create_fingerprint(profile.name, profile.os, regenerate=True)
    print(f"已为 {profile.name} 重新生成指纹。")
    return 0


def cmd_update_proxy(args) -> int:
    cfg = load_config()
    try:
        profile = cfg.get(args.name)
    except KeyError as e:
        print(str(e), file=sys.stderr)
        return 1
    proxy_raw = (args.proxy or "").strip()
    if not proxy_raw:
        print("请提供代理地址，如 socks5://1.2.3.4:1080", file=sys.stderr)
        return 1
    proxy = Proxy(server=proxy_raw).normalized()
    old = profile.proxy.server if profile.proxy else "（无）"
    profile.proxy = proxy
    save_config(cfg)
    print(f"已更新 {profile.name} 的代理")
    print(f"  旧: {old}")
    print(f"  新: {proxy.server}")
    print("  指纹: 未改动（同一身份指纹保持不变）")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="fpbrowser",
        description="每个浏览器独立指纹 + 专属 SOCKS5 代理的管理器",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("list", help="列出所有 profile 及其指纹状态").set_defaults(func=cmd_list)

    p_add = sub.add_parser("add", help="添加一个 profile")
    p_add.add_argument("name")
    p_add.add_argument("--os", default="macos", choices=["windows", "macos", "linux"])
    p_add.add_argument("--locale", default="en-US")
    p_add.add_argument("--proxy", help="代理地址，如 socks5://1.2.3.4:1080")
    p_add.add_argument("--user", help="代理用户名")
    p_add.add_argument("--password", help="代理密码")
    p_add.add_argument("--notes", help="备注")
    p_add.set_defaults(func=cmd_add)

    p_launch = sub.add_parser("launch", help="打开某个 profile 的浏览器窗口（手动操作）")
    p_launch.add_argument("name")
    p_launch.add_argument(
        "--engine",
        default="chrome",
        choices=["chrome", "camoufox"],
        help="chrome=系统 Google Chrome；camoufox=反检测 Firefox（默认 chrome）",
    )
    p_launch.add_argument("--headless", action="store_true", help="无头模式（一般手动操作不用）")
    p_launch.add_argument("--allow-no-proxy", action="store_true", help="允许无代理直连")
    p_launch.add_argument("--regen-fingerprint", action="store_true", help="启动前重置该 profile 指纹（仅 camoufox）")
    p_launch.set_defaults(func=cmd_launch)

    p_verify = sub.add_parser("verify", help="无头核验：确认出口 IP、时区、指纹是否符合预期")
    p_verify.add_argument("name")
    p_verify.add_argument(
        "--engine",
        default="chrome",
        choices=["chrome", "camoufox"],
        help="chrome=系统 Chrome；camoufox=Camoufox（默认 chrome）",
    )
    p_verify.set_defaults(func=cmd_verify)

    p_probe = sub.add_parser(
        "probe-proxy",
        help="无头探测单个 SOCKS5（与 verify 相同浏览器栈，供工厂批量检验）",
    )
    p_probe.add_argument("proxy")
    p_probe.set_defaults(func=cmd_probe_proxy)

    p_regen = sub.add_parser("regen", help="重新生成某个 profile 的指纹")
    p_regen.add_argument("name")
    p_regen.set_defaults(func=cmd_regen)

    p_uproxy = sub.add_parser("update-proxy", help="仅更换 profile 的 SOCKS5 代理，指纹不变")
    p_uproxy.add_argument("name")
    p_uproxy.add_argument("proxy", help="新代理，如 socks5://1.2.3.4:1080")
    p_uproxy.set_defaults(func=cmd_update_proxy)

    return parser


def main(argv=None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
