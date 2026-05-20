#!/bin/bash
# =============================================
#   Profile: app_installer (远程依赖)
#   版本: 1.x (ObjC, Classes/ 结构)
#   iOS 源文件:
#     ios/Classes/
#       AppInstallerPlugin.m
#
#   Status: draft
# =============================================

PROFILE_NAME="app_installer"
PROFILE_VERSION="1"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "AppInstallerPlugin"
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
