#!/usr/bin/env python3
"""同长度、就地中和 Mach-O 二进制里泄露的开发者路径 / 敏感源码路径。

用途：Flutter AOT 快照与部分闭源 framework 会把编译机上的绝对路径
（如 /Users/xxx/Desktop/UAPP/...、file:///Users/...）残留在二进制里，
被 App Store 机审或逆向直接读出，暴露开发者身份与工程结构。

原理：等长替换成 /dev/null + NUL 填充，绝不移动任何 Mach-O / 快照偏移，
因此改完后二进制结构不变，重签名即可安装运行。

用法:
    neutralize_macho_paths.py <binary> [<binary> ...]
"""
import re
import sys

PATTERNS = [
    rb'/Users/[A-Za-z0-9_.\-]+/[^\x00]*',
    rb'file:///Users/[^\x00]*',
]
COMPILED = [re.compile(p) for p in PATTERNS]
_SENTINEL = b'/dev/null'


def neutralize(path: str) -> int:
    with open(path, 'rb') as f:
        data = bytearray(f.read())
    count = 0
    for rx in COMPILED:
        for m in list(rx.finditer(data)):
            start, end = m.start(), m.end()
            seg = data[start:end]
            if len(seg) < len(_SENTINEL):
                replacement = b'\x00' * len(seg)
            else:
                replacement = _SENTINEL + b'\x00' * (len(seg) - len(_SENTINEL))
            if len(replacement) != len(seg):
                continue
            data[start:end] = replacement
            count += 1
    if count:
        with open(path, 'wb') as f:
            f.write(data)
    return count


if __name__ == '__main__':
    total = 0
    for p in sys.argv[1:]:
        try:
            c = neutralize(p)
        except Exception as e:
            print(f'{p}: 跳过 ({e})')
            continue
        total += c
        print(f'{p}: {c}')
    print(f'TOTAL paths neutralized: {total}')
