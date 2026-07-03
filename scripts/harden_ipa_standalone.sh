#!/bin/bash
# =============================================
#   harden_ipa_standalone.sh —— 独立 IPA 加固（非 AB 包工厂）
#
#   任意来源的 .ipa：资源指纹差异化 / 可选 Mach-O，可选重签。
#   不依赖 build_config.json、不跑 flutter build。
#
#   用法:
#     harden_ipa_standalone.sh --ipa /path/in.ipa [选项]
#
#   选项:
#     --out PATH           输出 IPA（默认: 同目录 <原名>_hardened.ipa）
#     --seed SEED          差异化 seed（默认从 IPA 内 Info.plist 读 Bundle ID）
#     --resources          资源指纹差异化（默认开）
#     --no-resources       关闭资源差异化
#     --macho              启用 Mach-O 类名混淆（中高风险）
#     --profile PATH       描述文件：填则加固后重签（可安装/上传）
#     --bundle-id ID       重签 Bundle ID（默认从 profile / IPA 推断）
#     --identity NAME      签名身份（默认钥匙串自动匹配）
#     -d, --dry-run        仅预览
# =============================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ipa_hardening_lib.sh
source "$SCRIPT_DIR/ipa_hardening_lib.sh"

IPA_IN=""
IPA_OUT=""
SEED=""
DO_RESOURCES=true
DO_MACHO=false
PROFILE=""
BUNDLE_ID=""
IDENTITY=""
DRY_RUN=false

log()  { printf '\033[0;34m[ipa-tool]\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m[ipa-tool]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[ipa-tool]\033[0m %s\n' "$*"; }
err()  { printf '\033[0;31m[ipa-tool]\033[0m %s\n' "$*" >&2; }

usage() {
    sed -n '1,22p' "$0"
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ipa) IPA_IN="$2"; shift 2 ;;
        --out) IPA_OUT="$2"; shift 2 ;;
        --seed) SEED="$2"; shift 2 ;;
        --resources) DO_RESOURCES=true; shift ;;
        --no-resources) DO_RESOURCES=false; shift ;;
        --macho) DO_MACHO=true; shift ;;
        --profile) PROFILE="$2"; shift 2 ;;
        --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
        --identity) IDENTITY="$2"; shift 2 ;;
        -d|--dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage 0 ;;
        *) err "未知参数: $1"; usage 2 ;;
    esac
done

[[ -n "$IPA_IN" ]] || { err "必须指定 --ipa"; usage 2; }
[[ -f "$IPA_IN" ]] || { err "IPA 不存在: $IPA_IN"; exit 1; }

IPA_IN="$(cd "$(dirname "$IPA_IN")" && pwd)/$(basename "$IPA_IN")"

if [[ -z "$IPA_OUT" ]]; then
    base="${IPA_IN%.ipa}"
    IPA_OUT="${base}_hardened.ipa"
fi
case "$IPA_OUT" in
    /*) ;;
    *) IPA_OUT="$(pwd)/$IPA_OUT" ;;
esac

# 从 IPA 读 Bundle ID（作 seed / 重签默认值）
read_bundle_from_ipa() {
    local ipa="$1"
    local tmp
    tmp="$(mktemp -d)"
    unzip -q "$ipa" "Payload/*.app/Info.plist" -d "$tmp" 2>/dev/null || true
    local plist
    plist="$(find "$tmp/Payload" -name Info.plist 2>/dev/null | head -1)"
    if [[ -f "$plist" ]]; then
        /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true
    fi
    rm -rf "$tmp"
}

if [[ -z "$SEED" ]]; then
    SEED="$(read_bundle_from_ipa "$IPA_IN")"
    [[ -n "$SEED" ]] || SEED="zt_standalone_$(date +%s)"
    log "seed 未指定，使用: $SEED"
fi

if [[ -z "$BUNDLE_ID" ]]; then
    BUNDLE_ID="$(read_bundle_from_ipa "$IPA_IN")"
fi

log "输入:   $IPA_IN"
log "输出:   $IPA_OUT"
log "seed:   $SEED"
log "资源:   $DO_RESOURCES  Mach-O: $DO_MACHO  重签: $([ -n "$PROFILE" ] && echo yes || echo no)"

if [[ "$DRY_RUN" == "true" ]]; then
    warn "[DRY-RUN] 未写入文件"
    exit 0
fi

mkdir -p "$(dirname "$IPA_OUT")"

if [[ -n "$PROFILE" ]]; then
    [[ -f "$PROFILE" ]] || { err "描述文件不存在: $PROFILE"; exit 1; }
    PROFILE="$(cd "$(dirname "$PROFILE")" && pwd)/$(basename "$PROFILE")"
    cp -f "$IPA_IN" "$IPA_OUT"
    if [[ -z "$IDENTITY" ]]; then
        local_team=""
        prof_plist="$(mktemp)"
        security cms -D -i "$PROFILE" > "$prof_plist" 2>/dev/null || true
        local_team="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "$prof_plist" 2>/dev/null || true)"
        rm -f "$prof_plist"
        IDENTITY="$(resolve_codesign_identity "$local_team" "")"
    fi
    [[ -n "$IDENTITY" ]] || { err "未找到签名身份，请传 --identity"; exit 1; }
    log "重签身份: $IDENTITY"
    harden_and_resign_ipa "$IPA_OUT" "$PROFILE" "$IDENTITY" "$BUNDLE_ID" \
        "$SEED" "$DO_RESOURCES" "$DO_MACHO" "$SCRIPT_DIR"
else
    warn "未提供 --profile：输出为未签名 IPA，需自行 resign 后才能安装"
    bash "$SCRIPT_DIR/obfuscate_ipa.sh" --ipa "$IPA_IN" --out "$IPA_OUT" --seed "$SEED" \
        $([[ "$DO_RESOURCES" == "true" ]] && echo --resources) \
        $([[ "$DO_MACHO" == "true" ]] && echo --macho)
fi

ok "完成: $IPA_OUT"
