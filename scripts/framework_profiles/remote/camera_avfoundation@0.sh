#!/bin/bash
# =============================================
#   Profile: camera_avfoundation (远程依赖，传递依赖)
#   版本: 0.x (Swift + ObjC Pigeon, SPM 结构)
#   iOS 源文件:
#     ios/camera_avfoundation/Sources/camera_avfoundation/
#       CameraPlugin.swift           # 主插件类
#       Camera.swift, DefaultCamera.swift
#       AssetWriter.swift, CaptureDevice.swift 等 (17+ Swift 文件)
#     ios/camera_avfoundation/Sources/camera_avfoundation_objc/
#       messages.g.m                 # Pigeon 生成 (不可修改)
#
#   Status: draft
#   注意: messages.g.m 是 Pigeon 自动生成的，必须跳过
# =============================================

PROFILE_NAME="camera_avfoundation"
PROFILE_VERSION="0"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "CameraPlugin"
    "register"
    "handle"
    "CameraPermissionManager"
    "CameraDeviceDiscoverer"
)

PROFILE_SKIP_FILES=(
    "messages.g.m"
    "messages.g.h"
)

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    local src_dir
    src_dir=$(bt_find_src_dir "$plugin_dir" "camera_avfoundation")
    [[ -z "$src_dir" ]] && return 1

    bt_inject_classes "$src_dir" "$PROFILE_NAME" 8

    if [[ "$level" == "L1" || "$level" == "L2" || "$level" == "L3" ]]; then
        for f in "$src_dir"/*.swift; do
            [[ -f "$f" ]] && bt_rename_swift_privates "$f" "${PROFILE_PROTECTED[@]}"
        done
    fi

    if [[ "$level" == "L2" || "$level" == "L3" ]]; then
        for f in "$src_dir"/*.swift; do
            [[ -f "$f" ]] && bt_reorder_swift_methods "$f"
        done
    fi

    if [[ "$level" == "L3" ]]; then
        for f in "$src_dir"/*.swift; do
            [[ -f "$f" ]] && bt_inject_swift_dead_branches "$f"
        done
    fi
}
