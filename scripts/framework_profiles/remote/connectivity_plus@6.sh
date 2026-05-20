#!/bin/bash
# =============================================
#   Profile: connectivity_plus (远程依赖)
#   版本: 6.1.x (Swift, SPM 结构)
#   iOS 源文件:
#     ios/connectivity_plus/Sources/connectivity_plus/
#       ConnectivityPlusPlugin.swift
#       PathMonitorConnectivityProvider.swift
#       ConnectivityProvider.swift
#   
#   Status: draft
#   测试: 待验证
# =============================================

PROFILE_NAME="connectivity_plus"
PROFILE_VERSION="6.1"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "ConnectivityPlusPlugin"
    "register"
    "handle"
    "ConnectivityProvider"
)

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    # 查找源码目录
    local src_dir
    src_dir=$(bt_find_src_dir "$plugin_dir" "connectivity_plus")
    [[ -z "$src_dir" ]] && return 1

    # L0: 注入唯一类
    bt_inject_classes "$src_dir" "$PROFILE_NAME" 6

    # L1: 重命名 private 符号
    if [[ "$level" == "L1" || "$level" == "L2" || "$level" == "L3" ]]; then
        for f in "$src_dir"/*.swift; do
            [[ -f "$f" ]] && bt_rename_swift_privates "$f" "${PROFILE_PROTECTED[@]}"
        done
    fi

    # L2: 方法顺序打乱
    if [[ "$level" == "L2" || "$level" == "L3" ]]; then
        for f in "$src_dir"/*.swift; do
            [[ -f "$f" ]] && bt_reorder_swift_methods "$f"
        done
    fi

    # L3: 死分支注入
    if [[ "$level" == "L3" ]]; then
        for f in "$src_dir"/*.swift; do
            [[ -f "$f" ]] && bt_inject_swift_dead_branches "$f"
        done
    fi
}
