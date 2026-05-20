#!/bin/bash
# =============================================
#   Profile: device_info_plus (远程依赖)
#   版本: 11.x (ObjC, SPM 结构)
#   iOS 源文件:
#     ios/device_info_plus/Sources/device_info_plus/
#       FPPDeviceInfoPlusPlugin.m
#       DeviceIdentifiers.m
#
#   Status: draft
#   测试: 待验证
# =============================================

PROFILE_NAME="device_info_plus"
PROFILE_VERSION="11"          # 主版本号，与实际版本校验
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "FPPDeviceInfoPlusPlugin"
    "registerWithRegistrar"
    "handleMethodCall"
)

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    local src_dir
    src_dir=$(bt_find_src_dir "$plugin_dir" "device_info_plus")
    [[ -z "$src_dir" ]] && return 1

    # L0: 注入唯一类
    bt_inject_classes "$src_dir" "$PROFILE_NAME" 5

    # L1: 重命名 static 函数
    if [[ "$level" == "L1" || "$level" == "L2" || "$level" == "L3" ]]; then
        for f in "$src_dir"/*.m; do
            [[ -f "$f" ]] && bt_rename_static_functions "$f" "${PROFILE_PROTECTED[@]}"
        done
    fi

    # L2: 方法顺序打乱
    if [[ "$level" == "L2" || "$level" == "L3" ]]; then
        for f in "$src_dir"/*.m; do
            [[ -f "$f" ]] && bt_reorder_objc_methods "$f"
        done
    fi

    # L3: 死分支注入
    if [[ "$level" == "L3" ]]; then
        for f in "$src_dir"/*.m; do
            [[ -f "$f" ]] && bt_inject_dead_branches "$f"
        done
    fi
}
