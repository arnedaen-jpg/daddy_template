#!/bin/bash
# =============================================
#   obfuscate_ipa.sh —— 成品包（.app / .ipa）层混淆
#
#   面向 App Store 4.3(a)：在「已编译、未签名」的产物上做差异化，无需源码。
#   三类手段（对应马甲包实践）：
#     1) 资源指纹差异化（--resources，默认开，低风险）
#        - 给图片尾部追加 seed 派生字节 → 改 MD5（不改内容、不重命名，运行安全）
#        - 向 .app / .bundle 注入 seed 派生惰性资源文件 → 改包内文件集合指纹
#     2) Mach-O 符号混淆（--macho，可选，中高风险，需真机回归）
#        - 就地等长改写主可执行文件与 Frameworks 的 ObjC 类名字符串
#        - 方法名默认不动（selector 全局 unique，改名极易崩），仅在提供白名单时改
#     3) cocoapods-mangle（编译期，见 enable_pod_mangle.sh，不在本脚本内）
#
#   ⚠️ 任何 Mach-O 改写都会使已有签名失效：本脚本只改产物，**不负责签名**。
#      必须由调用方（build_and_resign.sh / resign_ipa.sh）在其后重签名。
#
#   用法：
#     obfuscate_ipa.sh --app <Payload/Xxx.app> --seed <s> [--resources] [--macho] [-d]
#     obfuscate_ipa.sh --ipa <in.ipa> --out <out.ipa> --seed <s> [--macho] [-d]
#       （--ipa 模式仅解包/处理/重打包，不重签名）
# =============================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACHO_TOOL="$SCRIPT_DIR/macho_symbol_obfuscator.py"

log()  { printf '\033[0;34m[ipa-obf]\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m[ipa-obf]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[ipa-obf]\033[0m %s\n' "$*"; }
err()  { printf '\033[0;31m[ipa-obf]\033[0m %s\n' "$*" >&2; }

APP_PATH=""
IPA_IN=""
IPA_OUT=""
SEED=""
DO_RESOURCES=false
DO_MACHO=false
DRY_RUN=false
MACHO_MIN_LEN=5
METHODS_ALLOWLIST=""
PROTECT_FILE=""
# 未显式选择手段时，默认只开启低风险的资源差异化
_explicit_mode=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) APP_PATH="$2"; shift 2 ;;
        --ipa) IPA_IN="$2"; shift 2 ;;
        --out) IPA_OUT="$2"; shift 2 ;;
        --seed) SEED="$2"; shift 2 ;;
        --resources) DO_RESOURCES=true; _explicit_mode=true; shift ;;
        --macho) DO_MACHO=true; _explicit_mode=true; shift ;;
        --min-len) MACHO_MIN_LEN="$2"; shift 2 ;;
        --methods-allowlist) METHODS_ALLOWLIST="$2"; shift 2 ;;
        --protect-file) PROTECT_FILE="$2"; shift 2 ;;
        -d|--dry-run) DRY_RUN=true; shift ;;
        -h|--help) sed -n '1,40p' "$0"; exit 0 ;;
        *) err "未知参数: $1"; exit 2 ;;
    esac
done

[[ "$_explicit_mode" == "false" ]] && DO_RESOURCES=true

if [[ -z "$SEED" ]]; then
    err "必须提供 --seed（建议用 Bundle ID 或 sha1(bundleId+version)，同包可复现）"
    exit 2
fi

# 派生一个稳定的 12 位十六进制
_seed_hex() { printf '%s' "$1" | (md5 -q 2>/dev/null || md5sum | cut -d' ' -f1); }
SEED_HEX="$(_seed_hex "$SEED")"

# ---- 资源差异化：给图片追加 seed 字节（改 MD5，不改可见内容） ----
append_image_marker() {
    local f="$1" marker="$2"
    local ext="${f##*.}"; ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
    case "$ext" in
        png)      printf '\x00\x00\x00\x00tEXtComment\x00%s' "$marker" >> "$f" 2>/dev/null || true ;;
        jpg|jpeg) printf '\xFF\xFE\x00\x22%s' "$marker" >> "$f" 2>/dev/null || true ;;
        webp)     printf 'EXIF%s' "$marker" >> "$f" 2>/dev/null || true ;;
        gif)      printf '\x21\xFE%s\x00' "$marker" >> "$f" 2>/dev/null || true ;;
    esac
}

differentiate_resources() {
    local app="$1"
    log "资源差异化: $app"
    local img_count=0

    # 1) 图片 MD5 差异化（不重命名，避免破坏代码/nib 里的按名引用）
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        # 跳过 Assets.car（编译后的资源目录，追加字节可能损坏），只处理散图
        local marker
        marker="$(_seed_hex "${SEED}_$(basename "$f")_$img_count")"
        if [[ "$DRY_RUN" == "true" ]]; then
            img_count=$((img_count + 1))
        else
            append_image_marker "$f" "zt${marker:0:16}"
            img_count=$((img_count + 1))
        fi
    done < <(find "$app" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' -o -iname '*.gif' \) ! -path '*/Assets.car' 2>/dev/null)

    # 2) 向 .app 根与各 .bundle 注入 seed 派生惰性资源文件（改包内文件集合指纹）
    local bundle_touch=0
    local targets=("$app")
    while IFS= read -r b; do [[ -n "$b" ]] && targets+=("$b"); done \
        < <(find "$app" -type d -name '*.bundle' 2>/dev/null)
    local t
    for t in "${targets[@]}"; do
        local h fname
        h="$(_seed_hex "${SEED}_junk_$(basename "$t")")"
        fname=".zt_${h:0:12}.dat"
        if [[ "$DRY_RUN" == "true" ]]; then
            bundle_touch=$((bundle_touch + 1))
        elif printf '%s%s\n' "$h" "$h" > "$t/$fname" 2>/dev/null; then
            bundle_touch=$((bundle_touch + 1))
        fi
    done

    ok "资源差异化完成: 图片改指纹 $img_count，注入惰性文件 $bundle_touch"
}

# ---- Mach-O 符号混淆：主可执行文件 + Frameworks ---- 
list_macho_binaries() {
    local app="$1"
    # 主可执行文件（CFBundleExecutable）
    local exe
    exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist" 2>/dev/null || true)"
    [[ -n "$exe" && -f "$app/$exe" ]] && printf '%s\n' "$app/$exe"
    # Frameworks / dylib
    if [[ -d "$app/Frameworks" ]]; then
        find "$app/Frameworks" -type f \( -name '*.dylib' -o -perm -u+x \) 2>/dev/null \
            | while IFS= read -r f; do
                # framework 内的主二进制通常与 .framework 同名，无扩展名
                file "$f" 2>/dev/null | grep -q 'Mach-O' && printf '%s\n' "$f"
              done
    fi
}

obfuscate_macho() {
    local app="$1"
    if [[ ! -f "$MACHO_TOOL" ]]; then
        err "找不到 Mach-O 工具: $MACHO_TOOL"; return 1
    fi
    warn "Mach-O 符号混淆为中高风险操作，务必真机回归后再进产线。"
    local args_common=(--seed "$SEED" --min-len "$MACHO_MIN_LEN" --classes)
    [[ -n "$METHODS_ALLOWLIST" ]] && args_common+=(--methods --methods-allowlist "$METHODS_ALLOWLIST")
    [[ -n "$PROTECT_FILE" ]] && args_common+=(--protect-file "$PROTECT_FILE")

    local n=0
    while IFS= read -r bin; do
        [[ -z "$bin" ]] && continue
        n=$((n + 1))
        if [[ "$DRY_RUN" == "true" ]]; then
            log "[DRY-RUN] scan $bin"
            python3 "$MACHO_TOOL" scan "$bin" "${args_common[@]}" 2>&1 | sed 's/^/    /' || true
        else
            log "apply $bin"
            python3 "$MACHO_TOOL" apply "$bin" "${args_common[@]}" 2>&1 | sed 's/^/    /' || warn "  处理失败，跳过: $bin"
        fi
    done < <(list_macho_binaries "$app")
    ok "Mach-O 处理二进制数: $n（改写后必须重签名）"
}

process_app() {
    local app="$1"
    [[ -d "$app" ]] || { err "不是有效的 .app 目录: $app"; exit 1; }
    log "seed=$SEED (hex ${SEED_HEX:0:12})  resources=$DO_RESOURCES  macho=$DO_MACHO  dry_run=$DRY_RUN"
    [[ "$DO_RESOURCES" == "true" ]] && differentiate_resources "$app"
    [[ "$DO_MACHO" == "true" ]] && obfuscate_macho "$app"
}

# ---- 主流程 ----
if [[ -n "$APP_PATH" ]]; then
    process_app "$APP_PATH"
    ok "完成（.app 就地处理，未签名——请由调用方重签名）"
elif [[ -n "$IPA_IN" ]]; then
    [[ -f "$IPA_IN" ]] || { err "IPA 不存在: $IPA_IN"; exit 1; }
    [[ -z "$IPA_OUT" ]] && { err "--ipa 模式需 --out 指定输出"; exit 2; }
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    log "解包 $IPA_IN"
    ( cd "$TMP" && unzip -q "$IPA_IN" )
    APP="$(find "$TMP/Payload" -maxdepth 1 -name '*.app' -type d | head -1)"
    [[ -d "$APP" ]] || { err "IPA 内未找到 .app"; exit 1; }
    process_app "$APP"
    if [[ "$DRY_RUN" != "true" ]]; then
        log "重打包 → $IPA_OUT（未签名）"
        ( cd "$TMP" && zip -qr "$IPA_OUT" Payload )
        ok "输出: $IPA_OUT （⚠️ 未签名，需 resign_ipa.sh 重签名后才能安装/上传）"
    fi
else
    err "需指定 --app <dir> 或 --ipa <file>"
    exit 2
fi
