#!/bin/bash
# ipa_hardening_lib.sh —— AB 包工厂成品包加固共享函数
# 被 build_flutter_ipa.sh / resign_ipa.sh 等 source 使用。
set -euo pipefail

# 解析签名身份：优先用传入值；否则按 Team + 用途选择。
# 真机直装需要 Development / Ad Hoc；默认优先 Development，避免误用 Distribution
# 导致 0xe8008015（valid provisioning profile not found）。
# 导出上架包时显式传 --identity "Apple Distribution: …"。
resolve_codesign_identity() {
    local team_id="${1:-}"
    local override="${2:-}"
    if [[ -n "$override" ]]; then
        printf '%s' "$override"
        return 0
    fi
    # ZT_CODESIGN_IDENTITY 可强制指定（含 Distribution）
    if [[ -n "${ZT_CODESIGN_IDENTITY:-}" ]]; then
        printf '%s' "$ZT_CODESIGN_IDENTITY"
        return 0
    fi
    local prefer="${ZT_CODESIGN_PREFER:-development}"  # development | distribution
    local id=""
    local list
    list="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    # 从显示名取证书 subject 的 OU（Team ID）。
    # Apple Development 显示名括号内是个人 ID，不是 Team ID，不能靠 grep team_id。
    _identity_team_ou() {
        local name="$1"
        security find-certificate -c "$name" -p 2>/dev/null \
            | openssl x509 -noout -subject 2>/dev/null \
            | sed -n 's/.*OU=\([^/,]*\).*/\1/p' | head -1 || true
    }
    _pick() {
        local pat="$1"
        local line name ou
        while IFS= read -r line; do
            [[ "$line" == *"$pat"* ]] || continue
            name="$(printf '%s\n' "$line" | sed 's/.*"\(.*\)"/\1/')"
            [[ -n "$name" ]] || continue
            if [[ -z "$team_id" ]]; then
                printf '%s' "$name"
                return 0
            fi
            # 显示名含 Team ID（Distribution 常见）或证书 OU 匹配
            if [[ "$name" == *"$team_id"* ]]; then
                printf '%s' "$name"
                return 0
            fi
            ou="$(_identity_team_ou "$name")"
            if [[ "$ou" == "$team_id" ]]; then
                printf '%s' "$name"
                return 0
            fi
        done < <(printf '%s\n' "$list")
        return 0
    }
    if [[ "$prefer" == "distribution" ]]; then
        id="$(_pick "Apple Distribution")"
        [[ -z "$id" ]] && id="$(_pick "iPhone Distribution")"
        [[ -z "$id" ]] && id="$(_pick "Apple Development")"
    else
        id="$(_pick "Apple Development")"
        [[ -z "$id" ]] && id="$(_pick "iPhone Developer")"
        # 真机 development profile 绝不能落到 Distribution，否则 0xe8008015
        [[ -z "$id" ]] && id="$(_pick "Apple Distribution")"
    fi
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
    #   3) SDK what-string 品牌中和——ZT_NEUTRALIZE_BRANDS=0 可关
    #   4) LC_UUID 重写——ZT_REWRITE_UUIDS=0 可关
    #   5) LC_SOURCE_VERSION 重写——ZT_REWRITE_SOURCE_VERSION=0 可关
    #   6) LC SDK 版本字段扰动——ZT_REWRITE_SDK_VERSION=0 可关
    SEED="$seed" neutralize_bundle_binaries "$app_dir" "$script_dir"

    # Info.plist 构建元数据抹除（DTXcode 等）——ZT_NEUTRALIZE_PLIST_META=0 可关
    if [[ "${ZT_NEUTRALIZE_PLIST_META:-1}" != "0" ]]; then
        local plist_py="$script_dir/neutralize_info_plist_meta.py"
        if [[ -f "$plist_py" ]]; then
            echo "[ipa-harden] Info.plist 构建元数据抹除..."
            python3 "$plist_py" "$app_dir" | tail -1 \
                || echo "[ipa-harden] plist 元数据抹除部分失败" >&2
        fi
    fi

    # PrivacyInfo 键序扰动——ZT_NEUTRALIZE_PRIVACY=0 可关
    if [[ "${ZT_NEUTRALIZE_PRIVACY:-1}" != "0" ]]; then
        local priv_py="$script_dir/neutralize_privacy_manifests.py"
        if [[ -f "$priv_py" ]]; then
            echo "[ipa-harden] PrivacyInfo 键序扰动..."
            python3 "$priv_py" --seed "$seed" "$app_dir" | tail -1 \
                || echo "[ipa-harden] PrivacyInfo 扰动部分失败" >&2
        fi
    fi

    # Assets.car 尾部填充扰动——ZT_PERTURB_ASSETS_CAR=0 可关
    if [[ "${ZT_PERTURB_ASSETS_CAR:-1}" != "0" ]]; then
        local car_py="$script_dir/perturb_assets_car.py"
        if [[ -f "$car_py" ]]; then
            echo "[ipa-harden] Assets.car 尾部填充扰动..."
            python3 "$car_py" --seed "$seed" "$app_dir" | tail -1 \
                || echo "[ipa-harden] Assets.car 扰动部分失败" >&2
        fi
    fi

    # gzip 头扰动（NOTICES.Z 等）——ZT_PERTURB_GZIP=0 可关
    if [[ "${ZT_PERTURB_GZIP:-1}" != "0" ]]; then
        local gz_py="$script_dir/perturb_gzip_headers.py"
        if [[ -f "$gz_py" ]]; then
            echo "[ipa-harden] gzip 头扰动..."
            python3 "$gz_py" --seed "$seed" "$app_dir" | tail -1 \
                || echo "[ipa-harden] gzip 头扰动部分失败" >&2
        fi
    fi

    # PkgInfo / gitkeep / html / js 标记扰动——ZT_PERTURB_MARKERS=0 可关
    if [[ "${ZT_PERTURB_MARKERS:-1}" != "0" ]]; then
        local mark_py="$script_dir/perturb_bundle_markers.py"
        if [[ -f "$mark_py" ]]; then
            echo "[ipa-harden] 包内标记扰动..."
            python3 "$mark_py" --seed "$seed" "$app_dir" | tail -1 \
                || echo "[ipa-harden] 包内标记扰动部分失败" >&2
        fi
    fi

    # L292：文本资源品牌擦除（隐私政策 HTML 等）——ZT_SCRUB_TEXT_BRANDS=0 可关
    if [[ "${ZT_SCRUB_TEXT_BRANDS:-1}" != "0" ]]; then
        local scrub_py="$script_dir/scrub_text_brand_strings.py"
        if [[ -f "$scrub_py" ]]; then
            echo "[ipa-harden] 文本资源 SDK 品牌擦除..."
            python3 "$scrub_py" "$app_dir" "$seed" | tail -1 \
                || echo "[ipa-harden] 文本品牌擦除部分失败" >&2
        fi
    fi

    # JSON seed 标记（NativeAssets / Lottie）——ZT_PERTURB_JSON=0 可关
    if [[ "${ZT_PERTURB_JSON:-1}" != "0" ]]; then
        local json_py="$script_dir/perturb_json_markers.py"
        if [[ -f "$json_py" ]]; then
            echo "[ipa-harden] JSON 标记扰动..."
            python3 "$json_py" --seed "$seed" "$app_dir" | tail -1 \
                || echo "[ipa-harden] JSON 标记扰动部分失败" >&2
        fi
    fi

    # framework 版本号 / cocoapods bid 中和——ZT_NEUTRALIZE_FW_PLIST=0 可关
    if [[ "${ZT_NEUTRALIZE_FW_PLIST:-1}" != "0" ]]; then
        local fwpl_py="$script_dir/neutralize_framework_plist_versions.py"
        if [[ -f "$fwpl_py" ]]; then
            echo "[ipa-harden] framework Info.plist 版本中和..."
            python3 "$fwpl_py" --seed "$seed" "$app_dir" | tail -1 \
                || echo "[ipa-harden] framework plist 版本中和部分失败" >&2
        fi
    fi

    # Info.plist 指纹扰动（须在 fw plist 版本中和之后，避免被覆盖）
    # ——ZT_NEUTRALIZE_PLIST_ORDER=0 可关
    if [[ "${ZT_NEUTRALIZE_PLIST_ORDER:-1}" != "0" ]]; then
        local order_py="$script_dir/neutralize_info_plist_order.py"
        if [[ -f "$order_py" ]]; then
            echo "[ipa-harden] Info.plist 指纹扰动..."
            python3 "$order_py" --seed "$seed" "$app_dir" | tail -1 \
                || echo "[ipa-harden] Info.plist 指纹扰动部分失败" >&2
        fi
    fi

    # 剥离 Headers/Modules——ZT_STRIP_FW_HEADERS=0 可关
    if [[ "${ZT_STRIP_FW_HEADERS:-1}" != "0" ]]; then
        local strip_py="$script_dir/strip_framework_headers.py"
        if [[ -f "$strip_py" ]]; then
            echo "[ipa-harden] 剥离 framework Headers/Modules..."
            python3 "$strip_py" "$app_dir" | tail -1 \
                || echo "[ipa-harden] Headers 剥离部分失败" >&2
        fi
    fi

    # RCConfig.plist 等长改名 + cstring 同步——ZT_RENAME_RCCONFIG=0 可关
    if [[ "${ZT_RENAME_RCCONFIG:-1}" != "0" ]]; then
        local rcc_py="$script_dir/rename_rcconfig_plist.py"
        if [[ -f "$rcc_py" ]]; then
            echo "[ipa-harden] RCConfig.plist 改名..."
            python3 "$rcc_py" --seed "$seed" "$app_dir" | tail -1 \
                || echo "[ipa-harden] RCConfig 改名部分失败" >&2
        fi
    fi
}

# 收集 .app 内的 Mach-O 二进制并做同长度指纹中和
neutralize_bundle_binaries() {
    local app_dir="$1"
    local script_dir="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
    local do_paths="${ZT_NEUTRALIZE_PATHS:-1}"
    local do_enums="${ZT_NEUTRALIZE_ENUMS:-1}"
    local do_brands="${ZT_NEUTRALIZE_BRANDS:-1}"
    local do_uuids="${ZT_REWRITE_UUIDS:-1}"
    local do_srcver="${ZT_REWRITE_SOURCE_VERSION:-1}"
    local do_sdkver="${ZT_REWRITE_SDK_VERSION:-1}"
    [[ "$do_paths" == "0" && "$do_enums" == "0" && "$do_brands" == "0" && "$do_uuids" == "0" && "$do_srcver" == "0" && "$do_sdkver" == "0" ]] && return 0

    local paths_py="$script_dir/neutralize_macho_paths.py"
    local enums_py="$script_dir/neutralize_enum_names.py"
    local brands_py="$script_dir/neutralize_sdk_brand_strings.py"
    local uuids_py="$script_dir/rewrite_macho_uuids.py"
    local srcver_py="$script_dir/rewrite_macho_source_versions.py"
    local sdkver_py="$script_dir/rewrite_macho_sdk_versions.py"

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
    if [[ "$do_brands" != "0" && -f "$brands_py" ]]; then
        local brand_seed="${ZT_SEED:-${SEED:-com.app.brand}}"
        echo "[ipa-harden] SDK what-string 品牌中和（${#bins[@]} 个二进制）..."
        python3 "$brands_py" --seed "$brand_seed" "${bins[@]}" | tail -1 \
            || echo "[ipa-harden] 品牌中和部分失败" >&2
    fi
    if [[ "$do_uuids" != "0" && -f "$uuids_py" ]]; then
        local uuid_seed="${ZT_SEED:-${SEED:-com.app.brand}}"
        echo "[ipa-harden] LC_UUID 重写（${#bins[@]} 个二进制）..."
        python3 "$uuids_py" --seed "$uuid_seed" "${bins[@]}" | tail -1 \
            || echo "[ipa-harden] UUID 重写部分失败" >&2
    fi
    if [[ "$do_srcver" != "0" && -f "$srcver_py" ]]; then
        local srcver_seed="${ZT_SEED:-${SEED:-com.app.brand}}"
        echo "[ipa-harden] LC_SOURCE_VERSION 重写（${#bins[@]} 个二进制）..."
        python3 "$srcver_py" --seed "$srcver_seed" "${bins[@]}" | tail -1 \
            || echo "[ipa-harden] SOURCE_VERSION 重写部分失败" >&2
    fi
    if [[ "$do_sdkver" != "0" && -f "$sdkver_py" ]]; then
        local sdkver_seed="${ZT_SEED:-${SEED:-com.app.brand}}"
        echo "[ipa-harden] LC SDK 版本字段扰动（${#bins[@]} 个二进制）..."
        python3 "$sdkver_py" --seed "$sdkver_seed" "${bins[@]}" | tail -1 \
            || echo "[ipa-harden] SDK 版本扰动部分失败" >&2
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

    # 描述文件 application-identifier 决定可安装的 Bundle ID。
    # 若加固/UI 把 CFBundleIdentifier 改成随机值却仍嵌旧 profile，会触发 0xe8008015。
    local prof_app_id expected_bid
    prof_app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$tmp/profile.plist" 2>/dev/null || true)"
    expected_bid=""
    if [[ -n "$prof_app_id" && "$prof_app_id" != *"*"* ]]; then
        # TEAMID.bundle.id → bundle.id
        expected_bid="${prof_app_id#*.}"
    fi
    if [[ -n "$expected_bid" ]]; then
        if [[ -n "$bundle_id" && "$bundle_id" != "$expected_bid" ]]; then
            echo "[ipa-harden] 警告: --bundle-id=$bundle_id 与 profile($expected_bid) 不一致，以 profile 为准" >&2
        fi
        bundle_id="$expected_bid"
    fi
    if [[ -n "$bundle_id" ]]; then
        local cur
        cur="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_dir/Info.plist" 2>/dev/null || true)"
        if [[ -n "$cur" && "$cur" != "$bundle_id" ]]; then
            /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$app_dir/Info.plist"
            echo "[ipa-harden] CFBundleIdentifier: $cur → $bundle_id" >&2
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

    local pack_py="$script_dir/pack_ipa_seeded.py"
    if [[ -f "$pack_py" && "${ZT_SEED_ZIP_DATE:-1}" != "0" ]]; then
        python3 "$pack_py" --seed "$seed" --out "$work/hardened.ipa" "$work" \
            || ( cd "$work" && zip -qr "hardened.ipa" Payload )
    else
        ( cd "$work" && zip -qr "hardened.ipa" Payload )
    fi
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
