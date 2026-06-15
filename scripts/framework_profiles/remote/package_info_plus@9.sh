#!/bin/bash
# =============================================
#   Profile: package_info_plus (remote)
#   Version: 9.x (ObjC, SPM layout)
# =============================================

PROFILE_NAME="package_info_plus"
PROFILE_VERSION="9"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "FPPPackageInfoPlusPlugin"
    "registerWithRegistrar"
    "handleMethodCall"
)

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    local src_dir
    src_dir=$(bt_find_src_dir "$plugin_dir" "package_info_plus")
    [[ -z "$src_dir" ]] && return 1

    bt_inject_classes "$src_dir" "$PROFILE_NAME" 5

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
