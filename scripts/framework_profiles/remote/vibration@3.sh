#!/bin/bash
# =============================================
#   Profile: vibration (远程依赖)
#   版本: 3.x (Swift, SPM 结构)
#   iOS 源文件:
#     ios/vibration/Sources/vibration/
#       VibrationPlugin.swift
#
#   Status: draft
# =============================================

PROFILE_NAME="vibration"
PROFILE_VERSION="3"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "VibrationPlugin"
    "register"
    "handle"
)

PROFILE_SKIP_FILES=()

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    local src_dir
    src_dir=$(bt_find_src_dir "$plugin_dir" "vibration")
    [[ -z "$src_dir" ]] && return 1

    bt_inject_classes "$src_dir" "$PROFILE_NAME" 6

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
