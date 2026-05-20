#!/bin/bash
# =============================================
#   Profile: fluttertoast (远程依赖)
#   版本: 8.x (ObjC, Classes/ 结构)
#   iOS 源文件:
#     ios/Classes/
#       <Plugin>Plugin.m          # 主插件类
#       UIView+Toast.m            # Toast 实现
#
#   Status: draft
# =============================================

PROFILE_NAME="fluttertoast"
PROFILE_VERSION="8"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "registerWithRegistrar"
    "handleMethodCall"
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
    fi

    if [[ "$level" == "L2" || "$level" == "L3" ]]; then
        for f in "$src_dir"/*.m; do
            [[ -f "$f" ]] && bt_reorder_objc_methods "$f"
        done
    fi

    if [[ "$level" == "L3" ]]; then
        for f in "$src_dir"/*.m; do
            [[ -f "$f" ]] && bt_inject_dead_branches "$f"
        done
    fi
}
