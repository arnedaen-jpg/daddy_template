#!/bin/bash
# =============================================
#   Profile: connectivity_plus (远程依赖)
#   版本: 3.x (Swift + ObjC bridge, Classes/ 结构)
#   iOS 源文件:
#     ios/Classes/
#       ConnectivityPlusPlugin.m             # ObjC 桥接
#       SwiftConnectivityPlusPlugin.swift    # Swift 主实现
#       PathMonitorConnectivityProvider.swift
#       ReachabilityConnectivityProvider.swift
#       ConnectivityProvider.swift           # 协议
#
#   Status: draft
#   注意: v3.x 使用 Classes/ 结构 (非 SPM)，与 v6.x 不同
# =============================================

PROFILE_NAME="connectivity_plus"
PROFILE_VERSION="3"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "ConnectivityPlusPlugin"
    "SwiftConnectivityPlusPlugin"
    "ConnectivityProvider"
    "register"
    "handle"
    "registerWithRegistrar"
    "connectivityUpdateHandler"
    "pathUpdateHandler"
    "reachabilityChanged"
)

PROFILE_SKIP_FILES=()

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    local src_dir="$plugin_dir/ios/Classes"
    [[ -d "$src_dir" ]] || return 1

    bt_inject_classes "$src_dir" "$PROFILE_NAME" 6

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
