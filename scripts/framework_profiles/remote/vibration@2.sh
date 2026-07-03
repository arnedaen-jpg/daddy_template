#!/bin/bash
# =============================================
#   Profile: vibration (远程依赖)
#   版本: 2.x (Swift + ObjC bridge, Classes/ 结构)
#   iOS 源文件:
#     ios/Classes/
#       VibrationPlugin.m           # ObjC 桥接
#       VibrationPluginSwift.swift  # Swift 主实现 (CoreHaptics)
#
#   Status: draft
#   注意: v2.x 与 v1.x 同为 Classes/ 结构（非 SPM）；已对 dq vibration-2.1.0 实测结构一致。
#         本 profile 让 v2.x 同样可达 L3。
# =============================================

PROFILE_NAME="vibration"
PROFILE_VERSION="2"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "VibrationPlugin"
    "VibrationPluginSwift"
    "register"
    "handle"
    "registerWithRegistrar"
    "createEngine"
    "engine"
    "supportsHaptics"
    "supportsAudio"
)

PROFILE_SKIP_FILES=()

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
        for f in "$src_dir"/*.m; do
            [[ -f "$f" ]] && bt_rename_static_functions "$f" "${PROFILE_PROTECTED[@]}"
        done
    fi

    if [[ "$level" == "L2" || "$level" == "L3" ]]; then
        for f in "$src_dir"/*.swift; do
            [[ -f "$f" ]] && bt_reorder_swift_methods "$f"
        done
        for f in "$src_dir"/*.m; do
            [[ -f "$f" ]] && bt_reorder_objc_methods "$f"
        done
    fi

    if [[ "$level" == "L3" ]]; then
        for f in "$src_dir"/*.swift; do
            [[ -f "$f" ]] && bt_inject_swift_dead_branches "$f"
        done
        for f in "$src_dir"/*.m; do
            [[ -f "$f" ]] && bt_inject_dead_branches "$f"
        done
    fi
}
