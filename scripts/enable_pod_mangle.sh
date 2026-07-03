#!/bin/bash
# =============================================
#   enable_pod_mangle.sh —— 在 ios/Podfile 幂等注入 cocoapods-mangle
#
#   cocoapods-mangle 是编译期插件：pod install 时给依赖的符号（类、常量、
#   Category、C 符号）加一个统一前缀做命名空间。原用途是消解重复符号冲突，
#   顺带把第三方 Pod 的符号指纹整体改掉 —— 对 4.3(a) 的二进制相似度有帮助，
#   且是编译期处理，比成品包改 Mach-O 安全得多。
#
#   本脚本会做（都幂等）：
#     1) 若未安装则尝试 gem install cocoapods-mangle
#     2) 在 Podfile 顶部插入 `plugin 'cocoapods-mangle', :prefix => '<seed 派生前缀>'`
#
#   之后正常 `pod install` 即生效。移除请传 --disable。
#
#   用法:
#     enable_pod_mangle.sh [--podfile ios/Podfile] [--seed <s>] [--prefix <P>] [--disable] [-d]
# =============================================
set -euo pipefail

log()  { printf '\033[0;34m[mangle]\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m[mangle]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[mangle]\033[0m %s\n' "$*"; }
err()  { printf '\033[0;31m[mangle]\033[0m %s\n' "$*" >&2; }

PODFILE="ios/Podfile"
SEED=""
PREFIX=""
DISABLE=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --podfile) PODFILE="$2"; shift 2 ;;
        --seed) SEED="$2"; shift 2 ;;
        --prefix) PREFIX="$2"; shift 2 ;;
        --disable) DISABLE=true; shift ;;
        -d|--dry-run) DRY_RUN=true; shift ;;
        -h|--help) sed -n '1,25p' "$0"; exit 0 ;;
        *) err "未知参数: $1"; exit 2 ;;
    esac
done

[[ -f "$PODFILE" ]] || { err "Podfile 不存在: $PODFILE"; exit 1; }

MARKER_BEGIN="# >>> zt cocoapods-mangle (auto) >>>"
MARKER_END="# <<< zt cocoapods-mangle (auto) <<<"

# 先移除旧的自动块（保证幂等）
strip_block() {
    if grep -qF "$MARKER_BEGIN" "$PODFILE"; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log "[DRY-RUN] 将移除已存在的 mangle 注入块"
        else
            /usr/bin/sed -i '' "/$(printf '%s' "$MARKER_BEGIN" | sed 's/[.[\*^$/]/\\&/g')/,/$(printf '%s' "$MARKER_END" | sed 's/[.[\*^$/]/\\&/g')/d" "$PODFILE"
        fi
    fi
}

if [[ "$DISABLE" == "true" ]]; then
    strip_block
    ok "已移除 cocoapods-mangle 注入块（下次 pod install 生效）"
    exit 0
fi

# 计算 seed 派生前缀（合法 C/ObjC 标识符前缀，字母开头）
if [[ -z "$PREFIX" ]]; then
    if [[ -n "$SEED" ]]; then
        h="$(printf '%s' "$SEED" | (md5 -q 2>/dev/null || md5sum | cut -d' ' -f1))"
        PREFIX="ZT$(printf '%s' "${h:0:6}" | tr '[:lower:]' '[:upper:]')"
    else
        PREFIX="ZTMangle"
    fi
fi
# 兜底：确保以字母开头、仅含字母数字
PREFIX="$(printf '%s' "$PREFIX" | tr -cd 'A-Za-z0-9')"
[[ "$PREFIX" =~ ^[A-Za-z] ]] || PREFIX="Z$PREFIX"

strip_block

BLOCK="$MARKER_BEGIN
# 需先: gem install cocoapods-mangle
# 给第三方 Pod 符号加前缀做命名空间，改二进制指纹（编译期，安全）。
plugin 'cocoapods-mangle', :prefix => '$PREFIX'
$MARKER_END"

if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY-RUN] 将在 $PODFILE 顶部注入（prefix=$PREFIX）:"
    printf '%s\n' "$BLOCK" | sed 's/^/    /'
    exit 0
fi

# 插到 platform :ios 行之上，保证 plugin 在最顶部生效。
ensure_cocoapods_mangle_gem() {
    if gem list -i cocoapods-mangle >/dev/null 2>&1; then
        return 0
    fi
    log "cocoapods-mangle 未安装，尝试 gem install（每台 Mac 只需成功一次）..."
    if gem install cocoapods-mangle --no-document 2>/dev/null \
        || gem install cocoapods-mangle 2>/dev/null; then
        ok "cocoapods-mangle 已安装"
        return 0
    fi
    warn "自动 gem install 失败，请在本机手动执行: gem install cocoapods-mangle"
    warn "未安装时 Podfile 仍会注入 plugin 行，pod install 可能报错；资源/IPA 加固不受影响。"
    return 1
}

if [[ "$DRY_RUN" != "true" ]]; then
    ensure_cocoapods_mangle_gem || true
fi

# 通过文件传入 block，规避 BWK awk 不支持变量内换行的问题。
TMP="$(mktemp)"
BLOCKFILE="$(mktemp)"
printf '%s\n' "$BLOCK" > "$BLOCKFILE"
awk -v blockfile="$BLOCKFILE" '
    BEGIN {
        done=0
        while ((getline line < blockfile) > 0) {
            block = (block == "" ? line : block "\n" line)
        }
        close(blockfile)
    }
    done==0 && /^[[:space:]]*platform[[:space:]]/ {
        print block; done=1
    }
    { print }
    END {
        if (done==0) { print block }
    }
' "$PODFILE" > "$TMP" && mv "$TMP" "$PODFILE"
rm -f "$BLOCKFILE"

ok "已注入 cocoapods-mangle（prefix=$PREFIX）到 $PODFILE"
log "随后执行 pod install（或重跑 build / obfuscate_frameworks run）即生效。"
