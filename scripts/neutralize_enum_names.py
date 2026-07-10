#!/usr/bin/env python3
"""同长度、就地中和 Dart AOT 里泄露的「装饰性」业务枚举成员名。

原理：这些枚举（如 XMChatMsgType）在代码里只通过 fromInt(int) 数字开关解码，
从不调用 .name / .byName / .values.byName，因此成员名字符串纯属 Dart 为
EnumName.name 预埋的反射数据，运行时永不读取。用等长字节替换把它们改成
中性串，既清除 anchor/live/gift/noble 等业务词指纹，又不改变任何运行时行为。

安全约束：
  - 仅整词匹配（前后为非标识符字节），不误伤子串。
  - 等长替换，绝不移动 Mach-O / 快照偏移。
  - 只处理经源码核实为「int 编码、无 .name 依赖」的枚举成员白名单。

白名单可通过环境变量 ZT_ENUM_TARGETS_FILE 指定的文件追加（每行一个标识符）。
若某项目不含这些枚举，命中数为 0，脚本无副作用。

用法:
    neutralize_enum_names.py <binary> [<binary> ...]
"""
import hashlib
import os
import re
import sys

# 源码核实安全（XMChatMsgType 等 int 编码枚举，无 .name/.byName/.values.byName）。
TARGETS = [
    "anchorAnnouncementMsg", "anchorLiveAgainMsg", "anchorLiveMsg",
    "anchorLivePauseMsg", "anchorLiveStopMsg", "anchorMsg",
    "attentionAnchorMsg", "barrageMsg", "bigGiftMsg", "giftMsg",
    "giftReturnMsg", "labaMsg", "mountEntranceMsg", "openNobilityMsg",
    "smallGiftMsg", "specialBarrageMsg", "userRightChangeMsg",
    "wealthLevelUpMsg", "forbidSendMsg", "enableSendMsg", "modifyTitleMsg",
]


def _load_extra_targets():
    fp = os.environ.get("ZT_ENUM_TARGETS_FILE", "").strip()
    if not fp or not os.path.isfile(fp):
        return []
    out = []
    with open(fp, "r", encoding="utf-8") as f:
        for line in f:
            tok = line.strip()
            if tok and not tok.startswith("#"):
                out.append(tok)
    return out


def neutral_same_len(token: str) -> bytes:
    """生成与 token 等长的确定性中性 ASCII 串（字母开头，更像标识符）。"""
    h = hashlib.sha256(token.encode()).hexdigest()
    body = ("z" + h)[: len(token)]
    return body.encode()


def patch(path: str, targets) -> int:
    with open(path, "rb") as f:
        data = bytearray(f.read())
    count = 0
    for tok in targets:
        rep = neutral_same_len(tok)
        if len(rep) != len(tok):
            continue
        pat = re.compile(
            rb"(?<![A-Za-z0-9_])" + re.escape(tok.encode()) + rb"(?![A-Za-z0-9_])"
        )
        for m in list(pat.finditer(data)):
            data[m.start():m.end()] = rep
            count += 1
    if count:
        with open(path, "wb") as f:
            f.write(data)
    return count


if __name__ == "__main__":
    targets = sorted(set(TARGETS) | set(_load_extra_targets()))
    total = 0
    for p in sys.argv[1:]:
        try:
            c = patch(p, targets)
        except Exception as e:
            print(f"{p}: 跳过 ({e})")
            continue
        total += c
        print(f"{p}: {c}")
    print(f"TOTAL enum-name occurrences neutralized: {total}")
