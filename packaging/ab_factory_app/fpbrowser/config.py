"""读取/写入 profiles.json，并做基本校验。"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Optional

from .paths import PROFILES_FILE, ensure_dirs


VALID_OS = {"windows", "macos", "linux"}


@dataclass
class Proxy:
    server: str
    username: str = ""
    password: str = ""

    def normalized(self) -> "Proxy":
        """解析 socks5://host:port:user:pass 简写。"""
        import re

        s = (self.server or "").strip()
        if self.username or self.password:
            return self
        m = re.match(r"^(socks5|http|https)://([^:/]+):(\d+):([^:]+):(.+)$", s)
        if m:
            return Proxy(
                server=f"{m.group(1)}://{m.group(2)}:{m.group(3)}",
                username=m.group(4),
                password=m.group(5),
            )
        return self

    def chrome_proxy_server(self) -> str:
        n = self.normalized()
        return n.server.strip()

    def as_playwright(self) -> Optional[dict]:
        if not self.server:
            return None
        proxy = {"server": self.server}
        if self.username:
            proxy["username"] = self.username
        if self.password:
            proxy["password"] = self.password
        return proxy


@dataclass
class Profile:
    name: str
    os: str = "macos"
    locale: str = "en-US"
    proxy: Optional[Proxy] = None
    notes: str = ""

    def validate(self) -> None:
        if not self.name or "/" in self.name or "\\" in self.name:
            raise ValueError(f"profile 名称非法: {self.name!r}（不能为空或含路径分隔符）")
        if self.os not in VALID_OS:
            raise ValueError(f"profile {self.name} 的 os={self.os!r} 无效，应为 {sorted(VALID_OS)}")


@dataclass
class ProfilesConfig:
    profiles: list[Profile] = field(default_factory=list)

    def get(self, name: str) -> Profile:
        for p in self.profiles:
            if p.name == name:
                return p
        raise KeyError(f"找不到名为 {name!r} 的 profile")

    def names(self) -> list[str]:
        return [p.name for p in self.profiles]


def _parse_proxy(raw: Optional[dict]) -> Optional[Proxy]:
    if not raw:
        return None
    server = (raw.get("server") or "").strip()
    if not server:
        return None
    return Proxy(
        server=server,
        username=(raw.get("username") or "").strip(),
        password=(raw.get("password") or ""),
    )


def load_config(path=PROFILES_FILE) -> ProfilesConfig:
    ensure_dirs()
    if not path.exists():
        return ProfilesConfig()
    data = json.loads(path.read_text(encoding="utf-8"))
    profiles = []
    for raw in data.get("profiles", []):
        p = Profile(
            name=raw["name"],
            os=raw.get("os", "macos"),
            locale=raw.get("locale", "en-US"),
            proxy=_parse_proxy(raw.get("proxy")),
            notes=raw.get("notes", ""),
        )
        p.validate()
        profiles.append(p)
    names = [p.name for p in profiles]
    dupes = {n for n in names if names.count(n) > 1}
    if dupes:
        raise ValueError(f"profiles.json 中存在重复名称: {sorted(dupes)}")
    return ProfilesConfig(profiles=profiles)


def save_config(cfg: ProfilesConfig, path=PROFILES_FILE) -> None:
    ensure_dirs()
    out = {
        "profiles": [
            {
                "name": p.name,
                "os": p.os,
                "locale": p.locale,
                "proxy": {
                    "server": p.proxy.server if p.proxy else "",
                    "username": p.proxy.username if p.proxy else "",
                    "password": p.proxy.password if p.proxy else "",
                },
                "notes": p.notes,
            }
            for p in cfg.profiles
        ]
    }
    path.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
