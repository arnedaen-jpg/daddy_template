#!/bin/bash
# =============================================
#   Profile: webcrypto (远程依赖)
#   版本: 0.x (Swift+ObjC, darwin/Classes/ 结构)
#   iOS 源文件:
#     darwin/Classes/
#       WebcryptoPlugin.m       # ObjC 壳
#       SwiftWebcryptoPlugin.swift  # Swift 实现
#
#   Status: draft
# =============================================

PROFILE_NAME="webcrypto"
PROFILE_VERSION="0"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "WebcryptoPlugin"
    "SwiftWebcryptoPlugin"
    "registerWithRegistrar"
    "register"
    "handle"
)

PROFILE_SKIP_FILES=()

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    local src_dir="$plugin_dir/darwin/Classes"
    [[ -d "$src_dir" ]] || src_dir="$plugin_dir/ios/Classes"
    [[ -d "$src_dir" ]] || return 1

    bt_inject_classes "$src_dir" "$PROFILE_NAME" 6

    if [[ "$level" == "L1" || "$level" == "L2" || "$level" == "L3" ]]; then
        for f in "$src_dir"/*.m; do
            [[ -f "$f" ]] && bt_rename_static_functions "$f" "${PROFILE_PROTECTED[@]}"
        done
        for f in "$src_dir"/*.swift; do
            [[ -f "$f" ]] && bt_rename_swift_privates "$f" "${PROFILE_PROTECTED[@]}"
        done
    fi

    if [[ "$level" == "L2" || "$level" == "L3" ]]; then
        for f in "$src_dir"/*.m; do
            [[ -f "$f" ]] && bt_reorder_objc_methods "$f"
        done
        for f in "$src_dir"/*.swift; do
            [[ -f "$f" ]] && bt_reorder_swift_methods "$f"
        done
    fi

    if [[ "$level" == "L3" ]]; then
        for f in "$src_dir"/*.m; do
            [[ -f "$f" ]] && bt_inject_dead_branches "$f"
        done
        for f in "$src_dir"/*.swift; do
            [[ -f "$f" ]] && bt_inject_swift_dead_branches "$f"
        done
    fi
}
