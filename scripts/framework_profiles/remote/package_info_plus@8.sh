#!/bin/bash
# =============================================
#   Profile: package_info_plus (remote)
#   Version: 8.x (ObjC, SPM layout)
#   iOS 源文件:
#     ios/package_info_plus/Sources/package_info_plus/FPPPackageInfoPlusPlugin.m
#
#   Status: draft
#   注意: 8.x 与 9.x 同为 SPM ObjC 结构、同一主类 FPPPackageInfoPlusPlugin；
#         已对 dq package_info_plus-8.3.1 实测一致。其他 8.x 项目仅因未写 @8 profile 才停在 L0。
# =============================================

PROFILE_NAME="package_info_plus"
PROFILE_VERSION="8"
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
