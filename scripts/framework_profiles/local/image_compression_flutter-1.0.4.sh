#!/bin/bash
# =============================================
#   Profile: image_compression_flutter-1.0.4 (本地 fork 依赖)
#   iOS 源文件 (Swift + ObjC bridge):
#     ios/Classes/
#       Swift<Plugin>Plugin.swift    # Swift 主实现
#       <Plugin>Plugin.m             # ObjC 桥接
#
#   Status: draft
#   注意: ObjC Plugin.m 仅做桥接调用，主逻辑在 Swift 中
# =============================================

PROFILE_NAME="image_compression_flutter-1.0.4"
PROFILE_VERSION="local"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "register"
    "handle"
    "registerWithRegistrar"
)

PROFILE_SKIP_FILES=()

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    local src_dir="$plugin_dir/ios/Classes"
    [[ -d "$src_dir" ]] || return 1

    bt_inject_classes "$src_dir" "image_compression" 5

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
