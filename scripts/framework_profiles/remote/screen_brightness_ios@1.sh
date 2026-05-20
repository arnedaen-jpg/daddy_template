#!/bin/bash
# =============================================
#   Profile: screen_brightness_ios (远程依赖，传递依赖)
#   版本: 1.x (Swift+ObjC, Classes/ 结构)
#   iOS 源文件:
#     ios/Classes/
#       ScreenBrightnessIosPlugin.m     # ObjC 壳
#       SwiftScreenBrightnessIosPlugin.swift  # Swift 主实现
#       StreamHandler/
#         BaseStreamHandler.swift
#         CurrentBrightnessChangeStreamHandler.swift
#
#   Status: draft
# =============================================

PROFILE_NAME="screen_brightness_ios"
PROFILE_VERSION="1"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "ScreenBrightnessIosPlugin"
    "SwiftScreenBrightnessIosPlugin"
    "registerWithRegistrar"
    "register"
    "handle"
)

PROFILE_SKIP_FILES=()

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    local src_dir="$plugin_dir/ios/Classes"
    [[ -d "$src_dir" ]] || return 1

    bt_inject_classes "$src_dir" "$PROFILE_NAME" 6

    if [[ "$level" == "L1" || "$level" == "L2" || "$level" == "L3" ]]; then
        for f in "$src_dir"/*.m; do
            [[ -f "$f" ]] && bt_rename_static_functions "$f" "${PROFILE_PROTECTED[@]}"
        done
        while IFS= read -r f; do
            [[ -f "$f" ]] && bt_rename_swift_privates "$f" "${PROFILE_PROTECTED[@]}"
        done < <(find "$src_dir" -name "*.swift" -type f 2>/dev/null)
    fi

    if [[ "$level" == "L2" || "$level" == "L3" ]]; then
        for f in "$src_dir"/*.m; do
            [[ -f "$f" ]] && bt_reorder_objc_methods "$f"
        done
        while IFS= read -r f; do
            [[ -f "$f" ]] && bt_reorder_swift_methods "$f"
        done < <(find "$src_dir" -name "*.swift" -type f 2>/dev/null)
    fi

    if [[ "$level" == "L3" ]]; then
        for f in "$src_dir"/*.m; do
            [[ -f "$f" ]] && bt_inject_dead_branches "$f"
        done
        while IFS= read -r f; do
            [[ -f "$f" ]] && bt_inject_swift_dead_branches "$f"
        done < <(find "$src_dir" -name "*.swift" -type f 2>/dev/null)
    fi
}
