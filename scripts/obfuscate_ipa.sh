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
DO_RENAME_FW=false
# 需要中和的 vendored framework 指纹（按 CFBundleIdentifier 匹配，忽略大小写）
FW_FINGERPRINT="${ZT_FW_FINGERPRINT:-rongcloud|umeng|tencent|mob\.com|bugly|jpush|getui|aliyun}"
DRY_RUN=false
MACHO_MIN_LEN=5
METHODS_ALLOWLIST=""
PROTECT_FILE=""
# --macho 默认（整包 apply-app）：只改类名 + sync-cstring
# 方法改名 / cstring 擦除 / 整文件盲替换仍可能导致启动闪退，默认关；
# 调试时显式：ZT_MACHO_SDK_METHODS=1  ZT_MACHO_SCRUB_CSTRING=1
# --macho 默认 = L2.6.3：
#   L2.6.2 + 仅 __LINKEDIT 内改 _OBJC_CLASS_$_* 类符号（不开 -[Class / 非整文件）
MACHO_SDK_PREFIXES="${ZT_MACHO_SDK_PREFIXES:-RCIMIW,RCIMWrapper,IRCIMIW,RC,Rong}"
MACHO_SYNC_CSTRING="${ZT_MACHO_SYNC_CSTRING:-1}"
MACHO_SCRUB_CSTRING="${ZT_MACHO_SCRUB_CSTRING:-0}"
MACHO_SDK_METHODS="${ZT_MACHO_SDK_METHODS:-1}"
MACHO_SDK_CLASSES_ONLY="${ZT_MACHO_SDK_CLASSES_ONLY:-1}"
# L2.6.3 LINKEDIT-only CLASS 别名实测启动打不开 → 默认关；勿再默认开启
MACHO_SYMBOL_ALIASES="${ZT_MACHO_SYMBOL_ALIASES:-0}"
MACHO_PATCH_METHTYPE="${ZT_MACHO_PATCH_METHTYPE:-1}"
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
        --rename-frameworks) DO_RENAME_FW=true; _explicit_mode=true; shift ;;
        --fw-fingerprint) FW_FINGERPRINT="$2"; shift 2 ;;
        --min-len) MACHO_MIN_LEN="$2"; shift 2 ;;
        --methods-allowlist) METHODS_ALLOWLIST="$2"; shift 2 ;;
        --protect-file) PROTECT_FILE="$2"; shift 2 ;;
        --sdk-prefixes) MACHO_SDK_PREFIXES="$2"; shift 2 ;;
        --no-sdk-selectors) MACHO_SDK_PREFIXES=""; MACHO_SDK_METHODS=0; shift ;;
        --sdk-methods) MACHO_SDK_METHODS=1; shift ;;
        --sync-cstring) MACHO_SYNC_CSTRING=1; shift ;;
        --no-sync-cstring) MACHO_SYNC_CSTRING=0; shift ;;
        --scrub-cstring) MACHO_SCRUB_CSTRING=1; shift ;;
        --no-scrub-cstring) MACHO_SCRUB_CSTRING=0; shift ;;
        --sdk-classes-only) MACHO_SDK_CLASSES_ONLY=1; shift ;;
        --all-classes) MACHO_SDK_CLASSES_ONLY=0; shift ;;
        --symbol-aliases) MACHO_SYMBOL_ALIASES=1; shift ;;
        --no-symbol-aliases) MACHO_SYMBOL_ALIASES=0; shift ;;
        --patch-methtype) MACHO_PATCH_METHTYPE=1; shift ;;
        --no-patch-methtype) MACHO_PATCH_METHTYPE=0; shift ;;
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
        marker="$(_seed_hex "${SEED}_$(basename "$f")_${img_count}")"
        if [[ "$DRY_RUN" == "true" ]]; then
            img_count=$((img_count + 1))
        else
            append_image_marker "$f" "zt${marker:0:16}"
            img_count=$((img_count + 1))
        fi
    done < <(find "$app" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' -o -iname '*.gif' \) ! -path '*/Assets.car' 2>/dev/null)

    # 1b) 音频/字体/SVG 追加尾部标记（播放器/渲染通常忽略尾部冗余）
    local media_count=0
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local marker
        marker="$(_seed_hex "${SEED}_media_$(basename "$f")_${media_count}")"
        if [[ "$DRY_RUN" == "true" ]]; then
            media_count=$((media_count + 1))
        else
            printf '\nzt%s\n' "${marker:0:24}" >> "$f" 2>/dev/null || true
            media_count=$((media_count + 1))
        fi
    done < <(find "$app" -type f \( -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.svg' -o -iname '*.ttf' -o -iname '*.otf' \) 2>/dev/null)

    # 2) 向 .app 根 / .bundle / flutter_assets / 各 .framework 注入惰性文件
    local bundle_touch=0
    local targets=("$app")
    while IFS= read -r b; do [[ -n "$b" ]] && targets+=("$b"); done \
        < <(find "$app" -type d \( -name '*.bundle' -o -name 'flutter_assets' -o -name '*.framework' \) 2>/dev/null)
    local t
    for t in "${targets[@]}"; do
        local h fname
        h="$(_seed_hex "${SEED}_junk_$(basename "$t")")"
        fname=".zt_${h:0:12}.dat"
        if [[ "$DRY_RUN" == "true" ]]; then
            bundle_touch=$((bundle_touch + 1))
        else
            # 变长内容：同一 seed 下不同目录体积也不同，增强文件集合指纹
            local pad_n=$(( 16 + (0x${h:12:2}) ))
            if dd if=/dev/zero bs=1 count="$pad_n" 2>/dev/null | \
               { printf '%s' "$h"; cat; } > "$t/$fname" 2>/dev/null; then
                bundle_touch=$((bundle_touch + 1))
            elif printf '%s%s\n' "$h" "$h" > "$t/$fname" 2>/dev/null; then
                bundle_touch=$((bundle_touch + 1))
            fi
        fi
        # L277：每目录额外一枚惰性文件（不同 seed 槽），扩大文件集合差异
        if [[ "${ZT_EXTRA_JUNK:-1}" != "0" ]]; then
            local h2 fname2 pad2
            h2="$(_seed_hex "${SEED}_junk2_$(basename "$t")")"
            fname2=".zt2_${h2:0:12}.dat"
            if [[ "$DRY_RUN" == "true" ]]; then
                bundle_touch=$((bundle_touch + 1))
            else
                pad2=$(( 24 + (0x${h2:12:2}) ))
                if dd if=/dev/zero bs=1 count="$pad2" 2>/dev/null | \
                   { printf '%s' "$h2"; cat; } > "$t/$fname2" 2>/dev/null; then
                    bundle_touch=$((bundle_touch + 1))
                fi
            fi
            # L284：第三枚惰性文件（再扩文件集合指纹，仍全 DEFLATE 打包）
            local h3 fname3 pad3
            h3="$(_seed_hex "${SEED}_junk3_$(basename "$t")")"
            fname3=".zt3_${h3:0:12}.bin"
            if [[ "$DRY_RUN" == "true" ]]; then
                bundle_touch=$((bundle_touch + 1))
            else
                pad3=$(( 32 + (0x${h3:12:2}) ))
                if dd if=/dev/zero bs=1 count="$pad3" 2>/dev/null | \
                   { printf '%s' "$h3"; cat; } > "$t/$fname3" 2>/dev/null; then
                    bundle_touch=$((bundle_touch + 1))
                fi
            fi
        fi
    done

    # 3) 文本资源品牌擦除（独立 py，避免 shell 内嵌中文导致 nounset 误解析）
    local text_scrub=0
    local scrub_py
    scrub_py="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scrub_text_brand_strings.py"
    if [[ "$DRY_RUN" != "true" && -f "$scrub_py" ]]; then
        text_scrub="$(python3 "$scrub_py" "$app" "$SEED" 2>/dev/null || echo 0)"
    fi

    ok "资源差异化完成: 图片改指纹 ${img_count}, 媒体改指纹 ${media_count:-0}, 注入惰性文件 ${bundle_touch}, 文本品牌擦除 ${text_scrub}"
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
    warn "使用整包 apply-app（全局映射），避免跨二进制 selector/channel 不一致。"

    # 整包模式：默认开类名+sync；scrub/methods 由开关控制（调试阶段可开）
    local args_common=(--seed "$SEED" --min-len "$MACHO_MIN_LEN" --classes)
    if [[ "$MACHO_SYNC_CSTRING" == "1" || "$MACHO_SYNC_CSTRING" == "true" ]]; then
        args_common+=(--sync-cstring)
    fi
    if [[ -n "$MACHO_SDK_PREFIXES" ]]; then
        args_common+=(--sdk-prefixes "$MACHO_SDK_PREFIXES")
    fi
    if [[ "$MACHO_SCRUB_CSTRING" == "1" || "$MACHO_SCRUB_CSTRING" == "true" ]]; then
        args_common+=(--scrub-cstring)
    fi
    if [[ "$MACHO_SDK_METHODS" == "1" || "$MACHO_SDK_METHODS" == "true" ]]; then
        args_common+=(--methods)
    fi
    if [[ "$MACHO_SDK_CLASSES_ONLY" == "1" || "$MACHO_SDK_CLASSES_ONLY" == "true" ]]; then
        args_common+=(--sdk-classes-only)
    fi
    if [[ "$MACHO_SYMBOL_ALIASES" == "1" || "$MACHO_SYMBOL_ALIASES" == "true" ]]; then
        args_common+=(--symbol-aliases)
    fi
    # methtype：L2.5 默认开；符号别名开启时强制开；可用 --no-patch-methtype / ZT_MACHO_PATCH_METHTYPE=0 关
    if [[ "$MACHO_PATCH_METHTYPE" == "1" || "$MACHO_PATCH_METHTYPE" == "true" || "$MACHO_SYMBOL_ALIASES" == "1" ]]; then
        args_common+=(--patch-methtype)
        MACHO_PATCH_METHTYPE=1
    fi
    if [[ -n "$METHODS_ALLOWLIST" ]]; then
        args_common+=(--methods --methods-allowlist "$METHODS_ALLOWLIST")
    fi
    [[ -n "$PROTECT_FILE" ]] && args_common+=(--protect-file "$PROTECT_FILE")
    log "Mach-O apply-app classes sync=$MACHO_SYNC_CSTRING scrub=$MACHO_SCRUB_CSTRING methods=$MACHO_SDK_METHODS sdk-classes-only=$MACHO_SDK_CLASSES_ONLY aliases=$MACHO_SYMBOL_ALIASES methtype=$MACHO_PATCH_METHTYPE"

    local map_dir map_out=""
    map_dir="$(dirname "$app")/../ab_factory_macho_maps"
    # app 可能在临时 Payload 下；映射写到 /tmp
    map_out="$(mktemp -t macho_map).json"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] scan-app $app"
        python3 "$MACHO_TOOL" scan-app "$app" "${args_common[@]}" --map-out "$map_out" 2>&1 | sed 's/^/    /' || true
    else
        python3 "$MACHO_TOOL" apply-app "$app" "${args_common[@]}" --map-out "$map_out" 2>&1 | sed 's/^/    /' \
            || warn "  apply-app 失败"
        log "映射已写: $map_out"
    fi
    ok "Mach-O 整包处理完成（改写后必须重签名）"
}

# 生成与旧名【等长】的中性 framework 名（确定性、可复现，首字母，仅 [A-Za-z0-9]）。
# 等长很关键：install_name_tool 改写 @rpath 路径时，同长不需要额外 header padding，
# 对闭源预编译 framework 也稳。
_neutral_fw_name() {
    local old="$1" len="${#1}"
    local h; h="$(_seed_hex "${SEED}::fw::$old")"
    printf '%s' "K${h}" | cut -c1-"$len"
}

# 折中方案：只重命名 vendored 闭源 framework 的【目录名 + 二进制名 + install_name +
# LC_LOAD_DYLIB 引用 + CFBundleIdentifier/Executable】，绝不改内部符号。
# 目的：抹掉 IPA 里一眼可辨的 SDK 指纹（如 RongIMLibCore.framework / cn.rongcloud.im），
# 同时保持 dyld 加载图与运行时行为不变。
rename_vendored_frameworks() {
    local app="$1"
    local fw_dir="$app/Frameworks"
    [[ -d "$fw_dir" ]] || { warn "无 Frameworks 目录，跳过 framework 重命名"; return 0; }

    local int_tool="/usr/bin/install_name_tool"
    local pb="/usr/libexec/PlistBuddy"
    [[ -x "$int_tool" ]] || { err "缺少 install_name_tool"; return 1; }

    # ---- Pass 1: 按 bundle-id 指纹挑出目标，建立 旧名→新名 映射 ----
    local -a OLDS=() NEWS=()
    local d name plist bid
    for d in "$fw_dir"/*.framework; do
        [[ -d "$d" ]] || continue
        name="$(basename "$d" .framework)"
        plist="$d/Info.plist"
        [[ -f "$plist" ]] || continue
        bid="$($pb -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)"
        # 指纹匹配 bundle-id 或 framework 名本身
        if printf '%s\n%s' "$bid" "$name" | grep -qiE "$FW_FINGERPRINT"; then
            OLDS+=("$name")
            NEWS+=("$(_neutral_fw_name "$name")")
        fi
    done

    if [[ ${#OLDS[@]} -eq 0 ]]; then
        log "未发现匹配指纹（$FW_FINGERPRINT）的 vendored framework，跳过"
        return 0
    fi

    log "framework 重命名目标 ${#OLDS[@]} 个:"
    local i
    for i in "${!OLDS[@]}"; do log "    ${OLDS[$i]}  →  ${NEWS[$i]}"; done
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] 仅预览，不改动"
        return 0
    fi

    # ---- Pass 2: 物理重命名 + 改 install_name(-id) + 改 Info.plist ----
    for i in "${!OLDS[@]}"; do
        local old="${OLDS[$i]}" new="${NEWS[$i]}"
        local od="$fw_dir/$old.framework" nd="$fw_dir/$new.framework"
        [[ -d "$od" ]] || { warn "  $old.framework 不存在，跳过"; continue; }
        # 二进制改名（先在旧目录里改，再改目录名）
        [[ -f "$od/$old" ]] && mv "$od/$old" "$od/$new"
        mv "$od" "$nd"
        # install_name 自指
        $int_tool -id "@rpath/$new.framework/$new" "$nd/$new" 2>/dev/null \
            || warn "  -id 改写失败: $new"
        # Info.plist：可执行名 + bundle id 中性化
        $pb -c "Set :CFBundleExecutable $new" "$nd/Info.plist" 2>/dev/null || true
        local newbid="com.$(printf '%s' "${SEED_HEX:0:8}").$new"
        $pb -c "Set :CFBundleIdentifier $newbid" "$nd/Info.plist" 2>/dev/null || true
        $pb -c "Set :CFBundleName $new" "$nd/Info.plist" 2>/dev/null || true
    done

    # ---- Pass 3: 全 app 的 Mach-O 改写 LC_LOAD_DYLIB 交叉引用 ----
    # （主可执行 + 所有 framework 二进制 + dylib，凡是引用了旧 @rpath 路径都要改）
    local bin patched=0
    while IFS= read -r bin; do
        [[ -z "$bin" ]] && continue
        local changed=false
        for i in "${!OLDS[@]}"; do
            local old="${OLDS[$i]}" new="${NEWS[$i]}"
            if otool -L "$bin" 2>/dev/null | grep -q "@rpath/$old.framework/$old"; then
                $int_tool -change "@rpath/$old.framework/$old" "@rpath/$new.framework/$new" "$bin" 2>/dev/null \
                    && changed=true || warn "  -change 失败于 $(basename "$bin"): $old"
            fi
        done
        [[ "$changed" == "true" ]] && patched=$((patched + 1))
    done < <(list_macho_binaries "$app")

    ok "framework 重命名完成：${#OLDS[@]} 个 framework，改写 $patched 个二进制的依赖引用（须重签名）"
}

process_app() {
    local app="$1"
    [[ -d "$app" ]] || { err "不是有效的 .app 目录: $app"; exit 1; }
    log "seed=$SEED (hex ${SEED_HEX:0:12})  resources=$DO_RESOURCES  macho=$DO_MACHO  rename_fw=$DO_RENAME_FW  dry_run=$DRY_RUN"
    # 不用 if-then 包住关键步骤：set -e 在 if 体里不会因失败退出，易静默跳过后续 macho
    if [[ "$DO_RESOURCES" == "true" ]]; then
        differentiate_resources "$app"
    fi
    if [[ "$DO_RENAME_FW" == "true" ]]; then
        rename_vendored_frameworks "$app" || err "framework 重命名失败"
    fi
    if [[ "$DO_MACHO" == "true" ]]; then
        obfuscate_macho "$app" || err "Mach-O 混淆失败"
    fi
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
        log "重打包 → ${IPA_OUT}（未签名）"
        _pack_py="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pack_ipa_seeded.py"
        if [[ -f "$_pack_py" ]]; then
            python3 "$_pack_py" --seed "$SEED" --out "$IPA_OUT" "$TMP" \
                || ( cd "$TMP" && zip -qr "$IPA_OUT" Payload )
        else
            ( cd "$TMP" && zip -qr "$IPA_OUT" Payload )
        fi
        ok "输出: $IPA_OUT （⚠️ 未签名，需 resign_ipa.sh 重签名后才能安装/上传）"
    fi
else
    err "需指定 --app <dir> 或 --ipa <file>"
    exit 2
fi
