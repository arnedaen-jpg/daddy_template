#!/bin/bash
# ipa_hardening_lib.sh —— AB 包工厂成品包加固共享函数
# 被 build_flutter_ipa.sh / resign_ipa.sh 等 source 使用。
set -euo pipefail

# 解析签名身份：优先用传入值，否则按 Team ID 在钥匙串查找
resolve_codesign_identity() {
    local team_id="${1:-}"
    local override="${2:-}"
    if [[ -n "$override" ]]; then
        printf '%s' "$override"
        return 0
    fi
    local id=""
    if [[ -n "$team_id" ]]; then
        id="$(security find-identity -v -p codesigning 2>/dev/null \
            | grep "Apple Distribution" | grep "$team_id" | head -1 \
            | sed 's/.*"\(.*\)"/\1/' || true)"
    fi
    [[ -z "$id" ]] && id="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Apple Distribution" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)"
    [[ -z "$id" ]] && id="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "iPhone Distribution" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)"
    printf '%s' "$id"
}

# 对 .app 执行资源差异化 / Mach-O 混淆（不改签名）
harden_app_bundle() {
    local app_dir="$1"
    local seed="$2"
    local do_resources="${3:-true}"
    local do_macho="${4:-false}"
    local script_dir="${5:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
    # vendored 闭源 framework 目录名/bundleid 中和（折中方案，默认开；ZT_RENAME_FW=0 可关）
    local do_rename_fw="${6:-true}"
    [[ "${ZT_RENAME_FW:-}" == "0" ]] && do_rename_fw=false
    [[ "${ZT_RENAME_FW:-}" == "1" ]] && do_rename_fw=true
    local obf="$script_dir/obfuscate_ipa.sh"
    [[ -d "$app_dir" ]] || return 1
    [[ -f "$obf" ]] || { echo "[ipa-harden] 未找到 $obf" >&2; return 1; }
    local args=(--app "$app_dir" --seed "$seed")
    [[ "$do_resources" == "true" ]] && args+=(--resources)
    [[ "$do_rename_fw" == "true" ]] && args+=(--rename-frameworks)
    [[ "$do_macho" == "true" ]] && args+=(--macho)
    bash "$obf" "${args[@]}"

    # 成品包二进制指纹中和（须在 obfuscate_ipa 之后、重签名之前执行）：
    #   1) 开发者路径抹除（/Users/... → /dev/null）——ZT_NEUTRALIZE_PATHS=0 可关
    #   2) 业务枚举名中和（装饰性成员名 → 中性等长串）——ZT_NEUTRALIZE_ENUMS=0 可关
    neutralize_bundle_binaries "$app_dir" "$script_dir"
}

# 收集 .app 内的 Mach-O 二进制并做同长度指纹中和
neutralize_bundle_binaries() {
    local app_dir="$1"
    local script_dir="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
    local do_paths="${ZT_NEUTRALIZE_PATHS:-1}"
    local do_enums="${ZT_NEUTRALIZE_ENUMS:-1}"
    [[ "$do_paths" == "0" && "$do_enums" == "0" ]] && return 0

    local paths_py="$script_dir/neutralize_macho_paths.py"
    local enums_py="$script_dir/neutralize_enum_names.py"

    # 枚举所有 Mach-O 二进制（主可执行 + framework/dylib + Flutter App/Dart 快照）
    local -a bins=()
    local f
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        if file "$f" 2>/dev/null | grep -q "Mach-O"; then
            bins+=("$f")
        fi
    done < <(find "$app_dir" -type f \
        \( -perm -u+x -o -name '*.dylib' -o -path '*/Frameworks/*' \) 2>/dev/null)

    [[ ${#bins[@]} -eq 0 ]] && { echo "[ipa-harden] 未发现 Mach-O 二进制，跳过中和"; return 0; }

    if [[ "$do_paths" != "0" && -f "$paths_py" ]]; then
        echo "[ipa-harden] 开发者路径抹除（${#bins[@]} 个二进制）..."
        python3 "$paths_py" "${bins[@]}" | tail -1 || echo "[ipa-harden] 路径抹除部分失败" >&2
    fi
    if [[ "$do_enums" != "0" && -f "$enums_py" ]]; then
        echo "[ipa-harden] 业务枚举名中和（${#bins[@]} 个二进制）..."
        python3 "$enums_py" "${bins[@]}" | tail -1 || echo "[ipa-harden] 枚举中和部分失败" >&2
    fi
}

# 重签名 .app（profile + identity + entitlements）
resign_app_bundle() {
    local app_dir="$1"
    local profile_path="$2"
    local identity="$3"
    local bundle_id="${4:-}"

    [[ -d "$app_dir" ]] || return 1
    [[ -f "$profile_path" ]] || { echo "[ipa-harden] profile 不存在: $profile_path" >&2; return 1; }
    [[ -n "$identity" ]] || { echo "[ipa-harden] 未找到签名身份" >&2; return 1; }

    local tmp
    tmp="$(mktemp -d)"

    security cms -D -i "$profile_path" > "$tmp/profile.plist"
    /usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$tmp/profile.plist" > "$tmp/entitlements.plist"

    if [[ -n "$bundle_id" ]]; then
        local cur
        cur="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_dir/Info.plist" 2>/dev/null || true)"
        if [[ -n "$cur" && "$cur" != "$bundle_id" ]]; then
            /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$app_dir/Info.plist"
        fi
    fi

    rm -rf "$app_dir/_CodeSignature"
    cp "$profile_path" "$app_dir/embedded.mobileprovision"

    if [[ -d "$app_dir/Frameworks" ]]; then
        find "$app_dir/Frameworks" -depth \( -name '*.framework' -o -name '*.dylib' \) 2>/dev/null | while IFS= read -r fw; do
            [[ -n "$fw" ]] && /usr/bin/codesign --force --sign "$identity" --timestamp=none "$fw"
        done
    fi
    if [[ -d "$app_dir/PlugIns" ]]; then
        find "$app_dir/PlugIns" -depth -name '*.appex' 2>/dev/null | while IFS= read -r px; do
            [[ -n "$px" ]] && /usr/bin/codesign --force --sign "$identity" \
                --entitlements "$tmp/entitlements.plist" --timestamp=none "$px"
        done
    fi
    /usr/bin/codesign --force --sign "$identity" \
        --entitlements "$tmp/entitlements.plist" --timestamp=none "$app_dir"
    rm -rf "$tmp"
}

# 解包 IPA → 加固 → 重签 → 覆盖原 IPA
harden_and_resign_ipa() {
    local ipa_path="$1"
    local profile_path="$2"
    local identity="$3"
    local bundle_id="$4"
    local seed="$5"
    local do_resources="${6:-true}"
    local do_macho="${7:-false}"
    local script_dir="${8:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

    [[ -f "$ipa_path" ]] || return 1

    local work
    work="$(mktemp -d)"
    local orig_dir
    orig_dir="$(dirname "$ipa_path")"
    local ipa_name
    ipa_name="$(basename "$ipa_path")"

    cp "$ipa_path" "$work/orig.ipa"
    ( cd "$work" && unzip -q orig.ipa )

    local app_dir
    app_dir="$(find "$work/Payload" -maxdepth 1 -name '*.app' -type d | head -1)"
    [[ -d "$app_dir" ]] || { rm -rf "$work"; return 1; }

    harden_app_bundle "$app_dir" "$seed" "$do_resources" "$do_macho" "$script_dir" \
        || echo "[ipa-harden] 警告: 加固步骤部分失败，继续重签名" >&2

    resign_app_bundle "$app_dir" "$profile_path" "$identity" "$bundle_id" \
        || { rm -rf "$work"; return 1; }

    ( cd "$work" && zip -qr "hardened.ipa" Payload )
    mv "$work/hardened.ipa" "$orig_dir/$ipa_name"
    rm -rf "$work"
    echo "[ipa-harden] 已加固并重签: $orig_dir/$ipa_name"
}

# cocoapods-mangle 默认不自动开：它对 Pod 符号无差别加前缀，会与 framework 混淆的
# run_mutate_pods / differentiate_binary_pod 作用域重叠，且可能破坏闭源 SDK 的运行时
# 字符串查找（NSClassFromString 等）。仅在显式 ZT_POD_MANGLE=1 时启用。
should_auto_pod_mangle() {
    [[ "${ZT_POD_MANGLE:-}" == "1" ]] && return 0
    return 1
}

# 编译期：幂等注入 cocoapods-mangle（pod install 前调用）
maybe_enable_pod_mangle() {
    local enabled="${1:-false}"
    local seed="${2:-}"
    local podfile="${3:-ios/Podfile}"
    local script_dir="${4:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
    [[ "$enabled" == "true" ]] || return 0
    local helper="$script_dir/enable_pod_mangle.sh"
    [[ -f "$helper" ]] || { echo "[ipa-harden] 未找到 $helper，跳过 pod mangle" >&2; return 0; }
    bash "$helper" --podfile "$podfile" --seed "$seed"
}

# 解析 build_config / 环境变量中的加固开关（env 可覆盖 json）
# 用法: read_ipa_hardening_config enabled resources macho pod_mangle seed
# 输出变量名由调用方传入（nameref 模拟：打印 export 语句供 eval）
read_ipa_hardening_config() {
    local jget_fn="$1"
    local bundle_id="${2:-}"

    local enabled resources macho pod_mangle seed

    enabled="$($jget_fn ipa_hardening.enabled false)"
    resources="$($jget_fn ipa_hardening.resources true)"
    macho="$($jget_fn ipa_hardening.macho false)"
    pod_mangle="$($jget_fn ipa_hardening.pod_mangle false)"
    seed="$($jget_fn ipa_hardening.seed "")"
    [[ -z "$seed" ]] && seed="$bundle_id"

    # 环境变量覆盖（兼容手动调试 / CI）
    [[ "${ZT_IPA_OBFUSCATE:-}" == "1" ]] && enabled=true
    [[ "${ZT_IPA_OBFUSCATE:-}" == "0" ]] && enabled=false
    [[ "${ZT_IPA_MACHO:-}" == "1" ]] && macho=true
    [[ "${ZT_IPA_MACHO:-}" == "0" ]] && macho=false
    [[ "${ZT_POD_MANGLE:-}" == "0" ]] && pod_mangle=false
    [[ "${ZT_POD_MANGLE:-}" == "1" ]] && pod_mangle=true
    [[ -n "${ZT_IPA_SEED:-}" ]] && seed="$ZT_IPA_SEED"

    printf '%s\n' "$enabled" "$resources" "$macho" "$pod_mangle" "$seed"
}
