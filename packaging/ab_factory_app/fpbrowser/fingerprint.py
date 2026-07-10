"""为每个 profile 生成并固化一份指纹。"""
from __future__ import annotations

import dataclasses

import orjson
from browserforge.fingerprints import (
    Fingerprint,
    NavigatorFingerprint,
    ScreenFingerprint,
    VideoCard,
)
from camoufox.utils import generate_fingerprint

from .paths import profile_fingerprint_file


def _to_dict(fp: Fingerprint) -> dict:
    return dataclasses.asdict(fp)


def _from_dict(d: dict) -> Fingerprint:
    screen = ScreenFingerprint(**d["screen"])
    navigator = NavigatorFingerprint(**d["navigator"])
    video_card = VideoCard(**d["videoCard"]) if d.get("videoCard") else None
    return Fingerprint(
        screen=screen,
        navigator=navigator,
        headers=d.get("headers", {}),
        videoCodecs=d.get("videoCodecs", {}),
        audioCodecs=d.get("audioCodecs", {}),
        pluginsData=d.get("pluginsData", {}),
        battery=d.get("battery"),
        videoCard=video_card,
        multimediaDevices=d.get("multimediaDevices", []),
        fonts=d.get("fonts", []),
        mockWebRTC=d.get("mockWebRTC"),
        slim=d.get("slim"),
    )


def get_or_create_fingerprint(name: str, os_name: str, *, regenerate: bool = False) -> Fingerprint:
    path = profile_fingerprint_file(name)
    if path.exists() and not regenerate:
        data = orjson.loads(path.read_text(encoding="utf-8"))
        return _from_dict(data["fingerprint"])

    fp = generate_fingerprint(os=os_name)
    payload = {"os": os_name, "fingerprint": _to_dict(fp)}
    path.write_text(orjson.dumps(payload, option=orjson.OPT_INDENT_2).decode(), encoding="utf-8")
    return fp


def fingerprint_summary(name: str) -> dict:
    path = profile_fingerprint_file(name)
    if not path.exists():
        return {}
    data = orjson.loads(path.read_text(encoding="utf-8"))
    fp = data["fingerprint"]
    nav = fp.get("navigator", {})
    screen = fp.get("screen", {})
    return {
        "userAgent": nav.get("userAgent", ""),
        "platform": nav.get("platform", ""),
        "language": nav.get("language", ""),
        "screen": f"{screen.get('width')}x{screen.get('height')}",
        "hardwareConcurrency": nav.get("hardwareConcurrency"),
    }
