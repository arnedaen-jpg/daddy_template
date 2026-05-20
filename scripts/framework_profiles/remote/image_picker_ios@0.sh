#!/bin/bash
# =============================================
#   Profile: image_picker_ios (远程依赖，传递依赖)
#   版本: 0.8.x (ObjC, SPM 结构)
#   iOS 源文件:
#     ios/image_picker_ios/Sources/image_picker_ios/
#       FLTImagePickerPlugin.m          # 主插件类
#       FLTImagePickerImageUtil.m       # 图片工具
#       FLTImagePickerPhotoAssetUtil.m  # PHAsset 工具
#       FLTImagePickerMetaDataUtil.m    # 元数据工具
#       FLTPHPickerSaveImageToPathOperation.m  # PHPicker 操作
#       messages.g.m                    # Pigeon 生成 ← 不可修改
#
#   Status: draft
#   测试: 待验证
#   注意: messages.g.* 是 Pigeon 自动生成的，修改会破坏 Dart↔Native 通信
# =============================================

PROFILE_NAME="image_picker_ios"
PROFILE_VERSION="0.8"
PROFILE_STATUS="draft"

# 公开 API / Flutter 注册入口 / Pigeon 通信符号 — 不可重命名
PROFILE_PROTECTED=(
    "FLTImagePickerPlugin"
    "registerWithRegistrar"
    "handleMethodCall"
    "FLTImagePickerMethodCallContext"
    # Pigeon 生成的消息类
    "FLTImagePickerApi"
    "FLTSourceSpecification"
    "FLTMaxSize"
    "FLTMediaSelectionOptions"
)

# Pigeon 生成文件 — 完全跳过
PROFILE_SKIP_FILES=(
    "messages.g.m"
    "messages.g.h"
)

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    local src_dir
    src_dir=$(bt_find_src_dir "$plugin_dir" "image_picker_ios")
    [[ -z "$src_dir" ]] && return 1

    # L0: 注入唯一类
    bt_inject_classes "$src_dir" "$PROFILE_NAME" 6

    # L1+: 重命名非 Pigeon 文件中的 static 函数
    if [[ "$level" == "L1" || "$level" == "L2" || "$level" == "L3" ]]; then
        for f in "$src_dir"/*.m; do
            [[ -f "$f" ]] || continue
            local fname
            fname=$(basename "$f")

            local skip=false
            for sf in "${PROFILE_SKIP_FILES[@]}"; do
                [[ "$fname" == "$sf" ]] && skip=true && break
            done
            [[ "$skip" == "true" ]] && continue

            bt_rename_static_functions "$f" "${PROFILE_PROTECTED[@]}"
        done
    fi

    # L2+: 方法顺序打乱
    if [[ "$level" == "L2" || "$level" == "L3" ]]; then
        for f in "$src_dir"/*.m; do
            [[ -f "$f" ]] || continue
            local fname
            fname=$(basename "$f")
            local skip=false
            for sf in "${PROFILE_SKIP_FILES[@]}"; do
                [[ "$fname" == "$sf" ]] && skip=true && break
            done
            [[ "$skip" == "true" ]] && continue
            bt_reorder_objc_methods "$f"
        done
    fi

    # L3: 死分支注入
    if [[ "$level" == "L3" ]]; then
        for f in "$src_dir"/*.m; do
            [[ -f "$f" ]] || continue
            local fname
            fname=$(basename "$f")
            local skip=false
            for sf in "${PROFILE_SKIP_FILES[@]}"; do
                [[ "$fname" == "$sf" ]] && skip=true && break
            done
            [[ "$skip" == "true" ]] && continue
            bt_inject_dead_branches "$f"
        done
    fi
}
