#!/bin/bash
# =============================================
#   Profile: heif_converter_plus (远程依赖)
#   版本: 1.x (Swift, Classes/ 结构)
#   iOS 源文件:
#     ios/Classes/
#       HeifConverterPlugin.swift
#
#   Status: draft
# =============================================

PROFILE_NAME="heif_converter_plus"
PROFILE_VERSION="1"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "HeifConverterPlugin"
    "register"
    "handle"
)

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    local src_dir="$plugin_dir/ios/Classes"
    [[ -d "$src_dir" ]] || return 1

    bt_inject_classes "$src_dir" "$PROFILE_NAME" 5

    if [[ "$level" == "L1" || "$level" == "L2" || "$level" == "L3" ]]; then
        for f in "$src_dir"/*.swift; do
            [[ -f "$f" ]] && bt_rename_swift_privates "$f" "${PROFILE_PROTECTED[@]}"
        done
    fi

    if [[ "$level" == "L2" || "$level" == "L3" ]]; then
        for f in "$src_dir"/*.swift; do
            [[ -f "$f" ]] && bt_reorder_swift_methods "$f"
        done
    fi

    if [[ "$level" == "L3" ]]; then
        for f in "$src_dir"/*.swift; do
            [[ -f "$f" ]] && bt_inject_swift_dead_branches "$f"
        done
    fi
}
